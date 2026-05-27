import Foundation
import CryptoKit

public protocol CursorSDKHarness: Sendable {
    func validate(settings: CursorAPISettings, authorization: String?) throws
    func stream(prepared: PreparedChatRequest, settings: CursorAPISettings, authorization: String?) -> AsyncThrowingStream<CursorSDKStreamEvent, any Error>
}

public enum CursorSDKStreamEvent: Sendable, Equatable {
    case text(String)
    case toolCall(CursorToolCall)
    case done(CursorSDKOutput)
}

public extension CursorSDKHarness {
    func validate(settings: CursorAPISettings, authorization: String?) throws {}

    func complete(prepared: PreparedChatRequest, settings: CursorAPISettings, authorization: String?) async throws -> CursorSDKOutput {
        var text = ""
        var toolCalls: [CursorToolCall] = []
        var finalOutput: CursorSDKOutput?
        for try await event in stream(prepared: prepared, settings: settings, authorization: authorization) {
            switch event {
            case .text(let delta):
                text += delta
            case .toolCall(let toolCall):
                toolCalls.append(toolCall)
            case .done(let final):
                finalOutput = final
            }
        }
        if var output = finalOutput {
            if output.text.isEmpty, !text.isEmpty {
                output.text = text
            }
            if output.toolCalls.isEmpty, !toolCalls.isEmpty {
                output.toolCalls = toolCalls
            }
            return output
        }
        return CursorSDKOutput(text: text, toolCalls: toolCalls, agentID: "", runID: "")
    }
}

public struct LocalCursorSDKHarness: CursorSDKHarness {
    private static let sessionStore = CursorSDKSessionStore(maxEntries: 512)
    private static let accessTokenCache = CursorSDKAccessTokenCache(ttl: 10 * 60, maxEntries: 64)
    private static let toolRetryAttempts = 3

    public init() {}

