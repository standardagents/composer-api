import Foundation
import Network
import Darwin

struct CursorSDKBridgeEndpoint: Sendable {
    var url: URL
    var healthURL: URL
    var token: String
}

actor CursorSDKBridgeServer {
    static let shared = CursorSDKBridgeServer()

    private var process: Process?
    private var endpoint: CursorSDKBridgeEndpoint?
    private var logHandle: FileHandle?
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")

    func endpoint(settings: CursorAPISettings) async throws -> CursorSDKBridgeEndpoint {
        if let endpoint, process?.isRunning == true {
            return endpoint
        }
        if let endpoint, await isHealthy(endpoint.healthURL) {
            return endpoint
        }
        stop()
        let script = try bridgeScriptURL()
        let port = try await start(script: script, settings: settings)
        let endpoint = CursorSDKBridgeEndpoint(
            url: URL(string: "http://127.0.0.1:\(port)/sdk")!,
            healthURL: URL(string: "http://127.0.0.1:\(port)/health")!,
            token: token
        )
        self.endpoint = endpoint
        return endpoint
    }

    private func start(script: URL, settings: CursorAPISettings) async throws -> UInt16 {
        var lastError: (any Error)?
        for port in 8792...8892 {
            guard let candidate = UInt16(exactly: port), await !tcpPortIsOpen(candidate) else {
                continue
            }
            do {
                try launch(script: script, port: candidate, settings: settings)
                let health = URL(string: "http://127.0.0.1:\(candidate)/health")!
                for _ in 0..<40 {
                    if await isHealthy(health) {
                        return candidate
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                stop()
                lastError = CursorAPIError.transport("Cursor SDK bridge did not become ready.")
            } catch {
                stop()
                lastError = error
            }
        }
        throw lastError ?? CursorAPIError.transport("Could not start Cursor SDK bridge.")
    }

    private func launch(script: URL, port: UInt16, settings: CursorAPISettings) throws {
        let process = Process()
        let runtime = try runtimeExecutable()
        process.executableURL = runtime
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CURSOR_SDK_BRIDGE_HOST"] = "127.0.0.1"
        environment["CURSOR_SDK_BRIDGE_PORT"] = String(port)
        environment["CURSOR_SDK_BRIDGE_TOKEN"] = token
        environment["CURSOR_SDK_BRIDGE_RUN_TIMEOUT_MS"] = "120000"
        process.environment = environment
        process.currentDirectoryURL = script.deletingLastPathComponent()
        let logHandle = try bridgeLogHandle()
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { process in
            let message = "Cursor SDK bridge exited with status \(process.terminationStatus)\n"
            try? logHandle.write(contentsOf: Data(message.utf8))
        }
        try process.run()
        self.process = process
        self.logHandle = logHandle
    }

    private func runtimeExecutable() throws -> URL {
        for resourceName in ["node", "bun"] {
            if let bundled = Bundle.main.url(forResource: resourceName, withExtension: nil),
               FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }

        for command in ["node", "bun"] {
            if let url = try systemExecutable(named: command) {
                return url
            }
        }

        throw CursorAPIError.invalidConfiguration("\(CursorAPIBrand.displayName) is missing its bundled SDK bridge runtime. Repackage the app with Bun or Node bundled.")
    }

    private func systemExecutable(named command: String) throws -> URL? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            throw CursorAPIError.invalidConfiguration("\(command) is installed but could not be used for the SDK bridge.")
        }
        return URL(fileURLWithPath: path)
    }

    func shutdown() {
        stop()
    }

    private func stop() {
        let process = self.process
        self.process = nil
        endpoint = nil
        if let process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        try? logHandle?.close()
        logHandle = nil
    }

    private func bridgeLogHandle() throws -> FileHandle {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "api-for-cursor", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "sdk-bridge.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
           size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let header = "\n--- Cursor SDK bridge launch \(Date()) ---\n"
        try handle.write(contentsOf: Data(header.utf8))
        return handle
    }

    private func isHealthy(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            return data.contains(Data(#""ok": true"#.utf8)) || data.contains(Data(#""ok":true"#.utf8))
        } catch {
            return false
        }
    }

    private func tcpPortIsOpen(_ port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let queue = DispatchQueue(label: "CursorAPI.SDKBridgePortCheck.\(port)")
            let state = PortCheckState()
            let finish: @Sendable (Bool) -> Void = { value in
                guard state.finish() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 0.25) {
                finish(false)
            }
        }
    }

    private func bridgeScriptURL() throws -> URL {
        let candidates = [
            Bundle.main.url(forResource: "cursor-sdk-local-agent-bridge", withExtension: "mjs"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "scripts/cursor-sdk-local-agent-bridge.mjs"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent().appending(path: "scripts/cursor-sdk-local-agent-bridge.mjs")
        ].compactMap(\.self)
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw CursorAPIError.invalidConfiguration("Cursor SDK bridge script is missing. Repackage \(CursorAPIBrand.displayName) or run from the repository checkout.")
    }
}

private final class PortCheckState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
    }
}
