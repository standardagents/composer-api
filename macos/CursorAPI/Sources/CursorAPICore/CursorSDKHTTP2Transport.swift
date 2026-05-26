import Foundation

public final class CursorSDKHTTP2Transport: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    public static let shared = CursorSDKHTTP2Transport()

    private final class RequestState: @unchecked Sendable {
        let lock = NSLock()
        var continuation: CheckedContinuation<Data, any Error>?
        var outputStream: OutputStream?
        var inputStream: InputStream?
        var task: URLSessionTask?
        var responseData = Data()
        var parser = IncrementalConnectFrameParser()
        var requestContextSent = false
        var statusCode = 0
        var contentType = ""
        var networkProtocolName: String?
        var frameHandler: (@Sendable (Data) -> Void)?
        var completed = false

        init(
            continuation: CheckedContinuation<Data, any Error>,
            inputStream: InputStream,
            outputStream: OutputStream,
            frameHandler: @escaping @Sendable (Data) -> Void
        ) {
            self.continuation = continuation
            self.inputStream = inputStream
            self.outputStream = outputStream
            self.frameHandler = frameHandler
        }

        func write(_ data: Data) throws {
            guard let outputStream = lock.withLock({ self.outputStream }) else {
                throw CursorAPIError.transport("SDK upload stream is closed.")
            }
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var sent = 0
                while sent < data.count {
                    let written = outputStream.write(base.advanced(by: sent), maxLength: data.count - sent)
                    if written < 0 {
                        throw outputStream.streamError ?? CursorAPIError.transport("Could not write SDK upload stream.")
                    }
                    if written == 0 {
                        Thread.sleep(forTimeInterval: 0.005)
                        continue
                    }
                    sent += written
                }
            }
        }

        func closeUpload() {
            lock.withLock {
                outputStream?.close()
                outputStream = nil
            }
        }

        func closeStreams() {
            lock.withLock {
                outputStream?.close()
                inputStream?.close()
                outputStream = nil
                inputStream = nil
            }
        }
    }

    private let statesLock = NSLock()
    private var states: [Int: RequestState] = [:]
    private var session: URLSession!

    public override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 180
        configuration.httpShouldUsePipelining = true
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func run(request originalRequest: URLRequest, initialFrame: Data) async throws -> Data {
        try await runStreaming(request: originalRequest, initialFrame: initialFrame, onFrame: { _ in })
    }

    public func runStreaming(
        request originalRequest: URLRequest,
        initialFrame: Data,
        onFrame: @escaping @Sendable (Data) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            var readStream: InputStream?
            var writeStream: OutputStream?
            Stream.getBoundStreams(withBufferSize: 1024 * 1024, inputStream: &readStream, outputStream: &writeStream)
            guard let readStream, let writeStream else {
                continuation.resume(throwing: CursorAPIError.transport("Could not create SDK request stream."))
                return
            }
            writeStream.open()

            var request = originalRequest
            request.httpBodyStream = readStream
            request.httpBody = nil
            let task = session.dataTask(with: request)
            let state = RequestState(
                continuation: continuation,
                inputStream: readStream,
                outputStream: writeStream,
                frameHandler: onFrame
            )
            state.task = task
            statesLock.withLock {
                states[task.taskIdentifier] = state
            }
            task.resume()

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try state.write(initialFrame)
                } catch {
                    self?.finish(taskIdentifier: task.taskIdentifier, result: .failure(error))
                }
            }
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        if let http = response as? HTTPURLResponse, let state = state(for: dataTask) {
            state.lock.withLock {
                state.statusCode = http.statusCode
                state.contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            }
        }
        return .allow
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = state(for: dataTask) else {
            return
        }
        state.lock.withLock {
            state.responseData.append(data)
        }
        let canParseFrames = state.lock.withLock {
            state.statusCode == 200 && state.contentType.contains("application/connect+proto")
        }
        guard canParseFrames else {
            return
        }
        let parsed = state.lock.withLock {
            state.parser.push(data)
        }
        for payload in parsed {
            state.lock.withLock {
                state.frameHandler
            }?(payload)
            let shouldSendContext = state.lock.withLock { () -> CursorSDKRequestContext? in
                guard !state.requestContextSent, let context = CursorSDKRequestContext.decode(payload) else {
                    return nil
                }
                state.requestContextSent = true
                return context
            }
            if let context = shouldSendContext {
                let frame = ConnectProto.frame(CursorSDKProto.requestContextResult(id: context.id, execID: context.execID))
                do {
                    try state.write(frame)
                    state.closeUpload()
                } catch {
                    finish(taskIdentifier: dataTask.taskIdentifier, result: .failure(error))
                }
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        completionHandler(state(for: task)?.inputStream)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let name = metrics.transactionMetrics.last?.networkProtocolName
        if let state = state(for: task) {
            state.lock.withLock {
                state.networkProtocolName = name
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(taskIdentifier: task.taskIdentifier, result: .failure(error))
            return
        }
        guard let state = state(for: task) else {
            return
        }
        let data = state.lock.withLock { state.responseData }
        let status = state.lock.withLock { state.statusCode }
        guard (200..<300).contains(status) else {
            let text = String(data: data, encoding: .utf8) ?? "status \(status)"
            finish(taskIdentifier: task.taskIdentifier, result: .failure(status == 401 ? CursorAPIError.unauthorized : CursorAPIError.upstream(text)))
            return
        }
        let protocolName = state.lock.withLock { state.networkProtocolName }
        guard protocolName == "h2" else {
            finish(taskIdentifier: task.taskIdentifier, result: .failure(CursorAPIError.transport("Cursor SDK transport did not negotiate HTTP/2\(protocolName.map { " (got \($0))" } ?? "").")))
            return
        }
        finish(taskIdentifier: task.taskIdentifier, result: .success(data))
    }

    private func state(for task: URLSessionTask) -> RequestState? {
        statesLock.withLock {
            states[task.taskIdentifier]
        }
    }

    private func finish(taskIdentifier: Int, result: Result<Data, any Error>) {
        guard let state = statesLock.withLock({ states[taskIdentifier] }) else {
            return
        }
        let continuation: CheckedContinuation<Data, any Error>? = state.lock.withLock {
            if state.completed { return nil }
            state.completed = true
            let current = state.continuation
            state.continuation = nil
            state.frameHandler = nil
            return current
        }
        statesLock.withLock {
            states[taskIdentifier] = nil
        }
        state.closeStreams()
        switch result {
        case .success(let data):
            continuation?.resume(returning: data)
        case .failure(let error):
            state.task?.cancel()
            continuation?.resume(throwing: error)
        }
    }
}

struct CursorSDKRequestContext: Equatable {
    var id: Int
    var execID: String?

    static func decode(_ payload: Data) -> CursorSDKRequestContext? {
        for field in Proto.decodeFields(payload) {
            guard field.number == 2, case .bytes(let bytes) = field.value else {
                continue
            }
            let fields = Proto.decodeFields(bytes)
            if fields.contains(where: { $0.number == 10 }) {
                return CursorSDKRequestContext(id: Proto.numberField(fields, 1) ?? 0, execID: Proto.stringField(fields, 15))
            }
        }
        return nil
    }
}

struct IncrementalConnectFrameParser {
    private var buffer = Data()

    mutating func push(_ data: Data) -> [Data] {
        buffer.append(data)
        var output: [Data] = []
        while buffer.count >= 5 {
            let length = buffer[1..<5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let frameLength = 5 + Int(length)
            guard buffer.count >= frameLength else { break }
            output.append(Data(buffer[5..<frameLength]))
            buffer.removeSubrange(0..<frameLength)
        }
        return output
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