    public func validate(settings: CursorAPISettings, authorization: String?) throws {
        guard settings.hasCursorSDKConfiguration else {
            throw CursorAPIError.invalidConfiguration("This \(CursorAPIBrand.displayName) build is missing its bundled Composer transport. Repackage the app with release defaults or inspect Settings > Advanced Transport Overrides.")
        }
        let apiKey = try Self.resolvedCursorAPIKeyForRequest(from: authorization, settings: settings)
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CursorAPIError.unauthorized
        }
    }

    public func stream(prepared: PreparedChatRequest, settings: CursorAPISettings, authorization: String?) -> AsyncThrowingStream<CursorSDKStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try validate(settings: settings, authorization: authorization)
                    let apiKey = try Self.resolvedCursorAPIKeyForRequest(from: authorization, settings: settings)
                    let agentID = await Self.sessionStore.agentID(for: prepared.sessionKey)
                    let runID = Self.newRunID()
                    let tokenOrigin = settings.cursorAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    let accessToken = try await Self.accessTokenCache.token(for: apiKey, origin: tokenOrigin) {
                        try await exchangeCursorAPIKey(apiKey, settings: settings)
                    }
                    let output: CursorSDKOutput
                    do {
                        output = try await runSDKRequestWithToolRetry(
                            agentID: agentID,
                            runID: runID,
                            prepared: prepared,
                            accessToken: accessToken,
                            settings: settings,
                            onEvent: { continuation.yield($0) }
                        )
                    } catch CursorAPIError.unauthorized {
                        await Self.accessTokenCache.invalidate(apiKey: apiKey, origin: tokenOrigin)
                        let refreshedToken = try await Self.accessTokenCache.token(for: apiKey, origin: tokenOrigin) {
                            try await exchangeCursorAPIKey(apiKey, settings: settings)
                        }
                        output = try await runSDKRequestWithToolRetry(
                            agentID: agentID,
                            runID: runID,
                            prepared: prepared,
                            accessToken: refreshedToken,
                            settings: settings,
                            onEvent: { continuation.yield($0) }
                        )
                    }
                    continuation.yield(.done(output))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func runSDKRequestWithToolRetry(
        agentID: String,
        runID: String,
        prepared: PreparedChatRequest,
        accessToken: String,
        settings: CursorAPISettings,
        onEvent: @escaping @Sendable (CursorSDKStreamEvent) -> Void
    ) async throws -> CursorSDKOutput {
        let shouldRetryMissing = shouldRetryMissingLocalTool(prepared)
        guard shouldRetryMissing || !prepared.tools.isEmpty else {
            return try await runSDKRequest(
                agentID: agentID,
                runID: runID,
                prepared: prepared,
                accessToken: accessToken,
                settings: settings,
                onEvent: onEvent
            )
        }

        var attemptPrepared = prepared
        for attempt in 1...Self.toolRetryAttempts {
            let buffered = LockedEventBuffer()
            let output = try await runSDKRequest(
                agentID: agentID,
                runID: attempt == 1 ? runID : Self.newRunID(),
                prepared: attemptPrepared,
                accessToken: accessToken,
                settings: settings,
                onEvent: { buffered.append($0) }
            )
            let unsupportedToolCall = output.toolCalls.first { !OpenAICompatibility.canMapToolCall($0, tools: prepared.tools, context: prepared.toolContext) }
            if !output.toolCalls.isEmpty, unsupportedToolCall == nil {
                for event in buffered.events() {
                    onEvent(event)
                }
                return output
            }

            let needsRetry = unsupportedToolCall != nil || shouldRetryMissing
            guard needsRetry, attempt < Self.toolRetryAttempts else {
                for event in buffered.events() {
                    onEvent(event)
                }
                return output
            }

            var retry = prepared
            retry.prompt = unsupportedToolCall.map {
                retryPrompt(afterUnsupportedToolCall: $0, prepared: prepared, attempt: attempt + 1)
            } ?? retryPrompt(afterMissingToolAttempt: prepared, attempt: attempt + 1)
            retry.promptCharacters = retry.prompt.count
            attemptPrepared = retry
        }

        return try await runSDKRequest(
            agentID: agentID,
            runID: Self.newRunID(),
            prepared: prepared,
            accessToken: accessToken,
            settings: settings,
            onEvent: onEvent
        )
    }

    private func shouldRetryMissingLocalTool(_ prepared: PreparedChatRequest) -> Bool {
        !prepared.tools.isEmpty && prepared.prompt.contains("LOCAL TOOL REQUIRED FOR THE LATEST USER REQUEST")
    }

    private func retryPrompt(afterMissingToolAttempt prepared: PreparedChatRequest, attempt: Int) -> String {
        [
            prepared.prompt,
            "",
            "TOOL CALL RETRY (attempt \(attempt) of \(Self.toolRetryAttempts)):",
            "Your previous SDK response did not emit a local tool call, but the latest user request requires local execution.",
            "The next response is invalid unless it contains a tool_call.",
            "Do not answer in prose. Emit exactly one SDK tool call now using the allowed client tool inventory above, then wait for the local tool result.",
            "Use SDK mcp for an exact client tool route, or SDK shell/write when the routing map says those built-ins map to the client schema.",
            "If a specific client tool was named in the request, use that exact tool mapping and do not substitute shell, glob, or prose."
        ].joined(separator: "\n")
    }

    private func retryPrompt(afterUnsupportedToolCall toolCall: CursorToolCall, prepared: PreparedChatRequest, attempt: Int) -> String {
        [
            prepared.prompt,
            "",
            "TOOL CALL RETRY (attempt \(attempt) of \(Self.toolRetryAttempts)):",
            "Your previous SDK response requested \(toolCall.name), but that tool could not be mapped to the allowed client tool inventory above.",
            "Mapping failure detail: \(OpenAICompatibility.toolCallRetryHint(toolCall, tools: prepared.tools, context: prepared.toolContext))",
            "The next response is invalid unless it contains a mappable tool_call.",
            "Do not answer in prose. Emit exactly one SDK tool call that maps to an allowed client tool.",
            "For filesystem mutations, prefer SDK write with path and fileText or SDK shell with command when those capabilities are present.",
            "For OpenCode MCP/server tools exposed as provider_tool names, use SDK mcp with providerIdentifier, toolName, and args."
        ].joined(separator: "\n")
    }

    static func newRunID() -> String {
        "run-\(UUID().uuidString.lowercased())"
    }

    private func runSDKRequest(
        agentID: String,
        runID: String,
        prepared: PreparedChatRequest,
        accessToken: String,
        settings: CursorAPISettings,
        onEvent: @escaping @Sendable (CursorSDKStreamEvent) -> Void
    ) async throws -> CursorSDKOutput {
        let requestID = UUID().uuidString.lowercased()
        let request = CursorSDKProto.runRequest(
            agentID: agentID,
            messageID: runID,
            modelID: prepared.cursorModelID,
            prompt: prepared.prompt
        )
        let framed = ConnectProto.frame(request)
        let decoder = CursorSDKFrameDecoderBox()
        _ = try await runRawSDKRequest(
            framedBody: framed,
            accessToken: accessToken,
            requestID: requestID,
            settings: settings,
            workingDirectory: prepared.toolContext?.workingDirectory
        ) { payload in
            let events = decoder.push(payload)
            for event in events {
                onEvent(event)
            }
        }
        return decoder.output(agentID: agentID, runID: runID)
    }

    private func exchangeCursorAPIKey(_ apiKey: String, settings: CursorAPISettings) async throws -> String {
        guard settings.hasCursorAPIExchangeConfiguration else {
            throw CursorAPIError.invalidConfiguration("This \(CursorAPIBrand.displayName) build is missing its bundled Composer key-exchange origin. Repackage the app with complete transport defaults or inspect Settings > Advanced Transport Overrides.")
        }
        guard let base = URL(string: settings.cursorAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CursorAPIError.invalidConfiguration("Cursor key-exchange origin is not a valid URL.")
        }
        let url = base.appending(path: "/auth/exchange_user_api_key")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("sdk", forHTTPHeaderField: "x-cursor-client-type")
        request.setValue("composer-api-macos-0.1.0", forHTTPHeaderField: "x-cursor-client-version")
        request.setValue("true", forHTTPHeaderField: "x-ghost-mode")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CursorAPIError.transport("Cursor API did not return an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
            throw http.statusCode == 401 ? CursorAPIError.unauthorized : CursorAPIError.upstream(text)
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = payload["accessToken"] as? String,
              !accessToken.isEmpty else {
            throw CursorAPIError.upstream("Cursor did not return an internal access token.")
        }
        return accessToken
    }

    private func runRawSDKRequest(
        framedBody: Data,
        accessToken: String,
        requestID: String,
        settings: CursorAPISettings,
        workingDirectory: String?,
        onFrame: @escaping @Sendable (Data) -> Void
    ) async throws -> Data {
        let endpoint = try endpointURL(settings: settings)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = framedBody
        request.timeoutInterval = 180
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/connect+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("connect-es/1.6.1", forHTTPHeaderField: "User-Agent")
        request.setValue("sdk", forHTTPHeaderField: "x-cursor-client-type")
        request.setValue(settings.clientVersion.isEmpty ? "sdk-1.0.13" : settings.clientVersion, forHTTPHeaderField: "x-cursor-client-version")
        request.setValue("true", forHTTPHeaderField: "x-ghost-mode")
        request.setValue(requestID, forHTTPHeaderField: "x-original-request-id")
        request.setValue(requestID, forHTTPHeaderField: "x-request-id")

        if ProcessInfo.processInfo.environment["CURSOR_API_USE_SWIFT_HTTP2_TRANSPORT"] == "1" {
            return try await CursorSDKHTTP2Transport.shared.runStreaming(request: request, initialFrame: framedBody, workingDirectory: workingDirectory, onFrame: onFrame)
        } else {
            let bridge = try await CursorSDKBridgeServer.shared.endpoint(settings: settings)
            return try await runBridgeSDKRequest(
                bridge: bridge,
                framedBody: framedBody,
                accessToken: accessToken,
                requestID: requestID,
                settings: settings,
                workingDirectory: workingDirectory,
                onFrame: onFrame
            )
        }
    }

    private func runBridgeSDKRequest(
        bridge: CursorSDKBridgeEndpoint,
        framedBody: Data,
        accessToken: String,
        requestID: String,
        settings: CursorAPISettings,
        workingDirectory: String?,
        onFrame: @escaping @Sendable (Data) -> Void
    ) async throws -> Data {
        var request = URLRequest(url: bridge.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bridge.token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "accessToken": accessToken,
            "requestId": requestID,
            "backendBaseUrl": settings.backendBaseURL,
            "localAgentEndpoint": settings.localAgentEndpoint,
            "clientVersion": settings.clientVersion.isEmpty ? "sdk-1.0.13" : settings.clientVersion,
            "runFrame": framedBody.base64EncodedString(),
            "workingDirectory": workingDirectory ?? ""
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CursorAPIError.transport("Cursor SDK bridge did not return an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
            throw http.statusCode == 401 ? CursorAPIError.unauthorized : CursorAPIError.upstream(text)
        }
        for frame in ConnectProto.frames(from: data) {
            onFrame(frame)
        }
        return data
    }

    private func endpointURL(settings: CursorAPISettings) throws -> URL {
        let endpoint = settings.localAgentEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.hasPrefix("http://") || endpoint.hasPrefix("https://") {
            guard let url = URL(string: endpoint) else {
                throw CursorAPIError.invalidConfiguration("Cursor local-agent endpoint is not a valid URL.")
            }
            return url
        }
        guard let base = URL(string: settings.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CursorAPIError.invalidConfiguration("Cursor backend origin is not a valid URL.")
        }
        var normalized = endpoint
        if !normalized.hasPrefix("/") {
            normalized = "/" + normalized
        }
        return base.appending(path: normalized)
    }

    static func resolvedCursorAPIKey(from authorization: String?, settings: CursorAPISettings) -> String {
        guard let token = bearerToken(authorization), !isLocalPlaceholderToken(token) else {
            return settings.cursorAPIKey
        }
        return token
    }

    static func resolvedCursorAPIKeyForRequest(from authorization: String?, settings: CursorAPISettings) throws -> String {
        if let token = bearerToken(authorization), !isLocalPlaceholderToken(token) {
            return token
        }
        if settings.hasInlineCursorAPIKey {
            return settings.cursorAPIKey
        }
        if settings.keychainCursorAPIKeyAvailable {
            throw CursorAPIError.keychainLocked
        }
        return ""
    }

    private static func bearerToken(_ authorization: String?) -> String? {
        guard let authorization else { return nil }
        let pieces = authorization.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard pieces.count == 2, pieces[0].lowercased() == "bearer" else { return nil }
        return String(pieces[1])
    }

    private static func isLocalPlaceholderToken(_ token: String) -> Bool {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty
            || normalized == "cursor-local"
            || normalized == "CURSOR_API_KEY"
            || normalized == "{env:CURSOR_API_KEY}"
    }
}

actor CursorSDKSessionStore {
    private let maxEntries: Int
    private var sessionOrder: [String] = []
    private var agents: [String: String] = [:]

    init(maxEntries: Int) {
        self.maxEntries = max(1, maxEntries)
    }

    func agentID(for sessionKey: String?) -> String {
        guard let sessionKey, !sessionKey.isEmpty else {
            return "agent-\(UUID().uuidString.lowercased())"
        }
        if let existing = agents[sessionKey] {
            touch(sessionKey)
            return existing
        }
        let created = "agent-\(UUID().uuidString.lowercased())"
        agents[sessionKey] = created
        touch(sessionKey)
        evictIfNeeded()
        return created
    }

    func count() -> Int {
        agents.count
    }

    private func touch(_ sessionKey: String) {
        if let index = sessionOrder.firstIndex(of: sessionKey) {
            sessionOrder.remove(at: index)
        }
        sessionOrder.append(sessionKey)
    }

    private func evictIfNeeded() {
        while sessionOrder.count > maxEntries, let evicted = sessionOrder.first {
            sessionOrder.removeFirst()
            agents.removeValue(forKey: evicted)
        }
    }
}

actor CursorSDKAccessTokenCache {
    private struct Entry {
        var token: String
        var expiresAt: Date
    }

    private let ttl: TimeInterval
    private let maxEntries: Int
    private var entries: [String: Entry] = [:]
    private var entryOrder: [String] = []
    private var inFlight: [String: Task<String, any Error>] = [:]

    init(ttl: TimeInterval, maxEntries: Int = 64) {
        self.ttl = max(1, ttl)
        self.maxEntries = max(1, maxEntries)
    }

    func token(
        for apiKey: String,
        origin: String,
        now: Date = Date(),
        exchange: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        let key = cacheKey(apiKey: apiKey, origin: origin)
        if let entry = entries[key], entry.expiresAt > now {
            touch(key)
            return entry.token
        }

        if let task = inFlight[key] {
            return try await task.value
        }

        let task = Task {
            try await exchange()
        }
        inFlight[key] = task
        let token: String
        do {
            token = try await task.value
        } catch {
            inFlight.removeValue(forKey: key)
            throw error
        }
        inFlight.removeValue(forKey: key)
        entries[key] = Entry(token: token, expiresAt: now.addingTimeInterval(ttl))
        touch(key)
        evictIfNeeded()
        return token
    }

    func invalidate(apiKey: String, origin: String) {
        let key = cacheKey(apiKey: apiKey, origin: origin)
        entries.removeValue(forKey: key)
        inFlight.removeValue(forKey: key)?.cancel()
        entryOrder.removeAll { $0 == key }
    }

    func count() -> Int {
        entries.count
    }

    private func cacheKey(apiKey: String, origin: String) -> String {
        let normalizedOrigin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data("\(normalizedOrigin)\u{0}\(apiKey)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func touch(_ key: String) {
        entryOrder.removeAll { $0 == key }
        entryOrder.append(key)
    }

    private func evictIfNeeded() {
        while entryOrder.count > maxEntries, let evicted = entryOrder.first {
            entryOrder.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }
}

private final class CursorSDKFrameDecoderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = CursorSDKFrameDecoder()

    func push(_ payload: Data) -> [CursorSDKStreamEvent] {
        lock.withLock {
            decoder.push(payload)
        }
    }

    func output(agentID: String, runID: String) -> CursorSDKOutput {
        lock.withLock {
            decoder.output(agentID: agentID, runID: runID)
        }
    }
}

public struct CursorSDKFrameDecoder: Sendable {
    public var text: String = ""
    public var toolCalls: [CursorToolCall] = []

    public static func decode(data: Data) -> CursorSDKFrameDecoder {
        var decoder = CursorSDKFrameDecoder()
        for frame in ConnectProto.frames(from: data) {
            _ = decoder.push(frame)
        }
        return decoder
    }

    public func output(agentID: String, runID: String) -> CursorSDKOutput {
        CursorSDKOutput(text: text, toolCalls: toolCalls, agentID: agentID, runID: runID)
    }

    @discardableResult
    public mutating func push(_ payload: Data) -> [CursorSDKStreamEvent] {
        var output: [CursorSDKStreamEvent] = []
        for field in Proto.decodeFields(payload) {
            switch field.value {
            case .bytes(let bytes) where field.number == 1:
                output.append(contentsOf: decodeInteractionUpdate(bytes))
            case .bytes(let bytes) where field.number == 2:
                if let event = decodeExecServerMessage(bytes) {
                    output.append(event)
                }
            default:
                continue
            }
        }
        return output
    }

    private mutating func decodeInteractionUpdate(_ payload: Data) -> [CursorSDKStreamEvent] {
        var output: [CursorSDKStreamEvent] = []
        for field in Proto.decodeFields(payload) {
            guard case .bytes(let bytes) = field.value else { continue }
            if field.number == 1 {
                let textFields = Proto.decodeFields(bytes)
                if let value = Proto.stringField(textFields, 1) {
                    text += value
                    output.append(.text(value))
                }
            } else if field.number == 2 || field.number == 3 || field.number == 7 {
                if let toolCall = decodeToolCallUpdate(bytes, completed: field.number == 3) {
                    toolCalls.append(toolCall)
                    output.append(.toolCall(toolCall))
                }
            }
        }
        return output
    }

    private mutating func decodeExecServerMessage(_ payload: Data) -> CursorSDKStreamEvent? {
        let fields = Proto.decodeFields(payload)
        if fields.contains(where: { $0.number == 10 }) {
            return nil
        }
        for field in fields {
            guard case .bytes(let bytes) = field.value,
                  let spec = CursorSDKToolSpec.exec[field.number] else {
                continue
            }
            var args = CursorSDKToolSpec.decodeArgs(kind: spec.kind, payload: bytes)
            args.removeValue(forKey: "toolCallId")
            let toolCall = CursorSDKToolSpec.normalizedForOpenCode(CursorToolCall(name: spec.name, arguments: args))
            guard CursorSDKToolSpec.isEmittable(toolCall) else { continue }
            toolCalls.append(toolCall)
            return .toolCall(toolCall)
        }
        return nil
    }

    private func decodeToolCallUpdate(_ payload: Data, completed: Bool) -> CursorToolCall? {
        let fields = Proto.decodeFields(payload)
        guard let toolCallBytes = Proto.dataField(fields, 2) else { return nil }
        return decodeSDKToolCall(toolCallBytes, completed: completed)
    }

    private func decodeSDKToolCall(_ payload: Data, completed: Bool) -> CursorToolCall? {
        for field in Proto.decodeFields(payload) {
            guard case .bytes(let bytes) = field.value,
                  let spec = CursorSDKToolSpec.interaction[field.number] else {
                continue
            }
            let toolFields = Proto.decodeFields(bytes)
            let hasResult = toolFields.contains(where: { $0.number == 2 })
            if completed && hasResult {
                return nil
            }
            let argsPayload = Proto.dataField(toolFields, 1)
            var toolCall = CursorToolCall(name: spec.name, arguments: argsPayload.map { CursorSDKToolSpec.decodeArgs(kind: spec.kind, payload: $0) } ?? [:])
            toolCall = CursorSDKToolSpec.normalizedForOpenCode(toolCall)
            return CursorSDKToolSpec.isEmittable(toolCall) ? toolCall : nil
        }
        return nil
    }
}

private final class LockedEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CursorSDKStreamEvent] = []

    func append(_ event: CursorSDKStreamEvent) {
        lock.withLock {
            storage.append(event)
        }
    }

    func events() -> [CursorSDKStreamEvent] {
        lock.withLock {
            storage
        }
    }
}

