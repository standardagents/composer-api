import CursorAPICore
import Foundation
import XCTest

final class LocalAPIServerTests: XCTestCase {
    func testHealthEndpointReportsLoopbackAndSDKReadiness() async throws {
        let port = UInt16(Int.random(in: 10_000...14_999))
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["host"] as? String, "127.0.0.1")
        XCTAssertEqual(object["service"] as? String, CursorAPIBrand.displayName)
        XCTAssertEqual(object["sdkConfigured"] as? Bool, false)
        XCTAssertEqual(object["baseUrl"] as? String, "http://127.0.0.1:\(port)/v1")
    }

    func testModelsEndpoint() async throws {
        let port = UInt16(Int.random(in: 39_000...49_000))
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("composer-2.5"))
        XCTAssertTrue(text.contains("composer-2.5-fast"))
    }

    func testCORSPreflightAllowsSessionHeaders() async throws {
        let port = UInt16(Int.random(in: 63_001...64_000))
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "OPTIONS"
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        let allowedHeaders = http.value(forHTTPHeaderField: "Access-Control-Allow-Headers") ?? ""

        XCTAssertEqual(http.statusCode, 204)
        XCTAssertTrue(allowedHeaders.contains("X-Session-Affinity"))
        XCTAssertTrue(allowedHeaders.contains("X-OpenCode-Session-Id"))
        XCTAssertTrue(allowedHeaders.contains("X-OpenCode-Session"))
        XCTAssertTrue(allowedHeaders.contains("X-CursorAPI-Session"))
        XCTAssertTrue(allowedHeaders.contains("X-Project-Path"))
        XCTAssertTrue(allowedHeaders.contains("OpenAI-Beta"))
    }

    func testChatCompletionsEndpoint() async throws {
        let port = UInt16(Int.random(in: 49_001...59_000))
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"composer-2.5","messages":[{"role":"user","content":"hello"}]}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("chat.completion"))
        XCTAssertTrue(text.contains("ok"))
    }

    func testResponsesEndpoint() async throws {
        let port = UInt16(Int.random(in: 29_000...38_999))
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"composer-2.5","input":"hello"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"object\" : \"response\""))
        XCTAssertTrue(text.contains("ok"))
    }

    func testResponsesEndpointStoresResponseForRetrieval() async throws {
        let port = UInt16(Int.random(in: 29_000...38_999))
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let created = try await postResponse(port: port, body: #"{"model":"composer-2.5","input":"hello"}"#)
        let responseID = try XCTUnwrap(created["id"] as? String)
        let (status, retrieved) = try await getResponse(port: port, responseID: responseID)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(retrieved?["id"] as? String, responseID)
        XCTAssertEqual(retrieved?["object"] as? String, "response")
        XCTAssertEqual(retrieved?["model"] as? String, "composer-2.5")
    }

    func testResponsesEndpointStoresInputItemsForRetrieval() async throws {
        let port = UInt16(Int.random(in: 29_000...38_999))
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let created = try await postResponse(port: port, body: #"{"model":"composer-2.5","input":"hello"}"#)
        let responseID = try XCTUnwrap(created["id"] as? String)
        let (status, list) = try await getResponseInputItems(port: port, responseID: responseID)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(list?["object"] as? String, "list")
        XCTAssertEqual(list?["has_more"] as? Bool, false)
        XCTAssertEqual(list?["first_id"] as? String, "item_0")
        XCTAssertEqual(list?["last_id"] as? String, "item_0")
        let data = try XCTUnwrap(list?["data"] as? [[String: Any]])
        let item = try XCTUnwrap(data.first)
        XCTAssertEqual(item["id"] as? String, "item_0")
        XCTAssertEqual(item["type"] as? String, "message")
        XCTAssertEqual(item["role"] as? String, "user")
        let content = try XCTUnwrap(item["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "input_text")
        XCTAssertEqual(content.first?["text"] as? String, "hello")
    }

    func testResponsesEndpointInputItemsPreserveStructuredToolOutputs() async throws {
        let port = UInt16(Int.random(in: 29_000...38_999))
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let created = try await postResponse(port: port, body: #"""
        {
          "model":"composer-2.5",
          "input":[
            {"type":"function_call","call_id":"call_1","name":"shell","arguments":"{\"command\":\"pwd\"}"},
            {"type":"function_call_output","call_id":"call_1","output":"/tmp/project"}
          ]
        }
        """#)
        let responseID = try XCTUnwrap(created["id"] as? String)
        let (status, list) = try await getResponseInputItems(port: port, responseID: responseID)

        XCTAssertEqual(status, 200)
        let data = try XCTUnwrap(list?["data"] as? [[String: Any]])
        XCTAssertEqual(data.count, 2)
        XCTAssertEqual(data[0]["id"] as? String, "item_0")
        XCTAssertEqual(data[0]["type"] as? String, "function_call")
        XCTAssertEqual(data[0]["call_id"] as? String, "call_1")
        XCTAssertEqual(data[1]["id"] as? String, "item_1")
        XCTAssertEqual(data[1]["type"] as? String, "function_call_output")
        XCTAssertEqual(data[1]["output"] as? String, "/tmp/project")
    }

    func testResponsesStoreFalseDoesNotPersistForRetrieval() async throws {
        let port = UInt16(Int.random(in: 29_000...38_999))
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let created = try await postResponse(port: port, body: #"{"model":"composer-2.5","store":false,"input":"hello"}"#)
        let responseID = try XCTUnwrap(created["id"] as? String)
        let (status, retrieved) = try await getResponse(port: port, responseID: responseID)
        let (inputItemsStatus, inputItems) = try await getResponseInputItems(port: port, responseID: responseID)

        XCTAssertEqual(status, 404)
        XCTAssertNil(retrieved?["id"])
        XCTAssertEqual(inputItemsStatus, 404)
        XCTAssertNil(inputItems?["data"])
    }

    func testStreamingResponsesStoreCompletedResponseForRetrieval() async throws {
        let port = UInt16(Int.random(in: 29_000...38_999))
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"composer-2.5","stream":true,"input":"hello"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(data: data, encoding: .utf8) ?? ""
        let responseID = try XCTUnwrap(text.firstMatch(of: /"id":"(resp_[A-Za-z0-9]+)"/)?.1)
        let (status, retrieved) = try await getResponse(port: port, responseID: String(responseID))
        let (inputItemsStatus, inputItems) = try await getResponseInputItems(port: port, responseID: String(responseID))

        XCTAssertEqual(status, 200)
        XCTAssertEqual(retrieved?["id"] as? String, String(responseID))
        XCTAssertEqual(retrieved?["object"] as? String, "response")
        XCTAssertEqual(inputItemsStatus, 200)
        XCTAssertEqual(inputItems?["object"] as? String, "list")
    }

    func testResponsesPreviousResponseIDContinuesSameSDKSession() async throws {
        let port = UInt16(Int.random(in: 29_000...38_999))
        let recorder = PreparedRequestRecorder()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(recorder: recorder))
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let first = try await postResponse(port: port, body: #"{"model":"composer-2.5","input":"first"}"#)
        let firstID = try XCTUnwrap(first["id"] as? String)
        let second = try await postResponse(port: port, body: #"{"model":"composer-2.5","previous_response_id":"\#(firstID)","input":"second"}"#)

        XCTAssertEqual(second["previous_response_id"] as? String, firstID)
        let sessionKeys = await recorder.sessionKeys()
        XCTAssertEqual(sessionKeys.count, 2)
        XCTAssertEqual(sessionKeys[0], sessionKeys[1])
        XCTAssertTrue(sessionKeys[0].hasPrefix("response:"))
    }

    func testResponsesProjectMetadataSeparatesAndReusesSDKSessions() async throws {
        let port = UInt16(Int.random(in: 29_000...38_999))
        let recorder = PreparedRequestRecorder()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(recorder: recorder))
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        _ = try await postResponse(port: port, body: #"{"model":"composer-2.5","metadata":{"project_path":"/tmp/project-a"},"input":"a1"}"#)
        _ = try await postResponse(port: port, body: #"{"model":"composer-2.5","metadata":{"project_path":"/tmp/project-b"},"input":"b1"}"#)
        _ = try await postResponse(port: port, body: #"{"model":"composer-2.5","metadata":{"project_path":"/tmp/project-a"},"input":"a2"}"#)

        let sessionKeys = await recorder.sessionKeys()
        XCTAssertEqual(sessionKeys.count, 3)
        XCTAssertEqual(sessionKeys[0], sessionKeys[2])
        XCTAssertNotEqual(sessionKeys[0], sessionKeys[1])
        XCTAssertTrue(sessionKeys[0].contains("/tmp/project-a"))
        XCTAssertTrue(sessionKeys[1].contains("/tmp/project-b"))
    }

    func testResponsesConcurrentProjectMetadataKeepsIndependentSessions() async throws {
        let port = UInt16(Int.random(in: 29_000...38_999))
        let recorder = PreparedRequestRecorder()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(delayNanoseconds: 50_000_000, recorder: recorder))
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let projects = (0..<8).map { "/tmp/project-\($0)" }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for project in projects {
                group.addTask {
                    try await sendResponseRequest(
                        port: port,
                        body: #"{"model":"composer-2.5","metadata":{"project_path":"\#(project)"},"input":"hello"}"#
                    )
                }
            }
            try await group.waitForAll()
        }

        let sessionKeys = await recorder.sessionKeys()
        XCTAssertEqual(Set(sessionKeys).count, projects.count)
        for project in projects {
            XCTAssertTrue(sessionKeys.contains { $0.contains(project) }, "Missing session key for \(project)")
        }
    }

    func testResponsesRequestIncludesToolsAndFunctionOutputsInPrompt() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model": "composer-2.5",
          "tools": [
            {
              "type": "function",
              "name": "shell",
              "description": "Run a shell command",
              "parameters": {
                "type": "object",
                "properties": {
                  "command": { "type": "string" }
                }
              }
            }
          ],
          "input": [
            {
              "type": "function_call",
              "call_id": "call_1",
              "name": "shell",
              "arguments": "{\"command\":\"pwd\"}"
            },
            {
              "type": "function_call_output",
              "call_id": "call_1",
              "output": "/tmp/project"
            }
          ]
        }
        """#.utf8))

        XCTAssertEqual(prepared.tools.map(\.name), ["shell"])
        XCTAssertTrue(prepared.prompt.contains("LOCAL TOOL INVENTORY"))
        XCTAssertTrue(prepared.prompt.contains("FUNCTION CALL OUTPUT"))
        XCTAssertTrue(prepared.prompt.contains("LOCAL TOOL RESULT"))
        XCTAssertTrue(prepared.prompt.contains("/tmp/project"))
    }

    func testResponsesEndpointReturnsFunctionCallOutputItems() async throws {
        let port = UInt16(Int.random(in: 24_000...28_999))
        let toolCall = CursorToolCall(name: "shell", arguments: ["command": .string("pwd")])
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(events: [
            .toolCall(toolCall),
            .done(CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test"))
        ]))
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"""
        {
          "model":"composer-2.5",
          "input":"run pwd",
          "tools":[{"type":"function","name":"shell","parameters":{"type":"object","properties":{"command":{"type":"string"}}}}]
        }
        """#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = try XCTUnwrap(object["output"] as? [[String: Any]])
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?["type"] as? String, "function_call")
        let functionCall = try XCTUnwrap(output.first { ($0["type"] as? String) == "function_call" })
        XCTAssertEqual(functionCall["name"] as? String, "shell")
        XCTAssertTrue((functionCall["arguments"] as? String)?.contains("pwd") == true)
        XCTAssertTrue((functionCall["call_id"] as? String)?.hasPrefix("call_") == true)
    }

    func testChatToolCallsMapSDKShellToClientBashSchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"run pwd"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"bash",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "command":{"type":"string"},
                    "cwd":{"type":"string"},
                    "timeout_ms":{"type":"number"}
                  }
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "shell", arguments: [
            "command": .string("pwd"),
            "workingDirectory": .string("/tmp/project"),
            "timeout": .number(30)
        ])

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)

        XCTAssertEqual(function["name"] as? String, "bash")
        XCTAssertEqual(arguments["command"] as? String, "pwd")
        XCTAssertEqual(arguments["cwd"] as? String, "/tmp/project")
        XCTAssertEqual((arguments["timeout_ms"] as? NSNumber)?.doubleValue, 30)
        XCTAssertNil(arguments["workingDirectory"])
        XCTAssertNil(arguments["timeout"])
    }

    func testResponsesFunctionCallsMapSDKWriteToClientFileSchema() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"create a file",
          "tools":[
            {
              "type":"function",
              "name":"write_file",
              "parameters":{
                "type":"object",
                "properties":{
                  "file_path":{"type":"string"},
                  "content":{"type":"string"}
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "write", arguments: [
            "path": .string("index.html"),
            "fileText": .string("<h1>Hello</h1>")
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_test",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let output = try XCTUnwrap(object["output"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(output.first { ($0["type"] as? String) == "function_call" })
        let arguments = try decodedArguments(functionCall)

        XCTAssertEqual(functionCall["name"] as? String, "write_file")
        XCTAssertEqual(arguments["file_path"] as? String, "index.html")
        XCTAssertEqual(arguments["content"] as? String, "<h1>Hello</h1>")
        XCTAssertNil(arguments["path"])
        XCTAssertNil(arguments["fileText"])
    }

    func testFunctionCallsPreserveSDKToolWhenNoClientToolMatches() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"run pwd",
          "tools":[{"type":"function","name":"notify","parameters":{"type":"object","properties":{"message":{"type":"string"}}}}]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "shell", arguments: ["command": .string("pwd")])

        let object = OpenAICompatibility.responseObject(
            id: "resp_test",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let output = try XCTUnwrap(object["output"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(output.first { ($0["type"] as? String) == "function_call" })
        let arguments = try decodedArguments(functionCall)

        XCTAssertEqual(functionCall["name"] as? String, "shell")
        XCTAssertEqual(arguments["command"] as? String, "pwd")
    }

    func testChatCompletionsStreamingFlushesTextDeltas() async throws {
        let port = UInt16(Int.random(in: 20_000...28_999))
        let harness = MockHarness(
            events: [
                .text("first"),
                .text("second"),
                .done(CursorSDKOutput(text: "firstsecond", agentID: "agent-test", runID: "run-test"))
            ],
            delayNanoseconds: 300_000_000
        )
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: harness)
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"composer-2.5","stream":true,"messages":[{"role":"user","content":"hello"}]}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let started = Date()
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream; charset=utf-8")

        var firstContentLine: String?
        for try await line in bytes.lines {
            if line.contains(#""content":"first""#) {
                firstContentLine = line
                break
            }
        }

        XCTAssertNotNil(firstContentLine)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
    }

    func testResponsesStreamingUsesResponsesEvents() async throws {
        let port = UInt16(Int.random(in: 15_000...19_999))
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(events: [
            .text("ok"),
            .done(CursorSDKOutput(text: "ok", agentID: "agent-test", runID: "run-test"))
        ]))
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"composer-2.5","stream":true,"input":"hello"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("event: response.created"))
        XCTAssertTrue(text.contains("event: response.content_part.added"))
        XCTAssertTrue(text.contains("event: response.output_text.delta"))
        XCTAssertTrue(text.contains("event: response.output_text.done"))
        XCTAssertTrue(text.contains("event: response.completed"))
    }

    func testResponsesStreamingEmitsFunctionCallEvents() async throws {
        let port = UInt16(Int.random(in: 60_000...62_000))
        let toolCall = CursorToolCall(name: "shell", arguments: ["command": .string("pwd")])
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(events: [
            .toolCall(toolCall),
            .done(CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test"))
        ]))
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"""
        {
          "model":"composer-2.5",
          "stream":true,
          "input":"run pwd",
          "tools":[{"type":"function","name":"shell","parameters":{"type":"object","properties":{"command":{"type":"string"}}}}]
        }
        """#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("event: response.function_call_arguments.delta"))
        XCTAssertTrue(text.contains("event: response.function_call_arguments.done"))
        XCTAssertTrue(text.contains(#""type":"function_call""#))
        XCTAssertTrue(text.contains(#""name":"shell""#))
        XCTAssertTrue(text.contains("pwd"))
        XCTAssertFalse(text.contains("event: response.content_part.added"))
        XCTAssertFalse(text.contains("event: response.output_text.done"))
        XCTAssertFalse(text.contains(#""type":"message""#))
    }
}

private func sendResponseRequest(port: UInt16, body: String) async throws {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
    request.httpMethod = "POST"
    request.httpBody = Data(body.utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (_, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode
    guard status == 200 else {
        throw NSError(domain: "CursorAPITests", code: status ?? -1)
    }
}

private extension LocalAPIServerTests {
    func postResponse(port: UInt16, body: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func getResponse(port: UInt16, responseID: String) async throws -> (Int, [String: Any]?) {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/responses/\(responseID)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (status, object)
    }

    func getResponseInputItems(port: UInt16, responseID: String) async throws -> (Int, [String: Any]?) {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/responses/\(responseID)/input_items")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (status, object)
    }

    func decodedArguments(_ function: [String: Any]) throws -> [String: Any] {
        let arguments = try XCTUnwrap(function["arguments"] as? String)
        let data = Data(arguments.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor PreparedRequestRecorder {
    private var requests: [PreparedChatRequest] = []

    func record(_ request: PreparedChatRequest) {
        requests.append(request)
    }

    func sessionKeys() -> [String] {
        requests.map { $0.sessionKey ?? "" }
    }
}

private struct MockHarness: CursorSDKHarness {
    var events: [CursorSDKStreamEvent]
    var delayNanoseconds: UInt64
    var recorder: PreparedRequestRecorder?

    init(text: String = "ok", delayNanoseconds: UInt64 = 0, recorder: PreparedRequestRecorder? = nil) {
        self.events = [
            .text(text),
            .done(CursorSDKOutput(text: text, agentID: "agent-test", runID: "run-test"))
        ]
        self.delayNanoseconds = delayNanoseconds
        self.recorder = recorder
    }

    init(events: [CursorSDKStreamEvent], delayNanoseconds: UInt64 = 0, recorder: PreparedRequestRecorder? = nil) {
        self.events = events
        self.delayNanoseconds = delayNanoseconds
        self.recorder = recorder
    }

    func stream(prepared: PreparedChatRequest, settings: CursorAPISettings, authorization: String?) -> AsyncThrowingStream<CursorSDKStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    await recorder?.record(prepared)
                    for event in events {
                        if delayNanoseconds > 0 {
                            try await Task.sleep(nanoseconds: delayNanoseconds)
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
