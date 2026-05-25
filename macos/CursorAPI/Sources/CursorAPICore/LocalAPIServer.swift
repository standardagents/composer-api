import Foundation
import Network

private enum RoutedHTTPResponse {
    case response(HTTPResponse)
    case stream(HTTPStreamResponse)
}

private struct HTTPStreamResponse {
    var status: Int
    var headers: [String: String]
    var chunks: AsyncThrowingStream<Data, any Error>
}

public final class LocalAPIServer: @unchecked Sendable {
    public typealias SettingsProvider = @Sendable () -> CursorAPISettings

    private let queue = DispatchQueue(label: "CursorAPI.LocalAPIServer")
    private let settingsProvider: SettingsProvider
    private let harness: any CursorSDKHarness
    private let responseSessions = LocalResponseSessionStore()
    private var listener: NWListener?

    public private(set) var port: UInt16?

    public init(settingsProvider: @escaping SettingsProvider, harness: any CursorSDKHarness = LocalCursorSDKHarness()) {
        self.settingsProvider = settingsProvider
        self.harness = harness
    }

    public func start(port: UInt16) throws {
        stop()
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: endpointPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = port
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        self.port = port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection: connection, accumulated: Data())
    }

    private func read(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.send(connection: connection, response: self.errorResponse(error))
                return
            }
            var data = accumulated
            if let content {
                data.append(content)
            }
            if let request = HTTPParser.parse(data) {
                Task {
                    let routed = await self.route(request)
                    switch routed {
                    case .response(let response):
                        self.send(connection: connection, response: response)
                    case .stream(let response):
                        await self.sendStreaming(connection: connection, response: response)
                    }
                }
            } else if isComplete {
                self.send(connection: connection, response: self.errorResponse(CursorAPIError.badRequest("Could not parse HTTP request.")))
            } else {
                self.read(connection: connection, accumulated: data)
            }
        }
    }

    private func route(_ request: HTTPRequest) async -> RoutedHTTPResponse {
        do {
            if request.method == "OPTIONS" {
                return .response(HTTPResponse(status: 204, headers: corsHeaders(), body: Data()))
            }
            if request.method == "GET", request.path == "/health" {
                let settings = settingsProvider()
                return try .response(HTTPResponse.json([
                    "ok": true,
                    "service": CursorAPIBrand.displayName,
                    "baseUrl": settings.baseURL.absoluteString,
                    "host": "127.0.0.1",
                    "sdkConfigured": settings.hasCursorSDKConfiguration
                ]))
            }
            if request.method == "GET", request.path == "/v1/models" {
                return try .response(withCORS(HTTPResponse.json(OpenAICompatibility.modelList())))
            }
            if request.method == "POST", request.path == "/v1/chat/completions" {
                var prepared = try OpenAICompatibility.prepareChatRequest(request.body)
                prepared.sessionKey = sessionAffinity(request)
                let settings = settingsProvider()
                let id = "chatcmpl_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                let created = Int(Date().timeIntervalSince1970)
                if prepared.stream {
                    return .stream(HTTPStreamResponse(
                        status: 200,
                        headers: streamingHeaders(),
                        chunks: chatCompletionChunks(id: id, created: created, prepared: prepared, settings: settings, authorization: request.header("authorization"))
                    ))
                }
                let output = try await harness.complete(prepared: prepared, settings: settings, authorization: request.header("authorization"))
                return try .response(withCORS(HTTPResponse.json(OpenAICompatibility.chatCompletionResponse(id: id, created: created, prepared: prepared, output: output))))
            }
            if request.method == "POST", request.path == "/v1/responses" {
                var prepared = try OpenAICompatibility.prepareResponsesRequest(request.body)
                let settings = settingsProvider()
                let id = "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                prepared.sessionKey = await responseSessions.sessionKey(
                    responseID: id,
                    previousResponseID: prepared.previousResponseID,
                    explicitSessionKey: sessionAffinity(request) ?? prepared.requestedSessionKey
                )
                let created = Int(Date().timeIntervalSince1970)
                if prepared.stream {
                    return .stream(HTTPStreamResponse(
                        status: 200,
                        headers: streamingHeaders(),
                        chunks: responseChunks(id: id, created: created, prepared: prepared, settings: settings, authorization: request.header("authorization"))
                    ))
                }
                let output = try await harness.complete(prepared: prepared, settings: settings, authorization: request.header("authorization"))
                let responseObject = OpenAICompatibility.responseObject(id: id, created: created, prepared: prepared, output: output)
                let response = try HTTPResponse.json(responseObject)
                if prepared.storeResponse {
                    let inputItems = try JSONSerialization.data(
                        withJSONObject: OpenAICompatibility.responseInputItemsObject(prepared.responseInputItems),
                        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    )
                    await responseSessions.storeResponse(responseID: id, responseData: response.body, inputItemsData: inputItems)
                }
                return .response(withCORS(response))
            }
            if request.method == "GET", let responseID = responseInputItemsID(from: request.path) {
                guard let data = await responseSessions.responseInputItemsData(responseID: responseID) else {
                    throw CursorAPIError.notFound
                }
                return .response(withCORS(HTTPResponse.data(data, contentType: "application/json; charset=utf-8")))
            }
            if request.method == "GET", let responseID = responseID(from: request.path) {
                guard let data = await responseSessions.responseData(responseID: responseID) else {
                    throw CursorAPIError.notFound
                }
                return .response(withCORS(HTTPResponse.data(data, contentType: "application/json; charset=utf-8")))
            }
            throw CursorAPIError.notFound
        } catch {
            return .response(errorResponse(error))
        }
    }

    private func chatCompletionChunks(
        id: String,
        created: Int,
        prepared: PreparedChatRequest,
        settings: CursorAPISettings,
        authorization: String?
    ) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(OpenAICompatibility.chatCompletionStreamStart(id: id, created: created, model: prepared.model))
                    var emittedText = ""
                    var emittedToolCalls: [CursorToolCall] = []
                    var finalOutput: CursorSDKOutput?

                    for try await event in harness.stream(prepared: prepared, settings: settings, authorization: authorization) {
                        switch event {
                        case .text(let delta):
                            emittedText += delta
                            continuation.yield(OpenAICompatibility.chatCompletionStreamText(id: id, created: created, model: prepared.model, delta: delta))
                        case .toolCall(let toolCall):
                            let index = emittedToolCalls.count
                            emittedToolCalls.append(toolCall)
                            continuation.yield(OpenAICompatibility.chatCompletionStreamToolCall(id: id, created: created, prepared: prepared, toolCall: toolCall, index: index))
                        case .done(let output):
                            finalOutput = output
                        }
                    }

                    let output = resolvedOutput(finalOutput: finalOutput, emittedText: emittedText, emittedToolCalls: emittedToolCalls)
                    if output.text.count > emittedText.count, output.text.hasPrefix(emittedText) {
                        let suffix = String(output.text.dropFirst(emittedText.count))
                        continuation.yield(OpenAICompatibility.chatCompletionStreamText(id: id, created: created, model: prepared.model, delta: suffix))
                        emittedText += suffix
                    } else if emittedText.isEmpty, !output.text.isEmpty {
                        continuation.yield(OpenAICompatibility.chatCompletionStreamText(id: id, created: created, model: prepared.model, delta: output.text))
                    }
                    if output.toolCalls.count > emittedToolCalls.count {
                        for (offset, toolCall) in output.toolCalls.dropFirst(emittedToolCalls.count).enumerated() {
                            let index = emittedToolCalls.count + offset
                            continuation.yield(OpenAICompatibility.chatCompletionStreamToolCall(id: id, created: created, prepared: prepared, toolCall: toolCall, index: index))
                        }
                    }
                    continuation.yield(OpenAICompatibility.chatCompletionStreamFinish(
                        id: id,
                        created: created,
                        model: prepared.model,
                        emittedToolCallCount: max(emittedToolCalls.count, output.toolCalls.count)
                    ))
                    continuation.yield(OpenAICompatibility.chatCompletionStreamDone())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func responseChunks(
        id: String,
        created: Int,
        prepared: PreparedChatRequest,
        settings: CursorAPISettings,
        authorization: String?
    ) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for chunk in OpenAICompatibility.responseStreamStart(id: id, created: created, prepared: prepared) {
                        continuation.yield(chunk)
                    }
                    var emittedText = ""
                    var emittedToolCalls: [CursorToolCall] = []
                    var finalOutput: CursorSDKOutput?
                    var nextOutputIndex = 0
                    var textStarted = false
                    var textOutputIndex = 0

                    func startTextIfNeeded() {
                        guard !textStarted else { return }
                        textOutputIndex = nextOutputIndex
                        nextOutputIndex += 1
                        textStarted = true
                        for chunk in OpenAICompatibility.responseStreamTextStart(id: id, outputIndex: textOutputIndex) {
                            continuation.yield(chunk)
                        }
                    }

                    for try await event in harness.stream(prepared: prepared, settings: settings, authorization: authorization) {
                        switch event {
                        case .text(let delta):
                            guard !delta.isEmpty else { continue }
                            startTextIfNeeded()
                            emittedText += delta
                            continuation.yield(OpenAICompatibility.responseStreamText(id: id, delta: delta, outputIndex: textOutputIndex))
                        case .toolCall(let toolCall):
                            let index = emittedToolCalls.count
                            let outputIndex = nextOutputIndex
                            nextOutputIndex += 1
                            emittedToolCalls.append(toolCall)
                            for chunk in OpenAICompatibility.responseStreamToolCall(id: id, prepared: prepared, toolCall: toolCall, index: index, outputIndex: outputIndex) {
                                continuation.yield(chunk)
                            }
                        case .done(let output):
                            finalOutput = output
                        }
                    }

                    let output = resolvedOutput(finalOutput: finalOutput, emittedText: emittedText, emittedToolCalls: emittedToolCalls)
                    if output.text.count > emittedText.count, output.text.hasPrefix(emittedText) {
                        let suffix = String(output.text.dropFirst(emittedText.count))
                        if !suffix.isEmpty {
                            startTextIfNeeded()
                            continuation.yield(OpenAICompatibility.responseStreamText(id: id, delta: suffix, outputIndex: textOutputIndex))
                        }
                    } else if emittedText.isEmpty, !output.text.isEmpty {
                        startTextIfNeeded()
                        continuation.yield(OpenAICompatibility.responseStreamText(id: id, delta: output.text, outputIndex: textOutputIndex))
                    }
                    if output.toolCalls.count > emittedToolCalls.count {
                        for (offset, toolCall) in output.toolCalls.dropFirst(emittedToolCalls.count).enumerated() {
                            let index = emittedToolCalls.count + offset
                            let outputIndex = nextOutputIndex
                            nextOutputIndex += 1
                            for chunk in OpenAICompatibility.responseStreamToolCall(id: id, prepared: prepared, toolCall: toolCall, index: index, outputIndex: outputIndex) {
                                continuation.yield(chunk)
                            }
                        }
                    }
                    let includeMessage = textStarted || !output.text.isEmpty || output.toolCalls.isEmpty
                    if includeMessage {
                        startTextIfNeeded()
                    }
                    let completedResponse = OpenAICompatibility.responseObject(id: id, created: created, prepared: prepared, output: output)
                    if prepared.storeResponse,
                       let responseData = try? JSONSerialization.data(withJSONObject: completedResponse, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                       let inputItemsData = try? JSONSerialization.data(
                        withJSONObject: OpenAICompatibility.responseInputItemsObject(prepared.responseInputItems),
                        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                       ) {
                        await responseSessions.storeResponse(responseID: id, responseData: responseData, inputItemsData: inputItemsData)
                    }
                    for chunk in OpenAICompatibility.responseStreamFinish(
                        id: id,
                        created: created,
                        prepared: prepared,
                        output: output,
                        includeMessage: includeMessage,
                        textOutputIndex: textOutputIndex,
                        completedResponse: completedResponse
                    ) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func resolvedOutput(
        finalOutput: CursorSDKOutput?,
        emittedText: String,
        emittedToolCalls: [CursorToolCall]
    ) -> CursorSDKOutput {
        guard var output = finalOutput else {
            return CursorSDKOutput(text: emittedText, toolCalls: emittedToolCalls, agentID: "", runID: "")
        }
        if output.text.isEmpty, !emittedText.isEmpty {
            output.text = emittedText
        }
        if output.toolCalls.isEmpty, !emittedToolCalls.isEmpty {
            output.toolCalls = emittedToolCalls
        }
        return output
    }

    private func send(connection: NWConnection, response: HTTPResponse) {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        for (key, value) in corsHeaders() {
            headers[key] = value
        }
        let headerLines = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        var data = Data("HTTP/1.1 \(response.status) \(HTTPStatusText.text(for: response.status))\r\n\(headerLines)\r\n\r\n".utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendStreaming(connection: NWConnection, response: HTTPStreamResponse) async {
        var headers = response.headers
        headers["Transfer-Encoding"] = "chunked"
        headers["Connection"] = "close"
        for (key, value) in corsHeaders() {
            headers[key] = value
        }
        let headerLines = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        let headerData = Data("HTTP/1.1 \(response.status) \(HTTPStatusText.text(for: response.status))\r\n\(headerLines)\r\n\r\n".utf8)
        do {
            try await sendData(headerData, connection: connection)
            for try await chunk in response.chunks {
                guard !chunk.isEmpty else { continue }
                try await sendData(chunked(chunk), connection: connection)
            }
            try await sendData(Data("0\r\n\r\n".utf8), connection: connection)
        } catch {
            let errorChunk = chunked(OpenAICompatibility.streamError(error))
            try? await sendData(errorChunk, connection: connection)
            try? await sendData(Data("0\r\n\r\n".utf8), connection: connection)
        }
        connection.cancel()
    }

    private func sendData(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func chunked(_ data: Data) -> Data {
        var chunk = Data("\(String(data.count, radix: 16))\r\n".utf8)
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))
        return chunk
    }

    private func errorResponse(_ error: any Error) -> HTTPResponse {
        let status = (error as? CursorAPIError)?.statusCode ?? 500
        return (try? withCORS(HTTPResponse.json(OpenAICompatibility.openAIError(error), status: status)))
            ?? HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: Data())
    }

    private func withCORS(_ response: HTTPResponse) -> HTTPResponse {
        var response = response
        for (key, value) in corsHeaders() {
            response.headers[key] = value
        }
        return response
    }

    private func corsHeaders() -> [String: String] {
        [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Authorization, Content-Type, OpenAI-Beta, OpenAI-Organization, OpenAI-Project, X-Session-Affinity, X-OpenCode-Session-Id, X-OpenCode-Session, X-CursorAPI-Session, X-CursorAPI-Project, X-Project-Path, X-Workspace-Path, X-Working-Directory",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS"
        ]
    }

    private func streamingHeaders() -> [String: String] {
        [
            "Content-Type": "text/event-stream; charset=utf-8",
            "Cache-Control": "no-cache, no-transform",
            "X-Accel-Buffering": "no"
        ]
    }

    private func responseID(from path: String) -> String? {
        let prefix = "/v1/responses/"
        guard path.hasPrefix(prefix) else { return nil }
        let value = String(path.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("/") else { return nil }
        return value
    }

    private func responseInputItemsID(from path: String) -> String? {
        let prefix = "/v1/responses/"
        let suffix = "/input_items"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -suffix.count)
        let value = String(path[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("/") else { return nil }
        return value
    }

    private func sessionAffinity(_ request: HTTPRequest) -> String? {
        request.header("x-session-affinity")?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? request.header("x-opencode-session-id")?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? request.header("x-opencode-session")?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? request.header("x-cursorapi-session")?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? request.header("x-cursorapi-project")?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? request.header("x-project-path")?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? request.header("x-workspace-path")?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? request.header("x-working-directory")?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }
}

private actor LocalResponseSessionStore {
    private var responseSessions: [String: String] = [:]
    private var storedResponses: [String: Data] = [:]
    private var storedResponseInputItems: [String: Data] = [:]

    func sessionKey(responseID: String, previousResponseID: String?, explicitSessionKey: String?) -> String {
        let sessionKey: String
        if let previousResponseID, let existing = responseSessions[previousResponseID] {
            sessionKey = existing
        } else if let explicitSessionKey, !explicitSessionKey.isEmpty {
            sessionKey = "affinity:\(explicitSessionKey)"
        } else if let previousResponseID, !previousResponseID.isEmpty {
            sessionKey = "previous-response:\(previousResponseID)"
        } else {
            sessionKey = "response:\(responseID)"
        }
        responseSessions[responseID] = sessionKey
        return sessionKey
    }

    func storeResponse(responseID: String, responseData: Data, inputItemsData: Data) {
        storedResponses[responseID] = responseData
        storedResponseInputItems[responseID] = inputItemsData
    }

    func responseData(responseID: String) -> Data? {
        storedResponses[responseID]
    }

    func responseInputItemsData(responseID: String) -> Data? {
        storedResponseInputItems[responseID]
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

enum HTTPParser {
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<separatorRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        let targetParts = target.split(separator: "?", maxSplits: 1).map(String.init)
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let index = line.firstIndex(of: ":") else { continue }
            let key = line[..<index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        let bodyStart = separatorRange.upperBound
        let expectedLength = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count - bodyStart >= expectedLength else { return nil }
        let body = data[bodyStart..<(bodyStart + expectedLength)]
        return HTTPRequest(
            method: String(parts[0]),
            path: targetParts[0],
            query: targetParts.count > 1 ? targetParts[1] : nil,
            headers: headers,
            body: Data(body)
        )
    }
}