struct CursorSDKToolSpec {
    enum Kind {
        case delete
        case edit
        case glob
        case grep
        case ls
        case mcp
        case readExec
        case readLints
        case readTool
        case semSearch
        case shell
        case write
    }

    var name: String
    var kind: Kind

    static let interaction: [Int: CursorSDKToolSpec] = [
        1: CursorSDKToolSpec(name: "shell", kind: .shell),
        3: CursorSDKToolSpec(name: "delete", kind: .delete),
        4: CursorSDKToolSpec(name: "glob", kind: .glob),
        5: CursorSDKToolSpec(name: "grep", kind: .grep),
        8: CursorSDKToolSpec(name: "read", kind: .readTool),
        12: CursorSDKToolSpec(name: "edit", kind: .edit),
        13: CursorSDKToolSpec(name: "ls", kind: .ls),
        14: CursorSDKToolSpec(name: "readLints", kind: .readLints),
        15: CursorSDKToolSpec(name: "mcp", kind: .mcp),
        16: CursorSDKToolSpec(name: "semSearch", kind: .semSearch)
    ]

    static let exec: [Int: CursorSDKToolSpec] = [
        2: CursorSDKToolSpec(name: "shell", kind: .shell),
        3: CursorSDKToolSpec(name: "write", kind: .write),
        4: CursorSDKToolSpec(name: "delete", kind: .delete),
        5: CursorSDKToolSpec(name: "grep", kind: .grep),
        7: CursorSDKToolSpec(name: "read", kind: .readExec),
        8: CursorSDKToolSpec(name: "ls", kind: .ls),
        9: CursorSDKToolSpec(name: "readLints", kind: .readLints),
        11: CursorSDKToolSpec(name: "mcp", kind: .mcp),
        14: CursorSDKToolSpec(name: "shell", kind: .shell)
    ]

