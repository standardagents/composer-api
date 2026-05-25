import CursorAPICore
import XCTest

final class AgentProvisionerTests: XCTestCase {
    func testInstallsOpenCodeProvider() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        try provisioner.install(.opencode, settings: settings)

        let config = home.appending(path: ".config/opencode/opencode.json")
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("cursorapi"))
        XCTAssertTrue(text.contains(CursorAPIBrand.displayName))
        XCTAssertTrue(text.contains("cursor-local"))
        XCTAssertTrue(text.contains("composer-2.5-fast"))

        let root = try readJSONObject(config)
        let providers = try XCTUnwrap(root["provider"] as? [String: Any])
        let cursorProvider = try XCTUnwrap(providers["cursorapi"] as? [String: Any])
        let models = try XCTUnwrap(cursorProvider["models"] as? [String: Any])
        let fast = try XCTUnwrap(models["composer-2.5-fast"] as? [String: Any])
        assertComposerMetadata(fast, inputCost: 3.0, outputCost: 15.0)
        XCTAssertTrue(provisioner.status(for: .opencode, settings: settings).installed)
    }

    func testInstallsCodexProvider() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        try provisioner.install(.codex, settings: settings)

        let config = home.appending(path: ".codex/config.toml")
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("[model_providers.cursorapi]"))
        XCTAssertTrue(text.contains("name = \"\(CursorAPIBrand.displayName)\""))
        XCTAssertTrue(text.contains("[model_providers.cursorapi.auth]"))
        XCTAssertTrue(text.contains("wire_api = \"responses\""))
        XCTAssertTrue(text.contains("command = \"/bin/echo\""))
        XCTAssertTrue(text.contains("args = [\"cursor-local\"]"))
        XCTAssertFalse(text.contains("env_key = \"CURSOR_API_KEY\""))
        XCTAssertTrue(provisioner.status(for: .codex, settings: settings).installed)
    }

    func testCodexInstallUpdatesExistingProviderWithoutDuplicatingSections() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let config = home.appending(path: ".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        approval_policy = "on-request"

        [model_providers.cursorapi]
        name = "Old CursorAPI"
        base_url = "http://127.0.0.1:9999/v1"
        env_key = "OLD_KEY"

        [model_providers.cursorapi.auth]
        command = "/bin/echo"
        args = ["OLD_KEY"]

        [profiles.cursorapi]
        model_provider = "cursorapi"
        model = "old-model"

        [profiles.cursorapi-fast]
        model_provider = "cursorapi"
        model = "old-fast-model"

        [profiles.other]
        model_provider = "openai"
        model = "gpt-5"
        """.write(to: config, atomically: true, encoding: .utf8)

        let settings = CursorAPISettings(port: 8787)
        try provisioner.install(.codex, settings: settings)
        try provisioner.install(.codex, settings: settings)

        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertEqual(countOccurrences(of: "[model_providers.cursorapi]", in: text), 1)
        XCTAssertEqual(countOccurrences(of: "[model_providers.cursorapi.auth]", in: text), 1)
        XCTAssertEqual(countOccurrences(of: "[profiles.cursorapi]", in: text), 1)
        XCTAssertEqual(countOccurrences(of: "[profiles.cursorapi-fast]", in: text), 1)
        XCTAssertTrue(text.contains("approval_policy = \"on-request\""))
        XCTAssertTrue(text.contains("[profiles.other]"))
        XCTAssertTrue(text.contains("base_url = \"http://127.0.0.1:8787/v1\""))
        XCTAssertTrue(text.contains("wire_api = \"responses\""))
        XCTAssertTrue(text.contains("args = [\"cursor-local\"]"))
        XCTAssertFalse(text.contains("old-model"))
        XCTAssertFalse(text.contains("OLD_KEY"))
        XCTAssertFalse(text.contains("env_key"))
    }

    func testInstallsPiModels() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        try provisioner.install(.pi, settings: settings)

        let config = home.appending(path: ".pi/agent/models.json")
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("openai-completions"))
        XCTAssertTrue(text.contains("cursor-local"))
        XCTAssertTrue(text.contains("cursorapi"))

        let root = try readJSONObject(config)
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])
        let cursorProvider = try XCTUnwrap(providers["cursorapi"] as? [String: Any])
        let models = try XCTUnwrap(cursorProvider["models"] as? [[String: Any]])
        let fast = try XCTUnwrap(models.first { $0["id"] as? String == "composer-2.5-fast" })
        assertComposerMetadata(fast, inputCost: 3.0, outputCost: 15.0)
        XCTAssertEqual((fast["maxTokens"] as? NSNumber)?.intValue, 65_536)
        XCTAssertEqual((fast["contextWindow"] as? NSNumber)?.intValue, 200_000)
        XCTAssertTrue(provisioner.status(for: .pi, settings: settings).installed)
    }

    func testInstallsClineAndKiloProfiles() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        try provisioner.install(.cline, settings: settings)
        try provisioner.install(.kilo, settings: settings)

        let clineGlobalState = home.appending(path: ".cline/data/globalState.json")
        let clineText = try String(contentsOf: clineGlobalState, encoding: .utf8)
        XCTAssertTrue(clineText.contains(#""actModeOpenAiModelId" : "composer-2.5""#))
        XCTAssertTrue(clineText.contains(#""planModeOpenAiModelId" : "composer-2.5-fast""#))
        XCTAssertTrue(clineText.contains(#""actModeOpenAiModelInfo""#))
        XCTAssertTrue(clineText.contains(#""planModeOpenAiModelInfo""#))
        XCTAssertTrue(clineText.contains(#""supportsTools" : true"#))
        let clineGlobal = try readJSONObject(clineGlobalState)
        let clineFastInfo = try XCTUnwrap(clineGlobal["planModeOpenAiModelInfo"] as? [String: Any])
        XCTAssertEqual((clineFastInfo["maxTokens"] as? NSNumber)?.intValue, 65_536)
        XCTAssertEqual((clineFastInfo["contextWindow"] as? NSNumber)?.intValue, 200_000)
        XCTAssertEqual((clineFastInfo["outputPrice"] as? NSNumber)?.doubleValue, 15.0)

        let clineSecrets = home.appending(path: ".cline/data/secrets.json")
        let clineSecretsText = try String(contentsOf: clineSecrets, encoding: .utf8)
        XCTAssertTrue(clineSecretsText.contains("cursor-local"))

        let kiloConfig = home.appending(path: ".config/kilo/kilo.jsonc")
        let kiloText = try String(contentsOf: kiloConfig, encoding: .utf8)
        XCTAssertTrue(kiloText.contains("cursor-local"))
        let kiloRoot = try readJSONObject(kiloConfig)
        let kiloProviders = try XCTUnwrap(kiloRoot["provider"] as? [String: Any])
        let kiloProvider = try XCTUnwrap(kiloProviders["cursorapi"] as? [String: Any])
        let kiloModels = try XCTUnwrap(kiloProvider["models"] as? [String: Any])
        let kiloFast = try XCTUnwrap(kiloModels["composer-2.5-fast"] as? [String: Any])
        assertComposerMetadata(kiloFast, inputCost: 3.0, outputCost: 15.0)
        XCTAssertTrue(provisioner.status(for: .cline, settings: settings).installed)
        XCTAssertTrue(provisioner.status(for: .kilo, settings: settings).installed)
    }

    func testKiloInstallReadsJSONCAndBacksUpExistingConfig() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        let config = home.appending(path: ".config/kilo/kilo.jsonc")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {
          // Kilo allows comments here.
          "$schema": "https://app.kilo.ai/config.json",
          "model": "other/provider",
          "provider": {
            "existing": {
              "options": {
                "baseURL": "http://localhost:1234/v1"
              }
            }
          }
        }
        """.write(to: config, atomically: true, encoding: .utf8)

        try provisioner.install(.kilo, settings: settings)

        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("\"existing\""))
        XCTAssertTrue(text.contains("\"cursorapi\""))
        XCTAssertTrue(text.contains("cursor-local"))

        let backups = try FileManager.default.contentsOfDirectory(at: config.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("kilo.jsonc.cursorapi-backup.") }
        XCTAssertEqual(backups.count, 1)
        let backupText = try String(contentsOf: backups[0], encoding: .utf8)
        XCTAssertTrue(backupText.contains("Kilo allows comments"))
    }

    func testInstallBacksUpChangedJSONConfig() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        let config = home.appending(path: ".config/opencode/opencode.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"model":"other/model","provider":{"other":{"name":"Other"}}}"#.write(to: config, atomically: true, encoding: .utf8)

        try provisioner.install(.opencode, settings: settings)

        let backups = try FileManager.default.contentsOfDirectory(at: config.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("opencode.json.cursorapi-backup.") }
        XCTAssertEqual(backups.count, 1)
        let backupText = try String(contentsOf: backups[0], encoding: .utf8)
        XCTAssertTrue(backupText.contains("other/model"))
    }

    func testInstallsVSCodeModelMetadata() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        try provisioner.install(.vscode, settings: settings)

        let config = home.appending(path: "Library/Application Support/Code/User/chatLanguageModels.json")
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains(CursorAPIBrand.displayName))
        XCTAssertTrue(text.contains("composer-2.5-fast"))
        XCTAssertTrue(provisioner.status(for: .vscode, settings: settings).installed)
    }

    func testStatusesRequireCurrentLocalBaseURL() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let original = CursorAPISettings(port: 8787)
        let moved = CursorAPISettings(port: 9999)

        try provisioner.install(.opencode, settings: original)
        try provisioner.install(.codex, settings: original)
        try provisioner.install(.vscode, settings: original)
        try provisioner.install(.cline, settings: original)
        try provisioner.install(.kilo, settings: original)
        try provisioner.install(.pi, settings: original)

        for id in AgentIntegrationID.allCases {
            let status = provisioner.status(for: id, settings: moved)
            XCTAssertFalse(status.installed, "\(id.displayName) should require the current local API URL")
            XCTAssertTrue(status.canInstall, "\(id.displayName) should remain installable")
        }

        XCTAssertTrue(provisioner.status(for: .opencode, settings: moved).detail.contains("different local URL"))
        XCTAssertTrue(provisioner.status(for: .codex, settings: moved).detail.contains("different local URL"))
        XCTAssertTrue(provisioner.status(for: .vscode, settings: moved).detail.contains("different local URL"))
    }

    func testStatusesRequireCurrentModelMetadata() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)

        for id in [AgentIntegrationID.opencode, .cline, .kilo, .pi] {
            try provisioner.install(id, settings: settings)
            XCTAssertTrue(provisioner.status(for: id, settings: settings).installed)
        }

        let metadataFiles = [
            home.appending(path: ".config/opencode/opencode.json"),
            home.appending(path: ".cline/data/globalState.json"),
            home.appending(path: ".config/kilo/kilo.jsonc"),
            home.appending(path: ".pi/agent/models.json")
        ]
        for url in metadataFiles {
            try replaceText(in: url, matching: "65536", with: "16384")
        }

        for id in [AgentIntegrationID.opencode, .cline, .kilo, .pi] {
            let status = provisioner.status(for: id, settings: settings)
            XCTAssertFalse(status.installed, "\(id.displayName) should require current model limits")
            XCTAssertTrue(status.detail.contains("update"), "\(id.displayName) should explain stale metadata")

            try provisioner.install(id, settings: settings)
            XCTAssertTrue(provisioner.status(for: id, settings: settings).installed)
        }
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "CursorAPITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func countOccurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func readJSONObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func replaceText(in url: URL, matching oldValue: String, with newValue: String) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        try text.replacingOccurrences(of: oldValue, with: newValue).write(to: url, atomically: true, encoding: .utf8)
    }

    private func assertComposerMetadata(
        _ metadata: [String: Any],
        inputCost: Double,
        outputCost: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let cost = metadata["cost"] as? [String: Any]
        XCTAssertEqual((cost?["input"] as? NSNumber)?.doubleValue, inputCost, file: file, line: line)
        XCTAssertEqual((cost?["output"] as? NSNumber)?.doubleValue, outputCost, file: file, line: line)
        let limit = metadata["limit"] as? [String: Any]
        XCTAssertEqual((limit?["context"] as? NSNumber)?.intValue, 200_000, file: file, line: line)
        XCTAssertEqual((limit?["output"] as? NSNumber)?.intValue, 65_536, file: file, line: line)
    }
}
