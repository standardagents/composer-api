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
        XCTAssertEqual(object["routingConfigured"] as? Bool, false)
        XCTAssertEqual(object["sdkConfigured"] as? Bool, false)
        XCTAssertEqual(object["apiKeyConfigured"] as? Bool, false)
        XCTAssertEqual(object["apiKeyUnlocked"] as? Bool, false)
        XCTAssertEqual(object["keychainKeyAvailable"] as? Bool, false)
        XCTAssertEqual(object["ready"] as? Bool, false)
        XCTAssertEqual(object["status"] as? String, "needs_api_key")
        XCTAssertEqual(object["baseUrl"] as? String, "http://127.0.0.1:\(port)/v1")
        XCTAssertEqual(object["missing"] as? [String], ["cursorAPIKey", "cursorAPIBaseURL", "backendBaseURL", "localAgentEndpoint"])
        XCTAssertEqual(object["models"] as? [String], ["composer-2.5", "composer-2.5-fast"])
        let responses = try XCTUnwrap(object["responses"] as? [String: Any])
        XCTAssertEqual((responses["sessions"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((responses["stored"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((responses["inputItems"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((responses["toolCallMemory"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((responses["maxStored"] as? NSNumber)?.intValue, 512)
        let routing = try XCTUnwrap(object["routing"] as? [String: Any])
        XCTAssertEqual(routing["configured"] as? Bool, false)
        XCTAssertEqual(routing["keyExchangeConfigured"] as? Bool, false)
        XCTAssertEqual(routing["backendConfigured"] as? Bool, false)
        XCTAssertEqual(routing["localAgentConfigured"] as? Bool, false)
    }

    func testHealthEndpointReportsSanitizedReadyState() async throws {
        let port = try unusedTCPPort()
        let settings = CursorAPISettings(
            port: port,
            cursorAPIKey: "crsr_test",
            cursorAPIBaseURL: "https://exchange.example",
            backendBaseURL: "https://private-backend.example",
            localAgentEndpoint: "/private/sdk/run",
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
        XCTAssertFalse(text.contains("private-backend.example"))
        XCTAssertFalse(text.contains("/private/sdk/run"))
    }

    func testHealthEndpointReportsRoutingMissingWhenKeyIsPresent() async throws {
        let port = try unusedTCPPort()
        let settings = CursorAPISettings(port: port, cursorAPIKey: "crsr_test")
        let server = LocalAPIServer(settingsProvider: { settings }, harness: MockHarness())
        try server.start(port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 150_000_000)

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["ready"] as? Bool, false)
        XCTAssertEqual(object["status"] as? String, "routing_missing")
        XCTAssertEqual(object["apiKeyConfigured"] as? Bool, true)
        XCTAssertEqual(object["apiKeyUnlocked"] as? Bool, true)
        XCTAssertEqual(object["routingConfigured"] as? Bool, false)
        XCTAssertEqual(object["missing"] as? [String], ["cursorAPIBaseURL", "backendBaseURL", "localAgentEndpoint"])
    }

    func testHealthEndpointReportsNeedsUnlockForSavedKeyOnly() async throws {
        let port = try unusedTCPPort()
        let settings = CursorAPISettings(
            port: port,
            keychainCursorAPIKeyAvailable: true,
            cursorAPIBaseURL: "https://exchange.example",
            backendBaseURL: "https://private-backend.example",
            localAgentEndpoint: "/private/sdk/run"
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
            backendBaseURL: "https://private-backend.example",
            localAgentEndpoint: "/private/sdk/run"
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
            backendBaseURL: "https://private-backend.example",
            localAgentEndpoint: "/private/sdk/run"
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
            XCTAssertFalse(text.contains("private-backend.example"), path)
            XCTAssertFalse(text.contains("/private/sdk/run"), path)
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
        XCTAssertTrue(prepared.prompt.contains("Allowed tool names: repo_search"))
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
        XCTAssertTrue(prepared.prompt.contains("Use SDK shell now."))
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
        XCTAssertTrue(prepared.prompt.contains("For creating or overwriting a file, use SDK write with path and fileText."))
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
        XCTAssertTrue(prepared.prompt.contains("Use SDK shell now."))
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
        XCTAssertTrue(prepared.prompt.contains("Use SDK shell now."))
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
        XCTAssertTrue(prepared.prompt.contains("Use SDK shell now."))
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
        XCTAssertTrue(prepared.prompt.contains("Use the shell tool if you call a tool."))
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
        XCTAssertTrue(prepared.prompt.contains("Use the shell tool if you call a tool."))
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

private extension LocalAPIServerTests {
    func unusedTCPPort() throws -> UInt16 {
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
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                getsockname(descriptor, rebound, &boundLength)
            }
        }
        guard nameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }

        return UInt16(bigEndian: boundAddress.sin_port)
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