    static func decodeArgs(kind: Kind, payload: Data) -> [String: JSONValue] {
        let fields = Proto.decodeFields(payload)
        func string(_ number: Int) -> JSONValue? { Proto.stringField(fields, number).map(JSONValue.string) }
        func number(_ number: Int) -> JSONValue? { Proto.numberField(fields, number).map { .number(Double($0)) } }
        func bool(_ number: Int) -> JSONValue? { Proto.numberField(fields, number).map { .bool($0 != 0) } }
        func strings(_ number: Int) -> JSONValue? {
            let values = Proto.stringFields(fields, number)
            return values.isEmpty ? nil : .array(values.map(JSONValue.string))
        }
        switch kind {
        case .shell:
            return compact(["command": string(1), "workingDirectory": string(2), "timeout": number(3), "toolCallId": string(4)])
        case .write:
            return compact(["path": string(1), "fileText": string(2), "toolCallId": string(3), "returnFileContentAfterWrite": bool(4)])
        case .delete:
            return compact(["path": string(1), "toolCallId": string(2)])
        case .glob:
            return compact(["targetDirectory": string(1), "globPattern": string(2)])
        case .grep:
            return compact([
                "pattern": string(1), "path": string(2), "glob": string(3), "outputMode": string(4),
                "contextBefore": number(5), "contextAfter": number(6), "context": number(7),
                "caseInsensitive": bool(8), "type": string(9), "headLimit": number(10),
                "multiline": bool(11), "sort": string(12), "sortAscending": bool(13),
                "toolCallId": string(14), "offset": number(16)
            ])
        case .readTool:
            return compact(["path": string(1), "offset": number(2), "limit": number(3), "includeLineNumbers": bool(5)])
        case .readExec:
            return compact(["path": string(1), "toolCallId": string(2), "offset": number(4), "limit": number(5)])
        case .edit:
            return compact(["path": string(1), "streamContent": string(6)])
        case .ls:
            return compact(["path": string(1), "ignore": strings(2), "toolCallId": string(3)])
        case .readLints:
            return compact(["paths": strings(1)])
        case .mcp:
            return compact([
                "name": string(1),
                "args": protoValueMap(fields, 2),
                "toolCallId": string(3),
                "providerIdentifier": string(4),
                "toolName": string(5)
            ])
        case .semSearch:
            return compact(["query": string(1), "targetDirectories": strings(2), "explanation": string(3)])
        }
    }

