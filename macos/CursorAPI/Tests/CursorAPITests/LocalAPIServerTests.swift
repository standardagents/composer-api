import CursorAPICore
import Darwin
import Foundation
import XCTest

final class LocalAPIServerTests: XCTestCase {
    func testHealthEndpointReportsLoopbackAndSDKReadiness() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["host"] as? String, "127.0.0.1")
        XCTAssertEqual(object["service"] as? String, CursorAPIBrand.displayName)
        XCTAssertEqual(object["routingConfigured"] as? Bool, true)
        XCTAssertEqual(object["sdkConfigured"] as? Bool, true)
        XCTAssertEqual(object["apiKeyConfigured"] as? Bool, false)
        XCTAssertEqual(object["apiKeyUnlocked"] as? Bool, false)
        XCTAssertEqual(object["keychainKeyAvailable"] as? Bool, false)
        XCTAssertEqual(object["ready"] as? Bool, false)
        XCTAssertEqual(object["status"] as? String, "needs_api_key")
        XCTAssertEqual(object["baseUrl"] as? String, "http://127.0.0.1:\(port)/v1")
        XCTAssertEqual(object["missing"] as? [String], ["cursorAPIKey"])
        XCTAssertEqual(object["models"] as? [String], ["composer-2.5", "composer-2.5-fast"])
        let responses = try XCTUnwrap(object["responses"] as? [String: Any])
        XCTAssertEqual((responses["sessions"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((responses["stored"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((responses["inputItems"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((responses["toolCallMemory"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((responses["maxStored"] as? NSNumber)?.intValue, 512)
        let routing = try XCTUnwrap(object["routing"] as? [String: Any])
        XCTAssertEqual(routing["configured"] as? Bool, true)
        XCTAssertEqual(routing["sdkBridgeConfigured"] as? Bool, true)
    }

    func testHealthEndpointReportsSanitizedReadyState() async throws {
        let port = try unusedTCPPort()
        let settings = CursorAPISettings(
            port: port,
            cursorAPIKey: "crsr_test",
            cursorAPIBaseURL: "https://exchange.example",
            backendBaseURL: "https://redacted-backend.example",
            localAgentEndpoint: "/redacted/sdk/run",
            clientVersion: "sdk-test"
        )
        let server = LocalAPIServer(settingsProvider: { settings }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let text = String(data: data, encoding: .utf8) ?? ""

        XCTAssertEqual(object["ready"] as? Bool, true)
        XCTAssertEqual(object["status"] as? String, "ready")
        XCTAssertEqual(object["apiKeyConfigured"] as? Bool, true)
        XCTAssertEqual(object["apiKeyUnlocked"] as? Bool, true)
        XCTAssertEqual(object["keychainKeyAvailable"] as? Bool, false)
        XCTAssertEqual(object["routingConfigured"] as? Bool, true)
        XCTAssertEqual(object["sdkConfigured"] as? Bool, true)
        XCTAssertEqual(object["missing"] as? [String], [])
        XCTAssertFalse(text.contains("crsr_test"))
        XCTAssertFalse(text.contains("exchange.example"))
        XCTAssertFalse(text.contains("redacted-backend.example"))
        XCTAssertFalse(text.contains("/redacted/sdk/run"))
    }

    func testHealthEndpointReportsReadyWhenInlineKeyIsPresent() async throws {
        let port = try unusedTCPPort()
        let settings = CursorAPISettings(port: port, cursorAPIKey: "crsr_test")
        let server = LocalAPIServer(settingsProvider: { settings }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["ready"] as? Bool, true)
        XCTAssertEqual(object["status"] as? String, "ready")
        XCTAssertEqual(object["apiKeyConfigured"] as? Bool, true)
        XCTAssertEqual(object["apiKeyUnlocked"] as? Bool, true)
        XCTAssertEqual(object["routingConfigured"] as? Bool, true)
        XCTAssertEqual(object["missing"] as? [String], [])
    }

    func testHealthEndpointReportsNeedsUnlockForSavedKeyOnly() async throws {
        let port = try unusedTCPPort()
        let settings = CursorAPISettings(
            port: port,
            keychainCursorAPIKeyAvailable: true,
            cursorAPIBaseURL: "https://exchange.example",
            backendBaseURL: "https://redacted-backend.example",
            localAgentEndpoint: "/redacted/sdk/run"
        )
        let server = LocalAPIServer(settingsProvider: { settings }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["ready"] as? Bool, false)
        XCTAssertEqual(object["status"] as? String, "needs_unlock")
        XCTAssertEqual(object["apiKeyConfigured"] as? Bool, true)
        XCTAssertEqual(object["apiKeyUnlocked"] as? Bool, false)
        XCTAssertEqual(object["keychainKeyAvailable"] as? Bool, true)
        XCTAssertEqual(object["routingConfigured"] as? Bool, true)
        XCTAssertEqual(object["missing"] as? [String], [])
    }

    func testStreamingRequestsReturnHTTPErrorWhenSavedKeyIsLocked() async throws {
        let port = try unusedTCPPort()
        let settings = CursorAPISettings(
            port: port,
            keychainCursorAPIKeyAvailable: true,
            cursorAPIBaseURL: "https://exchange.example",
            backendBaseURL: "https://redacted-backend.example",
            localAgentEndpoint: "/redacted/sdk/run"
        )
        let server = LocalAPIServer(settingsProvider: { settings })
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let cases = [
            ("/v1/chat/completions", #"{"model":"composer-2.5","stream":true,"messages":[{"role":"user","content":"hello"}]}"#),
            ("/v1/responses", #"{"model":"composer-2.5","stream":true,"input":"hello"}"#)
        ]

        for (path, body) in cases {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer cursor-local", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse, path)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], path)
            let error = try XCTUnwrap(object["error"] as? [String: Any], path)

            XCTAssertEqual(http.statusCode, 401, path)
            XCTAssertEqual(error["code"] as? String, "keychain_locked", path)
            XCTAssertTrue((error["message"] as? String)?.contains("Unlock Key") == true, path)
        }
    }

    func testRootEndpointReportsLocalOpenAICompatibilityMetadata() async throws {
        let port = try unusedTCPPort()
        let settings = CursorAPISettings(
            port: port,
            cursorAPIKey: "crsr_test",
            cursorAPIBaseURL: "https://exchange.example",
            backendBaseURL: "https://redacted-backend.example",
            localAgentEndpoint: "/redacted/sdk/run"
        )
        let server = LocalAPIServer(settingsProvider: { settings }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        for path in ["/", "/v1"] {
            let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, path)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], path)
            let endpoints = try XCTUnwrap(object["endpoints"] as? [String: String], path)
            let features = try XCTUnwrap(object["features"] as? [String: Bool], path)
            let text = String(data: data, encoding: .utf8) ?? ""

            XCTAssertEqual(object["object"] as? String, "api.service", path)
            XCTAssertEqual(object["service"] as? String, CursorAPIBrand.displayName, path)
            XCTAssertEqual(object["baseUrl"] as? String, "http://127.0.0.1:\(port)/v1", path)
            XCTAssertEqual(object["ready"] as? Bool, true, path)
            XCTAssertEqual(object["status"] as? String, "ready", path)
            XCTAssertEqual(object["models"] as? [String], ["composer-2.5", "composer-2.5-fast"], path)
            XCTAssertEqual(endpoints["models"], "/v1/models", path)
            XCTAssertEqual(endpoints["chat_completions"], "/v1/chat/completions", path)
            XCTAssertEqual(endpoints["responses"], "/v1/responses", path)
            XCTAssertEqual(endpoints["response_input_tokens"], "POST /v1/responses/input_tokens", path)
            XCTAssertEqual(endpoints["compact_response"], "POST /v1/responses/compact", path)
            XCTAssertEqual(endpoints["delete_response"], "DELETE /v1/responses/{response_id}", path)
            XCTAssertEqual(endpoints["cancel_response"], "POST /v1/responses/{response_id}/cancel", path)
            XCTAssertEqual(features["stateful_responses"], true, path)
            XCTAssertEqual(features["response_input_tokens"], true, path)
            XCTAssertEqual(features["response_compaction"], true, path)
            XCTAssertEqual(features["response_deletion"], true, path)
            XCTAssertEqual(features["response_cancellation"], false, path)
            XCTAssertEqual(features["tool_calls"], true, path)
            XCTAssertFalse(text.contains("crsr_test"), path)
            XCTAssertFalse(text.contains("exchange.example"), path)
            XCTAssertFalse(text.contains("redacted-backend.example"), path)
            XCTAssertFalse(text.contains("/redacted/sdk/run"), path)
        }
    }

    func testRequestObserverRecordsJSONStreamingAndErrorRequests() async throws {
        let port = try unusedTCPPort()
        let recorder = LocalAPIRequestEventRecorder()
        let server = LocalAPIServer(
            settingsProvider: { CursorAPISettings(port: port) },
            harness: MockHarness(),
            requestObserver: { recorder.record($0) }
        )
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/models")!)

        var streaming = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        streaming.httpMethod = "POST"
        streaming.httpBody = Data(#"{"model":"composer-2.5","messages":[{"role":"user","content":"hello"}],"stream":true}"#.utf8)
        streaming.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await URLSession.shared.data(for: streaming)

        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/missing")!)

        let events = recorder.events()
        XCTAssertEqual(events.map(\.path), ["/v1/models", "/v1/chat/completions", "/missing"])
        XCTAssertEqual(events.map(\.status), [200, 200, 404])
        XCTAssertEqual(events.map(\.streaming), [false, true, false])
        XCTAssertTrue(events.allSatisfy { $0.durationMilliseconds >= 0 })
    }

    func testStartFailsWhenPortIsAlreadyInUse() throws {
        let port = try unusedTCPPort()
        let first = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        let second = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try first.start(port: port)
        defer {
            first.stop()
            second.stop()
        }

        XCTAssertThrowsError(try second.start(port: port)) { error in
            XCTAssertTrue(error.localizedDescription.contains("127.0.0.1:\(port)"))
        }
        XCTAssertNil(second.port)
    }

    func testStartFallsBackWhenPreferredPortIsAlreadyInUse() async throws {
        var port = try unusedTCPPort()
        while port > UInt16.max - 20 {
            port = try unusedTCPPort()
        }
        let preferredPort = port
        let first = LocalAPIServer(settingsProvider: { CursorAPISettings(port: preferredPort) }, harness: MockHarness())
        let second = LocalAPIServer(settingsProvider: { CursorAPISettings(port: preferredPort) }, harness: MockHarness())
        try first.start(port: preferredPort)
        defer {
            first.stop()
            second.stop()
        }

        let selectedPort = try second.start(preferredPort: preferredPort, fallbackLimit: 20)
        XCTAssertNotEqual(selectedPort, preferredPort)
        XCTAssertEqual(second.port, selectedPort)
        try await Task.sleep(nanoseconds: 150_000_000)

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(selectedPort)/health")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testModelsEndpoint() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dataModels = try XCTUnwrap(object["data"] as? [[String: Any]])
        let codexModels = try XCTUnwrap(object["models"] as? [[String: Any]])
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("composer-2.5"))
        XCTAssertTrue(text.contains("composer-2.5-fast"))
        XCTAssertEqual(dataModels.compactMap { $0["id"] as? String }, ["composer-2.5", "composer-2.5-fast"])
        XCTAssertEqual(codexModels.compactMap { $0["slug"] as? String }, ["composer-2.5", "composer-2.5-fast"])
        XCTAssertEqual(codexModels.first?["display_name"] as? String, "Composer 2.5")
        XCTAssertEqual(codexModels.first?["shell_type"] as? String, "shell_command")
        XCTAssertEqual(codexModels.first?["visibility"] as? String, "list")
        XCTAssertEqual(codexModels.first?["supported_in_api"] as? Bool, true)
        XCTAssertEqual(codexModels.first?["context_window"] as? Int, 200_000)
        XCTAssertNotNil(codexModels.first?["truncation_policy"] as? [String: Any])
    }

    func testHeadReadEndpointsReturnStatusWithoutBody() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        for path in ["/", "/v1", "/health", "/v1/models", "/v1/models/composer-2.5-fast"] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = "HEAD"
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse, path)

            XCTAssertEqual(http.statusCode, 200, path)
            XCTAssertTrue(data.isEmpty, path)
            XCTAssertEqual(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*", path)
        }

        var missingRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models/not-a-model")!)
        missingRequest.httpMethod = "HEAD"
        let (missingData, missingResponse) = try await URLSession.shared.data(for: missingRequest)

        XCTAssertEqual((missingResponse as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertTrue(missingData.isEmpty)
    }

    func testHeadReadEndpointsPreserveGetContentLength() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let getRequest = [
            "GET /v1/models HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        let headRequest = [
            "HEAD /v1/models HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        let getResponse = try await sendRawHTTPRequest(port: port, request: getRequest)
        let headResponse = try await sendRawHTTPRequest(port: port, request: headRequest)

        XCTAssertTrue(getResponse.hasPrefix("HTTP/1.1 200 OK"), getResponse)
        XCTAssertTrue(headResponse.hasPrefix("HTTP/1.1 200 OK"), headResponse)
        XCTAssertEqual(responseHeaderValue("Content-Length", in: headResponse), responseHeaderValue("Content-Length", in: getResponse))
        XCTAssertTrue(responseBody(headResponse).isEmpty, headResponse)
    }

    func testModelsEndpointAcceptsOriginBaseURLAndTrailingSlash() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/models/")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("composer-2.5"))
        XCTAssertTrue(text.contains("composer-2.5-fast"))
    }

    func testModelsEndpointAcceptsAbsoluteFormRequestTarget() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let request = [
            "GET http://127.0.0.1:\(port)/v1/models HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        let response = try await sendRawHTTPRequest(port: port, request: request)

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"), response)
        XCTAssertTrue(response.contains("composer-2.5"), response)
        XCTAssertTrue(response.contains("composer-2.5-fast"), response)
    }

    func testModelRetrieveEndpoint() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/models/composer-2.5-fast")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["id"] as? String, "composer-2.5-fast")
        XCTAssertEqual(object["object"] as? String, "model")
        XCTAssertEqual(object["owned_by"] as? String, "cursor")
        XCTAssertEqual(object["name"] as? String, "Composer 2.5 Fast")
        let limit = try XCTUnwrap(object["limit"] as? [String: Any])
        XCTAssertEqual((limit["context"] as? NSNumber)?.intValue, 200_000)
        XCTAssertEqual((limit["output"] as? NSNumber)?.intValue, 65_536)
    }

    func testModelRetrieveEndpointAcceptsDashAlias() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/models/composer-2-5-fast")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["id"] as? String, "composer-2.5-fast")
    }

    func testModelRetrieveEndpointAcceptsProviderPrefixedAliases() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let paths = [
            "/v1/models/cursorapi%2Fcomposer-2.5-fast-sdk",
            "/v1/models/cursorapi/composer-2.5-fast-sdk"
        ]

        for path in paths {
            let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, path)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["id"] as? String, "composer-2.5-fast", path)
        }
    }

    func testUnknownModelRetrieveEndpointReturns404() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/models/not-a-model")!)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
    }

    func testRequestModelAliasesNormalizeToComposerModels() async throws {
        let port = try unusedTCPPort()
        let recorder = PreparedRequestRecorder()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(recorder: recorder))
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"cursorapi/composer-2.5-fast-sdk","input":"hello"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["model"] as? String, "composer-2.5-fast")
        let models = await recorder.models()
        let cursorModelIDs = await recorder.cursorModelIDs()
        XCTAssertEqual(models, ["composer-2.5-fast"])
        XCTAssertEqual(cursorModelIDs, ["composer-2.5-fast"])
    }

    func testUnknownRequestModelsReturn404() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let requests = [
            ("/v1/completions", #"{"model":"not-a-model","prompt":"hello"}"#),
            ("/v1/chat/completions", #"{"model":"not-a-model","messages":[{"role":"user","content":"hello"}]}"#),
            ("/v1/responses", #"{"model":"not-a-model","input":"hello"}"#)
        ]

        for (path, body) in requests {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404, path)
            let text = String(data: data, encoding: .utf8) ?? ""
            XCTAssertTrue(text.contains(#""code":"not_found""#) || text.contains(#""code" : "not_found""#), path)
        }
    }

    func testCORSPreflightAllowsSessionHeaders() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "OPTIONS"
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        let allowedHeaders = http.value(forHTTPHeaderField: "Access-Control-Allow-Headers") ?? ""
        let allowedMethods = http.value(forHTTPHeaderField: "Access-Control-Allow-Methods") ?? ""

        XCTAssertEqual(http.statusCode, 204)
        XCTAssertTrue(allowedHeaders.contains("X-Session-Affinity"))
        XCTAssertTrue(allowedHeaders.contains("X-OpenCode-Session-Id"))
        XCTAssertTrue(allowedHeaders.contains("X-OpenCode-Session"))
        XCTAssertTrue(allowedHeaders.contains("X-CursorAPI-Session"))
        XCTAssertTrue(allowedHeaders.contains("X-Project-Path"))
        XCTAssertTrue(allowedHeaders.contains("OpenAI-Beta"))
        XCTAssertTrue(allowedHeaders.contains("X-Request-ID"))
        XCTAssertTrue(allowedHeaders.contains("X-Stainless-Lang"))
        XCTAssertTrue(allowedHeaders.contains("X-Stainless-Retry-Count"))
        XCTAssertEqual(http.value(forHTTPHeaderField: "Access-Control-Max-Age"), "86400")
        XCTAssertTrue(allowedMethods.contains("HEAD"))
    }

    func testCORSPreflightUsesStandardNoContentStatusLine() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let request = [
            "OPTIONS /v1/responses HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
            "Origin: http://localhost:3000",
            "Access-Control-Request-Method: POST",
            "Access-Control-Request-Headers: X-Stainless-Lang, X-Stainless-Retry-Count, X-Request-ID",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        let response = try await sendRawHTTPRequest(port: port, request: request)

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 204 No Content"), response)
        XCTAssertEqual(responseHeaderValue("Access-Control-Max-Age", in: response), "86400")
        let allowedHeaders = responseHeaderValue("Access-Control-Allow-Headers", in: response) ?? ""
        XCTAssertTrue(allowedHeaders.contains("X-Stainless-Lang"), response)
        XCTAssertTrue(allowedHeaders.contains("X-Stainless-Retry-Count"), response)
        XCTAssertTrue(allowedHeaders.contains("X-Request-ID"), response)
    }

    func testCompletionsEndpoint() async throws {
        let port = try unusedTCPPort()
        let recorder = PreparedRequestRecorder()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(recorder: recorder))
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/completions")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"composer-2.5","prompt":"hello"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])

        XCTAssertEqual(object["object"] as? String, "text_completion")
        XCTAssertEqual(choices.first?["text"] as? String, "ok")
        let prompts = await recorder.prompts()
        XCTAssertTrue(prompts.first?.contains("PROMPT:\nhello") == true)
    }

    func testCompletionsEndpointAcceptsOriginBaseURL() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/completions")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"composer-2.5","prompt":"hello"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("text_completion"))
        XCTAssertTrue(text.contains("ok"))
    }

    func testCompletionsStreamingEndpoint() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(events: [
            .text("hel"),
            .text("lo"),
            .done(CursorSDKOutput(text: "hello", agentID: "agent-test", runID: "run-test"))
        ]))
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/completions")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"composer-2.5","prompt":"hello","stream":true}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(text.contains(#""object":"text_completion""#))
        XCTAssertTrue(text.contains(#""text":"hel""#))
        XCTAssertTrue(text.contains(#""text":"lo""#))
        XCTAssertTrue(text.contains("data: [DONE]"))
    }

    func testChatCompletionsEndpoint() async throws {
        let port = try unusedTCPPort()
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

    func testChatCompletionsAcceptsChunkedRequestBody() async throws {
        let port = try unusedTCPPort()
        let recorder = PreparedRequestRecorder()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(recorder: recorder))
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let body = #"{"model":"composer-2.5","messages":[{"role":"user","content":"hello from chunked"}]}"#
        let request = [
            "POST /v1/chat/completions HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
            "Content-Type: application/json",
            "Transfer-Encoding: chunked",
            "Connection: close",
            "",
            chunkedBody(body, sizes: [7, 13, 3])
        ].joined(separator: "\r\n")
        let response = try await sendRawHTTPRequest(port: port, request: request)

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"), response)
        XCTAssertTrue(response.contains("chat.completion"), response)
        let prompts = await recorder.prompts()
        XCTAssertTrue(prompts.first?.contains("hello from chunked") == true)
    }

    func testChatCompletionsSupportsExpectContinueHandshake() async throws {
        let port = try unusedTCPPort()
        let recorder = PreparedRequestRecorder()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(recorder: recorder))
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let body = #"{"model":"composer-2.5","messages":[{"role":"user","content":"hello after continue"}]}"#
        let headers = [
            "POST /v1/chat/completions HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
            "Content-Type: application/json",
            "Content-Length: \(body.utf8.count)",
            "Expect: 100-continue",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        let (interim, final) = try await sendExpectContinueHTTPRequest(port: port, headers: headers, body: body)

        XCTAssertTrue(interim.hasPrefix("HTTP/1.1 100 Continue"), interim)
        XCTAssertTrue(final.hasPrefix("HTTP/1.1 200 OK"), final)
        XCTAssertTrue(final.contains("chat.completion"), final)
        let prompts = await recorder.prompts()
        XCTAssertTrue(prompts.first?.contains("hello after continue") == true)
    }

    func testChatCompletionsEndpointAcceptsOriginBaseURL() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/chat/completions")!)
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
        let port = try unusedTCPPort()
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
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let usage = try XCTUnwrap(object["usage"] as? [String: Any])
        XCTAssertGreaterThan((usage["input_tokens"] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertGreaterThanOrEqual((usage["output_tokens"] as? NSNumber)?.intValue ?? -1, 0)
        XCTAssertNotNil(usage["input_tokens_details"])
        XCTAssertNotNil(usage["output_tokens_details"])
    }

    func testResponsesEndpointAcceptsOriginBaseURLForStorageAndRetrieval() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"composer-2.5","input":"hello"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (createdData, createdResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((createdResponse as? HTTPURLResponse)?.statusCode, 200)
        let created = try XCTUnwrap(JSONSerialization.jsonObject(with: createdData) as? [String: Any])
        let responseID = try XCTUnwrap(created["id"] as? String)

        let (retrievedData, retrievedResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/responses/\(responseID)/")!)
        XCTAssertEqual((retrievedResponse as? HTTPURLResponse)?.statusCode, 200)
        let retrieved = try XCTUnwrap(JSONSerialization.jsonObject(with: retrievedData) as? [String: Any])
        XCTAssertEqual(retrieved["id"] as? String, responseID)

        let (itemsData, itemsResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/responses/\(responseID)/input_items/")!)
        XCTAssertEqual((itemsResponse as? HTTPURLResponse)?.statusCode, 200)
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: itemsData) as? [String: Any])
        XCTAssertEqual(items["object"] as? String, "list")
    }

    func testResponsesEndpointStoresResponseForRetrieval() async throws {
        let port = try unusedTCPPort()
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
        let port = try unusedTCPPort()
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
        let port = try unusedTCPPort()
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

    func testResponsesInputItemsSupportCursorPagination() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let created = try await postResponse(port: port, body: #"""
        {
          "model":"composer-2.5",
          "input":[
            "first",
            "second",
            "third"
          ]
        }
        """#)
        let responseID = try XCTUnwrap(created["id"] as? String)

        let (firstStatus, firstPage) = try await getResponseInputItems(port: port, responseID: responseID, query: "limit=1")
        XCTAssertEqual(firstStatus, 200)
        XCTAssertEqual(firstPage?["first_id"] as? String, "item_0")
        XCTAssertEqual(firstPage?["last_id"] as? String, "item_0")
        XCTAssertEqual(firstPage?["has_more"] as? Bool, true)
        let firstData = try XCTUnwrap(firstPage?["data"] as? [[String: Any]])
        XCTAssertEqual(firstData.map { $0["id"] as? String }, ["item_0"])

        let (afterStatus, afterPage) = try await getResponseInputItems(port: port, responseID: responseID, query: "after=item_0&limit=1")
        XCTAssertEqual(afterStatus, 200)
        XCTAssertEqual(afterPage?["first_id"] as? String, "item_1")
        XCTAssertEqual(afterPage?["last_id"] as? String, "item_1")
        XCTAssertEqual(afterPage?["has_more"] as? Bool, true)
        let afterData = try XCTUnwrap(afterPage?["data"] as? [[String: Any]])
        XCTAssertEqual(afterData.map { $0["id"] as? String }, ["item_1"])

        let (descStatus, descPage) = try await getResponseInputItems(port: port, responseID: responseID, query: "order=desc&limit=2")
        XCTAssertEqual(descStatus, 200)
        XCTAssertEqual(descPage?["first_id"] as? String, "item_2")
        XCTAssertEqual(descPage?["last_id"] as? String, "item_1")
        XCTAssertEqual(descPage?["has_more"] as? Bool, true)
        let descData = try XCTUnwrap(descPage?["data"] as? [[String: Any]])
        XCTAssertEqual(descData.map { $0["id"] as? String }, ["item_2", "item_1"])

        let (beforeStatus, beforePage) = try await getResponseInputItems(port: port, responseID: responseID, query: "before=item_2")
        XCTAssertEqual(beforeStatus, 200)
        XCTAssertEqual(beforePage?["first_id"] as? String, "item_0")
        XCTAssertEqual(beforePage?["last_id"] as? String, "item_1")
        XCTAssertEqual(beforePage?["has_more"] as? Bool, false)
        let beforeData = try XCTUnwrap(beforePage?["data"] as? [[String: Any]])
        XCTAssertEqual(beforeData.map { $0["id"] as? String }, ["item_0", "item_1"])
    }

    func testResponsesStoreFalseDoesNotPersistForRetrieval() async throws {
        let port = try unusedTCPPort()
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

    func testResponsesDeleteRemovesStoredResponseState() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let created = try await postResponse(port: port, body: #"{"model":"composer-2.5","input":"hello"}"#)
        let responseID = try XCTUnwrap(created["id"] as? String)
        let (statusBeforeDelete, _) = try await getResponse(port: port, responseID: responseID)
        let (itemsStatusBeforeDelete, _) = try await getResponseInputItems(port: port, responseID: responseID)

        var deleteRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses/\(responseID)")!)
        deleteRequest.httpMethod = "DELETE"
        let (deleteData, deleteResponse) = try await URLSession.shared.data(for: deleteRequest)
        let deleteObject = try XCTUnwrap(JSONSerialization.jsonObject(with: deleteData) as? [String: Any])

        let (statusAfterDelete, retrievedAfterDelete) = try await getResponse(port: port, responseID: responseID)
        let (itemsStatusAfterDelete, itemsAfterDelete) = try await getResponseInputItems(port: port, responseID: responseID)
        let (healthData, healthResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        let health = try XCTUnwrap(JSONSerialization.jsonObject(with: healthData) as? [String: Any])
        let responses = try XCTUnwrap(health["responses"] as? [String: Any])

        XCTAssertEqual(statusBeforeDelete, 200)
        XCTAssertEqual(itemsStatusBeforeDelete, 200)
        XCTAssertEqual((deleteResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(deleteObject["id"] as? String, responseID)
        XCTAssertEqual(deleteObject["object"] as? String, "response")
        XCTAssertEqual(deleteObject["deleted"] as? Bool, true)
        XCTAssertEqual(statusAfterDelete, 404)
        XCTAssertNil(retrievedAfterDelete?["id"])
        XCTAssertEqual(itemsStatusAfterDelete, 404)
        XCTAssertNil(itemsAfterDelete?["data"])
        XCTAssertEqual((healthResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((responses["sessions"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((responses["stored"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((responses["inputItems"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((responses["toolCallMemory"] as? NSNumber)?.intValue, 0)
    }

    func testResponsesDeleteUnknownResponseReturns404() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses/resp_missing")!)
        request.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: request)
        let text = String(data: data, encoding: .utf8) ?? ""

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertTrue(text.contains(#""code":"not_found""#) || text.contains(#""code" : "not_found""#))
    }

    func testResponsesCancelEndpointRejectsKnownSynchronousResponses() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let created = try await postResponse(port: port, body: #"{"model":"composer-2.5","input":"hello"}"#)
        let responseID = try XCTUnwrap(created["id"] as? String)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses/\(responseID)/cancel")!)
        request.httpMethod = "POST"
        let (cancelData, cancelResponse) = try await URLSession.shared.data(for: request)
        let cancelText = String(data: cancelData, encoding: .utf8) ?? ""
        let (statusAfterCancel, retrievedAfterCancel) = try await getResponse(port: port, responseID: responseID)

        XCTAssertEqual((cancelResponse as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertTrue(cancelText.contains("Only background responses can be cancelled"))
        XCTAssertTrue(cancelText.contains(#""code":"invalid_request""#) || cancelText.contains(#""code" : "invalid_request""#))
        XCTAssertEqual(statusAfterCancel, 200)
        XCTAssertEqual(retrievedAfterCancel?["id"] as? String, responseID)
    }

    func testResponsesInputTokensEndpointReturnsLocalEstimate() async throws {
        let port = try unusedTCPPort()
        let recorder = PreparedRequestRecorder()
        let harness = MockHarness(recorder: recorder)
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: harness)
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses/input_tokens")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"composer-2.5","input":"hello"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = await recorder.models()

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(object["object"] as? String, "response.input_tokens")
        XCTAssertGreaterThan((object["input_tokens"] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertEqual(models, [])
    }

    func testResponsesCompactEndpointReturnsReusableCompactionItem() async throws {
        let port = try unusedTCPPort()
        let recorder = PreparedRequestRecorder()
        let harness = MockHarness(text: "The app is local, uses Composer, and still needs packaging verification.", recorder: recorder)
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: harness)
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var compactRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses/compact")!)
        compactRequest.httpMethod = "POST"
        compactRequest.httpBody = Data("""
        {
          "model": "composer-2.5",
          "input": [
            {"role": "user", "content": "Build a local app."},
            {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Implemented local API."}]}
          ]
        }
        """.utf8)
        compactRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (compactData, compactResponse) = try await URLSession.shared.data(for: compactRequest)
        let compactObject = try XCTUnwrap(JSONSerialization.jsonObject(with: compactData) as? [String: Any])
        let compactOutput = try XCTUnwrap(compactObject["output"] as? [[String: Any]])
        let compaction = try XCTUnwrap(compactOutput.first)

        XCTAssertEqual((compactResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(compactObject["object"] as? String, "response.compaction")
        XCTAssertEqual(compaction["type"] as? String, "compaction")
        XCTAssertEqual(compaction["encrypted_content"] as? String, "The app is local, uses Composer, and still needs packaging verification.")

        let continueBody = try JSONSerialization.data(withJSONObject: [
            "model": "composer-2.5",
            "input": compactOutput
        ])
        let continueResponse = try await postResponse(port: port, body: String(data: continueBody, encoding: .utf8) ?? "{}")
        let prompts = await recorder.prompts()

        XCTAssertEqual(continueResponse["object"] as? String, "response")
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[0].contains("CONVERSATION TO COMPACT"))
        XCTAssertTrue(prompts[0].contains("Build a local app."))
        XCTAssertTrue(prompts[1].contains("COMPACTED CONVERSATION SUMMARY: The app is local, uses Composer, and still needs packaging verification."))
    }

    func testResponsesCancelUnknownResponseReturns404() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/responses/resp_missing/cancel")!)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        let text = String(data: data, encoding: .utf8) ?? ""

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertTrue(text.contains(#""code":"not_found""#) || text.contains(#""code" : "not_found""#))
    }

    func testStreamingResponsesStoreCompletedResponseForRetrieval() async throws {
        let port = try unusedTCPPort()
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

    func testResponsesStateIsBoundedAndVisibleInHealth() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(), responseStateLimit: 2)
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let first = try await postResponse(port: port, body: #"{"model":"composer-2.5","input":"first"}"#)
        let firstID = try XCTUnwrap(first["id"] as? String)
        let second = try await postResponse(port: port, body: #"{"model":"composer-2.5","input":"second"}"#)
        let secondID = try XCTUnwrap(second["id"] as? String)
        let (firstStatusBeforeThird, _) = try await getResponse(port: port, responseID: firstID)
        XCTAssertEqual(firstStatusBeforeThird, 200)

        let third = try await postResponse(port: port, body: #"{"model":"composer-2.5","input":"third"}"#)
        let thirdID = try XCTUnwrap(third["id"] as? String)

        let (firstStatus, _) = try await getResponse(port: port, responseID: firstID)
        let (secondStatus, _) = try await getResponse(port: port, responseID: secondID)
        let (thirdStatus, _) = try await getResponse(port: port, responseID: thirdID)
        XCTAssertEqual(firstStatus, 200)
        XCTAssertEqual(secondStatus, 404)
        XCTAssertEqual(thirdStatus, 200)

        let (healthData, healthResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertEqual((healthResponse as? HTTPURLResponse)?.statusCode, 200)
        let health = try XCTUnwrap(JSONSerialization.jsonObject(with: healthData) as? [String: Any])
        let responses = try XCTUnwrap(health["responses"] as? [String: Any])
        XCTAssertEqual((responses["sessions"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((responses["stored"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((responses["inputItems"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual((responses["toolCallMemory"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((responses["maxStored"] as? NSNumber)?.intValue, 2)
    }

    func testResponsesPreviousResponseIDContinuesSameSDKSession() async throws {
        let port = try unusedTCPPort()
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

    func testResponsesPreviousResponseIDRejectsUnknownAndDeletedResponses() async throws {
        let port = try unusedTCPPort()
        let recorder = PreparedRequestRecorder()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(recorder: recorder))
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let (unknownStatus, unknownBody) = try await postResponseStatus(
            port: port,
            body: #"{"model":"composer-2.5","previous_response_id":"resp_missing","input":"second"}"#
        )

        XCTAssertEqual(unknownStatus, 404)
        XCTAssertTrue(unknownBody.contains(#""code":"not_found""#) || unknownBody.contains(#""code" : "not_found""#))
        let sessionKeysAfterUnknown = await recorder.sessionKeys()
        XCTAssertEqual(sessionKeysAfterUnknown, [])

        let created = try await postResponse(port: port, body: #"{"model":"composer-2.5","input":"first"}"#)
        let responseID = try XCTUnwrap(created["id"] as? String)
        var deleteRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses/\(responseID)")!)
        deleteRequest.httpMethod = "DELETE"
        let (_, deleteResponse) = try await URLSession.shared.data(for: deleteRequest)
        XCTAssertEqual((deleteResponse as? HTTPURLResponse)?.statusCode, 200)

        let (deletedStatus, deletedBody) = try await postResponseStatus(
            port: port,
            body: #"{"model":"composer-2.5","previous_response_id":"\#(responseID)","input":"second"}"#
        )

        XCTAssertEqual(deletedStatus, 404)
        XCTAssertTrue(deletedBody.contains(#""code":"not_found""#) || deletedBody.contains(#""code" : "not_found""#))
        let sessionKeysAfterDeleted = await recorder.sessionKeys()
        XCTAssertEqual(sessionKeysAfterDeleted.count, 1)
    }

    func testResponsesPreviousResponseIDCanContinueStoreFalseInMemorySession() async throws {
        let port = try unusedTCPPort()
        let recorder = PreparedRequestRecorder()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(recorder: recorder))
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let first = try await postResponse(port: port, body: #"{"model":"composer-2.5","store":false,"input":"first"}"#)
        let firstID = try XCTUnwrap(first["id"] as? String)
        let second = try await postResponse(port: port, body: #"{"model":"composer-2.5","previous_response_id":"\#(firstID)","input":"second"}"#)

        XCTAssertEqual(second["previous_response_id"] as? String, firstID)
        let sessionKeys = await recorder.sessionKeys()
        XCTAssertEqual(sessionKeys.count, 2)
        XCTAssertEqual(sessionKeys[0], sessionKeys[1])
    }

    func testResponsesPreviousResponseIDCarriesFunctionCallMemory() async throws {
        let port = try unusedTCPPort()
        let recorder = PreparedRequestRecorder()
        let toolCall = CursorToolCall(name: "shell", arguments: ["command": .string("pwd")])
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(events: [
            .toolCall(toolCall),
            .done(CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test"))
        ], recorder: recorder))
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let first = try await postResponse(port: port, body: #"""
        {
          "model":"composer-2.5",
          "input":"run pwd",
          "tools":[{"type":"function","name":"bash","parameters":{"type":"object","properties":{"command":{"type":"string"}}}}]
        }
        """#)
        let firstID = try XCTUnwrap(first["id"] as? String)
        let output = try XCTUnwrap(first["output"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(output.first { ($0["type"] as? String) == "function_call" })
        let callID = try XCTUnwrap(functionCall["call_id"] as? String)

        _ = try await postResponse(port: port, body: #"""
        {
          "model":"composer-2.5",
          "previous_response_id":"\#(firstID)",
          "input":[{"type":"function_call_output","call_id":"\#(callID)","output":"/tmp/project"}]
        }
        """#)

        let prompts = await recorder.prompts()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].contains("FUNCTION CALL OUTPUT (name=bash call_id=\(callID))"))
        XCTAssertTrue(prompts[1].contains("LOCAL TOOL RESULT"))
        XCTAssertTrue(prompts[1].contains("bash"))
        XCTAssertTrue(prompts[1].contains("command"))
        XCTAssertTrue(prompts[1].contains("pwd"))
        XCTAssertTrue(prompts[1].contains("/tmp/project"))
    }

    func testResponsesProjectMetadataSeparatesAndReusesSDKSessions() async throws {
        let port = try unusedTCPPort()
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
        let port = try unusedTCPPort()
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
        XCTAssertTrue(prepared.prompt.contains("The above tool calls have been executed. Continue your response based on these results."))
        XCTAssertTrue(prepared.prompt.contains("/tmp/project"))
    }

    func testResponsesPiBashOutputsFeedBackWithSDKMillisecondTimeout() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model": "composer-2.5",
          "tools": [
            {
              "type": "function",
              "name": "bash",
              "parameters": {
                "type": "object",
                "properties": {
                  "command": { "type": "string" },
                  "timeout": { "type": "number", "description": "Timeout in seconds (optional, no default timeout)" }
                },
                "required": ["command"]
              }
            }
          ],
          "input": [
            {
              "type": "function_call",
              "call_id": "call_bash",
              "name": "bash",
              "arguments": "{\"command\":\"npm test\",\"timeout\":120}"
            },
            {
              "type": "function_call_output",
              "call_id": "call_bash",
              "output": "{\"exitCode\":0,\"stdout\":\"ok\",\"stderr\":\"\"}"
            }
          ]
        }
        """#.utf8))

        let prefix = "LOCAL TOOL RESULT: "
        let feedbackLine = try XCTUnwrap(prepared.prompt.split(separator: "\n").first { $0.hasPrefix(prefix) })
        let feedbackJSON = String(feedbackLine.dropFirst(prefix.count))
        let feedbackData = Data(feedbackJSON.utf8)
        let feedback = try XCTUnwrap(JSONSerialization.jsonObject(with: feedbackData) as? [String: Any])
        let arguments = try XCTUnwrap(feedback["arguments"] as? [String: Any])

        XCTAssertEqual(feedback["toolName"] as? String, "shell")
        XCTAssertEqual(arguments["command"] as? String, "npm test")
        XCTAssertEqual((arguments["timeout"] as? NSNumber)?.doubleValue, 120_000)
    }

    func testResponsesToolSchemaErrorsAddRepairHintForOpenCodeGlob() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "tools":[
            {
              "type":"function",
              "name":"glob",
              "parameters":{
                "type":"object",
                "properties":{
                  "pattern":{"type":"string"},
                  "path":{"type":"string"}
                },
                "required":["pattern"]
              }
            }
          ],
          "input":[
            {"type":"message","role":"user","content":[{"type":"input_text","text":"build a todo app in vite 8 and react"}]},
            {
              "type":"function_call",
              "call_id":"call_glob",
              "name":"glob",
              "arguments":"{}"
            },
            {
              "type":"function_call_output",
              "call_id":"call_glob",
              "output":"The glob tool was called with invalid arguments: SchemaError(Missing key\n  at [\"pattern\"]).\nPlease rewrite the input so it satisfies the expected schema."
            }
          ]
        }
        """#.utf8))

        XCTAssertTrue(prepared.prompt.contains("LOCAL TOOL ERROR REPAIR"))
        XCTAssertTrue(prepared.prompt.contains("SDK glob maps to client glob"))
        XCTAssertTrue(prepared.prompt.contains(#""pattern":"**/*""#))
        XCTAssertTrue(prepared.prompt.contains("Do not repeat the rejected arguments"))
    }

    func testResponsesAcceptsServerToolInputSchemasAndSkipsNamelessBuiltins() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model": "composer-2.5",
          "tools": [
            { "type": "web_search_preview" },
            {
              "type": "server_tool",
              "name": "repo_search",
              "description": "Search repository symbols",
              "inputSchema": {
                "type": "object",
                "properties": {
                  "query": { "type": "string" }
                },
                "required": ["query"]
              }
            }
          ],
          "input": "search the repo"
        }
        """#.utf8))

        XCTAssertEqual(prepared.tools.map(\.name), ["repo_search"])
        XCTAssertEqual(prepared.tools.first?.description, "Search repository symbols")
        guard case .object(let schema)? = prepared.tools.first?.parameters,
              case .object(let properties)? = schema["properties"] else {
            return XCTFail("Expected server tool input schema to be preserved")
        }
        XCTAssertNotNil(properties["query"])
        XCTAssertTrue(prepared.prompt.contains("Client tool targets: repo_search"))
        XCTAssertTrue(prepared.prompt.contains("These are client execution targets, not the names you should emit."))
    }

    func testChatFileRequestAddsRequiredLocalToolHint() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model": "composer-2.5",
          "messages": [
            {"role": "user", "content": "Create ~/Desktop/example.html with hello in it."}
          ],
          "tools": [
            {
              "type": "function",
              "function": {
                "name": "bash",
                "parameters": {
                  "type": "object",
                  "properties": {
                    "command": { "type": "string" },
                    "description": { "type": "string" }
                  }
                }
              }
            },
            {
              "type": "function",
              "function": {
                "name": "write",
                "parameters": {
                  "type": "object",
                  "properties": {
                    "filePath": { "type": "string" },
                    "content": { "type": "string" }
                  }
                }
              }
            }
          ]
        }
        """#.utf8))

        XCTAssertTrue(prepared.prompt.contains("LOCAL TOOL REQUIRED FOR THE LATEST USER REQUEST"))
        XCTAssertTrue(prepared.prompt.contains("Emit exactly one SDK tool call next and no prose."))
        XCTAssertTrue(prepared.prompt.contains("Use SDK shell when it maps to the client shell/bash tool"))
    }

    func testChatBuildAppRequestAddsRequiredLocalToolHintForSchemaCompatibleWriter() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model": "composer-2.5",
          "messages": [
            {"role": "user", "content": "build a todo app in vite 8 and react"}
          ],
          "tools": [
            {
              "type": "function",
              "function": {
                "name": "project_files",
                "parameters": {
                  "type": "object",
                  "properties": {
                    "input": {
                      "type": "object",
                      "properties": {
                        "action": {"type": "string", "enum": ["read", "write", "replace", "delete"]},
                        "path": {"type": "string"},
                        "content": {"type": "string"},
                        "old": {"type": "string"},
                        "replacement": {"type": "string"}
                      },
                      "required": ["action", "path"]
                    }
                  },
                  "required": ["input"]
                }
              }
            }
          ]
        }
        """#.utf8))

        XCTAssertTrue(prepared.prompt.contains("LOCAL TOOL REQUIRED FOR THE LATEST USER REQUEST"))
        XCTAssertTrue(prepared.prompt.contains("Emit exactly one SDK tool call next and no prose."))
        XCTAssertTrue(prepared.prompt.contains("use SDK write when it maps to the client write tool"))
    }

    func testChatBuildAppRequestDoesNotRepeatRequiredHintAfterCustomWriterCall() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model": "composer-2.5",
          "messages": [
            {"role": "user", "content": "build a todo app in vite 8 and react"},
            {
              "role": "assistant",
              "content": null,
              "tool_calls": [
                {
                  "id": "call_project_file",
                  "type": "function",
                  "function": {
                    "name": "project_files",
                    "arguments": "{\"input\":{\"action\":\"write\",\"path\":\"src/App.tsx\",\"content\":\"export default function App() { return null; }\"}}"
                  }
                }
              ]
            },
            {"role": "tool", "tool_call_id": "call_project_file", "name": "project_files", "content": "Wrote src/App.tsx"}
          ],
          "tools": [
            {
              "type": "function",
              "function": {
                "name": "project_files",
                "parameters": {
                  "type": "object",
                  "properties": {
                    "input": {
                      "type": "object",
                      "properties": {
                        "action": {"type": "string", "enum": ["read", "write", "replace", "delete"]},
                        "path": {"type": "string"},
                        "content": {"type": "string"},
                        "old": {"type": "string"},
                        "replacement": {"type": "string"}
                      },
                      "required": ["action", "path"]
                    }
                  },
                  "required": ["input"]
                }
              }
            }
          ]
        }
        """#.utf8))

        XCTAssertTrue(prepared.prompt.contains("The above tool calls have been executed. Continue your response based on these results."))
        XCTAssertFalse(prepared.prompt.contains("LOCAL TOOL REQUIRED FOR THE LATEST USER REQUEST"))
    }

    func testChatFileRequestUsesSchemaCompatibleShellHint() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model": "composer-2.5",
          "messages": [
            {"role": "user", "content": "Create ~/Desktop/example.html with hello in it."}
          ],
          "tools": [
            {
              "type": "function",
              "function": {
                "name": "command_runner",
                "parameters": {
                  "type": "object",
                  "properties": {
                    "input": {
                      "type": "object",
                      "properties": {
                        "command": {"type": "string"},
                        "workdir": {"type": "string"}
                      },
                      "required": ["command"]
                    }
                  },
                  "required": ["input"]
                }
              }
            }
          ]
        }
        """#.utf8))

        XCTAssertTrue(prepared.prompt.contains("LOCAL TOOL REQUIRED FOR THE LATEST USER REQUEST"))
        XCTAssertTrue(prepared.prompt.contains("Use SDK shell when it maps to the client shell/bash tool"))
    }

    func testResponsesFileRequestAddsRequiredLocalToolHint() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model": "composer-2.5",
          "input": [
            {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Write /tmp/example.html with hello in it."}]}
          ],
          "tools": [
            {
              "type": "function",
              "name": "bash",
              "parameters": {
                "type": "object",
                "properties": {
                  "command": { "type": "string" },
                  "description": { "type": "string" }
                }
              }
            },
            {
              "type": "function",
              "name": "write",
              "parameters": {
                "type": "object",
                "properties": {
                  "filePath": { "type": "string" },
                  "content": { "type": "string" }
                }
              }
            }
          ]
        }
        """#.utf8))

        XCTAssertTrue(prepared.prompt.contains("LOCAL TOOL REQUIRED FOR THE LATEST USER REQUEST"))
        XCTAssertTrue(prepared.prompt.contains("Emit exactly one SDK tool call next and no prose."))
        XCTAssertTrue(prepared.prompt.contains("Use SDK shell when it maps to the client shell/bash tool"))
    }

    func testResponsesFileRequestDoesNotRepeatRequiredHintAfterApplyPatchCall() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model": "composer-2.5",
          "input": [
            {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "build a todo app in vite 8 and react"}]},
            {
              "type": "function_call",
              "call_id": "call_patch",
              "name": "apply_patch",
              "arguments": "{\"patch\":\"*** Begin Patch\\n*** Add File: src/App.tsx\\n+export default function App() { return null; }\\n*** End Patch\"}"
            },
            {"type": "function_call_output", "call_id": "call_patch", "output": "Done"}
          ],
          "tools": [
            {
              "type": "function",
              "name": "apply_patch",
              "parameters": {
                "type": "object",
                "properties": {
                  "patch": {"type": "string"}
                },
                "required": ["patch"]
              }
            }
          ]
        }
        """#.utf8))

        XCTAssertTrue(prepared.prompt.contains("The above tool calls have been executed. Continue your response based on these results."))
        XCTAssertFalse(prepared.prompt.contains("LOCAL TOOL REQUIRED FOR THE LATEST USER REQUEST"))
    }

    func testChatFileRequestPrefersExplicitOpenCodeMCPToolHint() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model": "composer-2.5",
          "messages": [
            {"role": "user", "content": "Use the probe_write_file tool, not bash, to create mcp-marker.txt containing MCP_OK."}
          ],
          "tools": [
            {
              "type": "function",
              "function": {
                "name": "bash",
                "parameters": {
                  "type": "object",
                  "properties": {
                    "command": { "type": "string" },
                    "description": { "type": "string" }
                  }
                }
              }
            },
            {
              "type": "function",
              "function": {
                "name": "probe_write_file",
                "parameters": {
                  "type": "object",
                  "properties": {
                    "file_path": { "type": "string" },
                    "contents": { "type": "string" }
                  },
                  "required": ["file_path", "contents"]
                }
              }
            }
          ]
        }
        """#.utf8))

        XCTAssertTrue(prepared.prompt.contains("LOCAL TOOL REQUIRED FOR THE LATEST USER REQUEST"))
        XCTAssertTrue(prepared.prompt.contains("Use SDK mcp now with providerIdentifier \"probe\", toolName \"write_file\""))
        XCTAssertTrue(prepared.prompt.contains("Do not use SDK shell/write as a substitute"))
        XCTAssertFalse(prepared.prompt.contains("Use SDK shell now. For creating or overwriting a file"))
    }

    func testChatExplicitNonMutatingToolRequestAddsAndClearsRequiredLocalToolHint() throws {
        let first = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model": "composer-2.5",
          "messages": [
            {"role": "user", "content": "Use the glob tool, not bash, to find **/*.tsx files."}
          ],
          "tools": [
            {
              "type": "function",
              "function": {
                "name": "glob",
                "description": "Find files",
                "parameters": {
                  "type": "object",
                  "properties": {
                    "pattern": { "type": "string" },
                    "path": { "type": "string" }
                  },
                  "required": ["pattern"]
                }
              }
            }
          ]
        }
        """#.utf8))

        XCTAssertTrue(first.prompt.contains("LOCAL TOOL REQUIRED FOR THE LATEST USER REQUEST"))
        XCTAssertTrue(first.prompt.contains("Use SDK glob now; it will be forwarded to client tool glob"))

        let continued = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model": "composer-2.5",
          "messages": [
            {"role": "user", "content": "Use the glob tool, not bash, to find **/*.tsx files."},
            {
              "role": "assistant",
              "content": null,
              "tool_calls": [
                {
                  "id": "call_glob",
                  "type": "function",
                  "function": {"name": "glob", "arguments": "{\"pattern\":\"**/*.tsx\"}"}
                }
              ]
            },
            {"role": "tool", "tool_call_id": "call_glob", "name": "glob", "content": "{\"files\":[\"src/App.tsx\"]}"}
          ],
          "tools": [
            {
              "type": "function",
              "function": {
                "name": "glob",
                "parameters": {
                  "type": "object",
                  "properties": { "pattern": { "type": "string" } },
                  "required": ["pattern"]
                }
              }
            }
          ]
        }
        """#.utf8))

        XCTAssertFalse(continued.prompt.contains("LOCAL TOOL REQUIRED FOR THE LATEST USER REQUEST"))
    }

    func testChatToolSchemaErrorsAddRepairHintForOpenCodeGlob() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"user","content":"build a todo app in vite 8 and react"},
            {
              "role":"assistant",
              "content":null,
              "tool_calls":[
                {
                  "id":"call_glob",
                  "type":"function",
                  "function":{"name":"glob","arguments":"{}"}
                }
              ]
            },
            {
              "role":"tool",
              "tool_call_id":"call_glob",
              "name":"glob",
              "content":"The glob tool was called with invalid arguments: SchemaError(Missing key\n  at [\"pattern\"]).\nPlease rewrite the input so it satisfies the expected schema."
            }
          ],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"glob",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "pattern":{"type":"string"},
                    "path":{"type":"string"}
                  },
                  "required":["pattern"]
                }
              }
            }
          ]
        }
        """#.utf8))

        XCTAssertTrue(prepared.prompt.contains("LOCAL TOOL ERROR REPAIR"))
        XCTAssertTrue(prepared.prompt.contains("SDK glob maps to client glob"))
        XCTAssertTrue(prepared.prompt.contains(#""pattern":"**/*""#))
        XCTAssertTrue(prepared.prompt.contains("Do not repeat the rejected arguments"))
    }

    func testChatToolInventoryAdvertisesSingleWordClientToolsAsSDKMCP() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model": "composer-2.5",
          "messages": [
            {"role": "user", "content": "Use the webfetch tool to fetch https://example.com"}
          ],
          "tool_choice": {"type":"function","function":{"name":"webfetch"}},
          "tools": [
            {
              "type": "function",
              "function": {
                "name": "webfetch",
                "description": "Fetch a URL",
                "parameters": {
                  "type": "object",
                  "properties": {
                    "url": { "type": "string" },
                    "format": { "type": "string" }
                  },
                  "required": ["url"]
                }
              }
            }
          ]
        }
        """#.utf8))

        XCTAssertTrue(prepared.prompt.contains("\"providerIdentifier\":\"client\""))
        XCTAssertTrue(prepared.prompt.contains("\"toolName\":\"webfetch\""))
        XCTAssertTrue(prepared.prompt.contains("\"args\":\"match this tool schema\""))
        XCTAssertTrue(prepared.prompt.contains("\"sdk\":\"mcp\""))
        XCTAssertTrue(prepared.prompt.contains("\"client\":\"webfetch\""))
        XCTAssertTrue(prepared.prompt.contains("\"args\":\"match client schema\""))
        XCTAssertTrue(prepared.prompt.contains("Use SDK mcp now with providerIdentifier \"client\", toolName \"webfetch\""))
    }

    func testChatToolResultsRenderPriorCallsAndContinuationPrompt() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"user","content":"run pwd"},
            {
              "role":"assistant",
              "content":null,
              "tool_calls":[
                {
                  "id":"call_1",
                  "type":"function",
                  "function":{"name":"bash","arguments":"{\"command\":\"pwd\"}"}
                }
              ]
            },
            {"role":"tool","tool_call_id":"call_1","content":"/tmp/project"}
          ],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"bash",
                "parameters":{"type":"object","properties":{"command":{"type":"string"}}}
              }
            }
          ]
        }
        """#.utf8))

        XCTAssertTrue(prepared.prompt.contains("tool_call(id: call_1, name: bash, args: {\"command\":\"pwd\"})"))
        XCTAssertTrue(prepared.prompt.contains("TOOL RESULT (name=bash tool_call_id=call_1)"))
        XCTAssertTrue(prepared.prompt.contains("LOCAL TOOL RESULT"))
        XCTAssertTrue(prepared.prompt.contains("The above tool calls have been executed. Continue your response based on these results."))
    }

    func testChatToolResultsFeedProviderToolsBackAsSDKMCPCalls() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"user","content":"use the filesystem MCP writer"},
            {
              "role":"assistant",
              "content":null,
              "tool_calls":[
                {
                  "id":"call_mcp",
                  "type":"function",
                  "function":{
                    "name":"mcp__filesystem__write_file",
                    "arguments":"{\"file_path\":\"src/App.tsx\",\"contents\":\"export default function App() { return null }\"}"
                  }
                }
              ]
            },
            {"role":"tool","tool_call_id":"call_mcp","name":"mcp__filesystem__write_file","content":"{\"content\":\"ok\"}"}
          ],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"mcp__filesystem__write_file",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "file_path":{"type":"string"},
                    "contents":{"type":"string"}
                  },
                  "required":["file_path","contents"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let prefix = "LOCAL TOOL RESULT: "
        let feedbackLine = try XCTUnwrap(prepared.prompt.split(separator: "\n").first { $0.hasPrefix(prefix) })
        let feedbackJSON = String(feedbackLine.dropFirst(prefix.count))
        let feedbackData = Data(feedbackJSON.utf8)
        let feedback = try XCTUnwrap(JSONSerialization.jsonObject(with: feedbackData) as? [String: Any])
        let arguments = try XCTUnwrap(feedback["arguments"] as? [String: Any])
        let nested = try XCTUnwrap(arguments["args"] as? [String: Any])

        XCTAssertEqual(feedback["toolName"] as? String, "mcp")
        XCTAssertEqual(arguments["providerIdentifier"] as? String, "filesystem")
        XCTAssertEqual(arguments["toolName"] as? String, "write_file")
        XCTAssertEqual(nested["file_path"] as? String, "src/App.tsx")
        XCTAssertEqual(nested["contents"] as? String, "export default function App() { return null }")
    }

    func testChatToolResultsFeedSingleWordClientToolsBackAsSDKMCPCalls() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"user","content":"use webfetch"},
            {
              "role":"assistant",
              "content":null,
              "tool_calls":[
                {
                  "id":"call_webfetch",
                  "type":"function",
                  "function":{
                    "name":"webfetch",
                    "arguments":"{\"url\":\"https://example.com\",\"format\":\"markdown\"}"
                  }
                }
              ]
            },
            {"role":"tool","tool_call_id":"call_webfetch","name":"webfetch","content":"{\"content\":\"ok\"}"}
          ],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"webfetch",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "url":{"type":"string"},
                    "format":{"type":"string"}
                  },
                  "required":["url"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let prefix = "LOCAL TOOL RESULT: "
        let feedbackLine = try XCTUnwrap(prepared.prompt.split(separator: "\n").first { $0.hasPrefix(prefix) })
        let feedbackJSON = String(feedbackLine.dropFirst(prefix.count))
        let feedbackData = Data(feedbackJSON.utf8)
        let feedback = try XCTUnwrap(JSONSerialization.jsonObject(with: feedbackData) as? [String: Any])
        let arguments = try XCTUnwrap(feedback["arguments"] as? [String: Any])
        let nested = try XCTUnwrap(arguments["args"] as? [String: Any])

        XCTAssertEqual(feedback["toolName"] as? String, "mcp")
        XCTAssertEqual(arguments["providerIdentifier"] as? String, "client")
        XCTAssertEqual(arguments["toolName"] as? String, "webfetch")
        XCTAssertEqual(nested["url"] as? String, "https://example.com")
        XCTAssertEqual(nested["format"] as? String, "markdown")
    }

    func testChatToolResultsFeedLiveOpenCodeBuildToolsBackWithSDKArguments() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"user","content":"build a todo app"},
            {
              "role":"assistant",
              "content":null,
              "tool_calls":[
                {"id":"call_write","type":"function","function":{"name":"write","arguments":"{\"filePath\":\"/tmp/project/src/App.tsx\",\"content\":\"export default function App() { return null }\"}"}},
                {"id":"call_read","type":"function","function":{"name":"read","arguments":"{\"filePath\":\"/tmp/project/src/App.tsx\",\"offset\":5,\"limit\":20}"}},
                {"id":"call_edit","type":"function","function":{"name":"edit","arguments":"{\"filePath\":\"/tmp/project/src/App.tsx\",\"oldString\":\"return null\",\"newString\":\"return <main />\"}"}},
                {"id":"call_glob","type":"function","function":{"name":"glob","arguments":"{\"pattern\":\"**/*.tsx\",\"path\":\"/tmp/project/src\"}"}},
                {"id":"call_todo","type":"function","function":{"name":"todowrite","arguments":"{\"todos\":[{\"content\":\"Build app\",\"status\":\"in_progress\",\"priority\":\"high\"}]}"}},
                {"id":"call_task","type":"function","function":{"name":"task","arguments":"{\"description\":\"Inspect app\",\"prompt\":\"Find the app entry point\",\"subagent_type\":\"explore\"}"}},
                {"id":"call_skill","type":"function","function":{"name":"skill","arguments":"{\"name\":\"customize-opencode\"}"}}
              ]
            },
            {"role":"tool","tool_call_id":"call_write","content":"{\"content\":\"ok\"}"},
            {"role":"tool","tool_call_id":"call_read","content":"export default function App() { return null }"},
            {"role":"tool","tool_call_id":"call_edit","content":"{\"diff\":\"updated App\"}"},
            {"role":"tool","tool_call_id":"call_glob","content":"{\"files\":[\"src/App.tsx\"]}"},
            {"role":"tool","tool_call_id":"call_todo","content":"{\"content\":\"ok\"}"},
            {"role":"tool","tool_call_id":"call_task","content":"{\"content\":\"entry point is src/App.tsx\"}"},
            {"role":"tool","tool_call_id":"call_skill","content":"{\"content\":\"loaded\"}"}
          ],
          "tools":[
            {"type":"function","function":{"name":"write","parameters":{"type":"object","properties":{"filePath":{"type":"string"},"content":{"type":"string"}},"required":["filePath","content"]}}},
            {"type":"function","function":{"name":"read","parameters":{"type":"object","properties":{"filePath":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["filePath"]}}},
            {"type":"function","function":{"name":"edit","parameters":{"type":"object","properties":{"filePath":{"type":"string"},"oldString":{"type":"string"},"newString":{"type":"string"}},"required":["filePath","oldString","newString"]}}},
            {"type":"function","function":{"name":"glob","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"}},"required":["pattern"]}}},
            {"type":"function","function":{"name":"todowrite","parameters":{"type":"object","properties":{"todos":{"type":"array"}},"required":["todos"]}}},
            {"type":"function","function":{"name":"task","parameters":{"type":"object","properties":{"description":{"type":"string"},"prompt":{"type":"string"},"subagent_type":{"type":"string"}},"required":["description","prompt","subagent_type"]}}},
            {"type":"function","function":{"name":"skill","parameters":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}}
          ]
        }
        """#.utf8))

        let prefix = "LOCAL TOOL RESULT: "
        let feedback = try prepared.prompt
            .split(separator: "\n")
            .filter { $0.hasPrefix(prefix) }
            .map { line -> [String: Any] in
                let json = String(line.dropFirst(prefix.count))
                let data = Data(json.utf8)
                return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }

        XCTAssertEqual(feedback.compactMap { $0["toolName"] as? String }, ["write", "read", "edit", "glob", "todowrite", "mcp", "mcp"])
        let arguments = try feedback.map { try XCTUnwrap($0["arguments"] as? [String: Any]) }
        XCTAssertEqual(arguments[0]["path"] as? String, "/tmp/project/src/App.tsx")
        XCTAssertEqual(arguments[0]["fileText"] as? String, "export default function App() { return null }")
        XCTAssertEqual(arguments[1]["path"] as? String, "/tmp/project/src/App.tsx")
        XCTAssertEqual((arguments[1]["offset"] as? NSNumber)?.doubleValue, 5)
        XCTAssertEqual((arguments[1]["limit"] as? NSNumber)?.doubleValue, 20)
        XCTAssertEqual(arguments[2]["path"] as? String, "/tmp/project/src/App.tsx")
        XCTAssertEqual(arguments[2]["oldString"] as? String, "return null")
        XCTAssertEqual(arguments[2]["newString"] as? String, "return <main />")
        XCTAssertEqual(arguments[3]["targetDirectory"] as? String, "/tmp/project/src")
        XCTAssertEqual(arguments[3]["globPattern"] as? String, "**/*.tsx")
        let todos = try XCTUnwrap(arguments[4]["todos"] as? [[String: Any]])
        XCTAssertEqual(todos.first?["content"] as? String, "Build app")
        XCTAssertEqual(arguments[5]["providerIdentifier"] as? String, "client")
        XCTAssertEqual(arguments[5]["toolName"] as? String, "task")
        let taskArgs = try XCTUnwrap(arguments[5]["args"] as? [String: Any])
        XCTAssertEqual(taskArgs["subagent_type"] as? String, "explore")
        XCTAssertEqual(arguments[6]["providerIdentifier"] as? String, "client")
        XCTAssertEqual(arguments[6]["toolName"] as? String, "skill")
        let skillArgs = try XCTUnwrap(arguments[6]["args"] as? [String: Any])
        XCTAssertEqual(skillArgs["name"] as? String, "customize-opencode")
    }

    func testChatToolResultsFeedBatchOperationArraysBackWithSDKArguments() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"user","content":"update files"},
            {
              "role":"assistant",
              "content":null,
              "tool_calls":[
                {"id":"call_batch_write","type":"function","function":{"name":"workspace_batch","arguments":"{\"operations\":[{\"action\":\"create\",\"filePath\":\"src/App.tsx\",\"content\":\"export default function App() { return null }\"}]}"}},
                {"id":"call_batch_edit","type":"function","function":{"name":"workspace_batch","arguments":"{\"operations\":[{\"action\":\"replace\",\"filePath\":\"src/App.tsx\",\"oldText\":\"return null\",\"newText\":\"return <main />\"}]}"}},
                {"id":"call_batch_delete","type":"function","function":{"name":"workspace_batch","arguments":"{\"operations\":[{\"action\":\"delete\",\"filePath\":\"src/old.tsx\"}]}"}}
              ]
            },
            {"role":"tool","tool_call_id":"call_batch_write","content":"wrote file"},
            {"role":"tool","tool_call_id":"call_batch_edit","content":"edited file"},
            {"role":"tool","tool_call_id":"call_batch_delete","content":"deleted file"}
          ],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"workspace_batch",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "operations":{
                      "type":"array",
                      "items":{
                        "type":"object",
                        "additionalProperties":false,
                        "properties":{
                          "action":{"type":"string","enum":["read","create","replace","delete"]},
                          "filePath":{"type":"string"},
                          "content":{"type":"string"},
                          "oldText":{"type":"string"},
                          "newText":{"type":"string"}
                        },
                        "required":["action","filePath"]
                      }
                    }
                  },
                  "required":["operations"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let prefix = "LOCAL TOOL RESULT: "
        let feedback = try prepared.prompt
            .split(separator: "\n")
            .filter { $0.hasPrefix(prefix) }
            .map { line -> [String: Any] in
                let json = String(line.dropFirst(prefix.count))
                let data = Data(json.utf8)
                return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }

        XCTAssertEqual(feedback.compactMap { $0["toolName"] as? String }, ["write", "edit", "delete"])
        let arguments = try feedback.map { try XCTUnwrap($0["arguments"] as? [String: Any]) }
        XCTAssertEqual(arguments[0]["path"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments[0]["fileText"] as? String, "export default function App() { return null }")
        XCTAssertEqual(arguments[1]["path"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments[1]["oldString"] as? String, "return null")
        XCTAssertEqual(arguments[1]["newString"] as? String, "return <main />")
        XCTAssertEqual(arguments[2]["path"] as? String, "src/old.tsx")
    }

    func testChatToolResultsFeedFindBackAsSDKGlobCalls() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"user","content":"find source files"},
            {
              "role":"assistant",
              "content":null,
              "tool_calls":[
                {
                  "id":"call_find",
                  "type":"function",
                  "function":{
                    "name":"find",
                    "arguments":"{\"pattern\":\"**/*.tsx\",\"path\":\"src\"}"
                  }
                }
              ]
            },
            {"role":"tool","tool_call_id":"call_find","content":"{\"files\":[\"src/App.tsx\"]}"}
          ],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"find",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "pattern":{"type":"string"},
                    "path":{"type":"string"}
                  },
                  "required":["pattern"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let prefix = "LOCAL TOOL RESULT: "
        let feedbackLine = try XCTUnwrap(prepared.prompt.split(separator: "\n").first { $0.hasPrefix(prefix) })
        let feedbackJSON = String(feedbackLine.dropFirst(prefix.count))
        let feedbackData = Data(feedbackJSON.utf8)
        let feedback = try XCTUnwrap(JSONSerialization.jsonObject(with: feedbackData) as? [String: Any])
        let arguments = try XCTUnwrap(feedback["arguments"] as? [String: Any])

        XCTAssertEqual(feedback["toolName"] as? String, "glob")
        XCTAssertEqual(arguments["targetDirectory"] as? String, "src")
        XCTAssertEqual(arguments["globPattern"] as? String, "**/*.tsx")
        XCTAssertNil(arguments["providerIdentifier"])
    }

    func testChatToolResultsFeedPiBashBackWithSDKMillisecondTimeout() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"user","content":"run tests"},
            {
              "role":"assistant",
              "content":null,
              "tool_calls":[
                {
                  "id":"call_bash",
                  "type":"function",
                  "function":{
                    "name":"bash",
                    "arguments":"{\"command\":\"npm test\",\"timeout\":120}"
                  }
                }
              ]
            },
            {"role":"tool","tool_call_id":"call_bash","content":"{\"exitCode\":0,\"stdout\":\"ok\",\"stderr\":\"\"}"}
          ],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"bash",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "command":{"type":"string"},
                    "timeout":{"type":"number","description":"Timeout in seconds (optional, no default timeout)"}
                  },
                  "required":["command"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let prefix = "LOCAL TOOL RESULT: "
        let feedbackLine = try XCTUnwrap(prepared.prompt.split(separator: "\n").first { $0.hasPrefix(prefix) })
        let feedbackJSON = String(feedbackLine.dropFirst(prefix.count))
        let feedbackData = Data(feedbackJSON.utf8)
        let feedback = try XCTUnwrap(JSONSerialization.jsonObject(with: feedbackData) as? [String: Any])
        let arguments = try XCTUnwrap(feedback["arguments"] as? [String: Any])

        XCTAssertEqual(feedback["toolName"] as? String, "shell")
        XCTAssertEqual(arguments["command"] as? String, "npm test")
        XCTAssertEqual((arguments["timeout"] as? NSNumber)?.doubleValue, 120_000)
    }

    func testChatToolResultsFeedPiEditBackWithSDKArgumentNames() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"user","content":"edit the app"},
            {
              "role":"assistant",
              "content":null,
              "tool_calls":[
                {
                  "id":"call_edit",
                  "type":"function",
                  "function":{
                    "name":"edit",
                    "arguments":"{\"path\":\"src/App.tsx\",\"oldText\":\"return null\",\"newText\":\"return <main />\"}"
                  }
                }
              ]
            },
            {"role":"tool","tool_call_id":"call_edit","content":"{\"diff\":\"ok\"}"}
          ],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"edit",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "path":{"type":"string"},
                    "oldText":{"type":"string"},
                    "newText":{"type":"string"}
                  },
                  "required":["path","oldText","newText"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let prefix = "LOCAL TOOL RESULT: "
        let feedbackLine = try XCTUnwrap(prepared.prompt.split(separator: "\n").first { $0.hasPrefix(prefix) })
        let feedbackJSON = String(feedbackLine.dropFirst(prefix.count))
        let feedbackData = Data(feedbackJSON.utf8)
        let feedback = try XCTUnwrap(JSONSerialization.jsonObject(with: feedbackData) as? [String: Any])
        let arguments = try XCTUnwrap(feedback["arguments"] as? [String: Any])

        XCTAssertEqual(feedback["toolName"] as? String, "edit")
        XCTAssertEqual(arguments["path"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments["oldString"] as? String, "return null")
        XCTAssertEqual(arguments["newString"] as? String, "return <main />")
        XCTAssertNil(arguments["oldText"])
        XCTAssertNil(arguments["newText"])
    }

    func testChatToolResultsFeedPiGrepBackWithSDKOptionNames() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"user","content":"search source files"},
            {
              "role":"assistant",
              "content":null,
              "tool_calls":[
                {
                  "id":"call_grep",
                  "type":"function",
                  "function":{
                    "name":"grep",
                    "arguments":"{\"pattern\":\"TODO\",\"path\":\"src\",\"glob\":\"*.tsx\",\"ignoreCase\":true,\"literal\":true,\"context\":2,\"limit\":10}"
                  }
                }
              ]
            },
            {"role":"tool","tool_call_id":"call_grep","content":"src/App.tsx:1:TODO"}
          ],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"grep",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "pattern":{"type":"string"},
                    "path":{"type":"string"},
                    "glob":{"type":"string"},
                    "ignoreCase":{"type":"boolean"},
                    "literal":{"type":"boolean"},
                    "context":{"type":"number"},
                    "limit":{"type":"number"}
                  },
                  "required":["pattern"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let prefix = "LOCAL TOOL RESULT: "
        let feedbackLine = try XCTUnwrap(prepared.prompt.split(separator: "\n").first { $0.hasPrefix(prefix) })
        let feedbackJSON = String(feedbackLine.dropFirst(prefix.count))
        let feedbackData = Data(feedbackJSON.utf8)
        let feedback = try XCTUnwrap(JSONSerialization.jsonObject(with: feedbackData) as? [String: Any])
        let arguments = try XCTUnwrap(feedback["arguments"] as? [String: Any])

        XCTAssertEqual(feedback["toolName"] as? String, "grep")
        XCTAssertEqual(arguments["pattern"] as? String, "TODO")
        XCTAssertEqual(arguments["path"] as? String, "src")
        XCTAssertEqual(arguments["glob"] as? String, "*.tsx")
        XCTAssertEqual(arguments["caseInsensitive"] as? Bool, true)
        XCTAssertEqual(arguments["literal"] as? Bool, true)
        XCTAssertEqual((arguments["context"] as? NSNumber)?.doubleValue, 2)
        XCTAssertEqual((arguments["headLimit"] as? NSNumber)?.doubleValue, 10)
        XCTAssertNil(arguments["ignoreCase"])
        XCTAssertNil(arguments["limit"])
    }

    func testChatToolResultsFeedPiListBackWithSDKArgumentNames() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"user","content":"list files"},
            {
              "role":"assistant",
              "content":null,
              "tool_calls":[
                {
                  "id":"call_ls",
                  "type":"function",
                  "function":{
                    "name":"ls",
                    "arguments":"{\"path\":\"src\",\"limit\":20}"
                  }
                }
              ]
            },
            {"role":"tool","tool_call_id":"call_ls","content":"App.tsx"}
          ],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"ls",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "path":{"type":"string"},
                    "limit":{"type":"number"}
                  }
                }
              }
            }
          ]
        }
        """#.utf8))

        let prefix = "LOCAL TOOL RESULT: "
        let feedbackLine = try XCTUnwrap(prepared.prompt.split(separator: "\n").first { $0.hasPrefix(prefix) })
        let feedbackJSON = String(feedbackLine.dropFirst(prefix.count))
        let feedbackData = Data(feedbackJSON.utf8)
        let feedback = try XCTUnwrap(JSONSerialization.jsonObject(with: feedbackData) as? [String: Any])
        let arguments = try XCTUnwrap(feedback["arguments"] as? [String: Any])

        XCTAssertEqual(feedback["toolName"] as? String, "ls")
        XCTAssertEqual(arguments["path"] as? String, "src")
        XCTAssertEqual((arguments["limit"] as? NSNumber)?.doubleValue, 20)
    }

    func testChatFileRequestAfterPriorToolResultStillRequiresLocalTool() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"user","content":"run pwd"},
            {
              "role":"assistant",
              "content":null,
              "tool_calls":[
                {
                  "id":"call_1",
                  "type":"function",
                  "function":{"name":"bash","arguments":"{\"command\":\"pwd\"}"}
                }
              ]
            },
            {"role":"tool","tool_call_id":"call_1","content":"/tmp/project"},
            {"role":"assistant","content":"done"},
            {"role":"user","content":"Create rain-in-spain.html in this project."}
          ],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"bash",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "command":{"type":"string"},
                    "description":{"type":"string"}
                  }
                }
              }
            }
          ]
        }
        """#.utf8))

        XCTAssertTrue(prepared.prompt.contains("The above tool calls have been executed. Continue your response based on these results."))
        XCTAssertTrue(prepared.prompt.contains("LOCAL TOOL REQUIRED FOR THE LATEST USER REQUEST"))
        XCTAssertTrue(prepared.prompt.contains("Use SDK shell when it maps to the client shell/bash tool"))
    }

    func testResponsesToolChoiceDirectFunctionShapeAddsPromptHint() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model": "composer-2.5",
          "tool_choice": { "type": "function", "name": "shell" },
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
          "input": "Run pwd with the shell tool."
        }
        """#.utf8))

        XCTAssertEqual(prepared.tools.map(\.name), ["shell"])
        XCTAssertTrue(prepared.prompt.contains(#"Use SDK shell now; it will be forwarded to client tool shell"#))
    }

    func testResponsesToolChoiceNestedFunctionShapeAddsPromptHint() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model": "composer-2.5",
          "tool_choice": { "type": "function", "function": { "name": "shell" } },
          "tools": [
            {
              "type": "function",
              "function": {
                "name": "shell",
                "description": "Run a shell command",
                "parameters": {
                  "type": "object",
                  "properties": {
                    "command": { "type": "string" }
                  }
                }
              }
            }
          ],
          "input": "Run pwd with the shell tool."
        }
        """#.utf8))

        XCTAssertEqual(prepared.tools.map(\.name), ["shell"])
        XCTAssertTrue(prepared.prompt.contains(#"Use SDK shell now; it will be forwarded to client tool shell"#))
    }

    func testResponsesEndpointReturnsFunctionCallOutputItems() async throws {
        let port = try unusedTCPPort()
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
                    "description":{"type":"string"},
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
        XCTAssertTrue(message["content"] is NSNull)
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)

        XCTAssertEqual(function["name"] as? String, "bash")
        XCTAssertEqual(arguments["command"] as? String, "pwd")
        XCTAssertEqual(arguments["description"] as? String, "Run pwd")
        XCTAssertEqual(arguments["cwd"] as? String, "/tmp/project")
        XCTAssertEqual((arguments["timeout_ms"] as? NSNumber)?.doubleValue, 30)
        XCTAssertNil(arguments["workingDirectory"])
        XCTAssertNil(arguments["timeout"])
    }

    func testShellToolCallsDetachLikelyDevServers() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"run a server"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"bash",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "command":{"type":"string"}
                  }
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "shell", arguments: [
            "command": .string("python3 -m http.server 8080")
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
        let command = try XCTUnwrap(arguments["command"] as? String)

        XCTAssertTrue(command.contains("nohup sh -lc 'python3 -m http.server 8080'"))
        XCTAssertTrue(command.contains("/tmp/api-for-cursor/dev-server-"))
        XCTAssertTrue(command.contains("Started background process"))
    }

    func testShellToolCallsKeepAlreadyDetachedDevServers() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"run a server"}],
          "tools":[{"type":"function","function":{"name":"bash","parameters":{"type":"object","properties":{"command":{"type":"string"}}}}}]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "shell", arguments: [
            "command": .string("npm run dev > dev.log 2>&1 &")
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

        XCTAssertEqual(arguments["command"] as? String, "npm run dev > dev.log 2>&1 &")
    }

    func testChatToolCallsExpandHomeRelativePathsForAbsoluteFileSchemas() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"Create ~/Desktop/rain-in-spain.html"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"write",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "filePath":{"type":"string","description":"The absolute path to the file to write"},
                    "content":{"type":"string"}
                  },
                  "required":["filePath","content"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "write", arguments: [
            "path": .string("~/Desktop/rain-in-spain.html"),
            "fileText": .string("<main>Rain</main>")
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
        let expectedPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("rain-in-spain.html")
            .path

        XCTAssertEqual(function["name"] as? String, "write")
        XCTAssertEqual(arguments["filePath"] as? String, expectedPath)
        XCTAssertEqual(arguments["content"] as? String, "<main>Rain</main>")
    }

    func testChatToolCallsMapSDKGlobToOpenCodeSchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"find source files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"glob",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "pattern":{"type":"string"},
                    "path":{"type":"string"}
                  },
                  "required":["pattern"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "glob", arguments: [
            "targetDirectory": .string("/tmp/project"),
            "globPattern": .string("**/*.tsx")
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

        XCTAssertEqual(function["name"] as? String, "glob")
        XCTAssertEqual(arguments["pattern"] as? String, "**/*.tsx")
        XCTAssertEqual(arguments["path"] as? String, "/tmp/project")
        XCTAssertNil(arguments["targetDirectory"])
        XCTAssertNil(arguments["globPattern"])
    }

    func testChatToolCallsMapSDKGlobToBareInputSchemaTool() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"find source files"}],
          "tools":[
            {
              "name":"glob",
              "description":"Find files",
              "input_schema":{
                "type":"object",
                "properties":{
                  "pattern":{"type":"string"},
                  "path":{"type":"string"}
                },
                "required":["pattern"]
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "glob", arguments: [
            "targetDirectory": .string("src"),
            "globPattern": .string("**/*.tsx")
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

        XCTAssertEqual(prepared.tools.first?.description, "Find files")
        XCTAssertEqual(function["name"] as? String, "glob")
        XCTAssertEqual(arguments["pattern"] as? String, "**/*.tsx")
        XCTAssertEqual(arguments["path"] as? String, "src")
        XCTAssertNil(arguments["targetDirectory"])
        XCTAssertNil(arguments["globPattern"])
    }

    func testChatToolCallsUseOpenCodeWorkingDirectoryForRealFileAndGlobSchemas() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {
              "role":"system",
              "content":"Environment:\n  Working directory: /tmp/project\n  Workspace root folder: /tmp/project"
            },
            {"role":"user","content":"build a todo app in vite 8 and react"}
          ],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"write",
                "description":"Writes a file to the local filesystem.",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "content":{"type":"string","description":"The content to write to the file"},
                    "filePath":{"type":"string","description":"The absolute path to the file to write (must be absolute, not relative)"}
                  },
                  "required":["content","filePath"]
                }
              }
            },
            {
              "type":"function",
              "function":{
                "name":"read",
                "description":"Read a file or directory from the local filesystem.",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "filePath":{"type":"string","description":"The absolute path to the file or directory to read"}
                  },
                  "required":["filePath"]
                }
              }
            },
            {
              "type":"function",
              "function":{
                "name":"edit",
                "description":"Performs exact string replacements in files.",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "filePath":{"type":"string","description":"The absolute path to the file to modify"},
                    "oldString":{"type":"string"},
                    "newString":{"type":"string"}
                  },
                  "required":["filePath","oldString","newString"]
                }
              }
            },
            {
              "type":"function",
              "function":{
                "name":"glob",
                "description":"Fast file pattern matching tool.",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "pattern":{"type":"string","description":"The glob pattern to match files against"},
                    "path":{"type":"string","description":"The directory to search in"}
                  },
                  "required":["pattern"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "write", arguments: [
                "path": .string("src/App.tsx"),
                "fileText": .string("export default function App() { return null }")
            ]),
            CursorToolCall(name: "read", arguments: [
                "path": .string("src/App.tsx")
            ]),
            CursorToolCall(name: "edit", arguments: [
                "path": .string("src/App.tsx"),
                "oldString": .string("return null"),
                "newString": .string("return <main />")
            ]),
            CursorToolCall(name: "glob", arguments: [
                "targeting": .string("src/**"),
                "glob_pattern": .string("*.tsx")
            ])
        ], agentID: "agent-test", runID: "run-test")

        XCTAssertEqual(prepared.toolContext?.workingDirectory, "/tmp/project")

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: output
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 4)

        let writeFunction = try XCTUnwrap(toolCalls[0]["function"] as? [String: Any])
        XCTAssertEqual(writeFunction["name"] as? String, "write")
        XCTAssertEqual(try decodedArguments(writeFunction)["filePath"] as? String, "/tmp/project/src/App.tsx")
        XCTAssertEqual(try decodedArguments(writeFunction)["content"] as? String, "export default function App() { return null }")

        let readFunction = try XCTUnwrap(toolCalls[1]["function"] as? [String: Any])
        XCTAssertEqual(readFunction["name"] as? String, "read")
        XCTAssertEqual(try decodedArguments(readFunction)["filePath"] as? String, "/tmp/project/src/App.tsx")

        let editFunction = try XCTUnwrap(toolCalls[2]["function"] as? [String: Any])
        let editArguments = try decodedArguments(editFunction)
        XCTAssertEqual(editFunction["name"] as? String, "edit")
        XCTAssertEqual(editArguments["filePath"] as? String, "/tmp/project/src/App.tsx")
        XCTAssertEqual(editArguments["oldString"] as? String, "return null")
        XCTAssertEqual(editArguments["newString"] as? String, "return <main />")

        let globFunction = try XCTUnwrap(toolCalls[3]["function"] as? [String: Any])
        let globArguments = try decodedArguments(globFunction)
        XCTAssertEqual(globFunction["name"] as? String, "glob")
        XCTAssertEqual(globArguments["pattern"] as? String, "**/*.tsx")
        XCTAssertEqual(globArguments["path"] as? String, "/tmp/project/src")
    }

    func testChatToolCallsRepairSwappedSDKGlobArgumentsForOpenCode() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"find source files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"glob",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "pattern":{"type":"string"},
                    "path":{"type":"string"}
                  },
                  "required":["pattern"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "glob", arguments: [
            "targetDirectory": .string("**/*.tsx"),
            "globPattern": .string("/tmp/project")
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

        XCTAssertEqual(function["name"] as? String, "glob")
        XCTAssertEqual(arguments["pattern"] as? String, "**/*.tsx")
        XCTAssertEqual(arguments["path"] as? String, "/tmp/project")
        XCTAssertNil(arguments["targetDirectory"])
        XCTAssertNil(arguments["globPattern"])
    }

    func testChatToolCallsRepairSwappedSDKGlobArgumentsWithCurrentDirectoryRoot() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"find source files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"glob",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "pattern":{"type":"string"},
                    "path":{"type":"string"}
                  },
                  "required":["pattern"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "glob", arguments: [
            "targetDirectory": .string("**/*"),
            "globPattern": .string(".")
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

        XCTAssertEqual(function["name"] as? String, "glob")
        XCTAssertEqual(arguments["pattern"] as? String, "**/*")
        XCTAssertEqual(arguments["path"] as? String, ".")
        XCTAssertNil(arguments["targetDirectory"])
        XCTAssertNil(arguments["globPattern"])
    }

    func testChatToolCallsDefaultEmptySDKGlobForOpenCode() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"find project files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"glob",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "pattern":{"type":"string"},
                    "path":{"type":"string"}
                  },
                  "required":["pattern"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "glob", arguments: [:])

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

        XCTAssertEqual(function["name"] as? String, "glob")
        XCTAssertEqual(arguments["pattern"] as? String, "**/*")
        XCTAssertNil(arguments["path"])
    }

    func testChatToolCallsDoNotEmitSchemaInvalidFileToolCalls() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"write a file"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"write",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "filePath":{"type":"string"},
                    "content":{"type":"string"}
                  },
                  "required":["filePath","content"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "write", arguments: [
            "path": .string("src/App.tsx")
        ])

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        XCTAssertEqual((message["tool_calls"] as? [[String: Any]])?.count, 0)
    }

    func testChatToolCallsMapWrapperToolCallsThroughNestedReferencedSchemas() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"write a file"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"workspace_write",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "input":{
                      "type":"object",
                      "additionalProperties":false,
                      "properties":{
                        "filePath":{"$ref":"#/$defs/FilePath"},
                        "content":{"type":"string"}
                      },
                      "required":["filePath","content"]
                    }
                  },
                  "required":["input"],
                  "$defs":{
                    "FilePath":{"type":"string"}
                  }
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "write", arguments: [
            "path": .string("src/App.tsx"),
            "fileText": .string("export default function App() { return null }")
        ])

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_nested_ref",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)
        let input = try XCTUnwrap(arguments["input"] as? [String: Any])

        XCTAssertEqual(function["name"] as? String, "workspace_write")
        XCTAssertEqual(input["filePath"] as? String, "src/App.tsx")
        XCTAssertEqual(input["content"] as? String, "export default function App() { return null }")
        XCTAssertNil(arguments["path"])
        XCTAssertNil(arguments["fileText"])
    }

    func testChatToolCallsDoNotIgnoreInvalidNestedReferencedSchemas() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"write a file"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"workspace_write",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "input":{
                      "type":"object",
                      "additionalProperties":false,
                      "properties":{
                        "filePath":{"$ref":"#/$defs/FilePath"},
                        "content":{"type":"string"}
                      },
                      "required":["filePath","content"]
                    }
                  },
                  "required":["input"],
                  "$defs":{
                    "FilePath":{"type":"number"}
                  }
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "write", arguments: [
            "path": .string("src/App.tsx"),
            "fileText": .string("export default function App() { return null }")
        ])

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_nested_ref_invalid",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        XCTAssertEqual((message["tool_calls"] as? [[String: Any]])?.count, 0)
    }

    func testChatToolCallsMapDirectoryOnlySDKGlobForOpenCode() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"find project files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"glob",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "pattern":{"type":"string"},
                    "path":{"type":"string"}
                  },
                  "required":["pattern"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "glob", arguments: [
            "targetDirectory": .string("src")
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

        XCTAssertEqual(function["name"] as? String, "glob")
        XCTAssertEqual(arguments["pattern"] as? String, "**/*")
        XCTAssertEqual(arguments["path"] as? String, "src")
    }

    func testChatToolCallsFillRequiredGlobPathForStrictHarnesses() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"find project files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"glob",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "pattern":{"type":"string"},
                    "path":{"type":"string"}
                  },
                  "required":["pattern","path"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "glob", arguments: [
            "globPattern": .string("**/*.tsx")
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

        XCTAssertEqual(function["name"] as? String, "glob")
        XCTAssertEqual(arguments["pattern"] as? String, "**/*.tsx")
        XCTAssertEqual(arguments["path"] as? String, ".")
    }

    func testChatToolCallsMapSDKGlobToQueryBasedFileSearchSchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"find source files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"file_search",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "query":{"type":"string"},
                    "basePath":{"type":"string"}
                  },
                  "required":["query"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "glob", arguments: [
            "globPattern": .string("**/*.tsx"),
            "targetDirectory": .string("src")
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

        XCTAssertEqual(function["name"] as? String, "file_search")
        XCTAssertEqual(arguments["query"] as? String, "**/*.tsx")
        XCTAssertEqual(arguments["basePath"] as? String, "src")
    }

    func testChatToolCallsMapSDKListToQueryBasedFileSearchSchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"list source files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"find_files",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "filePattern":{"type":"string"},
                    "root":{"type":"string"}
                  },
                  "required":["filePattern"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "ls", arguments: ["path": .string("src")])

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

        XCTAssertEqual(function["name"] as? String, "find_files")
        XCTAssertEqual(arguments["filePattern"] as? String, "*")
        XCTAssertEqual(arguments["root"] as? String, "src")
    }

    func testChatToolCallsMapSDKFileOperationsToAnthropicTextEditorSchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"update app files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"str_replace_editor",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "command":{"type":"string"},
                    "path":{"type":"string"},
                    "file_text":{"type":"string"},
                    "old_str":{"type":"string"},
                    "new_str":{"type":"string"},
                    "view_range":{"type":"array","items":{"type":"integer"}}
                  },
                  "required":["command","path"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "write", arguments: [
                "path": .string("src/App.tsx"),
                "fileText": .string("export default function App() { return null }")
            ]),
            CursorToolCall(name: "read", arguments: [
                "path": .string("src/App.tsx"),
                "offset": .number(10),
                "limit": .number(20)
            ]),
            CursorToolCall(name: "edit", arguments: [
                "path": .string("src/App.tsx"),
                "oldString": .string("Hello"),
                "newString": .string("Hi")
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: output
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 3)

        let writeFunction = try XCTUnwrap(toolCalls[0]["function"] as? [String: Any])
        let writeArguments = try decodedArguments(writeFunction)
        XCTAssertEqual(writeFunction["name"] as? String, "str_replace_editor")
        XCTAssertEqual(writeArguments["command"] as? String, "create")
        XCTAssertEqual(writeArguments["path"] as? String, "src/App.tsx")
        XCTAssertEqual(writeArguments["file_text"] as? String, "export default function App() { return null }")

        let readFunction = try XCTUnwrap(toolCalls[1]["function"] as? [String: Any])
        let readArguments = try decodedArguments(readFunction)
        XCTAssertEqual(readFunction["name"] as? String, "str_replace_editor")
        XCTAssertEqual(readArguments["command"] as? String, "view")
        XCTAssertEqual(readArguments["path"] as? String, "src/App.tsx")
        let viewRange = try XCTUnwrap(readArguments["view_range"] as? [Any])
        XCTAssertEqual((viewRange[0] as? NSNumber)?.intValue, 10)
        XCTAssertEqual((viewRange[1] as? NSNumber)?.intValue, 29)

        let editFunction = try XCTUnwrap(toolCalls[2]["function"] as? [String: Any])
        let editArguments = try decodedArguments(editFunction)
        XCTAssertEqual(editFunction["name"] as? String, "str_replace_editor")
        XCTAssertEqual(editArguments["command"] as? String, "str_replace")
        XCTAssertEqual(editArguments["path"] as? String, "src/App.tsx")
        XCTAssertEqual(editArguments["old_str"] as? String, "Hello")
        XCTAssertEqual(editArguments["new_str"] as? String, "Hi")
    }

    func testChatToolCallsMapSDKFileOperationsToActionBasedFileTool() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"update app files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"file_manager",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "action":{"type":"string","enum":["read","write","replace","delete"]},
                    "path":{"type":"string"},
                    "content":{"type":"string"},
                    "old":{"type":"string"},
                    "replacement":{"type":"string"},
                    "offset":{"type":"integer"},
                    "limit":{"type":"integer"}
                  },
                  "required":["action","path"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "write", arguments: [
                "path": .string("src/App.tsx"),
                "fileText": .string("export default function App() { return null }")
            ]),
            CursorToolCall(name: "read", arguments: [
                "path": .string("src/App.tsx"),
                "offset": .number(5),
                "limit": .number(10)
            ]),
            CursorToolCall(name: "edit", arguments: [
                "path": .string("src/App.tsx"),
                "oldString": .string("Hello"),
                "newString": .string("Hi")
            ]),
            CursorToolCall(name: "delete", arguments: [
                "path": .string("src/old.tsx")
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: output
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 4)

        let writeFunction = try XCTUnwrap(toolCalls[0]["function"] as? [String: Any])
        let writeArguments = try decodedArguments(writeFunction)
        XCTAssertEqual(writeFunction["name"] as? String, "file_manager")
        XCTAssertEqual(writeArguments["action"] as? String, "write")
        XCTAssertEqual(writeArguments["path"] as? String, "src/App.tsx")
        XCTAssertEqual(writeArguments["content"] as? String, "export default function App() { return null }")

        let readFunction = try XCTUnwrap(toolCalls[1]["function"] as? [String: Any])
        let readArguments = try decodedArguments(readFunction)
        XCTAssertEqual(readFunction["name"] as? String, "file_manager")
        XCTAssertEqual(readArguments["action"] as? String, "read")
        XCTAssertEqual(readArguments["path"] as? String, "src/App.tsx")
        XCTAssertEqual((readArguments["offset"] as? NSNumber)?.intValue, 5)
        XCTAssertEqual((readArguments["limit"] as? NSNumber)?.intValue, 10)

        let editFunction = try XCTUnwrap(toolCalls[2]["function"] as? [String: Any])
        let editArguments = try decodedArguments(editFunction)
        XCTAssertEqual(editFunction["name"] as? String, "file_manager")
        XCTAssertEqual(editArguments["action"] as? String, "replace")
        XCTAssertEqual(editArguments["path"] as? String, "src/App.tsx")
        XCTAssertEqual(editArguments["old"] as? String, "Hello")
        XCTAssertEqual(editArguments["replacement"] as? String, "Hi")

        let deleteFunction = try XCTUnwrap(toolCalls[3]["function"] as? [String: Any])
        let deleteArguments = try decodedArguments(deleteFunction)
        XCTAssertEqual(deleteFunction["name"] as? String, "file_manager")
        XCTAssertEqual(deleteArguments["action"] as? String, "delete")
        XCTAssertEqual(deleteArguments["path"] as? String, "src/old.tsx")
    }

    func testChatToolCallsMapSDKReadToArrayRangeSchemas() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"read part of a file"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"read_file",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "path":{"type":"string"},
                    "range":{"type":"array","items":{"type":"integer"},"minItems":2,"maxItems":2}
                  },
                  "required":["path","range"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_read_range",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "read", arguments: [
                    "path": .string("src/App.tsx"),
                    "offset": .number(10),
                    "limit": .number(20)
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)
        let range = try XCTUnwrap(arguments["range"] as? [Any])

        XCTAssertEqual(function["name"] as? String, "read_file")
        XCTAssertEqual(arguments["path"] as? String, "src/App.tsx")
        XCTAssertEqual((range[0] as? NSNumber)?.intValue, 10)
        XCTAssertEqual((range[1] as? NSNumber)?.intValue, 29)
        XCTAssertNil(arguments["offset"])
        XCTAssertNil(arguments["limit"])
    }

    func testChatToolCallsMapSDKReadToActionBasedArrayRangeSchemas() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"read part of a file"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"file_manager",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "action":{"type":"string","enum":["read","write","replace","delete"]},
                    "path":{"type":"string"},
                    "view_range":{"type":"array","items":{"type":"integer"},"minItems":2,"maxItems":2}
                  },
                  "required":["action","path","view_range"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_action_read_range",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "read", arguments: [
                    "path": .string("src/App.tsx"),
                    "offset": .number(5),
                    "limit": .number(10)
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)
        let viewRange = try XCTUnwrap(arguments["view_range"] as? [Any])

        XCTAssertEqual(function["name"] as? String, "file_manager")
        XCTAssertEqual(arguments["action"] as? String, "read")
        XCTAssertEqual(arguments["path"] as? String, "src/App.tsx")
        XCTAssertEqual((viewRange[0] as? NSNumber)?.intValue, 5)
        XCTAssertEqual((viewRange[1] as? NSNumber)?.intValue, 14)
        XCTAssertNil(arguments["offset"])
        XCTAssertNil(arguments["limit"])
    }

    func testChatToolCallsMapSDKEditStreamContentToWriteSchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"replace app file"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"write_file",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "filePath":{"type":"string"},
                    "content":{"type":"string"}
                  },
                  "required":["filePath","content"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "edit", arguments: [
                "path": .string("src/App.tsx"),
                "streamContent": .string("export default function App() { return null }")
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: output
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)

        XCTAssertEqual(function["name"] as? String, "write_file")
        XCTAssertEqual(arguments["filePath"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments["content"] as? String, "export default function App() { return null }")
        XCTAssertNil(arguments["streamContent"])
    }

    func testChatToolCallsMapSDKOperationsIntoWrapperObjectSchemas() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"run and update app files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"wrapped_bash",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "input":{
                      "type":"object",
                      "properties":{
                        "command":{"type":"string"},
                        "workdir":{"type":"string"}
                      },
                      "required":["command"]
                    }
                  },
                  "required":["input"]
                }
              }
            },
            {
              "type":"function",
              "function":{
                "name":"wrapped_files",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "input":{
                      "type":"object",
                      "properties":{
                        "action":{"type":"string","enum":["read","write","replace","delete"]},
                        "path":{"type":"string"},
                        "content":{"type":"string"},
                        "old":{"type":"string"},
                        "replacement":{"type":"string"}
                      },
                      "required":["action","path"]
                    }
                  },
                  "required":["input"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "shell", arguments: [
                "command": .string("npm test"),
                "workingDirectory": .string("/tmp/app")
            ]),
            CursorToolCall(name: "write", arguments: [
                "path": .string("src/App.tsx"),
                "fileText": .string("export default function App() { return null }")
            ]),
            CursorToolCall(name: "edit", arguments: [
                "path": .string("src/App.tsx"),
                "oldString": .string("Hello"),
                "newString": .string("Hi")
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: output
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 3)

        let shellFunction = try XCTUnwrap(toolCalls[0]["function"] as? [String: Any])
        let shellArguments = try decodedArguments(shellFunction)
        let shellInput = try XCTUnwrap(shellArguments["input"] as? [String: Any])
        XCTAssertEqual(shellFunction["name"] as? String, "wrapped_bash")
        XCTAssertEqual(shellInput["command"] as? String, "npm test")
        XCTAssertEqual(shellInput["workdir"] as? String, "/tmp/app")

        let writeFunction = try XCTUnwrap(toolCalls[1]["function"] as? [String: Any])
        let writeArguments = try decodedArguments(writeFunction)
        let writeInput = try XCTUnwrap(writeArguments["input"] as? [String: Any])
        XCTAssertEqual(writeFunction["name"] as? String, "wrapped_files")
        XCTAssertEqual(writeInput["action"] as? String, "write")
        XCTAssertEqual(writeInput["path"] as? String, "src/App.tsx")
        XCTAssertEqual(writeInput["content"] as? String, "export default function App() { return null }")

        let editFunction = try XCTUnwrap(toolCalls[2]["function"] as? [String: Any])
        let editArguments = try decodedArguments(editFunction)
        let editInput = try XCTUnwrap(editArguments["input"] as? [String: Any])
        XCTAssertEqual(editFunction["name"] as? String, "wrapped_files")
        XCTAssertEqual(editInput["action"] as? String, "replace")
        XCTAssertEqual(editInput["path"] as? String, "src/App.tsx")
        XCTAssertEqual(editInput["old"] as? String, "Hello")
        XCTAssertEqual(editInput["replacement"] as? String, "Hi")
    }

    func testChatToolCallsMapSDKPatchContentToApplyPatchTool() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"patch app files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"apply_patch",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "patch":{"type":"string"},
                    "path":{"type":"string"}
                  },
                  "required":["patch"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let patch = [
            "*** Begin Patch",
            "*** Update File: src/App.tsx",
            "@@",
            "-return null",
            "+return <main />",
            "*** End Patch"
        ].joined(separator: "\n")
        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "edit", arguments: [
                "path": .string("src/App.tsx"),
                "patchContent": .string(patch)
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: output
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)

        XCTAssertEqual(function["name"] as? String, "apply_patch")
        XCTAssertEqual(arguments["path"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments["patch"] as? String, patch)
    }

    func testChatToolCallsMapSDKPatchContentWithoutSeparatePathToPatchOnlyTool() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"patch app files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"apply_patch",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "patch":{"type":"string"}
                  },
                  "required":["patch"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let patch = [
            "*** Begin Patch",
            "*** Update File: src/App.tsx",
            "@@",
            "-return null",
            "+return <main />",
            "*** End Patch"
        ].joined(separator: "\n")
        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "edit", arguments: [
                "patchContent": .string(patch)
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: output
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)

        XCTAssertEqual(function["name"] as? String, "apply_patch")
        XCTAssertNil(arguments["path"])
        XCTAssertEqual(arguments["patch"] as? String, patch)
    }

    func testChatToolCallsMapSDKFileOperationsToApplyPatchTool() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"patch app files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"apply_patch",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "patch":{"type":"string"},
                    "path":{"type":"string"}
                  },
                  "required":["patch"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "write", arguments: [
                "path": .string("src/App.tsx"),
                "fileText": .string("export default function App() {\n  return null\n}\n")
            ]),
            CursorToolCall(name: "edit", arguments: [
                "path": .string("src/App.tsx"),
                "oldString": .string("return null"),
                "newString": .string("return <main />")
            ]),
            CursorToolCall(name: "delete", arguments: [
                "path": .string("src/old.tsx")
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: output
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 3)

        let writeFunction = try XCTUnwrap(toolCalls[0]["function"] as? [String: Any])
        let writeArguments = try decodedArguments(writeFunction)
        XCTAssertEqual(writeFunction["name"] as? String, "apply_patch")
        XCTAssertEqual(writeArguments["path"] as? String, "src/App.tsx")
        XCTAssertEqual(writeArguments["patch"] as? String, [
            "*** Begin Patch",
            "*** Add File: src/App.tsx",
            "+export default function App() {",
            "+  return null",
            "+}",
            "*** End Patch"
        ].joined(separator: "\n"))

        let editFunction = try XCTUnwrap(toolCalls[1]["function"] as? [String: Any])
        let editArguments = try decodedArguments(editFunction)
        XCTAssertEqual(editFunction["name"] as? String, "apply_patch")
        XCTAssertEqual(editArguments["path"] as? String, "src/App.tsx")
        XCTAssertEqual(editArguments["patch"] as? String, [
            "*** Begin Patch",
            "*** Update File: src/App.tsx",
            "@@",
            "-return null",
            "+return <main />",
            "*** End Patch"
        ].joined(separator: "\n"))

        let deleteFunction = try XCTUnwrap(toolCalls[2]["function"] as? [String: Any])
        let deleteArguments = try decodedArguments(deleteFunction)
        XCTAssertEqual(deleteFunction["name"] as? String, "apply_patch")
        XCTAssertEqual(deleteArguments["path"] as? String, "src/old.tsx")
        XCTAssertEqual(deleteArguments["patch"] as? String, [
            "*** Begin Patch",
            "*** Delete File: src/old.tsx",
            "*** End Patch"
        ].joined(separator: "\n"))
    }

    func testChatToolCallsMapSDKCoreToolsToOpenCodeSchemas() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"inspect and edit files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"bash",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "command":{"type":"string"},
                    "timeout":{"type":"integer"},
                    "workdir":{"type":"string"},
                    "description":{"type":"string"}
                  },
                  "required":["command","description"]
                }
              }
            },
            {
              "type":"function",
              "function":{
                "name":"grep",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "pattern":{"type":"string"},
                    "path":{"type":"string"},
                    "include":{"type":"string"}
                  },
                  "required":["pattern"]
                }
              }
            },
            {
              "type":"function",
              "function":{
                "name":"read",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "filePath":{"type":"string"},
                    "offset":{"type":"integer"},
                    "limit":{"type":"integer"}
                  },
                  "required":["filePath"]
                }
              }
            },
            {
              "type":"function",
              "function":{
                "name":"write",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "content":{"type":"string"},
                    "filePath":{"type":"string"}
                  },
                  "required":["content","filePath"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "shell", arguments: [
                "command": .string("npm install"),
                "workingDirectory": .string("/tmp/project"),
                "timeout": .number(120_000)
            ]),
            CursorToolCall(name: "grep", arguments: [
                "pattern": .string("useState"),
                "path": .string("/tmp/project/src"),
                "glob": .string("*.tsx")
            ]),
            CursorToolCall(name: "read", arguments: [
                "path": .string("/tmp/project/src/App.tsx"),
                "offset": .number(10),
                "limit": .number(20)
            ]),
            CursorToolCall(name: "write", arguments: [
                "path": .string("/tmp/project/src/App.tsx"),
                "fileText": .string("export default function App() { return null }")
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: output
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 4)

        let bashFunction = try XCTUnwrap(toolCalls[0]["function"] as? [String: Any])
        let bashArguments = try decodedArguments(bashFunction)
        XCTAssertEqual(bashFunction["name"] as? String, "bash")
        XCTAssertEqual(bashArguments["command"] as? String, "npm install")
        XCTAssertEqual(bashArguments["description"] as? String, "Run npm install")
        XCTAssertEqual(bashArguments["workdir"] as? String, "/tmp/project")
        XCTAssertEqual((bashArguments["timeout"] as? NSNumber)?.doubleValue, 120_000)
        XCTAssertNil(bashArguments["workingDirectory"])

        let grepFunction = try XCTUnwrap(toolCalls[1]["function"] as? [String: Any])
        let grepArguments = try decodedArguments(grepFunction)
        XCTAssertEqual(grepFunction["name"] as? String, "grep")
        XCTAssertEqual(grepArguments["pattern"] as? String, "useState")
        XCTAssertEqual(grepArguments["path"] as? String, "/tmp/project/src")
        XCTAssertEqual(grepArguments["include"] as? String, "*.tsx")
        XCTAssertNil(grepArguments["glob"])

        let readFunction = try XCTUnwrap(toolCalls[2]["function"] as? [String: Any])
        let readArguments = try decodedArguments(readFunction)
        XCTAssertEqual(readFunction["name"] as? String, "read")
        XCTAssertEqual(readArguments["filePath"] as? String, "/tmp/project/src/App.tsx")
        XCTAssertEqual((readArguments["offset"] as? NSNumber)?.doubleValue, 10)
        XCTAssertEqual((readArguments["limit"] as? NSNumber)?.doubleValue, 20)
        XCTAssertNil(readArguments["path"])

        let writeFunction = try XCTUnwrap(toolCalls[3]["function"] as? [String: Any])
        let writeArguments = try decodedArguments(writeFunction)
        XCTAssertEqual(writeFunction["name"] as? String, "write")
        XCTAssertEqual(writeArguments["filePath"] as? String, "/tmp/project/src/App.tsx")
        XCTAssertEqual(writeArguments["content"] as? String, "export default function App() { return null }")
        XCTAssertNil(writeArguments["path"])
        XCTAssertNil(writeArguments["fileText"])
    }

    func testChatToolCallsMapSDKCallsThroughComposedJSONSchemas() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"build the app"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"run_command",
                "json_schema":{
                  "schema":{
                    "allOf":[
                      {
                        "type":"object",
                        "properties":{"shellCommand":{"type":"string"}},
                        "required":["shellCommand"]
                      },
                      {
                        "type":"object",
                        "properties":{
                          "workingDir":{"type":"string"},
                          "timeoutSeconds":{"type":"number","description":"Timeout in seconds"},
                          "description":{"type":"string"}
                        }
                      }
                    ],
                    "additionalProperties":false
                  }
                }
              }
            },
            {
              "type":"function",
              "function":{
                "name":"workspace_file",
                "parameters":{
                  "anyOf":[
                    {
                      "type":"object",
                      "properties":{
                        "action":{"type":"string","const":"create"},
                        "target":{"type":"string"},
                        "body":{"type":"string"}
                      },
                      "required":["action","target","body"]
                    },
                    {
                      "type":"object",
                      "properties":{
                        "action":{"type":"string","const":"replace"},
                        "target":{"type":"string"},
                        "find":{"type":"string"},
                        "replaceWith":{"type":"string"}
                      },
                      "required":["action","target","find","replaceWith"]
                    }
                  ],
                  "additionalProperties":false
                }
              }
            }
          ]
        }
        """#.utf8))

        XCTAssertTrue(prepared.prompt.contains(#""sdk":"shell""#))
        XCTAssertTrue(prepared.prompt.contains(#""client":"run_command""#))
        XCTAssertTrue(prepared.prompt.contains(#""sdk":"write""#))
        XCTAssertTrue(prepared.prompt.contains(#""client":"workspace_file""#))

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "shell", arguments: [
                    "command": .string("npm run build"),
                    "workingDirectory": .string("/workspace"),
                    "timeout": .number(120_000)
                ]),
                CursorToolCall(name: "write", arguments: [
                    "path": .string("src/App.jsx"),
                    "fileText": .string("export default function App() { return null }")
                ]),
                CursorToolCall(name: "edit", arguments: [
                    "path": .string("src/App.jsx"),
                    "oldString": .string("return null"),
                    "newString": .string("return <main />")
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 3)

        let shellFunction = try XCTUnwrap(toolCalls[0]["function"] as? [String: Any])
        let shellArguments = try decodedArguments(shellFunction)
        XCTAssertEqual(shellFunction["name"] as? String, "run_command")
        XCTAssertEqual(shellArguments["shellCommand"] as? String, "npm run build")
        XCTAssertNil(shellArguments["workingDir"])
        XCTAssertEqual((shellArguments["timeoutSeconds"] as? NSNumber)?.doubleValue, 120)
        XCTAssertEqual(shellArguments["description"] as? String, "Run npm run build")

        let writeFunction = try XCTUnwrap(toolCalls[1]["function"] as? [String: Any])
        let writeArguments = try decodedArguments(writeFunction)
        XCTAssertEqual(writeFunction["name"] as? String, "workspace_file")
        XCTAssertEqual(writeArguments["action"] as? String, "create")
        XCTAssertEqual(writeArguments["target"] as? String, "src/App.jsx")
        XCTAssertEqual(writeArguments["body"] as? String, "export default function App() { return null }")

        let editFunction = try XCTUnwrap(toolCalls[2]["function"] as? [String: Any])
        let editArguments = try decodedArguments(editFunction)
        XCTAssertEqual(editFunction["name"] as? String, "workspace_file")
        XCTAssertEqual(editArguments["action"] as? String, "replace")
        XCTAssertEqual(editArguments["target"] as? String, "src/App.jsx")
        XCTAssertEqual(editArguments["find"] as? String, "return null")
        XCTAssertEqual(editArguments["replaceWith"] as? String, "return <main />")
    }

    func testChatToolCallsMapSDKCallsThroughReferencedJSONSchemas() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"write the referenced schema file"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"workspace_file",
                "parameters":{
                  "$ref":"#/$defs/FileInput",
                  "$defs":{
                    "FileInput":{
                      "type":"object",
                      "properties":{
                        "operation":{"$ref":"#/$defs/FileOperation"},
                        "absolutePath":{"type":"string","description":"absolute path to the file"},
                        "text":{"type":"string"}
                      },
                      "required":["operation","absolutePath","text"],
                      "additionalProperties":false
                    },
                    "FileOperation":{
                      "type":"string",
                      "enum":["create","replace","read"]
                    }
                  }
                }
              }
            }
          ]
        }
        """#.utf8))

        XCTAssertTrue(prepared.prompt.contains(#""sdk":"write""#))
        XCTAssertTrue(prepared.prompt.contains(#""client":"workspace_file""#))

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "write", arguments: [
                    "path": .string("src/App.jsx"),
                    "fileText": .string("export default function App() { return <main>Ref</main> }")
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 1)

        let function = try XCTUnwrap(toolCalls[0]["function"] as? [String: Any])
        let arguments = try decodedArguments(function)
        XCTAssertEqual(function["name"] as? String, "workspace_file")
        XCTAssertEqual(arguments["operation"] as? String, "create")
        XCTAssertEqual(arguments["absolutePath"] as? String, "src/App.jsx")
        XCTAssertEqual(arguments["text"] as? String, "export default function App() { return <main>Ref</main> }")
    }

    func testChatToolCallsMapSDKCallsThroughInputSchemaWrappers() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"find react files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"find_files",
                "parameters":{
                  "inputSchema":{
                    "$ref":"#/$defs/FindInput",
                    "$defs":{
                      "FindInput":{
                        "type":"object",
                        "properties":{
                          "pattern":{"type":"string"},
                          "root":{"type":"string"}
                        },
                        "required":["pattern"],
                        "additionalProperties":false
                      }
                    }
                  }
                }
              }
            }
          ]
        }
        """#.utf8))

        XCTAssertTrue(prepared.prompt.contains(#""sdk":"glob""#))
        XCTAssertTrue(prepared.prompt.contains(#""client":"find_files""#))

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_input_schema",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "glob", arguments: [
                    "targetDirectory": .string("src"),
                    "globPattern": .string("**/*.tsx")
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 1)

        let function = try XCTUnwrap(toolCalls[0]["function"] as? [String: Any])
        let arguments = try decodedArguments(function)
        XCTAssertEqual(function["name"] as? String, "find_files")
        XCTAssertEqual(arguments["pattern"] as? String, "**/*.tsx")
        XCTAssertEqual(arguments["root"] as? String, "src")
        XCTAssertNil(arguments["globPattern"])
        XCTAssertNil(arguments["targetDirectory"])
    }

    func testChatToolInventoryAdvertisesPiFindAsExactSDKMCPWithGlobFallback() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"find source files"}],
          "tool_choice":{"type":"function","function":{"name":"find"}},
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"find",
                "description":"Find files by glob pattern",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "pattern":{"type":"string"},
                    "path":{"type":"string"},
                    "limit":{"type":"number"}
                  },
                  "required":["pattern"]
                }
              }
            }
          ]
        }
        """#.utf8))

        XCTAssertTrue(prepared.prompt.contains(#""name":"find""#))
        XCTAssertFalse(prepared.prompt.contains(#""sdk_mcp":{"providerIdentifier":"client","toolName":"find""#))
        XCTAssertTrue(prepared.prompt.contains(#""sdk":"glob""#))
        XCTAssertTrue(prepared.prompt.contains(#""client":"find""#))
        XCTAssertTrue(prepared.prompt.contains(#"Use SDK glob now; it will be forwarded to client tool find"#))

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "glob", arguments: [
                    "targetDirectory": .string("src"),
                    "globPattern": .string("**/*.tsx")
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)

        XCTAssertEqual(function["name"] as? String, "find")
        XCTAssertEqual(arguments["pattern"] as? String, "**/*.tsx")
        XCTAssertEqual(arguments["path"] as? String, "src")
        XCTAssertNil(arguments["globPattern"])
        XCTAssertNil(arguments["targetDirectory"])
    }

    func testChatToolCallsMapExactSDKMCPToBuiltInClientToolSchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"find source files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"glob",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "pattern":{"type":"string"},
                    "path":{"type":"string"}
                  },
                  "required":["pattern"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "mcp", arguments: [
                    "providerIdentifier": .string("client"),
                    "toolName": .string("glob"),
                    "args": .object([
                        "pattern": .string("**/*.tsx"),
                        "path": .string("src")
                    ])
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)

        XCTAssertEqual(function["name"] as? String, "glob")
        XCTAssertEqual(arguments["pattern"] as? String, "**/*.tsx")
        XCTAssertEqual(arguments["path"] as? String, "src")
    }

    func testChatToolCallsMapSDKGrepToPiGrepSchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"search source files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"grep",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "pattern":{"type":"string"},
                    "path":{"type":"string"},
                    "glob":{"type":"string"},
                    "ignoreCase":{"type":"boolean"},
                    "literal":{"type":"boolean"},
                    "context":{"type":"number"},
                    "limit":{"type":"number"}
                  },
                  "required":["pattern"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "grep", arguments: [
                    "pattern": .string("TODO"),
                    "path": .string("src"),
                    "glob": .string("*.tsx"),
                    "caseInsensitive": .bool(true),
                    "literal": .bool(true),
                    "context": .number(2),
                    "headLimit": .number(10)
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)

        XCTAssertEqual(function["name"] as? String, "grep")
        XCTAssertEqual(arguments["pattern"] as? String, "TODO")
        XCTAssertEqual(arguments["path"] as? String, "src")
        XCTAssertEqual(arguments["glob"] as? String, "*.tsx")
        XCTAssertEqual(arguments["ignoreCase"] as? Bool, true)
        XCTAssertEqual(arguments["literal"] as? Bool, true)
        XCTAssertEqual((arguments["context"] as? NSNumber)?.doubleValue, 2)
        XCTAssertEqual((arguments["limit"] as? NSNumber)?.doubleValue, 10)
        XCTAssertNil(arguments["caseInsensitive"])
        XCTAssertNil(arguments["headLimit"])
    }

    func testChatToolCallsMapSDKEditToPiEditSchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"edit app"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"edit",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "path":{"type":"string"},
                    "oldText":{"type":"string"},
                    "newText":{"type":"string"}
                  },
                  "required":["path","oldText","newText"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "edit", arguments: [
                    "path": .string("src/App.tsx"),
                    "oldString": .string("return null"),
                    "newString": .string("return <main />")
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)

        XCTAssertEqual(function["name"] as? String, "edit")
        XCTAssertEqual(arguments["path"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments["oldText"] as? String, "return null")
        XCTAssertEqual(arguments["newText"] as? String, "return <main />")
        XCTAssertNil(arguments["oldString"])
        XCTAssertNil(arguments["newString"])
    }

    func testChatToolCallsMapSDKEditToArrayReplacementSchemas() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"edit app"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"multi_edit",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "path":{"type":"string"},
                    "edits":{
                      "type":"array",
                      "items":{
                        "type":"object",
                        "additionalProperties":false,
                        "properties":{
                          "oldText":{"type":"string"},
                          "newText":{"type":"string"}
                        },
                        "required":["oldText","newText"]
                      },
                      "minItems":1
                    }
                  },
                  "required":["path","edits"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_edit_array",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "edit", arguments: [
                    "path": .string("src/App.tsx"),
                    "oldString": .string("return null"),
                    "newString": .string("return <main />")
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)
        let edits = try XCTUnwrap(arguments["edits"] as? [[String: Any]])

        XCTAssertEqual(function["name"] as? String, "multi_edit")
        XCTAssertEqual(arguments["path"] as? String, "src/App.tsx")
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?["oldText"] as? String, "return null")
        XCTAssertEqual(edits.first?["newText"] as? String, "return <main />")
        XCTAssertNil(arguments["oldString"])
        XCTAssertNil(arguments["newString"])
    }

    func testChatToolCallsMapFullPiBuiltinSchemaMatrix() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"work in the project"}],
          "tools":[
            {"type":"function","function":{"name":"bash","parameters":{"type":"object","properties":{"command":{"type":"string"},"timeout":{"type":"number","description":"Timeout in seconds (optional, no default timeout)"}},"required":["command"]}}},
            {"type":"function","function":{"name":"read","parameters":{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"number"},"limit":{"type":"number"}},"required":["path"]}}},
            {"type":"function","function":{"name":"write","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}},
            {"type":"function","function":{"name":"edit","parameters":{"type":"object","properties":{"path":{"type":"string"},"oldText":{"type":"string"},"newText":{"type":"string"}},"required":["path","oldText","newText"]}}},
            {"type":"function","function":{"name":"find","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"limit":{"type":"number"}},"required":["pattern"]}}},
            {"type":"function","function":{"name":"grep","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"},"ignoreCase":{"type":"boolean"},"literal":{"type":"boolean"},"context":{"type":"number"},"limit":{"type":"number"}},"required":["pattern"]}}},
            {"type":"function","function":{"name":"ls","parameters":{"type":"object","properties":{"path":{"type":"string"},"limit":{"type":"number"}}}}}
          ]
        }
        """#.utf8))

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "shell", arguments: ["command": .string("npm test"), "timeout": .number(120_000)]),
                CursorToolCall(name: "read", arguments: ["path": .string("src/App.tsx"), "offset": .number(5), "limit": .number(20)]),
                CursorToolCall(name: "write", arguments: ["path": .string("src/App.tsx"), "fileText": .string("export default function App() { return null }")]),
                CursorToolCall(name: "edit", arguments: ["path": .string("src/App.tsx"), "oldString": .string("return null"), "newString": .string("return <main />")]),
                CursorToolCall(name: "glob", arguments: ["globPattern": .string("**/*.tsx"), "targetDirectory": .string("src")]),
                CursorToolCall(name: "grep", arguments: [
                    "pattern": .string("TODO"),
                    "path": .string("src"),
                    "glob": .string("*.tsx"),
                    "caseInsensitive": .bool(true),
                    "literal": .bool(true),
                    "context": .number(2),
                    "headLimit": .number(10)
                ]),
                CursorToolCall(name: "ls", arguments: ["path": .string("src"), "limit": .number(50)])
            ], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }, ["bash", "read", "write", "edit", "find", "grep", "ls"])

        let arguments = try toolCalls.map { try decodedArguments(try XCTUnwrap($0["function"] as? [String: Any])) }
        XCTAssertEqual(arguments[0]["command"] as? String, "npm test")
        XCTAssertEqual((arguments[0]["timeout"] as? NSNumber)?.doubleValue, 120)
        XCTAssertEqual(arguments[1]["path"] as? String, "src/App.tsx")
        XCTAssertEqual((arguments[1]["offset"] as? NSNumber)?.doubleValue, 5)
        XCTAssertEqual((arguments[1]["limit"] as? NSNumber)?.doubleValue, 20)
        XCTAssertEqual(arguments[2]["path"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments[2]["content"] as? String, "export default function App() { return null }")
        XCTAssertEqual(arguments[3]["oldText"] as? String, "return null")
        XCTAssertEqual(arguments[3]["newText"] as? String, "return <main />")
        XCTAssertEqual(arguments[4]["pattern"] as? String, "**/*.tsx")
        XCTAssertEqual(arguments[4]["path"] as? String, "src")
        XCTAssertEqual(arguments[5]["ignoreCase"] as? Bool, true)
        XCTAssertEqual(arguments[5]["literal"] as? Bool, true)
        XCTAssertEqual((arguments[5]["limit"] as? NSNumber)?.doubleValue, 10)
        XCTAssertEqual(arguments[6]["path"] as? String, "src")
        XCTAssertEqual((arguments[6]["limit"] as? NSNumber)?.doubleValue, 50)
    }

    func testChatToolCallsMapLiveOpenCodeBuildToolMatrix() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"system","content":"Environment:\n  Working directory: /tmp/project\n  Workspace root folder: /tmp/project"},
            {"role":"user","content":"work in the project"}
          ],
          "tools":[
            {"type":"function","function":{"name":"bash","parameters":{"type":"object","properties":{"command":{"type":"string"},"timeout":{"type":"integer"},"workdir":{"type":"string"},"description":{"type":"string"}},"required":["command","description"]}}},
            {"type":"function","function":{"name":"edit","parameters":{"type":"object","properties":{"filePath":{"type":"string","description":"The absolute path to the file to modify"},"oldString":{"type":"string"},"newString":{"type":"string"},"replaceAll":{"type":"boolean"}},"required":["filePath","oldString","newString"]}}},
            {"type":"function","function":{"name":"glob","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string","description":"The directory to search in"}},"required":["pattern"]}}},
            {"type":"function","function":{"name":"grep","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"include":{"type":"string"}},"required":["pattern"]}}},
            {"type":"function","function":{"name":"read","parameters":{"type":"object","properties":{"filePath":{"type":"string","description":"The absolute path to the file or directory to read"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["filePath"]}}},
            {"type":"function","function":{"name":"skill","parameters":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}},
            {"type":"function","function":{"name":"task","parameters":{"type":"object","properties":{"description":{"type":"string"},"prompt":{"type":"string"},"subagent_type":{"type":"string"},"task_id":{"type":"string"},"command":{"type":"string"}},"required":["description","prompt","subagent_type"]}}},
            {"type":"function","function":{"name":"todowrite","parameters":{"type":"object","properties":{"todos":{"type":"array","items":{"type":"object","properties":{"content":{"type":"string"},"status":{"type":"string"},"priority":{"type":"string"}},"required":["content","status","priority"]}}},"required":["todos"]}}},
            {"type":"function","function":{"name":"webfetch","parameters":{"type":"object","properties":{"url":{"type":"string"},"format":{"anyOf":[{"type":"string","enum":["text","markdown","html"]},{"type":"null"}]},"timeout":{"type":"number"}},"required":["url"]}}},
            {"type":"function","function":{"name":"write","parameters":{"type":"object","properties":{"content":{"type":"string"},"filePath":{"type":"string","description":"The absolute path to the file to write (must be absolute, not relative)"}},"required":["content","filePath"]}}}
          ]
        }
        """#.utf8))

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "shell", arguments: [
                    "command": .string("npm test"),
                    "timeout": .number(120_000),
                    "workingDirectory": .string("/tmp/project")
                ]),
                CursorToolCall(name: "read", arguments: ["path": .string("src/App.tsx"), "offset": .number(5), "limit": .number(20)]),
                CursorToolCall(name: "write", arguments: ["path": .string("src/App.tsx"), "fileText": .string("export default function App() { return null }")]),
                CursorToolCall(name: "edit", arguments: [
                    "path": .string("src/App.tsx"),
                    "oldString": .string("return null"),
                    "newString": .string("return <main />"),
                    "replaceAll": .bool(true)
                ]),
                CursorToolCall(name: "glob", arguments: ["targetDirectory": .string("src"), "globPattern": .string("**/*.tsx")]),
                CursorToolCall(name: "grep", arguments: ["pattern": .string("TODO"), "path": .string("src"), "glob": .string("*.tsx")]),
                CursorToolCall(name: "todowrite", arguments: [
                    "todos": .array([.object(["content": .string("Build app"), "status": .string("in_progress"), "priority": .string("high")])])
                ]),
                CursorToolCall(name: "delete", arguments: ["path": .string("src/old.tsx")]),
                CursorToolCall(name: "ls", arguments: ["path": .string("src")]),
                CursorToolCall(name: "semsearch", arguments: ["query": .string("submit button"), "targetDirectories": .array([.string("src")])]),
                CursorToolCall(name: "mcp", arguments: [
                    "providerIdentifier": .string("client"),
                    "toolName": .string("webfetch"),
                    "args": .object(["url": .string("https://example.com"), "format": .string("markdown"), "timeout": .number(10)])
                ]),
                CursorToolCall(name: "mcp", arguments: [
                    "providerIdentifier": .string("client"),
                    "toolName": .string("task"),
                    "args": .object([
                        "description": .string("Inspect app"),
                        "prompt": .string("Find the app entry point"),
                        "subagent_type": .string("explore"),
                        "command": .string("inspect")
                    ])
                ]),
                CursorToolCall(name: "mcp", arguments: [
                    "providerIdentifier": .string("client"),
                    "toolName": .string("skill"),
                    "args": .object(["name": .string("customize-opencode")])
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }, [
            "bash",
            "read",
            "write",
            "edit",
            "glob",
            "grep",
            "todowrite",
            "bash",
            "glob",
            "bash",
            "webfetch",
            "task",
            "skill"
        ])

        let arguments = try toolCalls.map { try decodedArguments(try XCTUnwrap($0["function"] as? [String: Any])) }
        XCTAssertEqual(arguments[0]["command"] as? String, "npm test")
        XCTAssertEqual(arguments[0]["description"] as? String, "Run npm test")
        XCTAssertEqual(arguments[0]["workdir"] as? String, "/tmp/project")
        XCTAssertEqual((arguments[0]["timeout"] as? NSNumber)?.doubleValue, 120_000)
        XCTAssertEqual(arguments[1]["filePath"] as? String, "/tmp/project/src/App.tsx")
        XCTAssertEqual((arguments[1]["offset"] as? NSNumber)?.doubleValue, 5)
        XCTAssertEqual((arguments[1]["limit"] as? NSNumber)?.doubleValue, 20)
        XCTAssertEqual(arguments[2]["filePath"] as? String, "/tmp/project/src/App.tsx")
        XCTAssertEqual(arguments[2]["content"] as? String, "export default function App() { return null }")
        XCTAssertEqual(arguments[3]["filePath"] as? String, "/tmp/project/src/App.tsx")
        XCTAssertEqual(arguments[3]["oldString"] as? String, "return null")
        XCTAssertEqual(arguments[3]["newString"] as? String, "return <main />")
        XCTAssertEqual(arguments[3]["replaceAll"] as? Bool, true)
        XCTAssertEqual(arguments[4]["pattern"] as? String, "**/*.tsx")
        XCTAssertEqual(arguments[4]["path"] as? String, "/tmp/project/src")
        XCTAssertEqual(arguments[5]["pattern"] as? String, "TODO")
        XCTAssertEqual(arguments[5]["path"] as? String, "src")
        XCTAssertEqual(arguments[5]["include"] as? String, "*.tsx")
        let todos = try XCTUnwrap(arguments[6]["todos"] as? [[String: Any]])
        XCTAssertEqual(todos.first?["content"] as? String, "Build app")
        XCTAssertEqual(todos.first?["status"] as? String, "in_progress")
        XCTAssertEqual(todos.first?["priority"] as? String, "high")
        XCTAssertEqual(arguments[7]["command"] as? String, "rm -rf 'src/old.tsx'")
        XCTAssertEqual(arguments[7]["description"] as? String, "Run rm -rf 'src/old.tsx'")
        XCTAssertEqual(arguments[8]["pattern"] as? String, "*")
        XCTAssertEqual(arguments[8]["path"] as? String, "src")
        XCTAssertEqual(arguments[9]["command"] as? String, "rg --line-number --color never --hidden 'submit button' 'src'")
        XCTAssertEqual(arguments[9]["description"] as? String, "Run rg --line-number --color never --hidden 'submit button' 'src'")
        XCTAssertEqual(arguments[10]["url"] as? String, "https://example.com")
        XCTAssertEqual(arguments[10]["format"] as? String, "markdown")
        XCTAssertEqual((arguments[10]["timeout"] as? NSNumber)?.doubleValue, 10)
        XCTAssertEqual(arguments[11]["description"] as? String, "Inspect app")
        XCTAssertEqual(arguments[11]["prompt"] as? String, "Find the app entry point")
        XCTAssertEqual(arguments[11]["subagent_type"] as? String, "explore")
        XCTAssertEqual(arguments[11]["command"] as? String, "inspect")
        XCTAssertEqual(arguments[12]["name"] as? String, "customize-opencode")
    }

    func testChatToolCallsMapViteReactBuildFlowThroughStrictOpenCodeSchemas() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"system","content":"Working directory: /tmp/todo-vite"},
            {"role":"user","content":"build a todo app in vite 8 and react"}
          ],
          "tools":[
            {"type":"function","function":{"name":"bash","parameters":{"type":"object","additionalProperties":false,"properties":{"command":{"type":"string"},"cwd":{"type":"string"},"timeout_ms":{"type":"number"},"description":{"type":"string"}},"required":["command","cwd","timeout_ms","description"]}}},
            {"type":"function","function":{"name":"glob","parameters":{"type":"object","additionalProperties":false,"properties":{"pattern":{"type":"string"},"path":{"type":"string"}},"required":["pattern","path"]}}},
            {"type":"function","function":{"name":"write","parameters":{"type":"object","additionalProperties":false,"properties":{"filePath":{"type":"string","description":"The absolute path to the file to write"},"content":{"type":"string"}},"required":["filePath","content"]}}},
            {"type":"function","function":{"name":"edit","parameters":{"type":"object","additionalProperties":false,"properties":{"filePath":{"type":"string","description":"The absolute path to the file to modify"},"oldString":{"type":"string"},"newString":{"type":"string"}},"required":["filePath","oldString","newString"]}}}
          ]
        }
        """#.utf8))
        XCTAssertTrue(prepared.prompt.contains("LOCAL TOOL REQUIRED FOR THE LATEST USER REQUEST"))
        XCTAssertTrue(prepared.prompt.contains("Client tool targets: bash, glob, write, edit"))
        XCTAssertFalse(prepared.prompt.contains("Allowed tool names: bash"))
        XCTAssertTrue(prepared.prompt.contains("SDK TOOL ROUTING MAP:"))
        let routes = try prepared.prompt
            .split(separator: "\n")
            .filter { $0.contains(#""sdk""#) && $0.contains(#""client""#) }
            .map { line -> [String: Any] in
                let data = Data(String(line).utf8)
                return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }
        let globRoute = try XCTUnwrap(routes.first { ($0["sdk"] as? String) == "glob" })
        let globRouteArgs = try XCTUnwrap(globRoute["clientArgs"] as? [String: Any])
        XCTAssertEqual(globRoute["client"] as? String, "glob")
        XCTAssertEqual(globRouteArgs["pattern"] as? String, "**/*")
        XCTAssertEqual(globRouteArgs["path"] as? String, "/tmp/todo-vite")
        let shellRoute = try XCTUnwrap(routes.first { ($0["sdk"] as? String) == "shell" })
        let shellRouteArgs = try XCTUnwrap(shellRoute["clientArgs"] as? [String: Any])
        XCTAssertEqual(shellRoute["client"] as? String, "bash")
        XCTAssertEqual(shellRouteArgs["command"] as? String, "<command>")
        XCTAssertEqual(shellRouteArgs["cwd"] as? String, ".")
        XCTAssertEqual((shellRouteArgs["timeout_ms"] as? NSNumber)?.doubleValue, 120_000)

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_viteflow",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "glob", arguments: ["targetDirectory": .string(".")]),
                CursorToolCall(name: "shell", arguments: [
                    "command": .string("npm create vite@latest . -- --template react"),
                    "workingDirectory": .string("/workspace")
                ]),
                CursorToolCall(name: "write", arguments: [
                    "path": .string("src/App.jsx"),
                    "fileText": .string("export default function App() { return <main>Todos</main> }")
                ]),
                CursorToolCall(name: "edit", arguments: [
                    "path": .string("package.json"),
                    "oldString": .string("\"scripts\": {"),
                    "newString": .string("\"scripts\": {")
                ]),
                CursorToolCall(name: "shell", arguments: [
                    "command": .string("npm install && npm run build"),
                    "timeout": .number(120_000)
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }, ["glob", "bash", "write", "edit", "bash"])

        let arguments = try toolCalls.map { try decodedArguments(try XCTUnwrap($0["function"] as? [String: Any])) }
        XCTAssertEqual(arguments[0]["pattern"] as? String, "**/*")
        XCTAssertEqual(arguments[0]["path"] as? String, "/tmp/todo-vite")
        XCTAssertEqual(arguments[1]["command"] as? String, "npm create vite@latest . -- --template react")
        XCTAssertEqual(arguments[1]["cwd"] as? String, ".")
        XCTAssertEqual((arguments[1]["timeout_ms"] as? NSNumber)?.doubleValue, 120_000)
        XCTAssertEqual(arguments[1]["description"] as? String, "Run npm create vite@latest . -- --template react")
        XCTAssertEqual(arguments[2]["filePath"] as? String, "/tmp/todo-vite/src/App.jsx")
        XCTAssertEqual(arguments[2]["content"] as? String, "export default function App() { return <main>Todos</main> }")
        XCTAssertEqual(arguments[3]["filePath"] as? String, "/tmp/todo-vite/package.json")
        XCTAssertEqual(arguments[3]["oldString"] as? String, "\"scripts\": {")
        XCTAssertEqual(arguments[3]["newString"] as? String, "\"scripts\": {")
        XCTAssertEqual(arguments[4]["command"] as? String, "npm install && npm run build")
        XCTAssertEqual(arguments[4]["cwd"] as? String, ".")
        XCTAssertEqual((arguments[4]["timeout_ms"] as? NSNumber)?.doubleValue, 120_000)
        XCTAssertEqual(arguments[4]["description"] as? String, "Run npm install && npm run build")
    }

    func testChatToolCallsSynthesizeSafeRequiredDefaultsForStrictHarnessSchemas() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"system","content":"Working directory: /tmp/strict-project"},
            {"role":"user","content":"write app files and inspect source"}
          ],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"workspace_writer",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "mode":{"type":"string","enum":["create","overwrite"]},
                    "absolutePath":{"type":"string","description":"Absolute path to the file"},
                    "content":{"type":"string"},
                    "description":{"type":"string"},
                    "overwrite":{"type":"boolean"}
                  },
                  "required":["mode","absolutePath","content","description","overwrite"]
                }
              }
            },
            {
              "type":"function",
              "function":{
                "name":"find_files",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "pattern":{"type":"string"},
                    "root":{"type":"string"},
                    "limit":{"type":"integer"},
                    "recursive":{"type":"boolean"},
                    "description":{"type":"string"}
                  },
                  "required":["pattern","root","limit","recursive","description"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_strict_defaults",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "write", arguments: [
                    "path": .string("src/App.jsx"),
                    "fileText": .string("export default function App() { return <main /> }")
                ]),
                CursorToolCall(name: "glob", arguments: [
                    "targetDirectory": .string("src/**/*.jsx")
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }, ["workspace_writer", "find_files"])

        let arguments = try toolCalls.map { try decodedArguments(try XCTUnwrap($0["function"] as? [String: Any])) }
        XCTAssertEqual(arguments[0]["mode"] as? String, "create")
        XCTAssertEqual(arguments[0]["absolutePath"] as? String, "/tmp/strict-project/src/App.jsx")
        XCTAssertEqual(arguments[0]["content"] as? String, "export default function App() { return <main /> }")
        XCTAssertEqual(arguments[0]["description"] as? String, "Write /tmp/strict-project/src/App.jsx")
        XCTAssertEqual(arguments[0]["overwrite"] as? Bool, false)
        XCTAssertEqual(arguments[1]["pattern"] as? String, "**/*.jsx")
        XCTAssertEqual(arguments[1]["root"] as? String, "/tmp/strict-project/src")
        XCTAssertEqual((arguments[1]["limit"] as? NSNumber)?.doubleValue, 200)
        XCTAssertEqual(arguments[1]["recursive"] as? Bool, false)
        XCTAssertEqual(arguments[1]["description"] as? String, "Find matching files")
    }

    func testChatToolCallsMapSDKAliasNamesToClientSchemas() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"run and edit files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"bash",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "command":{"type":"string"},
                    "description":{"type":"string"}
                  },
                  "required":["command","description"]
                }
              }
            },
            {
              "type":"function",
              "function":{
                "name":"edit",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "filePath":{"type":"string"},
                    "oldString":{"type":"string"},
                    "newString":{"type":"string"}
                  },
                  "required":["filePath","oldString","newString"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "run_terminal_cmd", arguments: [
                "cmd": .string("npm test")
            ]),
            CursorToolCall(name: "edit_file", arguments: [
                "target_file": .string("src/App.tsx"),
                "old_string": .string("Hello"),
                "new_contents": .string("Hi")
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: output
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 2)

        let bashFunction = try XCTUnwrap(toolCalls[0]["function"] as? [String: Any])
        let bashArguments = try decodedArguments(bashFunction)
        XCTAssertEqual(bashFunction["name"] as? String, "bash")
        XCTAssertEqual(bashArguments["command"] as? String, "npm test")
        XCTAssertEqual(bashArguments["description"] as? String, "Run npm test")

        let editFunction = try XCTUnwrap(toolCalls[1]["function"] as? [String: Any])
        let editArguments = try decodedArguments(editFunction)
        XCTAssertEqual(editFunction["name"] as? String, "edit")
        XCTAssertEqual(editArguments["filePath"] as? String, "src/App.tsx")
        XCTAssertEqual(editArguments["oldString"] as? String, "Hello")
        XCTAssertEqual(editArguments["newString"] as? String, "Hi")
        XCTAssertNil(editArguments["target_file"])
        XCTAssertNil(editArguments["new_contents"])
    }

    func testChatToolCallsMapSDKCallsToGenericHarnessSchemasByToolShape() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"build and inspect files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"workspace_file",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "action":{"type":"string","enum":["read","write","replace","remove"]},
                    "target":{"type":"string"},
                    "body":{"type":"string"},
                    "find":{"type":"string"},
                    "replaceWith":{"type":"string"}
                  },
                  "required":["action","target"]
                }
              }
            },
            {
              "type":"function",
              "function":{
                "name":"run_command",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "shellCommand":{"type":"string"},
                    "dir":{"type":"string"}
                  },
                  "required":["shellCommand"]
                }
              }
            },
            {
              "type":"function",
              "function":{
                "name":"discover_files",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "includePattern":{"type":"string"},
                    "dir":{"type":"string"}
                  },
                  "required":["includePattern"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "write", arguments: [
                "path": .string("src/App.tsx"),
                "fileText": .string("export default function App() { return null }")
            ]),
            CursorToolCall(name: "edit", arguments: [
                "path": .string("src/App.tsx"),
                "oldString": .string("return null"),
                "newString": .string("return <main />")
            ]),
            CursorToolCall(name: "shell", arguments: [
                "command": .string("npm test"),
                "workingDirectory": .string("src")
            ]),
            CursorToolCall(name: "glob", arguments: [
                "globPattern": .string("**/*.tsx"),
                "targetDirectory": .string("src")
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: output
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }, [
            "workspace_file",
            "workspace_file",
            "run_command",
            "discover_files"
        ])

        let arguments = try toolCalls.map { try decodedArguments(try XCTUnwrap($0["function"] as? [String: Any])) }
        XCTAssertEqual(arguments[0]["action"] as? String, "write")
        XCTAssertEqual(arguments[0]["target"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments[0]["body"] as? String, "export default function App() { return null }")
        XCTAssertEqual(arguments[1]["action"] as? String, "replace")
        XCTAssertEqual(arguments[1]["target"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments[1]["find"] as? String, "return null")
        XCTAssertEqual(arguments[1]["replaceWith"] as? String, "return <main />")
        XCTAssertEqual(arguments[2]["shellCommand"] as? String, "npm test")
        XCTAssertEqual(arguments[2]["dir"] as? String, "src")
        XCTAssertEqual(arguments[3]["includePattern"] as? String, "**/*.tsx")
        XCTAssertEqual(arguments[3]["dir"] as? String, "src")
    }

    func testChatToolResultsFeedGenericHarnessToolsBackWithSDKBuiltinNames() throws {
        let tools: [[String: Any]] = [
            [
                "type": "function",
                "function": [
                    "name": "workspace_file",
                    "parameters": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "action": ["type": "string", "enum": ["read", "write", "replace", "remove"]],
                            "target": ["type": "string"],
                            "body": ["type": "string"],
                            "find": ["type": "string"],
                            "replaceWith": ["type": "string"]
                        ],
                        "required": ["action", "target"]
                    ]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "run_command",
                    "parameters": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "shellCommand": ["type": "string"],
                            "dir": ["type": "string"]
                        ],
                        "required": ["shellCommand"]
                    ]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "discover_files",
                    "parameters": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "includePattern": ["type": "string"],
                            "dir": ["type": "string"]
                        ],
                        "required": ["includePattern"]
                    ]
                ]
            ]
        ]
        let requestData = try JSONSerialization.data(withJSONObject: [
            "model": "composer-2.5",
            "messages": [["role": "user", "content": "build and inspect files"]],
            "tools": tools
        ])
        let prepared = try OpenAICompatibility.prepareChatRequest(requestData)
        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "write", arguments: [
                "path": .string("src/App.tsx"),
                "fileText": .string("export default function App() { return null }")
            ]),
            CursorToolCall(name: "edit", arguments: [
                "path": .string("src/App.tsx"),
                "oldString": .string("return null"),
                "newString": .string("return <main />")
            ]),
            CursorToolCall(name: "shell", arguments: [
                "command": .string("npm test"),
                "workingDirectory": .string("src")
            ]),
            CursorToolCall(name: "glob", arguments: [
                "globPattern": .string("**/*.tsx"),
                "targetDirectory": .string("src")
            ])
        ], agentID: "agent-test", runID: "run-test")

        let response = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: output
        )
        let choices = try XCTUnwrap(response["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])

        XCTAssertTrue((toolCalls[0]["id"] as? String)?.contains("_write_") == true)
        XCTAssertTrue((toolCalls[1]["id"] as? String)?.contains("_edit_") == true)
        XCTAssertTrue((toolCalls[2]["id"] as? String)?.contains("_shell_") == true)
        XCTAssertTrue((toolCalls[3]["id"] as? String)?.contains("_glob_") == true)

        let toolResults: [[String: Any]] = toolCalls.enumerated().map { index, toolCall in
            [
                "role": "tool",
                "tool_call_id": toolCall["id"] as? String ?? "",
                "content": ["ok-write", "ok-edit", "ok-shell", "ok-glob"][index]
            ]
        }
        let continueData = try JSONSerialization.data(withJSONObject: [
            "model": "composer-2.5",
            "messages": [
                ["role": "user", "content": "build and inspect files"],
                ["role": "assistant", "content": NSNull(), "tool_calls": toolCalls]
            ] + toolResults,
            "tools": tools
        ])
        let continued = try OpenAICompatibility.prepareChatRequest(continueData)
        let prefix = "LOCAL TOOL RESULT: "
        let feedback = try continued.prompt
            .split(separator: "\n")
            .filter { $0.hasPrefix(prefix) }
            .map { line -> [String: Any] in
                let data = Data(String(line.dropFirst(prefix.count)).utf8)
                return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }

        XCTAssertEqual(feedback.compactMap { $0["toolName"] as? String }, ["write", "edit", "shell", "glob"])
        let arguments = try feedback.map { try XCTUnwrap($0["arguments"] as? [String: Any]) }
        XCTAssertEqual(arguments[0]["path"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments[0]["fileText"] as? String, "export default function App() { return null }")
        XCTAssertEqual(arguments[1]["path"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments[1]["oldString"] as? String, "return null")
        XCTAssertEqual(arguments[1]["newString"] as? String, "return <main />")
        XCTAssertEqual(arguments[2]["command"] as? String, "npm test")
        XCTAssertEqual(arguments[2]["workingDirectory"] as? String, "src")
        XCTAssertEqual(arguments[3]["targetDirectory"] as? String, "src")
        XCTAssertEqual(arguments[3]["globPattern"] as? String, "**/*.tsx")
    }

    func testChatToolCallsMapSDKWriteThroughGenericWrapperWithOperationDiscriminator() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"write wrapped"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"workspace_action",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "operation":{"type":"string","enum":["read","write","replace","delete"]},
                    "input":{
                      "type":"object",
                      "additionalProperties":false,
                      "properties":{
                        "filePath":{"type":"string"},
                        "content":{"type":"string"}
                      },
                      "required":["filePath","content"]
                    }
                  },
                  "required":["operation","input"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "write", arguments: [
            "path": .string("src/App.tsx"),
            "fileText": .string("export default function App() { return null }")
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
        let input = try XCTUnwrap(arguments["input"] as? [String: Any])

        XCTAssertEqual(function["name"] as? String, "workspace_action")
        XCTAssertEqual(arguments["operation"] as? String, "write")
        XCTAssertEqual(input["filePath"] as? String, "src/App.tsx")
        XCTAssertEqual(input["content"] as? String, "export default function App() { return null }")
        XCTAssertNil(arguments["path"])
        XCTAssertNil(arguments["fileText"])
    }

    func testChatToolCallsMapSDKFileOperationsThroughBatchArraySchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"update files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"workspace_batch",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "operations":{
                      "type":"array",
                      "items":{
                        "type":"object",
                        "additionalProperties":false,
                        "properties":{
                          "action":{"type":"string","enum":["read","create","replace","delete"]},
                          "filePath":{"type":"string"},
                          "content":{"type":"string"},
                          "oldText":{"type":"string"},
                          "newText":{"type":"string"}
                        },
                        "required":["action","filePath"]
                      },
                      "minItems":1
                    }
                  },
                  "required":["operations"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_batch_files",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "write", arguments: [
                    "path": .string("src/App.tsx"),
                    "fileText": .string("export default function App() { return null }")
                ]),
                CursorToolCall(name: "edit", arguments: [
                    "path": .string("src/App.tsx"),
                    "oldString": .string("return null"),
                    "newString": .string("return <main />")
                ]),
                CursorToolCall(name: "delete", arguments: [
                    "path": .string("src/old.tsx")
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }, [
            "workspace_batch",
            "workspace_batch",
            "workspace_batch"
        ])

        let arguments = try toolCalls.map { try decodedArguments(try XCTUnwrap($0["function"] as? [String: Any])) }
        let writeOperations = try XCTUnwrap(arguments[0]["operations"] as? [[String: Any]])
        XCTAssertEqual(writeOperations.first?["action"] as? String, "create")
        XCTAssertEqual(writeOperations.first?["filePath"] as? String, "src/App.tsx")
        XCTAssertEqual(writeOperations.first?["content"] as? String, "export default function App() { return null }")

        let editOperations = try XCTUnwrap(arguments[1]["operations"] as? [[String: Any]])
        XCTAssertEqual(editOperations.first?["action"] as? String, "replace")
        XCTAssertEqual(editOperations.first?["filePath"] as? String, "src/App.tsx")
        XCTAssertEqual(editOperations.first?["oldText"] as? String, "return null")
        XCTAssertEqual(editOperations.first?["newText"] as? String, "return <main />")

        let deleteOperations = try XCTUnwrap(arguments[2]["operations"] as? [[String: Any]])
        XCTAssertEqual(deleteOperations.first?["action"] as? String, "delete")
        XCTAssertEqual(deleteOperations.first?["filePath"] as? String, "src/old.tsx")
    }

    func testChatToolCallsCoerceScalarSDKArgumentsToClientArraySchemas() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"inspect arrays"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"diagnostics",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "files":{"type":"array","items":{"type":"string"}}
                  },
                  "required":["files"]
                }
              }
            },
            {
              "type":"function",
              "function":{
                "name":"semantic_search",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "query":{"type":"string"},
                    "targetDirectories":{"type":"array","items":{"type":"string"}}
                  },
                  "required":["query","targetDirectories"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "readLints", arguments: [
                "paths": .string("src/App.tsx")
            ]),
            CursorToolCall(name: "semSearch", arguments: [
                "query": .string("submit button"),
                "targetDirectories": .string(#"["src","app"]"#)
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: output
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }, ["diagnostics", "semantic_search"])

        let arguments = try toolCalls.map { try decodedArguments(try XCTUnwrap($0["function"] as? [String: Any])) }
        XCTAssertEqual(arguments[0]["files"] as? [String], ["src/App.tsx"])
        XCTAssertEqual(arguments[1]["query"] as? String, "submit button")
        XCTAssertEqual(arguments[1]["targetDirectories"] as? [String], ["src", "app"])
    }

    func testChatToolCallsMapSDKSemanticSearchToCodeSearchDirectoryAliases() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"search the code"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"code_search",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "query":{"type":"string"},
                    "directories":{"type":"array","items":{"type":"string"},"minItems":1},
                    "reason":{"type":"string"}
                  },
                  "required":["query","directories"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "semSearch", arguments: [
                "query": .string("submit button"),
                "targetDirectory": .string("src"),
                "explanation": .string("inspect UI wiring")
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_semsearch",
            created: 1,
            prepared: prepared,
            output: output
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)

        XCTAssertEqual(function["name"] as? String, "code_search")
        XCTAssertEqual(arguments["query"] as? String, "submit button")
        XCTAssertEqual(arguments["directories"] as? [String], ["src"])
        XCTAssertEqual(arguments["reason"] as? String, "inspect UI wiring")
        XCTAssertNil(arguments["targetDirectory"])
    }

    func testChatToolCallsMapSDKReadLintsToFilePathArraySchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"check diagnostics"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"get_diagnostics",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "filePaths":{"type":"array","items":{"type":"string"},"minItems":1}
                  },
                  "required":["filePaths"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_readlints",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "readLints", arguments: [
                    "path": .string("src/App.tsx")
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)

        XCTAssertEqual(function["name"] as? String, "get_diagnostics")
        XCTAssertEqual(arguments["filePaths"] as? [String], ["src/App.tsx"])
        XCTAssertNil(arguments["paths"])
    }

    func testChatToolResultsFeedDiagnosticsBackWithSDKReadLintsArguments() throws {
        let requestData = Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"check diagnostics"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"get_diagnostics",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "filePaths":{"type":"array","items":{"type":"string"},"minItems":1}
                  },
                  "required":["filePaths"]
                }
              }
            }
          ]
        }
        """#.utf8)
        let prepared = try OpenAICompatibility.prepareChatRequest(requestData)
        let response = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_readlints_feedback",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "readLints", arguments: [
                    "paths": .array([.string("src/App.tsx")])
                ])
            ], agentID: "agent-test", runID: "run-test")
        )
        let choices = try XCTUnwrap(response["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let requestObject = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let tools = try XCTUnwrap(requestObject["tools"] as? [[String: Any]])

        let continueData = try JSONSerialization.data(withJSONObject: [
            "model": "composer-2.5",
            "messages": [
                ["role": "user", "content": "check diagnostics"],
                ["role": "assistant", "content": NSNull(), "tool_calls": toolCalls],
                ["role": "tool", "tool_call_id": toolCalls.first?["id"] as? String ?? "", "content": "No diagnostics"]
            ],
            "tools": tools
        ])
        let continued = try OpenAICompatibility.prepareChatRequest(continueData)
        let prefix = "LOCAL TOOL RESULT: "
        let feedbackLine = try XCTUnwrap(continued.prompt.split(separator: "\n").first { $0.hasPrefix(prefix) })
        let feedback = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(feedbackLine.dropFirst(prefix.count)).utf8)) as? [String: Any])
        let arguments = try XCTUnwrap(feedback["arguments"] as? [String: Any])

        XCTAssertEqual(feedback["toolName"] as? String, "readlints")
        XCTAssertEqual(arguments["paths"] as? [String], ["src/App.tsx"])
        XCTAssertNil(arguments["filePaths"])
    }

    func testChatToolCallsMapSDKGlobToPluralArrayClientSchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"system","content":"Working directory: /tmp/array-glob"},
            {"role":"user","content":"find source files"}
          ],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"discover_files",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "patterns":{"type":"array","items":{"type":"string"},"minItems":1},
                    "roots":{"type":"array","items":{"type":"string"},"minItems":1},
                    "description":{"type":"string"}
                  },
                  "required":["patterns","roots","description"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "glob", arguments: [
                "targetDirectory": .string("src/**/*.tsx")
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_arrayglob",
            created: 1,
            prepared: prepared,
            output: output
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)

        XCTAssertEqual(function["name"] as? String, "discover_files")
        XCTAssertEqual(arguments["patterns"] as? [String], ["**/*.tsx"])
        XCTAssertEqual(arguments["roots"] as? [String], ["/tmp/array-glob/src"])
        XCTAssertEqual(arguments["description"] as? String, "Find matching files")
    }

    func testResponsesFunctionCallsPadScalarGlobArgumentsToArrayMinimums() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"find files",
          "tools":[
            {
              "type":"function",
              "name":"find_files",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "patterns":{"type":"array","items":{"type":"string"},"minItems":2},
                  "directories":{"type":"array","items":{"type":"string"},"minItems":1}
                },
                "required":["patterns","directories"]
              }
            }
          ]
        }
        """#.utf8))
        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "glob", arguments: [
                "globPattern": .string("**/*.jsx"),
                "targetDirectory": .string("src")
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.responseObject(
            id: "resp_arrayglob",
            created: 1,
            prepared: prepared,
            output: output
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(outputItems.first { ($0["type"] as? String) == "function_call" })
        let arguments = try decodedArguments(functionCall)

        XCTAssertEqual(functionCall["name"] as? String, "find_files")
        XCTAssertEqual(arguments["patterns"] as? [String], ["**/*.jsx", "**/*.jsx"])
        XCTAssertEqual(arguments["directories"] as? [String], ["src"])
    }

    func testChatToolCallsCoerceScalarGlobArgumentsThroughNullableArraySchemas() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"system","content":"Working directory: /tmp/composed-array-glob"},
            {"role":"user","content":"find source files"}
          ],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"discover_files",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "patterns":{
                      "anyOf":[
                        {"type":"array","items":{"type":"string"},"minItems":1},
                        {"type":"null"}
                      ]
                    },
                    "roots":{
                      "oneOf":[
                        {"type":"array","items":{"type":"string"},"minItems":1},
                        {"type":"null"}
                      ]
                    }
                  },
                  "required":["patterns","roots"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "glob", arguments: [
                "targetDirectory": .string("src/**/*.tsx")
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_composed_arrayglob",
            created: 1,
            prepared: prepared,
            output: output
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)

        XCTAssertEqual(function["name"] as? String, "discover_files")
        XCTAssertEqual(arguments["patterns"] as? [String], ["**/*.tsx"])
        XCTAssertEqual(arguments["roots"] as? [String], ["/tmp/composed-array-glob/src"])
    }

    func testResponsesFunctionCallsCoerceScalarGlobArgumentsThroughNullableArraySchemas() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"find source files",
          "tools":[
            {
              "type":"function",
              "name":"discover_files",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "patterns":{
                    "anyOf":[
                      {"type":"array","items":{"type":"string"},"minItems":1},
                      {"type":"null"}
                    ]
                  },
                  "roots":{
                    "oneOf":[
                      {"type":"array","items":{"type":"string"},"minItems":1},
                      {"type":"null"}
                    ]
                  }
                },
                "required":["patterns","roots"]
              }
            }
          ]
        }
        """#.utf8))
        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "glob", arguments: [
                "globPattern": .string("**/*.jsx"),
                "targetDirectory": .string("src")
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.responseObject(
            id: "resp_composed_arrayglob",
            created: 1,
            prepared: prepared,
            output: output
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(outputItems.first { ($0["type"] as? String) == "function_call" })
        let arguments = try decodedArguments(functionCall)

        XCTAssertEqual(functionCall["name"] as? String, "discover_files")
        XCTAssertEqual(arguments["patterns"] as? [String], ["**/*.jsx"])
        XCTAssertEqual(arguments["roots"] as? [String], ["src"])
    }

    func testChatToolCallsFallbackToSchemaEnumWhenRequiredModeIsNotOperation() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"run tests"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"run_shell",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "command":{"type":"string"},
                    "mode":{"type":"string","enum":["sync","async"]}
                  },
                  "required":["command","mode"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "shell", arguments: [
            "command": .string("npm test")
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

        XCTAssertEqual(function["name"] as? String, "run_shell")
        XCTAssertEqual(arguments["command"] as? String, "npm test")
        XCTAssertEqual(arguments["mode"] as? String, "sync")
    }

    func testChatToolCallsDoNotMapSDKEditToSchemaMissingReplacementArguments() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"edit files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"replace_file",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "path":{"type":"string"},
                    "search":{"type":"string"}
                  },
                  "required":["path","search"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "edit", arguments: [
                "path": .string("src/App.tsx"),
                "oldString": .string("Hello"),
                "newString": .string("Hi")
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: output
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = message["tool_calls"] as? [[String: Any]]
        XCTAssertTrue((toolCalls ?? []).isEmpty)
    }

    func testChatToolCallsDoNotMapExactSDKEditNameToIncompatibleSchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"edit files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"edit",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "path":{"type":"string"},
                    "search":{"type":"string"}
                  },
                  "required":["path","search"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let output = CursorSDKOutput(text: "", toolCalls: [
            CursorToolCall(name: "edit", arguments: [
                "path": .string("src/App.tsx"),
                "oldString": .string("Hello"),
                "newString": .string("Hi")
            ])
        ], agentID: "agent-test", runID: "run-test")

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: output
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = message["tool_calls"] as? [[String: Any]]
        XCTAssertTrue((toolCalls ?? []).isEmpty)
    }

    func testChatToolCallsExpandNestedSDKArgumentsBeforeSchemaMapping() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"write a file"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"write_file",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "filePath":{"type":"string"},
                    "content":{"type":"string"}
                  },
                  "required":["filePath","content"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "write", arguments: [
            "arguments": .object([
                "file_path": .string("src/App.tsx"),
                "contents": .string("export default function App() { return null }")
            ])
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

        XCTAssertEqual(function["name"] as? String, "write_file")
        XCTAssertEqual(arguments["filePath"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments["content"] as? String, "export default function App() { return null }")
        XCTAssertNil(arguments["arguments"])
        XCTAssertNil(arguments["file_path"])
        XCTAssertNil(arguments["contents"])
    }

    func testChatToolCallsPreserveAdditionalPropertiesWhenClientSchemaAllowsThem() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"call custom tool"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"custom_tool",
                "parameters":{
                  "type":"object",
                  "properties":{"input":{"type":"string"}},
                  "required":["input"],
                  "additionalProperties":true
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "custom_tool", arguments: [
            "input": .string("hello"),
            "customFlag": .bool(true)
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

        XCTAssertEqual(function["name"] as? String, "custom_tool")
        XCTAssertEqual(arguments["input"] as? String, "hello")
        XCTAssertEqual(arguments["customFlag"] as? Bool, true)
    }

    func testChatToolCallsMapSDKMCPArgsToSpecificClientTool() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"use mcp"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"mcp__filesystem__write_file",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "filePath":{"type":"string"},
                    "content":{"type":"string"}
                  },
                  "required":["filePath","content"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("filesystem"),
            "toolName": .string("write_file"),
            "args": .object([
                "file_path": .string("src/App.tsx"),
                "contents": .string("export default function App() { return null }")
            ])
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

        XCTAssertEqual(function["name"] as? String, "mcp__filesystem__write_file")
        XCTAssertEqual(arguments["filePath"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments["content"] as? String, "export default function App() { return null }")
        XCTAssertNil(arguments["providerIdentifier"])
        XCTAssertNil(arguments["toolName"])
        XCTAssertNil(arguments["args"])
    }

    func testChatToolCallsPreferSchemaValidProviderSpecificMCPTool() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"use filesystem writer"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"write_file",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "url":{"type":"string"}
                  },
                  "required":["url"]
                }
              }
            },
            {
              "type":"function",
              "function":{
                "name":"mcp__filesystem__write_file",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "mode":{"type":"string","enum":["write","append"]},
                    "filePath":{"type":"string"},
                    "content":{"type":"string"},
                    "overwrite":{"type":"boolean"}
                  },
                  "required":["mode","filePath","content","overwrite"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("filesystem"),
            "toolName": .string("write_file"),
            "args": .object([
                "file_path": .string("src/App.tsx"),
                "contents": .string("export default function App() { return null }"),
                "overwrite": .bool(true)
            ])
        ])

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_mcp_collision",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)

        XCTAssertEqual(function["name"] as? String, "mcp__filesystem__write_file")
        XCTAssertEqual(arguments["mode"] as? String, "write")
        XCTAssertEqual(arguments["filePath"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments["content"] as? String, "export default function App() { return null }")
        XCTAssertEqual(arguments["overwrite"] as? Bool, true)
        XCTAssertNil(arguments["url"])
    }

    func testChatToolCallsMapSDKMCPArgsToSingleWordClientTool() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"use webfetch"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"webfetch",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "url":{"type":"string"},
                    "format":{"type":"string"}
                  },
                  "required":["url"],
                  "additionalProperties":false
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("client"),
            "toolName": .string("webfetch"),
            "args": .object([
                "url": .string("https://example.com"),
                "format": .string("markdown")
            ])
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

        XCTAssertEqual(function["name"] as? String, "webfetch")
        XCTAssertEqual(arguments["url"] as? String, "https://example.com")
        XCTAssertEqual(arguments["format"] as? String, "markdown")
        XCTAssertNil(arguments["providerIdentifier"])
        XCTAssertNil(arguments["toolName"])
        XCTAssertNil(arguments["args"])
    }

    func testChatToolCallsMapSDKMCPDirectPayloadFieldsToSingleWordClientTool() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"use webfetch"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"webfetch",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "url":{"type":"string"},
                    "format":{"type":"string"}
                  },
                  "required":["url"],
                  "additionalProperties":false
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("client"),
            "toolName": .string("webfetch"),
            "url": .string("https://example.com"),
            "format": .string("markdown")
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

        XCTAssertEqual(function["name"] as? String, "webfetch")
        XCTAssertEqual(arguments["url"] as? String, "https://example.com")
        XCTAssertEqual(arguments["format"] as? String, "markdown")
        XCTAssertNil(arguments["providerIdentifier"])
        XCTAssertNil(arguments["toolName"])
        XCTAssertNil(arguments["args"])
    }

    func testChatToolCallsMapSDKMCPArgsToWrappedSingleWordClientTool() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"use task"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"task",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "input":{
                      "type":"object",
                      "properties":{
                        "description":{"type":"string"},
                        "prompt":{"type":"string"},
                        "subagent_type":{"type":"string"}
                      },
                      "required":["description","prompt","subagent_type"]
                    }
                  },
                  "required":["input"],
                  "additionalProperties":false
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("client"),
            "toolName": .string("task"),
            "args": .object([
                "description": .string("Explore files"),
                "prompt": .string("Find the app entrypoint"),
                "subagent_type": .string("explore")
            ])
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
        let input = try XCTUnwrap(arguments["input"] as? [String: Any])

        XCTAssertEqual(function["name"] as? String, "task")
        XCTAssertEqual(input["description"] as? String, "Explore files")
        XCTAssertEqual(input["prompt"] as? String, "Find the app entrypoint")
        XCTAssertEqual(input["subagent_type"] as? String, "explore")
        XCTAssertNil(arguments["providerIdentifier"])
        XCTAssertNil(arguments["toolName"])
        XCTAssertNil(arguments["args"])
    }

    func testChatToolCallsMapSDKMCPArgsToOpenCodeServerToolName() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"use mcp"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"probe_write_file",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "file_path":{"type":"string"},
                    "contents":{"type":"string"},
                    "overwrite":{"type":"boolean"}
                  },
                  "required":["file_path","contents"],
                  "additionalProperties":false
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("probe"),
            "toolName": .string("write_file"),
            "args": .object([
                "file_path": .string("src/App.tsx"),
                "contents": .string("export default function App() { return null }"),
                "overwrite": .bool(true)
            ])
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

        XCTAssertEqual(function["name"] as? String, "probe_write_file")
        XCTAssertEqual(arguments["file_path"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments["contents"] as? String, "export default function App() { return null }")
        XCTAssertEqual(arguments["overwrite"] as? Bool, true)
        XCTAssertNil(arguments["providerIdentifier"])
        XCTAssertNil(arguments["toolName"])
        XCTAssertNil(arguments["args"])
    }

    func testChatToolCallsMapSDKMCPAlternatePayloadEnvelopes() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"use mcp"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"probe_write_file",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "file_path":{"type":"string"},
                    "contents":{"type":"string"},
                    "overwrite":{"type":"boolean"}
                  },
                  "required":["file_path","contents"],
                  "additionalProperties":false
                }
              }
            },
            {
              "type":"function",
              "function":{
                "name":"call_mcp_tool",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "serverName":{"type":"string"},
                    "toolName":{"type":"string"},
                    "input":{"type":"object"}
                  },
                  "required":["serverName","toolName","input"],
                  "additionalProperties":false
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCalls = [
            CursorToolCall(name: "mcp", arguments: [
                "serverName": .string("probe"),
                "name": .string("write_file"),
                "arguments": .string(#"{"file_path":"src/App.tsx","contents":"export default function App() { return null }","overwrite":true}"#)
            ]),
            CursorToolCall(name: "mcp", arguments: [
                "provider": .string("filesystem"),
                "tool": .string("read_file"),
                "parameters": .string(#"{"path":"README.md"}"#)
            ])
        ]

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: toolCalls, agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let generated = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(generated.count, 2)

        let specificFunction = try XCTUnwrap(generated[0]["function"] as? [String: Any])
        let specificArguments = try decodedArguments(specificFunction)
        XCTAssertEqual(specificFunction["name"] as? String, "probe_write_file")
        XCTAssertEqual(specificArguments["file_path"] as? String, "src/App.tsx")
        XCTAssertEqual(specificArguments["contents"] as? String, "export default function App() { return null }")
        XCTAssertEqual(specificArguments["overwrite"] as? Bool, true)

        let wrapperFunction = try XCTUnwrap(generated[1]["function"] as? [String: Any])
        let wrapperArguments = try decodedArguments(wrapperFunction)
        let input = try XCTUnwrap(wrapperArguments["input"] as? [String: Any])
        XCTAssertEqual(wrapperFunction["name"] as? String, "call_mcp_tool")
        XCTAssertEqual(wrapperArguments["serverName"] as? String, "filesystem")
        XCTAssertEqual(wrapperArguments["toolName"] as? String, "read_file")
        XCTAssertEqual(input["path"] as? String, "README.md")
    }

    func testChatToolCallsDoNotEmitSchemaInvalidSpecificMCPToolCalls() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"use mcp"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"mcp__github__create_issue",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "title":{"type":"string"},
                    "body":{"type":"string"}
                  },
                  "required":["title"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("github"),
            "toolName": .string("create_issue"),
            "args": .object([
                "body": .string("Missing required title")
            ])
        ])

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        XCTAssertEqual((message["tool_calls"] as? [[String: Any]])?.count, 0)
    }

    func testChatToolCallsDoNotEmitSpecificMCPToolCallsViolatingScalarConstraints() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"use mcp"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"mcp__github__create_issue",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "title":{"type":"string","minLength":1,"pattern":"^[A-Z]"},
                    "priority":{"type":"integer","minimum":1,"maximum":5,"multipleOf":1}
                  },
                  "required":["title","priority"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("github"),
            "toolName": .string("create_issue"),
            "args": .object([
                "title": .string(""),
                "priority": .number(3)
            ])
        ])

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        XCTAssertEqual((message["tool_calls"] as? [[String: Any]])?.count, 0)
    }

    func testChatToolCallsAllowSpecificMCPArrayMembershipConstraints() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"use mcp"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"mcp__runner__run_steps",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "steps":{
                      "type":"array",
                      "items":{"type":"string"},
                      "uniqueItems":true,
                      "contains":{"const":"build"},
                      "minContains":1,
                      "maxContains":1
                    },
                    "labels":{
                      "type":"array",
                      "items":{"type":"string"},
                      "contains":{"type":"string","pattern":"^release:"},
                      "minContains":0,
                      "maxContains":1
                    }
                  },
                  "required":["steps"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("runner"),
            "toolName": .string("run_steps"),
            "args": .object([
                "steps": .array([.string("install"), .string("build"), .string("test")]),
                "labels": .array([.string("release:stable"), .string("ui")])
            ])
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

        XCTAssertEqual(function["name"] as? String, "mcp__runner__run_steps")
        XCTAssertEqual(arguments["steps"] as? [String], ["install", "build", "test"])
        XCTAssertEqual(arguments["labels"] as? [String], ["release:stable", "ui"])
    }

    func testChatToolCallsAllowSpecificMCPOneOfSchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"use mcp"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"mcp__deploy__deploy_target",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "target":{
                      "oneOf":[
                        {
                          "type":"object",
                          "properties":{"path":{"type":"string"}},
                          "required":["path"]
                        },
                        {
                          "type":"object",
                          "properties":{"path":{"type":"string"},"mode":{"const":"preview"}},
                          "required":["path","mode"]
                        }
                      ]
                    }
                  },
                  "required":["target"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("deploy"),
            "toolName": .string("deploy_target"),
            "args": .object([
                "target": .object([
                    "path": .string("dist")
                ])
            ])
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
        let target = try XCTUnwrap(arguments["target"] as? [String: Any])

        XCTAssertEqual(function["name"] as? String, "mcp__deploy__deploy_target")
        XCTAssertEqual(target["path"] as? String, "dist")
        XCTAssertNil(target["mode"])
    }

    func testChatToolCallsAllowSpecificMCPConditionalSchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"use mcp"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"mcp__notify__send_notice",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "channel":{"type":"string","enum":["email","slack"]},
                    "message":{"type":"string"},
                    "email":{"type":"string","minLength":3},
                    "channelId":{"type":"string","pattern":"^C[A-Z0-9]+$"}
                  },
                  "required":["channel","message"],
                  "if":{
                    "properties":{"channel":{"const":"email"}},
                    "required":["channel"]
                  },
                  "then":{
                    "required":["email"]
                  },
                  "else":{
                    "required":["channelId"]
                  }
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("notify"),
            "toolName": .string("send_notice"),
            "args": .object([
                "channel": .string("email"),
                "message": .string("Build passed"),
                "email": .string("dev@example.com")
            ])
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

        XCTAssertEqual(function["name"] as? String, "mcp__notify__send_notice")
        XCTAssertEqual(arguments["channel"] as? String, "email")
        XCTAssertEqual(arguments["message"] as? String, "Build passed")
        XCTAssertEqual(arguments["email"] as? String, "dev@example.com")
        XCTAssertNil(arguments["channelId"])
    }

    func testChatToolCallsAllowSpecificMCPPatternProperties() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"use mcp"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"mcp__runner__run_with_env",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "command":{"type":"string"},
                    "env":{
                      "type":"object",
                      "additionalProperties":false,
                      "patternProperties":{
                        "^VITE_[A-Z0-9_]+$":{"type":"string","minLength":1}
                      }
                    }
                  },
                  "required":["command","env"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("runner"),
            "toolName": .string("run_with_env"),
            "args": .object([
                "command": .string("npm run build"),
                "env": .object([
                    "VITE_API_URL": .string("https://example.com")
                ])
            ])
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
        let env = try XCTUnwrap(arguments["env"] as? [String: Any])

        XCTAssertEqual(function["name"] as? String, "mcp__runner__run_with_env")
        XCTAssertEqual(arguments["command"] as? String, "npm run build")
        XCTAssertEqual(env["VITE_API_URL"] as? String, "https://example.com")
    }

    func testChatToolCallsAllowSpecificMCPObjectKeyConstraints() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"use mcp"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"mcp__runner__configure_env",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "settings":{
                      "type":"object",
                      "minProperties":1,
                      "maxProperties":2,
                      "propertyNames":{"type":"string","pattern":"^APP_[A-Z0-9_]+$"},
                      "patternProperties":{
                        "^APP_SECRET$":false
                      },
                      "additionalProperties":{"type":"string","minLength":1},
                      "dependentRequired":{
                        "APP_TOKEN":["APP_URL"]
                      }
                    }
                  },
                  "required":["settings"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("runner"),
            "toolName": .string("configure_env"),
            "args": .object([
                "settings": .object([
                    "APP_URL": .string("https://example.com"),
                    "APP_TOKEN": .string("secret")
                ])
            ])
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
        let settings = try XCTUnwrap(arguments["settings"] as? [String: Any])

        XCTAssertEqual(function["name"] as? String, "mcp__runner__configure_env")
        XCTAssertEqual(settings["APP_URL"] as? String, "https://example.com")
        XCTAssertEqual(settings["APP_TOKEN"] as? String, "secret")
    }

    func testChatToolCallsDoNotEmitWrapperMCPCallsWithSchemaInvalidNestedInput() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"use mcp"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"call_mcp_tool",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "serverName":{"type":"string"},
                    "toolName":{"type":"string"},
                    "input":{
                      "type":"object",
                      "additionalProperties":false,
                      "properties":{
                        "file_path":{"type":"string"},
                        "contents":{"type":"string"}
                      },
                      "required":["file_path","contents"]
                    }
                  },
                  "required":["serverName","toolName","input"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("filesystem"),
            "toolName": .string("write_file"),
            "args": .object([
                "file_path": .string("src/App.tsx")
            ])
        ])

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_test",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        XCTAssertEqual((message["tool_calls"] as? [[String: Any]])?.count, 0)
    }

    func testChatToolCallsMapSDKMCPArgsToWrapperTool() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"use mcp"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"call_mcp_tool",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "serverName":{"type":"string"},
                    "toolName":{"type":"string"},
                    "arguments":{"type":"object"}
                  },
                  "required":["serverName","toolName","arguments"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("filesystem"),
            "toolName": .string("write_file"),
            "args": .object([
                "file_path": .string("src/App.tsx")
            ])
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
        let nested = try XCTUnwrap(arguments["arguments"] as? [String: Any])

        XCTAssertEqual(function["name"] as? String, "call_mcp_tool")
        XCTAssertEqual(arguments["serverName"] as? String, "filesystem")
        XCTAssertEqual(arguments["toolName"] as? String, "write_file")
        XCTAssertEqual(nested["file_path"] as? String, "src/App.tsx")
        XCTAssertNil(arguments["providerIdentifier"])
        XCTAssertNil(arguments["args"])
    }

    func testChatToolCallsMapSDKMCPDirectPayloadFieldsToWrapperTool() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"use mcp"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"call_mcp_tool",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "serverName":{"type":"string"},
                    "toolName":{"type":"string"},
                    "input":{"type":"object"}
                  },
                  "required":["serverName","toolName","input"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("filesystem"),
            "toolName": .string("write_file"),
            "file_path": .string("src/App.tsx"),
            "contents": .string("export default function App() { return null }")
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
        let nested = try XCTUnwrap(arguments["input"] as? [String: Any])

        XCTAssertEqual(function["name"] as? String, "call_mcp_tool")
        XCTAssertEqual(arguments["serverName"] as? String, "filesystem")
        XCTAssertEqual(arguments["toolName"] as? String, "write_file")
        XCTAssertEqual(nested["file_path"] as? String, "src/App.tsx")
        XCTAssertEqual(nested["contents"] as? String, "export default function App() { return null }")
        XCTAssertNil(arguments["providerIdentifier"])
        XCTAssertNil(arguments["file_path"])
    }

    func testChatToolCallsMapSDKMCPArgsToStrictWrapperToolWithNestedSchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[
            {"role":"system","content":"Working directory: /tmp/mcp-wrapper"},
            {"role":"user","content":"use mcp"}
          ],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"call_mcp_tool",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "serverName":{"type":"string"},
                    "toolName":{"type":"string"},
                    "input":{
                      "type":"object",
                      "additionalProperties":false,
                      "properties":{
                        "mode":{"type":"string","enum":["create","overwrite"]},
                        "filePath":{"type":"string","description":"Absolute path to the file"},
                        "content":{"type":"string"},
                        "description":{"type":"string"}
                      },
                      "required":["mode","filePath","content","description"]
                    }
                  },
                  "required":["serverName","toolName","input"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("filesystem"),
            "toolName": .string("write_file"),
            "args": .object([
                "file_path": .string("src/App.tsx"),
                "contents": .string("export default function App() { return null }")
            ])
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
        let input = try XCTUnwrap(arguments["input"] as? [String: Any])

        XCTAssertEqual(function["name"] as? String, "call_mcp_tool")
        XCTAssertEqual(arguments["serverName"] as? String, "filesystem")
        XCTAssertEqual(arguments["toolName"] as? String, "write_file")
        XCTAssertEqual(input["mode"] as? String, "create")
        XCTAssertEqual(input["filePath"] as? String, "/tmp/mcp-wrapper/src/App.tsx")
        XCTAssertEqual(input["content"] as? String, "export default function App() { return null }")
        XCTAssertEqual(input["description"] as? String, "Write /tmp/mcp-wrapper/src/App.tsx")
        XCTAssertNil(arguments["providerIdentifier"])
        XCTAssertNil(arguments["args"])
    }

    func testChatToolCallsDefaultEmptySDKListToReadableDirectorySchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"list files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"read",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "filePath":{"type":"string"},
                    "offset":{"type":"integer"},
                    "limit":{"type":"integer"}
                  },
                  "required":["filePath"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "ls", arguments: [:])

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

        XCTAssertEqual(function["name"] as? String, "read")
        XCTAssertEqual(arguments["filePath"] as? String, ".")
        XCTAssertNil(arguments["path"])
    }

    func testChatToolCallsPreferGlobForSDKListWhenClientHasGlobTool() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"list source files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"read",
                "parameters":{
                  "type":"object",
                  "properties":{"filePath":{"type":"string"}},
                  "required":["filePath"]
                }
              }
            },
            {
              "type":"function",
              "function":{
                "name":"glob",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "pattern":{"type":"string"},
                    "path":{"type":"string"}
                  },
                  "required":["pattern"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "ls", arguments: [
            "path": .string("src")
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

        XCTAssertEqual(function["name"] as? String, "glob")
        XCTAssertEqual(arguments["pattern"] as? String, "*")
        XCTAssertEqual(arguments["path"] as? String, "src")
        XCTAssertNil(arguments["filePath"])
    }

    func testChatToolCallsEmulateSDKWriteThroughShellWhenNoWriteToolExists() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"create a file"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"bash",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "command":{"type":"string"},
                    "description":{"type":"string"},
                    "cwd":{"type":"string"},
                    "timeout_ms":{"type":"number"}
                  },
                  "required":["command","description","cwd","timeout_ms"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "write", arguments: [
            "path": .string("src/App.tsx"),
            "fileText": .string("export default function App() { return null }")
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
        let command = try XCTUnwrap(arguments["command"] as? String)

        XCTAssertEqual(function["name"] as? String, "bash")
        XCTAssertTrue(command.contains("mkdir -p \"$(dirname 'src/App.tsx')\""))
        XCTAssertTrue(command.contains("cat > 'src/App.tsx' <<'API_FOR_CURSOR_EOF'"))
        XCTAssertTrue(command.contains("export default function App() { return null }"))
        XCTAssertEqual(arguments["description"] as? String, "Create requested file")
        XCTAssertEqual(arguments["cwd"] as? String, ".")
        XCTAssertEqual((arguments["timeout_ms"] as? NSNumber)?.doubleValue, 120_000)
    }

    func testChatToolCallsEmulateSDKPartialReadThroughShellWhenNoReadToolExists() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"read part of a file"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"bash",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "command":{"type":"string"},
                    "description":{"type":"string"}
                  },
                  "required":["command","description"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "read", arguments: [
            "path": .string("src/App.tsx"),
            "offset": .number(5),
            "limit": .number(10)
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
        XCTAssertEqual(arguments["command"] as? String, "sed -n '5,14p' 'src/App.tsx'")
        XCTAssertEqual(arguments["description"] as? String, "Run sed -n '5,14p' 'src/App.tsx'")
    }

    func testChatToolCallsEmulateSDKEditThroughShellWhenNoEditToolExists() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"edit a file"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"run_command",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "command":{"type":"string"},
                    "description":{"type":"string"}
                  },
                  "required":["command","description"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "edit", arguments: [
            "path": .string("src/App.tsx"),
            "oldString": .string("return null"),
            "newString": .string("return <main />")
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
        let command = try XCTUnwrap(arguments["command"] as? String)

        XCTAssertEqual(function["name"] as? String, "run_command")
        XCTAssertTrue(command.contains("from pathlib import Path"))
        XCTAssertTrue(command.contains(#"path = Path("src/App.tsx")"#))
        XCTAssertTrue(command.contains(#"old = "return null""#))
        XCTAssertTrue(command.contains(#"new = "return <main />""#))
        XCTAssertTrue(command.contains("text.replace(old, new, 1)"))
        XCTAssertEqual(arguments["description"] as? String, "Run local shell command")
    }

    func testChatToolResultsFeedEmulatedShellCallsBackWithOriginalSDKArguments() throws {
        let tools: [[String: Any]] = [
            [
                "type": "function",
                "function": [
                    "name": "bash",
                    "parameters": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "command": ["type": "string"],
                            "description": ["type": "string"]
                        ],
                        "required": ["command", "description"]
                    ]
                ]
            ]
        ]
        let initialData = try JSONSerialization.data(withJSONObject: [
            "model": "composer-2.5",
            "messages": [["role": "user", "content": "build a todo app"]],
            "tools": tools
        ])
        let initial = try OpenAICompatibility.prepareChatRequest(initialData)
        let response = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_shellmemory",
            created: 1,
            prepared: initial,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "write", arguments: [
                    "path": .string("src/App.tsx"),
                    "fileText": .string("export default function App() { return null }")
                ]),
                CursorToolCall(name: "edit", arguments: [
                    "path": .string("src/App.tsx"),
                    "oldString": .string("return null"),
                    "newString": .string("return <main />")
                ])
            ], agentID: "agent-test", runID: "run-test")
        )
        let choices = try XCTUnwrap(response["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let generated = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(generated.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }, ["bash", "bash"])

        let toolResults: [[String: Any]] = generated.map {
            [
                "role": "tool",
                "tool_call_id": $0["id"] as? String ?? "",
                "content": #"{"exitCode":0,"stdout":"","stderr":""}"#
            ]
        }
        let continueData = try JSONSerialization.data(withJSONObject: [
            "model": "composer-2.5",
            "messages": [
                ["role": "user", "content": "build a todo app"],
                ["role": "assistant", "content": NSNull(), "tool_calls": generated]
            ] + toolResults,
            "tools": tools
        ])
        let continued = try OpenAICompatibility.prepareChatRequest(continueData)
        let prefix = "LOCAL TOOL RESULT: "
        let feedback = try continued.prompt
            .split(separator: "\n")
            .filter { $0.hasPrefix(prefix) }
            .map { line -> [String: Any] in
                let data = Data(String(line.dropFirst(prefix.count)).utf8)
                return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }

        XCTAssertEqual(feedback.compactMap { $0["toolName"] as? String }, ["write", "edit"])
        let arguments = try feedback.map { try XCTUnwrap($0["arguments"] as? [String: Any]) }
        XCTAssertEqual(arguments[0]["path"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments[0]["fileText"] as? String, "export default function App() { return null }")
        XCTAssertEqual(arguments[1]["path"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments[1]["oldString"] as? String, "return null")
        XCTAssertEqual(arguments[1]["newString"] as? String, "return <main />")
    }

    func testChatToolCallsEmulateSDKGrepThroughShellWhenNoSearchToolExists() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"search files"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"run_command",
                "parameters":{
                  "type":"object",
                  "properties":{
                    "command":{"type":"string"},
                    "description":{"type":"string"}
                  },
                  "required":["command"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "grep", arguments: [
            "pattern": .string("TODO"),
            "path": .string("src"),
            "glob": .string("*.swift")
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

        XCTAssertEqual(function["name"] as? String, "run_command")
        XCTAssertEqual(arguments["command"] as? String, "rg --line-number --color never --hidden --glob '*.swift' 'TODO' 'src'")
        XCTAssertEqual(arguments["description"] as? String, "Run rg --line-number --color never --hidden --glob '*.swift' 'TODO' 'src'")
        XCTAssertNil(arguments["pattern"])
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

    func testResponsesFunctionCallsMapSDKWriteThroughInputSchemaWrapper() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"create a file through a wrapped schema",
          "tools":[
            {
              "type":"function",
              "name":"write_file",
              "parameters":{
                "input_schema":{
                  "$ref":"#/$defs/WriteInput",
                  "$defs":{
                    "WriteInput":{
                      "type":"object",
                      "properties":{
                        "file_path":{"type":"string"},
                        "content":{"type":"string"}
                      },
                      "required":["file_path","content"],
                      "additionalProperties":false
                    }
                  }
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
            id: "resp_input_schema",
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

    func testResponsesFunctionCallsMapSDKReadToArrayRangeSchemas() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"read part of a file",
          "tools":[
            {
              "type":"function",
              "name":"read_file",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "file_path":{"type":"string"},
                  "view_range":{"type":"array","items":{"type":"integer"},"minItems":2,"maxItems":2}
                },
                "required":["file_path","view_range"]
              }
            }
          ]
        }
        """#.utf8))

        let object = OpenAICompatibility.responseObject(
            id: "resp_read_range",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "read", arguments: [
                    "path": .string("src/App.tsx"),
                    "offset": .number(5),
                    "limit": .number(10)
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let output = try XCTUnwrap(object["output"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(output.first { ($0["type"] as? String) == "function_call" })
        let arguments = try decodedArguments(functionCall)
        let viewRange = try XCTUnwrap(arguments["view_range"] as? [Any])

        XCTAssertEqual(functionCall["name"] as? String, "read_file")
        XCTAssertEqual(arguments["file_path"] as? String, "src/App.tsx")
        XCTAssertEqual((viewRange[0] as? NSNumber)?.intValue, 5)
        XCTAssertEqual((viewRange[1] as? NSNumber)?.intValue, 14)
        XCTAssertNil(arguments["offset"])
        XCTAssertNil(arguments["limit"])
    }

    func testResponsesFunctionCallsMapSDKReadLintsToFilesArraySchema() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"check diagnostics",
          "tools":[
            {
              "type":"function",
              "name":"diagnostics",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "files":{"type":"array","items":{"type":"string"},"minItems":1}
                },
                "required":["files"]
              }
            }
          ]
        }
        """#.utf8))

        let object = OpenAICompatibility.responseObject(
            id: "resp_readlints",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "readLints", arguments: [
                    "paths": .string("src/App.tsx")
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(outputItems.first { ($0["type"] as? String) == "function_call" })
        let arguments = try decodedArguments(functionCall)

        XCTAssertEqual(functionCall["name"] as? String, "diagnostics")
        XCTAssertEqual(arguments["files"] as? [String], ["src/App.tsx"])
        XCTAssertNil(arguments["paths"])
    }

    func testChatToolCallsMapSDKTodosToTaskCollectionSchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"update the plan"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"set_plan",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "tasks":{
                      "type":"array",
                      "items":{
                        "type":"object",
                        "additionalProperties":false,
                        "properties":{
                          "content":{"type":"string"},
                          "status":{"type":"string"},
                          "priority":{"type":"string"}
                        },
                        "required":["content","status","priority"]
                      }
                    }
                  },
                  "required":["tasks"]
                }
              }
            }
          ]
        }
        """#.utf8))

        let object = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_todo_tasks",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "updateTodos", arguments: [
                    "todos": .array([
                        .object([
                            "content": .string("Ship local API"),
                            "status": .string("todo_status_in_progress")
                        ])
                    ])
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        let arguments = try decodedArguments(function)
        let tasks = try XCTUnwrap(arguments["tasks"] as? [[String: Any]])

        XCTAssertEqual(function["name"] as? String, "set_plan")
        XCTAssertEqual(tasks.first?["content"] as? String, "Ship local API")
        XCTAssertEqual(tasks.first?["status"] as? String, "in_progress")
        XCTAssertEqual(tasks.first?["priority"] as? String, "medium")
        XCTAssertNil(arguments["todos"])
    }

    func testChatToolResultsFeedTaskCollectionBackAsSDKTodos() throws {
        let requestData = Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"update the plan"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"set_plan",
                "parameters":{
                  "type":"object",
                  "additionalProperties":false,
                  "properties":{
                    "tasks":{"type":"array","items":{"type":"object"}}
                  },
                  "required":["tasks"]
                }
              }
            }
          ]
        }
        """#.utf8)
        let prepared = try OpenAICompatibility.prepareChatRequest(requestData)
        let response = OpenAICompatibility.chatCompletionResponse(
            id: "chatcmpl_todo_feedback",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "updateTodos", arguments: [
                    "todos": .array([.object(["content": .string("Ship"), "status": .string("pending")])])
                ])
            ], agentID: "agent-test", runID: "run-test")
        )
        let choices = try XCTUnwrap(response["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let requestObject = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let tools = try XCTUnwrap(requestObject["tools"] as? [[String: Any]])

        let continueData = try JSONSerialization.data(withJSONObject: [
            "model": "composer-2.5",
            "messages": [
                ["role": "user", "content": "update the plan"],
                ["role": "assistant", "content": NSNull(), "tool_calls": toolCalls],
                ["role": "tool", "tool_call_id": toolCalls.first?["id"] as? String ?? "", "content": "Plan saved"]
            ],
            "tools": tools
        ])
        let continued = try OpenAICompatibility.prepareChatRequest(continueData)
        let prefix = "LOCAL TOOL RESULT: "
        let feedbackLine = try XCTUnwrap(continued.prompt.split(separator: "\n").first { $0.hasPrefix(prefix) })
        let feedback = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(feedbackLine.dropFirst(prefix.count)).utf8)) as? [String: Any])
        let arguments = try XCTUnwrap(feedback["arguments"] as? [String: Any])
        let todos = try XCTUnwrap(arguments["todos"] as? [[String: Any]])

        XCTAssertEqual(feedback["toolName"] as? String, "todowrite")
        XCTAssertEqual(todos.first?["content"] as? String, "Ship")
        XCTAssertEqual(todos.first?["status"] as? String, "pending")
        XCTAssertNil(arguments["tasks"])
    }

    func testResponsesFunctionCallsMapSDKTodosToItemsCollectionSchema() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"update the plan",
          "tools":[
            {
              "type":"function",
              "name":"plan_update",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "items":{"type":"array","items":{"type":"object"}}
                },
                "required":["items"]
              }
            }
          ]
        }
        """#.utf8))

        let object = OpenAICompatibility.responseObject(
            id: "resp_todo_items",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "updateTodos", arguments: [
                    "todoList": .array([
                        .object([
                            "content": .string("Wire Responses"),
                            "status": .string("todo_status_done"),
                            "priority": .string("")
                        ])
                    ])
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(outputItems.first { ($0["type"] as? String) == "function_call" })
        let arguments = try decodedArguments(functionCall)
        let items = try XCTUnwrap(arguments["items"] as? [[String: Any]])

        XCTAssertEqual(functionCall["name"] as? String, "plan_update")
        XCTAssertEqual(items.first?["content"] as? String, "Wire Responses")
        XCTAssertEqual(items.first?["status"] as? String, "completed")
        XCTAssertEqual(items.first?["priority"] as? String, "medium")
        XCTAssertNil(arguments["todos"])
        XCTAssertNil(arguments["todoList"])
    }

    func testResponsesFunctionCallsPreferSchemaValidProviderSpecificMCPTool() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"use filesystem writer",
          "tools":[
            {
              "type":"function",
              "name":"write_file",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "url":{"type":"string"}
                },
                "required":["url"]
              }
            },
            {
              "type":"function",
              "name":"mcp__filesystem__write_file",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "mode":{"type":"string","enum":["write","append"]},
                  "filePath":{"type":"string"},
                  "content":{"type":"string"},
                  "overwrite":{"type":"boolean"}
                },
                "required":["mode","filePath","content","overwrite"]
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("filesystem"),
            "toolName": .string("write_file"),
            "args": .object([
                "file_path": .string("src/App.tsx"),
                "contents": .string("export default function App() { return null }"),
                "overwrite": .bool(true)
            ])
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_mcp_collision",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(outputItems.first { ($0["type"] as? String) == "function_call" })
        let arguments = try decodedArguments(functionCall)

        XCTAssertEqual(functionCall["name"] as? String, "mcp__filesystem__write_file")
        XCTAssertEqual(arguments["mode"] as? String, "write")
        XCTAssertEqual(arguments["filePath"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments["content"] as? String, "export default function App() { return null }")
        XCTAssertEqual(arguments["overwrite"] as? Bool, true)
        XCTAssertNil(arguments["url"])
    }

    func testResponsesFunctionCallsMapSDKMCPDirectPayloadFieldsToProviderSpecificTool() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"use filesystem writer",
          "tools":[
            {
              "type":"function",
              "name":"mcp__filesystem__write_file",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "mode":{"type":"string","enum":["write","append"]},
                  "filePath":{"type":"string"},
                  "content":{"type":"string"},
                  "overwrite":{"type":"boolean"}
                },
                "required":["mode","filePath","content","overwrite"]
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("filesystem"),
            "toolName": .string("write_file"),
            "file_path": .string("src/App.tsx"),
            "contents": .string("export default function App() { return null }"),
            "overwrite": .bool(true)
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_mcp_direct_payload",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(outputItems.first { ($0["type"] as? String) == "function_call" })
        let arguments = try decodedArguments(functionCall)

        XCTAssertEqual(functionCall["name"] as? String, "mcp__filesystem__write_file")
        XCTAssertEqual(arguments["mode"] as? String, "write")
        XCTAssertEqual(arguments["filePath"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments["content"] as? String, "export default function App() { return null }")
        XCTAssertEqual(arguments["overwrite"] as? Bool, true)
        XCTAssertNil(arguments["providerIdentifier"])
        XCTAssertNil(arguments["toolName"])
        XCTAssertNil(arguments["args"])
    }

    func testResponsesFunctionCallsDoNotEmitProviderSpecificMCPToolViolatingScalarConstraints() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"use constrained search",
          "tools":[
            {
              "type":"function",
              "name":"mcp__search__query",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "query":{"type":"string","minLength":2,"maxLength":12,"pattern":"^[A-Za-z0-9_]+$"},
                  "limit":{"type":"integer","minimum":1,"maximum":50,"multipleOf":5}
                },
                "required":["query","limit"]
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("search"),
            "toolName": .string("query"),
            "args": .object([
                "query": .string("todo app"),
                "limit": .number(7)
            ])
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_mcp_scalar_invalid",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        XCTAssertNil(outputItems.first { ($0["type"] as? String) == "function_call" })
    }

    func testResponsesFunctionCallsDoNotEmitProviderSpecificMCPToolViolatingArrayMembershipConstraints() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"run steps",
          "tools":[
            {
              "type":"function",
              "name":"mcp__runner__run_steps",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "steps":{
                    "type":"array",
                    "items":{"type":"string"},
                    "uniqueItems":true,
                    "contains":{"const":"build"},
                    "minContains":1,
                    "maxContains":1
                  },
                  "labels":{
                    "type":"array",
                    "items":{"type":"string"},
                    "contains":{"type":"string","pattern":"^release:"},
                    "minContains":0,
                    "maxContains":1
                  }
                },
                "required":["steps"]
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("runner"),
            "toolName": .string("run_steps"),
            "args": .object([
                "steps": .array([.string("install"), .string("test")]),
                "labels": .array([.string("release:stable"), .string("release:beta")])
            ])
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_mcp_array_membership_invalid",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        XCTAssertNil(outputItems.first { ($0["type"] as? String) == "function_call" })
    }

    func testResponsesFunctionCallsDoNotEmitProviderSpecificMCPToolViolatingOneOfSchema() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"deploy target",
          "tools":[
            {
              "type":"function",
              "name":"mcp__deploy__deploy_target",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "target":{
                    "oneOf":[
                      {
                        "type":"object",
                        "properties":{"path":{"type":"string"}},
                        "required":["path"]
                      },
                      {
                        "type":"object",
                        "properties":{"path":{"type":"string"},"mode":{"const":"preview"}},
                        "required":["path","mode"]
                      }
                    ]
                  }
                },
                "required":["target"]
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("deploy"),
            "toolName": .string("deploy_target"),
            "args": .object([
                "target": .object([
                    "path": .string("dist"),
                    "mode": .string("preview")
                ])
            ])
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_mcp_oneof_invalid",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        XCTAssertNil(outputItems.first { ($0["type"] as? String) == "function_call" })
    }

    func testResponsesFunctionCallsDoNotEmitProviderSpecificMCPToolViolatingConditionalSchema() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"send notice",
          "tools":[
            {
              "type":"function",
              "name":"mcp__notify__send_notice",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "channel":{"type":"string","enum":["email","slack"]},
                  "message":{"type":"string"},
                  "email":{"type":"string","minLength":3},
                  "channelId":{"type":"string","pattern":"^C[A-Z0-9]+$"}
                },
                "required":["channel","message"],
                "if":{
                  "properties":{"channel":{"const":"email"}},
                  "required":["channel"]
                },
                "then":{
                  "required":["email"]
                },
                "else":{
                  "required":["channelId"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("notify"),
            "toolName": .string("send_notice"),
            "args": .object([
                "channel": .string("email"),
                "message": .string("Build passed")
            ])
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_mcp_conditional_invalid",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        XCTAssertNil(outputItems.first { ($0["type"] as? String) == "function_call" })
    }

    func testResponsesFunctionCallsPreserveProviderSpecificMCPBranchConditionalArguments() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"send notice",
          "tools":[
            {
              "type":"function",
              "name":"mcp__notify__send_notice",
              "parameters":{
                "type":"object",
                "unevaluatedProperties":false,
                "properties":{
                  "channel":{"type":"string","enum":["email","slack"]},
                  "message":{"type":"string"}
                },
                "required":["channel","message"],
                "if":{
                  "properties":{"channel":{"const":"email"}},
                  "required":["channel"]
                },
                "then":{
                  "properties":{"email":{"type":"string","minLength":3}},
                  "required":["email"]
                },
                "else":{
                  "properties":{"channelId":{"type":"string","pattern":"^C[A-Z0-9]+$"}},
                  "required":["channelId"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("notify"),
            "toolName": .string("send_notice"),
            "args": .object([
                "channel": .string("slack"),
                "message": .string("Build passed"),
                "channelId": .string("C123")
            ])
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_mcp_conditional_branch",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(outputItems.first { ($0["type"] as? String) == "function_call" })
        let arguments = try decodedArguments(functionCall)

        XCTAssertEqual(functionCall["name"] as? String, "mcp__notify__send_notice")
        XCTAssertEqual(arguments["channel"] as? String, "slack")
        XCTAssertEqual(arguments["message"] as? String, "Build passed")
        XCTAssertEqual(arguments["channelId"] as? String, "C123")
        XCTAssertNil(arguments["email"])
    }

    func testResponsesFunctionCallsDoNotEmitProviderSpecificMCPToolWithUnselectedConditionalBranchArgument() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"send notice",
          "tools":[
            {
              "type":"function",
              "name":"mcp__notify__send_notice",
              "parameters":{
                "type":"object",
                "unevaluatedProperties":false,
                "properties":{
                  "channel":{"type":"string","enum":["email","slack"]},
                  "message":{"type":"string"}
                },
                "required":["channel","message"],
                "if":{
                  "properties":{"channel":{"const":"email"}},
                  "required":["channel"]
                },
                "then":{
                  "properties":{"email":{"type":"string","minLength":3}},
                  "required":["email"]
                },
                "else":{
                  "properties":{"channelId":{"type":"string","pattern":"^C[A-Z0-9]+$"}},
                  "required":["channelId"]
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("notify"),
            "toolName": .string("send_notice"),
            "args": .object([
                "channel": .string("slack"),
                "message": .string("Build passed"),
                "channelId": .string("C123"),
                "email": .string("dev@example.com")
            ])
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_mcp_conditional_branch_extra",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        XCTAssertNil(outputItems.first { ($0["type"] as? String) == "function_call" })
    }

    func testResponsesFunctionCallsDoNotEmitProviderSpecificMCPToolViolatingTupleArraySchema() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"run pipeline",
          "tools":[
            {
              "type":"function",
              "name":"mcp__runner__run_pipeline",
              "parameters":{
                "type":"object",
                "properties":{
                  "steps":{
                    "type":"array",
                    "items":[
                      {"const":"install"},
                      {"const":"build"}
                    ],
                    "additionalItems":false
                  }
                },
                "required":["steps"]
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("runner"),
            "toolName": .string("run_pipeline"),
            "args": .object([
                "steps": .array([.string("install"), .string("build"), .string("test")])
            ])
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_mcp_tuple_invalid",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        XCTAssertNil(outputItems.first { ($0["type"] as? String) == "function_call" })
    }

    func testResponsesFunctionCallsDoNotEmitProviderSpecificMCPToolViolatingUnevaluatedObjectSchema() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"configure deploy",
          "tools":[
            {
              "type":"function",
              "name":"mcp__deploy__configure_deploy",
              "parameters":{
                "type":"object",
                "allOf":[
                  {
                    "properties":{
                      "command":{"type":"string"}
                    },
                    "required":["command"]
                  },
                  {
                    "properties":{
                      "metadata":{
                        "type":"object",
                        "properties":{
                          "owner":{"type":"string"}
                        },
                        "required":["owner"],
                        "unevaluatedProperties":false
                      }
                    },
                    "required":["metadata"]
                  }
                ],
                "unevaluatedProperties":false
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("deploy"),
            "toolName": .string("configure_deploy"),
            "args": .object([
                "command": .string("npm run build"),
                "metadata": .object([
                    "owner": .string("web"),
                    "extra": .bool(true)
                ])
            ])
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_mcp_unevaluated_invalid",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        XCTAssertNil(outputItems.first { ($0["type"] as? String) == "function_call" })
    }

    func testResponsesFunctionCallsEmitProviderSpecificMCPToolWhenAdditionalPropertiesEvaluateUnevaluatedSchema() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"configure env",
          "tools":[
            {
              "type":"function",
              "name":"mcp__runner__configure_env",
              "parameters":{
                "type":"object",
                "properties":{
                  "command":{"type":"string"}
                },
                "required":["command"],
                "additionalProperties":{"type":"string","minLength":1},
                "unevaluatedProperties":false
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("runner"),
            "toolName": .string("configure_env"),
            "args": .object([
                "command": .string("npm run build"),
                "NODE_ENV": .string("production")
            ])
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_mcp_additional_evaluated",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(outputItems.first { ($0["type"] as? String) == "function_call" })
        XCTAssertEqual(functionCall["name"] as? String, "mcp__runner__configure_env")
        let arguments = try decodedArguments(functionCall)
        XCTAssertEqual(arguments["command"] as? String, "npm run build")
        XCTAssertEqual(arguments["NODE_ENV"] as? String, "production")
    }

    func testResponsesFunctionCallsEmitProviderSpecificMCPToolWhenDependentSchemasEvaluateUnevaluatedProperties() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"run command",
          "tools":[
            {
              "type":"function",
              "name":"mcp__runner__run_command",
              "parameters":{
                "type":"object",
                "properties":{
                  "command":{"type":"string"}
                },
                "required":["command"],
                "dependentSchemas":{
                  "command":{
                    "properties":{
                      "cwd":{"type":"string"}
                    },
                    "required":["cwd"]
                  }
                },
                "unevaluatedProperties":false
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("runner"),
            "toolName": .string("run_command"),
            "args": .object([
                "command": .string("npm run build"),
                "cwd": .string(".")
            ])
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_mcp_dependent_evaluated",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(outputItems.first { ($0["type"] as? String) == "function_call" })
        XCTAssertEqual(functionCall["name"] as? String, "mcp__runner__run_command")
        let arguments = try decodedArguments(functionCall)
        XCTAssertEqual(arguments["command"] as? String, "npm run build")
        XCTAssertEqual(arguments["cwd"] as? String, ".")
    }

    func testResponsesFunctionCallsEmitProviderSpecificMCPToolWhenContainsEvaluatesUnevaluatedItems() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"run pipeline",
          "tools":[
            {
              "type":"function",
              "name":"mcp__runner__run_pipeline",
              "parameters":{
                "type":"object",
                "properties":{
                  "steps":{
                    "type":"array",
                    "prefixItems":[{"const":"install"}],
                    "contains":{"const":"build"},
                    "minContains":1,
                    "unevaluatedItems":false
                  }
                },
                "required":["steps"]
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("runner"),
            "toolName": .string("run_pipeline"),
            "args": .object([
                "steps": .array([.string("install"), .string("build")])
            ])
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_mcp_contains_evaluated",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(outputItems.first { ($0["type"] as? String) == "function_call" })
        XCTAssertEqual(functionCall["name"] as? String, "mcp__runner__run_pipeline")
        let arguments = try decodedArguments(functionCall)
        XCTAssertEqual(arguments["steps"] as? [String], ["install", "build"])
    }

    func testResponsesFunctionCallsDoNotEmitProviderSpecificMCPToolViolatingPatternProperties() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"use env runner",
          "tools":[
            {
              "type":"function",
              "name":"mcp__runner__run_with_env",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "command":{"type":"string"},
                  "env":{
                    "type":"object",
                    "additionalProperties":false,
                    "patternProperties":{
                      "^VITE_[A-Z0-9_]+$":{"type":"string","minLength":1}
                    }
                  }
                },
                "required":["command","env"]
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("runner"),
            "toolName": .string("run_with_env"),
            "args": .object([
                "command": .string("npm run build"),
                "env": .object([
                    "API_URL": .string("https://example.com")
                ])
            ])
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_mcp_pattern_invalid",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        XCTAssertNil(outputItems.first { ($0["type"] as? String) == "function_call" })
    }

    func testResponsesFunctionCallsDoNotEmitProviderSpecificMCPToolViolatingObjectKeyConstraints() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"configure env",
          "tools":[
            {
              "type":"function",
              "name":"mcp__runner__configure_env",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "settings":{
                    "type":"object",
                    "minProperties":1,
                    "maxProperties":2,
                    "propertyNames":{"type":"string","pattern":"^APP_[A-Z0-9_]+$"},
                    "patternProperties":{
                      "^APP_SECRET$":false
                    },
                    "additionalProperties":{"type":"string","minLength":1},
                    "dependentRequired":{
                      "APP_TOKEN":["APP_URL"]
                    }
                  }
                },
                "required":["settings"]
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("runner"),
            "toolName": .string("configure_env"),
            "args": .object([
                "settings": .object([
                    "APP_TOKEN": .string("secret")
                ])
            ])
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_mcp_object_constraints_invalid",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        XCTAssertNil(outputItems.first { ($0["type"] as? String) == "function_call" })
    }

    func testResponsesFunctionCallsDoNotEmitProviderSpecificMCPToolWithForbiddenPatternProperty() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"configure env",
          "tools":[
            {
              "type":"function",
              "name":"mcp__runner__configure_env",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "settings":{
                    "type":"object",
                    "propertyNames":{"type":"string","pattern":"^APP_[A-Z0-9_]+$"},
                    "patternProperties":{
                      "^APP_SECRET$":false
                    },
                    "additionalProperties":{"type":"string","minLength":1}
                  }
                },
                "required":["settings"]
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "mcp", arguments: [
            "providerIdentifier": .string("runner"),
            "toolName": .string("configure_env"),
            "args": .object([
                "settings": .object([
                    "APP_SECRET": .string("secret")
                ])
            ])
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_mcp_forbidden_pattern_invalid",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let outputItems = try XCTUnwrap(object["output"] as? [[String: Any]])
        XCTAssertNil(outputItems.first { ($0["type"] as? String) == "function_call" })
    }

    func testResponsesFunctionCallsMapSDKPatchContentWithoutSeparatePathToPatchOnlyTool() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"patch a file",
          "tools":[
            {
              "type":"function",
              "name":"apply_patch",
              "parameters":{
                "type":"object",
                "properties":{
                  "patch":{"type":"string"}
                },
                "required":["patch"]
              }
            }
          ]
        }
        """#.utf8))
        let patch = [
            "*** Begin Patch",
            "*** Update File: src/App.tsx",
            "@@",
            "-return null",
            "+return <main />",
            "*** End Patch"
        ].joined(separator: "\n")
        let toolCall = CursorToolCall(name: "edit", arguments: [
            "patchContent": .string(patch)
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

        XCTAssertEqual(functionCall["name"] as? String, "apply_patch")
        XCTAssertNil(arguments["path"])
        XCTAssertEqual(arguments["patch"] as? String, patch)
    }

    func testResponsesFunctionCallsMapSDKEditToArrayReplacementSchemas() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"edit app",
          "tools":[
            {
              "type":"function",
              "name":"apply_edits",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "changes":{
                    "type":"array",
                    "items":{
                      "type":"object",
                      "additionalProperties":false,
                      "properties":{
                        "filePath":{"type":"string"},
                        "oldString":{"type":"string"},
                        "newString":{"type":"string"}
                      },
                      "required":["filePath","oldString","newString"]
                    },
                    "minItems":1
                  }
                },
                "required":["changes"]
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "edit", arguments: [
            "path": .string("src/App.tsx"),
            "oldString": .string("return null"),
            "newString": .string("return <main />")
        ])

        let object = OpenAICompatibility.responseObject(
            id: "resp_edit_array",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test")
        )

        let output = try XCTUnwrap(object["output"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(output.first { ($0["type"] as? String) == "function_call" })
        let arguments = try decodedArguments(functionCall)
        let changes = try XCTUnwrap(arguments["changes"] as? [[String: Any]])

        XCTAssertEqual(functionCall["name"] as? String, "apply_edits")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?["filePath"] as? String, "src/App.tsx")
        XCTAssertEqual(changes.first?["oldString"] as? String, "return null")
        XCTAssertEqual(changes.first?["newString"] as? String, "return <main />")
        XCTAssertNil(arguments["path"])
        XCTAssertNil(arguments["oldText"])
        XCTAssertNil(arguments["newText"])
    }

    func testResponsesFunctionCallsMapSDKFileOperationsThroughBatchArraySchema() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"update files",
          "tools":[
            {
              "type":"function",
              "name":"workspace_batch",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "actions":{
                    "type":"array",
                    "items":{
                      "type":"object",
                      "additionalProperties":false,
                      "properties":{
                        "op":{"type":"string","enum":["view","create","replace","remove"]},
                        "path":{"type":"string"},
                        "body":{"type":"string"},
                        "find":{"type":"string"},
                        "replaceWith":{"type":"string"}
                      },
                      "required":["op","path"]
                    },
                    "minItems":1
                  }
                },
                "required":["actions"]
              }
            }
          ]
        }
        """#.utf8))

        let object = OpenAICompatibility.responseObject(
            id: "resp_batch_files",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "write", arguments: [
                    "path": .string("src/App.tsx"),
                    "fileText": .string("export default function App() { return null }")
                ]),
                CursorToolCall(name: "edit", arguments: [
                    "path": .string("src/App.tsx"),
                    "oldString": .string("return null"),
                    "newString": .string("return <main />")
                ]),
                CursorToolCall(name: "delete", arguments: [
                    "path": .string("src/old.tsx")
                ])
            ], agentID: "agent-test", runID: "run-test")
        )

        let output = try XCTUnwrap(object["output"] as? [[String: Any]])
        let functionCalls = output.filter { ($0["type"] as? String) == "function_call" }
        XCTAssertEqual(functionCalls.compactMap { $0["name"] as? String }, [
            "workspace_batch",
            "workspace_batch",
            "workspace_batch"
        ])

        let arguments = try functionCalls.map { try decodedArguments($0) }
        let writeActions = try XCTUnwrap(arguments[0]["actions"] as? [[String: Any]])
        XCTAssertEqual(writeActions.first?["op"] as? String, "create")
        XCTAssertEqual(writeActions.first?["path"] as? String, "src/App.tsx")
        XCTAssertEqual(writeActions.first?["body"] as? String, "export default function App() { return null }")

        let editActions = try XCTUnwrap(arguments[1]["actions"] as? [[String: Any]])
        XCTAssertEqual(editActions.first?["op"] as? String, "replace")
        XCTAssertEqual(editActions.first?["path"] as? String, "src/App.tsx")
        XCTAssertEqual(editActions.first?["find"] as? String, "return null")
        XCTAssertEqual(editActions.first?["replaceWith"] as? String, "return <main />")

        let deleteActions = try XCTUnwrap(arguments[2]["actions"] as? [[String: Any]])
        XCTAssertEqual(deleteActions.first?["op"] as? String, "remove")
        XCTAssertEqual(deleteActions.first?["path"] as? String, "src/old.tsx")
    }

    func testResponsesToolResultsFeedGenericHarnessToolsBackWithSDKBuiltinNames() throws {
        let tools: [[String: Any]] = [
            [
                "type": "function",
                "name": "workspace_file",
                "parameters": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "action": ["type": "string", "enum": ["read", "write", "replace", "remove"]],
                        "target": ["type": "string"],
                        "body": ["type": "string"],
                        "find": ["type": "string"],
                        "replaceWith": ["type": "string"]
                    ],
                    "required": ["action", "target"]
                ]
            ],
            [
                "type": "function",
                "name": "run_command",
                "parameters": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "shellCommand": ["type": "string"],
                        "dir": ["type": "string"]
                    ],
                    "required": ["shellCommand"]
                ]
            ],
            [
                "type": "function",
                "name": "discover_files",
                "parameters": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "includePattern": ["type": "string"],
                        "dir": ["type": "string"]
                    ],
                    "required": ["includePattern"]
                ]
            ]
        ]
        let requestData = try JSONSerialization.data(withJSONObject: [
            "model": "composer-2.5",
            "input": "build and inspect files",
            "tools": tools
        ])
        let prepared = try OpenAICompatibility.prepareResponsesRequest(requestData)
        let response = OpenAICompatibility.responseObject(
            id: "resp_generic",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "write", arguments: [
                    "path": .string("src/App.tsx"),
                    "fileText": .string("export default function App() { return null }")
                ]),
                CursorToolCall(name: "edit", arguments: [
                    "path": .string("src/App.tsx"),
                    "oldString": .string("return null"),
                    "newString": .string("return <main />")
                ]),
                CursorToolCall(name: "shell", arguments: [
                    "command": .string("npm test"),
                    "workingDirectory": .string("src")
                ]),
                CursorToolCall(name: "glob", arguments: [
                    "globPattern": .string("**/*.tsx"),
                    "targetDirectory": .string("src")
                ])
            ], agentID: "agent-test", runID: "run-test")
        )
        let output = try XCTUnwrap(response["output"] as? [[String: Any]])
        let functionCalls = output.filter { ($0["type"] as? String) == "function_call" }

        XCTAssertTrue((functionCalls[0]["call_id"] as? String)?.contains("_write_") == true)
        XCTAssertTrue((functionCalls[1]["call_id"] as? String)?.contains("_edit_") == true)
        XCTAssertTrue((functionCalls[2]["call_id"] as? String)?.contains("_shell_") == true)
        XCTAssertTrue((functionCalls[3]["call_id"] as? String)?.contains("_glob_") == true)

        let functionOutputs: [[String: Any]] = functionCalls.enumerated().flatMap { index, functionCall in
            [
                functionCall,
                [
                    "type": "function_call_output",
                    "call_id": functionCall["call_id"] as? String ?? "",
                    "output": ["{\"content\":\"ok\"}", "{\"diff\":\"updated\"}", "{\"exitCode\":0,\"stdout\":\"ok\",\"stderr\":\"\"}", "{\"files\":[\"src/App.tsx\"]}"][index]
                ]
            ]
        }
        let continueData = try JSONSerialization.data(withJSONObject: [
            "model": "composer-2.5",
            "input": [["role": "user", "content": "build and inspect files"]] + functionOutputs,
            "tools": tools
        ])
        let continued = try OpenAICompatibility.prepareResponsesRequest(continueData)
        let prefix = "LOCAL TOOL RESULT: "
        let feedback = try continued.prompt
            .split(separator: "\n")
            .filter { $0.hasPrefix(prefix) }
            .map { line -> [String: Any] in
                let data = Data(String(line.dropFirst(prefix.count)).utf8)
                return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }

        XCTAssertEqual(feedback.compactMap { $0["toolName"] as? String }, ["write", "edit", "shell", "glob"])
        let arguments = try feedback.map { try XCTUnwrap($0["arguments"] as? [String: Any]) }
        XCTAssertEqual(arguments[0]["path"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments[0]["fileText"] as? String, "export default function App() { return null }")
        XCTAssertEqual(arguments[1]["oldString"] as? String, "return null")
        XCTAssertEqual(arguments[1]["newString"] as? String, "return <main />")
        XCTAssertEqual(arguments[2]["command"] as? String, "npm test")
        XCTAssertEqual(arguments[2]["workingDirectory"] as? String, "src")
        XCTAssertEqual(arguments[3]["targetDirectory"] as? String, "src")
        XCTAssertEqual(arguments[3]["globPattern"] as? String, "**/*.tsx")
    }

    func testResponsesSemanticSearchOutputsFeedBackWithSDKArguments() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":[
            {
              "type":"function_call",
              "call_id":"call_semsearch",
              "name":"code_search",
              "arguments":"{\"search\":\"submit button\",\"directories\":[\"src\",\"app\"],\"reason\":\"inspect UI wiring\"}"
            },
            {
              "type":"function_call_output",
              "call_id":"call_semsearch",
              "output":"src/App.tsx:12: submit button"
            }
          ],
          "tools":[
            {
              "type":"function",
              "name":"code_search",
              "parameters":{
                "type":"object",
                "additionalProperties":false,
                "properties":{
                  "search":{"type":"string"},
                  "directories":{"type":"array","items":{"type":"string"}},
                  "reason":{"type":"string"}
                },
                "required":["search","directories"]
              }
            }
          ]
        }
        """#.utf8))

        let prefix = "LOCAL TOOL RESULT: "
        let feedbackLine = try XCTUnwrap(prepared.prompt.split(separator: "\n").first { $0.hasPrefix(prefix) })
        let feedback = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(feedbackLine.dropFirst(prefix.count)).utf8)) as? [String: Any])
        let arguments = try XCTUnwrap(feedback["arguments"] as? [String: Any])

        XCTAssertEqual(feedback["toolName"] as? String, "semsearch")
        XCTAssertEqual(arguments["query"] as? String, "submit button")
        XCTAssertEqual(arguments["targetDirectories"] as? [String], ["src", "app"])
        XCTAssertEqual(arguments["explanation"] as? String, "inspect UI wiring")
    }

    func testResponsesToolResultsFeedEmulatedShellCallsBackWithOriginalSDKArguments() throws {
        let tools: [[String: Any]] = [
            [
                "type": "function",
                "name": "bash",
                "parameters": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "command": ["type": "string"],
                        "description": ["type": "string"]
                    ],
                    "required": ["command", "description"]
                ]
            ]
        ]
        let requestData = try JSONSerialization.data(withJSONObject: [
            "model": "composer-2.5",
            "input": "build a todo app",
            "tools": tools
        ])
        let prepared = try OpenAICompatibility.prepareResponsesRequest(requestData)
        let response = OpenAICompatibility.responseObject(
            id: "resp_shellmemory",
            created: 1,
            prepared: prepared,
            output: CursorSDKOutput(text: "", toolCalls: [
                CursorToolCall(name: "write", arguments: [
                    "path": .string("src/App.tsx"),
                    "fileText": .string("export default function App() { return null }")
                ]),
                CursorToolCall(name: "edit", arguments: [
                    "path": .string("src/App.tsx"),
                    "oldString": .string("return null"),
                    "newString": .string("return <main />")
                ])
            ], agentID: "agent-test", runID: "run-test")
        )
        let output = try XCTUnwrap(response["output"] as? [[String: Any]])
        let functionCalls = output.filter { ($0["type"] as? String) == "function_call" }
        XCTAssertEqual(functionCalls.compactMap { $0["name"] as? String }, ["bash", "bash"])

        let functionOutputs: [[String: Any]] = functionCalls.enumerated().flatMap { _, functionCall in
            [
                functionCall,
                [
                    "type": "function_call_output",
                    "call_id": functionCall["call_id"] as? String ?? "",
                    "output": #"{"exitCode":0,"stdout":"","stderr":""}"#
                ]
            ]
        }
        let continueData = try JSONSerialization.data(withJSONObject: [
            "model": "composer-2.5",
            "input": [["role": "user", "content": "build a todo app"]] + functionOutputs,
            "tools": tools
        ])
        let continued = try OpenAICompatibility.prepareResponsesRequest(continueData)
        let prefix = "LOCAL TOOL RESULT: "
        let feedback = try continued.prompt
            .split(separator: "\n")
            .filter { $0.hasPrefix(prefix) }
            .map { line -> [String: Any] in
                let data = Data(String(line.dropFirst(prefix.count)).utf8)
                return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }

        XCTAssertEqual(feedback.compactMap { $0["toolName"] as? String }, ["write", "edit"])
        let arguments = try feedback.map { try XCTUnwrap($0["arguments"] as? [String: Any]) }
        XCTAssertEqual(arguments[0]["path"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments[0]["fileText"] as? String, "export default function App() { return null }")
        XCTAssertEqual(arguments[1]["path"] as? String, "src/App.tsx")
        XCTAssertEqual(arguments[1]["oldString"] as? String, "return null")
        XCTAssertEqual(arguments[1]["newString"] as? String, "return <main />")
    }

    func testResponsesFunctionCallsEmulateSDKGlobThroughShellWhenNoGlobToolExists() throws {
        let prepared = try OpenAICompatibility.prepareResponsesRequest(Data(#"""
        {
          "model":"composer-2.5",
          "input":"find source files",
          "tools":[
            {
              "type":"function",
              "name":"run_command",
              "parameters":{
                "type":"object",
                "properties":{
                  "command":{"type":"string"},
                  "description":{"type":"string"}
                },
                "required":["command"]
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "glob", arguments: [
            "targetDirectory": .string("src"),
            "globPattern": .string("**/*.tsx")
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
        let command = try XCTUnwrap(arguments["command"] as? String)

        XCTAssertEqual(functionCall["name"] as? String, "run_command")
        XCTAssertTrue(command.contains("python3 - <<'PY'"))
        XCTAssertTrue(command.contains(#"base = Path("src")"#))
        XCTAssertTrue(command.contains(#"pattern = "**/*.tsx""#))
        XCTAssertNil(arguments["targetDirectory"])
        XCTAssertNil(arguments["globPattern"])
    }

    func testFunctionCallsMapSDKUpdateTodosToClientTodoWriteSchema() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"make todos"}],
          "tools":[
            {
              "type":"function",
              "function":{
                "name":"todowrite",
                "parameters":{
                  "type":"object",
                  "properties":{"todos":{"type":"array"}}
                }
              }
            }
          ]
        }
        """#.utf8))
        let toolCall = CursorToolCall(name: "updateTodos", arguments: [
            "todos": .array([
                .object([
                    "content": .string("Ship local API"),
                    "status": .string("todo_status_in_progress")
                ])
            ])
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
        let todos = try XCTUnwrap(arguments["todos"] as? [[String: Any]])

        XCTAssertEqual(function["name"] as? String, "todowrite")
        XCTAssertEqual(todos.first?["status"] as? String, "in_progress")
        XCTAssertEqual(todos.first?["priority"] as? String, "medium")
    }

    func testFunctionCallsDropSDKToolWhenNoClientToolMatches() throws {
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
        let message = try XCTUnwrap(output.first { ($0["type"] as? String) == "message" })

        XCTAssertNil(output.first { ($0["type"] as? String) == "function_call" })
        XCTAssertEqual(message["role"] as? String, "assistant")
    }

    func testChatCompletionsStreamingSuppressesTextBeforeToolCall() async throws {
        let port = try unusedTCPPort()
        let toolCall = CursorToolCall(name: "shell", arguments: ["command": .string("pwd")])
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(events: [
            .text("I will run that."),
            .toolCall(toolCall),
            .done(CursorSDKOutput(text: "I will run that.", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test"))
        ]))
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"""
        {
          "model":"composer-2.5",
          "stream":true,
          "messages":[{"role":"user","content":"run pwd"}],
          "tools":[{"type":"function","function":{"name":"bash","parameters":{"type":"object","properties":{"command":{"type":"string"}}}}}]
        }
        """#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains(#""tool_calls""#))
        XCTAssertTrue(text.contains(#""name":"bash""#))
        XCTAssertTrue(text.contains(#""finish_reason":"tool_calls""#))
        XCTAssertFalse(text.contains("I will run that."))
    }

    func testChatCompletionStreamUsageSerializesToolArguments() throws {
        let prepared = try OpenAICompatibility.prepareChatRequest(Data(#"""
        {
          "model":"composer-2.5",
          "messages":[{"role":"user","content":"run pwd"}],
          "tools":[{"type":"function","function":{"name":"bash","parameters":{"type":"object","properties":{"command":{"type":"string"}}}}}]
        }
        """#.utf8))
        let output = CursorSDKOutput(
            text: "",
            toolCalls: [CursorToolCall(name: "shell", arguments: ["command": .string("pwd")])],
            agentID: "agent-test",
            runID: "run-test"
        )

        let data = OpenAICompatibility.chatCompletionStreamUsage(id: "chatcmpl_test", created: 1, prepared: prepared, output: output)
        let text = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(text.contains(#""usage":"#))
        XCTAssertTrue(text.contains(#""completion_tokens":"#))
    }

    func testChatCompletionsStreamingFlushesTextDeltas() async throws {
        let port = try unusedTCPPort()
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

    func testChatCompletionsStreamingIncludesUsageWhenRequested() async throws {
        let port = try unusedTCPPort()
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(events: [
            .text("ok"),
            .done(CursorSDKOutput(text: "ok", agentID: "agent-test", runID: "run-test"))
        ]))
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"composer-2.5","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"hello"}]}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains(#""content":"ok""#))
        XCTAssertTrue(text.contains(#""choices":[]"#))
        XCTAssertTrue(text.contains(#""usage":"#))
        XCTAssertTrue(text.contains("data: [DONE]"))
    }

    func testResponsesStreamingUsesResponsesEvents() async throws {
        let port = try unusedTCPPort()
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
        XCTAssertTrue(text.contains(#""input_tokens":"#))
        XCTAssertTrue(text.contains(#""output_tokens":"#))
        XCTAssertTrue(text.contains(#""input_tokens_details":"#))
        XCTAssertTrue(text.contains(#""output_tokens_details":"#))
    }

    func testResponsesStreamingEmitsFunctionCallEvents() async throws {
        let port = try unusedTCPPort()
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

    func testResponsesStreamingSuppressesTextBeforeFunctionCall() async throws {
        let port = try unusedTCPPort()
        let toolCall = CursorToolCall(name: "shell", arguments: ["command": .string("pwd")])
        let server = LocalAPIServer(settingsProvider: { CursorAPISettings(port: port) }, harness: MockHarness(events: [
            .text("I will run that."),
            .toolCall(toolCall),
            .done(CursorSDKOutput(text: "I will run that.", toolCalls: [toolCall], agentID: "agent-test", runID: "run-test"))
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
        XCTAssertTrue(text.contains(#""type":"function_call""#))
        XCTAssertTrue(text.contains(#""name":"shell""#))
        XCTAssertFalse(text.contains("I will run that."))
        XCTAssertFalse(text.contains("event: response.content_part.added"))
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

private final class TestPortAllocator: @unchecked Sendable {
    static let shared = TestPortAllocator()

    private let lock = NSLock()
    private var nextPort: UInt16 = 20_000
    private let firstPort: UInt16 = 20_000
    private let lastPort: UInt16 = 48_000

    private init() {}

    func nextAvailablePort() throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }

        for _ in firstPort...lastPort {
            let candidate = nextPort
            nextPort = candidate == lastPort ? firstPort : candidate + 1
            if isAvailable(candidate) {
                return candidate
            }
        }
        throw POSIXError(.EADDRINUSE)
    }

    private func isAvailable(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer {
            close(descriptor)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }
}

private extension LocalAPIServerTests {
    func unusedTCPPort() throws -> UInt16 {
        try TestPortAllocator.shared.nextAvailablePort()
    }

    func postResponse(port: UInt16, body: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func postResponseStatus(port: UInt16, body: String) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, String(data: data, encoding: .utf8) ?? "")
    }

    func chunkedBody(_ body: String, sizes: [Int]) -> String {
        var remaining = body
        var chunks: [String] = []
        for size in sizes where !remaining.isEmpty {
            let end = remaining.index(remaining.startIndex, offsetBy: min(size, remaining.count))
            let chunk = String(remaining[..<end])
            chunks.append("\(String(chunk.utf8.count, radix: 16))\r\n\(chunk)\r\n")
            remaining = String(remaining[end...])
        }
        if !remaining.isEmpty {
            chunks.append("\(String(remaining.utf8.count, radix: 16))\r\n\(remaining)\r\n")
        }
        chunks.append("0\r\n\r\n")
        return chunks.joined()
    }

    func responseHeaderValue(_ name: String, in response: String) -> String? {
        let headerBlock = response.components(separatedBy: "\r\n\r\n").first ?? response
        for line in headerBlock.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let headerName = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            guard headerName.caseInsensitiveCompare(name) == .orderedSame else {
                continue
            }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    func responseBody(_ response: String) -> String {
        guard let separator = response.range(of: "\r\n\r\n") else {
            return ""
        }
        return String(response[separator.upperBound...])
    }

    func sendRawHTTPRequest(port: UInt16, request: String) async throws -> String {
        try await Task.detached {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
            }
            defer {
                close(descriptor)
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let connectResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                    Darwin.connect(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connectResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
            }

            let bytes = Array(request.utf8)
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(descriptor, bytes.withUnsafeBytes { pointer in
                    pointer.baseAddress!.advanced(by: sent)
                }, bytes.count - sent, 0)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
                }
                sent += count
            }
            shutdown(descriptor, SHUT_WR)

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(descriptor, &buffer, buffer.count, 0)
                if count > 0 {
                    data.append(contentsOf: buffer.prefix(count))
                    continue
                }
                if count == 0 {
                    break
                }
                if errno == EINTR {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
            }
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }

    func sendExpectContinueHTTPRequest(port: UInt16, headers: String, body: String) async throws -> (String, String) {
        try await Task.detached {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
            }
            defer {
                close(descriptor)
            }

            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let connectResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                    Darwin.connect(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connectResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
            }

            try sendAll(Array(headers.utf8), descriptor: descriptor)
            let interimData = try receiveUntilHeaderEnd(descriptor: descriptor)
            try sendAll(Array(body.utf8), descriptor: descriptor)
            shutdown(descriptor, SHUT_WR)

            var finalData = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(descriptor, &buffer, buffer.count, 0)
                if count > 0 {
                    finalData.append(contentsOf: buffer.prefix(count))
                    continue
                }
                if count == 0 {
                    break
                }
                if errno == EINTR {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
            }

            return (
                String(data: interimData, encoding: .utf8) ?? "",
                String(data: finalData, encoding: .utf8) ?? ""
            )
        }.value
    }

    func getResponse(port: UInt16, responseID: String) async throws -> (Int, [String: Any]?) {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/responses/\(responseID)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (status, object)
    }

    func getResponseInputItems(port: UInt16, responseID: String, query: String? = nil) async throws -> (Int, [String: Any]?) {
        let querySuffix = query.map { "?\($0)" } ?? ""
        let url = URL(string: "http://127.0.0.1:\(port)/v1/responses/\(responseID)/input_items\(querySuffix)")!
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

private func sendAll(_ bytes: [UInt8], descriptor: Int32) throws {
    var sent = 0
    while sent < bytes.count {
        let count = Darwin.send(descriptor, bytes.withUnsafeBytes { pointer in
            pointer.baseAddress!.advanced(by: sent)
        }, bytes.count - sent, 0)
        if count < 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        sent += count
    }
}

private func receiveUntilHeaderEnd(descriptor: Int32) throws -> Data {
    let terminator = Data("\r\n\r\n".utf8)
    var data = Data()
    var byte = [UInt8](repeating: 0, count: 1)
    while true {
        let count = recv(descriptor, &byte, byte.count, 0)
        if count > 0 {
            data.append(byte[0])
            if data.count >= terminator.count,
               data.suffix(terminator.count) == terminator {
                return data
            }
            continue
        }
        if count == 0 {
            return data
        }
        if errno == EINTR {
            continue
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
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

    func models() -> [String] {
        requests.map(\.model)
    }

    func cursorModelIDs() -> [String] {
        requests.map(\.cursorModelID)
    }

    func prompts() -> [String] {
        requests.map(\.prompt)
    }
}

private final class LocalAPIRequestEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LocalAPIRequestEvent] = []

    func record(_ event: LocalAPIRequestEvent) {
        lock.lock()
        values.append(event)
        lock.unlock()
    }

    func events() -> [LocalAPIRequestEvent] {
        lock.lock()
        let snapshot = values
        lock.unlock()
        return snapshot
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