    static func isEmittable(_ toolCall: CursorToolCall) -> Bool {
        let name = toolCall.name.lowercased()
        let args = toolCall.arguments
        if name == "glob" { return hasGlobRequest(args) }
        if name == "ls" { return true }
        if name == "shell" { return hasString(args, keys: ["command", "cmd", "script"]) }
        if name == "write" {
            return hasString(args, keys: ["path", "filePath", "file_path", "targetFile", "target_file"])
                && hasStringAllowingEmpty(args, keys: ["fileText", "file_text", "content", "contents", "text", "fileContent", "file_content", "streamContent", "stream_content"])
        }
        if name == "edit" {
            let hasCompleteReplacement = hasStringAllowingEmpty(args, keys: ["oldText", "old_text", "oldString", "old_string", "old_str", "old", "search", "searchString", "search_string"])
                && hasStringAllowingEmpty(args, keys: ["newText", "new_text", "newString", "new_string", "new_str", "replacement", "replace", "content"])
            return hasString(args, keys: ["path", "filePath", "file_path", "targetFile", "target_file"])
                && (hasStringAllowingEmpty(args, keys: ["patchContent", "patch_content", "patch", "diff", "unifiedDiff", "unified_diff"])
                    || hasStringAllowingEmpty(args, keys: ["streamContent", "stream_content"])
                    || hasCompleteReplacement)
        }
        if name == "read" || name == "delete" { return hasString(args, keys: ["path", "filePath", "file_path", "targetFile", "target_file"]) }
        if name == "grep" { return hasString(args, keys: ["pattern", "query", "regex", "search"]) }
        if name == "semsearch" { return hasString(args, keys: ["query", "pattern", "search"]) }
        if name == "readlints" { return stringArrayValue(args["paths"]).contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        if name == "mcp" { return hasString(args, keys: ["toolName", "tool_name", "name"]) }
        return !args.isEmpty
    }

    static func normalizedForOpenCode(_ toolCall: CursorToolCall) -> CursorToolCall {
        guard toolCall.name.lowercased() == "edit",
              let path = stringValue(toolCall.arguments, keys: ["path"]),
              let streamContent = firstStringValue(toolCall.arguments, keys: ["streamContent", "stream_content"]) else {
            return toolCall
        }
        return CursorToolCall(name: "write", arguments: ["path": .string(path), "fileText": .string(streamContent)])
    }

    private static func hasString(_ args: [String: JSONValue], keys: [String]) -> Bool {
        keys.contains { key in
            guard let value = args[key]?.stringValue else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func hasStringAllowingEmpty(_ args: [String: JSONValue], keys: [String]) -> Bool {
        keys.contains { args[$0]?.stringValue != nil }
    }

    private static func hasGlobRequest(_ args: [String: JSONValue]) -> Bool {
        if hasString(args, keys: ["globPattern", "glob_pattern", "filePattern", "file_pattern", "pattern", "glob", "query", "include", "includeGlob", "include_glob"]) {
            return true
        }
        return stringValue(args, keys: ["targetDirectory", "target_directory", "targeting", "path"]) != nil
    }

    private static func stringValue(_ args: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let value = args[key]?.stringValue,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            return value
        }
        return nil
    }

    private static func firstStringValue(_ args: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = args[key]?.stringValue {
                return value
            }
        }
        return nil
    }

    private static func stringArrayValue(_ value: JSONValue?) -> [String] {
        switch value {
        case .array(let values):
            return values.compactMap(\.stringValue)
        case .string(let value):
            return [value]
        default:
            return []
        }
    }

    static func compact(_ input: [String: JSONValue?]) -> [String: JSONValue] {
        input.compactMapValues { value in
            guard let value else { return nil }
            if case .null = value { return nil }
            return value
        }
    }

    private static func protoValueMap(_ fields: [ProtoField], _ number: Int) -> JSONValue? {
        var output: [String: JSONValue] = [:]
        for field in fields where field.number == number {
            guard case .bytes(let entryData) = field.value else { continue }
            let entryFields = Proto.decodeFields(entryData)
            guard let key = Proto.stringField(entryFields, 1),
                  let valueData = Proto.dataField(entryFields, 2),
                  let value = protoValue(valueData) else {
                continue
            }
            output[key] = value
        }
        return output.isEmpty ? nil : .object(output)
    }

    private static func protoStruct(_ data: Data) -> [String: JSONValue]? {
        var output: [String: JSONValue] = [:]
        for field in Proto.decodeFields(data) where field.number == 1 {
            guard case .bytes(let entryData) = field.value else { continue }
            let entryFields = Proto.decodeFields(entryData)
            guard let key = Proto.stringField(entryFields, 1),
                  let valueData = Proto.dataField(entryFields, 2),
                  let value = protoValue(valueData) else {
                continue
            }
            output[key] = value
        }
        return output
    }

    private static func protoList(_ data: Data) -> [JSONValue]? {
        let values = Proto.decodeFields(data).compactMap { field -> JSONValue? in
            guard field.number == 1, case .bytes(let valueData) = field.value else { return nil }
            return protoValue(valueData)
        }
        return values
    }

    private static func protoValue(_ data: Data) -> JSONValue? {
        let fields = Proto.decodeFields(data)
        if fields.contains(where: { $0.number == 1 }) {
            return .null
        }
        if case .fixed64(let bits)? = fields.first(where: { $0.number == 2 })?.value {
            return .number(Double(bitPattern: bits))
        }
        if let string = Proto.stringField(fields, 3) {
            return .string(string)
        }
        if case .varint(let value)? = fields.first(where: { $0.number == 4 })?.value {
            return .bool(value != 0)
        }
        if let structData = Proto.dataField(fields, 5),
           let object = protoStruct(structData) {
            return .object(object)
        }
        if let listData = Proto.dataField(fields, 6),
           let array = protoList(listData) {
            return .array(array)
        }
        return nil
    }
}
