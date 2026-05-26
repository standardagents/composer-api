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

    func testOpenCodeAndKiloRespectXDGConfigHome() throws {
        let home = try temporaryHome()
        let xdgConfig = home.appending(path: "Library/Config")
        let provisioner = AgentProvisioner(
            homeDirectory: home,
            environment: ["XDG_CONFIG_HOME": xdgConfig.path]
        )
        let settings = CursorAPISettings(port: 8787)

        try provisioner.install(.opencode, settings: settings)
        try provisioner.install(.kilo, settings: settings)

        let opencodeConfig = xdgConfig.appending(path: "opencode/opencode.json")
        let kiloConfig = xdgConfig.appending(path: "kilo/kilo.jsonc")
        let defaultOpenCodeConfig = home.appending(path: ".config/opencode/opencode.json")
        let defaultKiloConfig = home.appending(path: ".config/kilo/kilo.jsonc")
        let opencodeText = try String(contentsOf: opencodeConfig, encoding: .utf8)
        let kiloText = try String(contentsOf: kiloConfig, encoding: .utf8)

        XCTAssertTrue(opencodeText.contains(CursorAPIBrand.displayName))
        XCTAssertTrue(kiloText.contains("cursorapi"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultOpenCodeConfig.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultKiloConfig.path))
        XCTAssertEqual(provisioner.status(for: .opencode, settings: settings).configPath, opencodeConfig.path)
        XCTAssertEqual(provisioner.status(for: .kilo, settings: settings).configPath, kiloConfig.path)
        XCTAssertTrue(provisioner.status(for: .opencode, settings: settings).installed)
        XCTAssertTrue(provisioner.status(for: .kilo, settings: settings).installed)
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

    func testInstallsContinueModelsInExistingConfig() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        let config = home.appending(path: ".continue/config.yaml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        name: Existing Continue Config
        version: 1.0.0
        models:
          - name: Other Local Model
            provider: openai
            model: other-model
            apiBase: http://localhost:1234/v1
            apiKey: other
        context:
          - provider: code
        """.write(to: config, atomically: true, encoding: .utf8)

        try provisioner.install(.continueDev, settings: settings)
        try provisioner.install(.continueDev, settings: settings)

        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("name: Existing Continue Config"))
        XCTAssertTrue(text.contains("name: Other Local Model"))
        XCTAssertTrue(text.contains("context:"))
        XCTAssertTrue(text.contains("# api-for-cursor-start"))
        XCTAssertTrue(text.contains("name: Composer 2.5"))
        XCTAssertTrue(text.contains("model: composer-2.5-fast"))
        XCTAssertTrue(text.contains("provider: openai"))
        XCTAssertTrue(text.contains("apiBase: http://127.0.0.1:8787/v1"))
        XCTAssertTrue(text.contains("apiKey: cursor-local"))
        XCTAssertEqual(countOccurrences(of: "# api-for-cursor-start", in: text), 1)
        XCTAssertEqual(countOccurrences(of: "# api-for-cursor-end", in: text), 1)
        XCTAssertTrue(provisioner.status(for: .continueDev, settings: settings).installed)
    }

    func testInstallsAiderOpenAICompatibleConfig() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        let config = home.appending(path: ".aider.conf.yml")
        try """
        dark-mode: true
        model: openai/old-model
        weak-model: openai/old-fast
        openai-api-base: http://127.0.0.1:9999/v1
        openai-api-key: old-key
        show-model-warnings: false
        """.write(to: config, atomically: true, encoding: .utf8)

        try provisioner.install(.aider, settings: settings)
        try provisioner.install(.aider, settings: settings)

        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("dark-mode: true"))
        XCTAssertTrue(text.contains("show-model-warnings: false"))
        XCTAssertTrue(text.contains("# api-for-cursor-aider-start"))
        XCTAssertTrue(text.contains("model: openai/composer-2.5"))
        XCTAssertTrue(text.contains("weak-model: openai/composer-2.5-fast"))
        XCTAssertTrue(text.contains("editor-model: openai/composer-2.5-fast"))
        XCTAssertTrue(text.contains("openai-api-base: http://127.0.0.1:8787/v1"))
        XCTAssertTrue(text.contains("openai-api-key: cursor-local"))
        XCTAssertFalse(text.contains("old-model"))
        XCTAssertFalse(text.contains("old-key"))
        XCTAssertEqual(countOccurrences(of: "# api-for-cursor-aider-start", in: text), 1)
        XCTAssertEqual(countOccurrences(of: "# api-for-cursor-aider-end", in: text), 1)
        XCTAssertEqual(countOccurrences(of: "openai-api-base:", in: text), 1)
        XCTAssertTrue(provisioner.status(for: .aider, settings: settings).installed)

        let backups = try FileManager.default.contentsOfDirectory(at: config.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".aider.conf.yml.api-for-cursor-backup.") }
        XCTAssertEqual(backups.count, 1)
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
            .filter { $0.lastPathComponent.hasPrefix("kilo.jsonc.api-for-cursor-backup.") }
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
            .filter { $0.lastPathComponent.hasPrefix("opencode.json.api-for-cursor-backup.") }
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

    func testVSCodeInstallTargetsExistingCodeFamilyUserData() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let cursorUser = home.appending(path: "Library/Application Support/Cursor/User")
        try FileManager.default.createDirectory(at: cursorUser, withIntermediateDirectories: true)
        let settings = CursorAPISettings(port: 8787)

        try provisioner.install(.vscode, settings: settings)

        let cursorConfig = cursorUser.appending(path: "chatLanguageModels.json")
        let stableConfig = home.appending(path: "Library/Application Support/Code/User/chatLanguageModels.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cursorConfig.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stableConfig.path))
        XCTAssertTrue(provisioner.status(for: .vscode, settings: settings).installed)
        XCTAssertEqual(provisioner.status(for: .vscode, settings: settings).configPath, cursorConfig.path)
    }

    func testVSCodeStatusDetectsInstalledCodeFamilyConfig() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        let windsurfConfig = home.appending(path: "Library/Application Support/Windsurf/User/chatLanguageModels.json")
        try FileManager.default.createDirectory(at: windsurfConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [
          {
            "name": "\(CursorAPIBrand.displayName)",
            "provider": "openai-compatible",
            "baseUrl": "\(settings.baseURL.absoluteString)",
            "models": ["composer-2.5", "composer-2.5-fast"]
          }
        ]
        """.write(to: windsurfConfig, atomically: true, encoding: .utf8)

        let status = provisioner.status(for: .vscode, settings: settings)

        XCTAssertTrue(status.installed)
        XCTAssertEqual(status.configPath, windsurfConfig.path)
    }

    func testAllGeneratedAgentConfigsAreLocalOnlyAndIncludeBothComposerModels() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)

        for id in AgentIntegrationID.allCases {
            try provisioner.install(id, settings: settings)
            XCTAssertTrue(provisioner.status(for: id, settings: settings).installed, "\(id.displayName) should be installed")
        }

        let generatedText = try allGeneratedConfigText(under: home)
        XCTAssertTrue(generatedText.contains("http://127.0.0.1:8787/v1"))
        XCTAssertTrue(generatedText.contains("composer-2.5"))
        XCTAssertTrue(generatedText.contains("composer-2.5-fast"))
        XCTAssertTrue(generatedText.contains("cursor-local"))
        XCTAssertFalse(generatedText.contains("cursor-api.standardagents.ai"))
        XCTAssertFalse(generatedText.contains("/opencode"))
        XCTAssertFalse(generatedText.contains("/opencodev2"))
        XCTAssertFalse(generatedText.contains("CURSOR_API_KEY"))
        XCTAssertFalse(generatedText.contains("crsr_"))
    }

    func testInstallAllInstallsEverySupportedIntegration() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)

        let statuses = try provisioner.installAll(settings: settings)

        XCTAssertEqual(Set(statuses.map(\.id)), Set(AgentIntegrationID.allCases))
        XCTAssertTrue(statuses.allSatisfy(\.installed))
        XCTAssertTrue(statuses.allSatisfy { $0.actionTitle == "Installed" })

        let generatedText = try allGeneratedConfigText(under: home)
        XCTAssertTrue(generatedText.contains("http://127.0.0.1:8787/v1"))
        XCTAssertTrue(generatedText.contains("composer-2.5"))
        XCTAssertTrue(generatedText.contains("composer-2.5-fast"))
        XCTAssertTrue(generatedText.contains("cursor-local"))
        XCTAssertFalse(generatedText.contains("cursor-api.standardagents.ai"))
        XCTAssertFalse(generatedText.contains("crsr_"))
    }

    func testInstallAllUpdatesStaleProviderWithoutDuplicatingInstalledConfigs() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let original = CursorAPISettings(port: 8787)
        let moved = CursorAPISettings(port: 9999)

        _ = try provisioner.installAll(settings: original)
        _ = try provisioner.installAll(settings: moved)
        _ = try provisioner.installAll(settings: moved)

        for status in provisioner.statuses(settings: moved) {
            XCTAssertTrue(status.installed, "\(status.id.displayName) should be current after bulk update")
        }

        let opencode = try String(contentsOf: home.appending(path: ".config/opencode/opencode.json"), encoding: .utf8)
        let codex = try String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8)
        let kilo = try String(contentsOf: home.appending(path: ".config/kilo/kilo.jsonc"), encoding: .utf8)
        let pi = try String(contentsOf: home.appending(path: ".pi/agent/models.json"), encoding: .utf8)
        let continueConfig = try String(contentsOf: home.appending(path: ".continue/config.yaml"), encoding: .utf8)
        let aiderConfig = try String(contentsOf: home.appending(path: ".aider.conf.yml"), encoding: .utf8)

        XCTAssertEqual(countOccurrences(of: "\"cursorapi\"", in: opencode), 1)
        XCTAssertEqual(countOccurrences(of: "[model_providers.cursorapi]", in: codex), 1)
        XCTAssertEqual(countOccurrences(of: "\"cursorapi\"", in: kilo), 1)
        XCTAssertEqual(countOccurrences(of: "\"cursorapi\"", in: pi), 1)
        XCTAssertEqual(countOccurrences(of: "# api-for-cursor-start", in: continueConfig), 1)
        XCTAssertEqual(countOccurrences(of: "# api-for-cursor-aider-start", in: aiderConfig), 1)
        for currentConfig in [opencode, codex, kilo, pi, continueConfig, aiderConfig] {
            XCTAssertFalse(currentConfig.contains("http://127.0.0.1:8787/v1"))
            XCTAssertTrue(currentConfig.contains("http://127.0.0.1:9999/v1"))
        }
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
        try provisioner.install(.continueDev, settings: original)
        try provisioner.install(.aider, settings: original)

        for id in AgentIntegrationID.allCases {
            let status = provisioner.status(for: id, settings: moved)
            XCTAssertFalse(status.installed, "\(id.displayName) should require the current local API URL")
            XCTAssertTrue(status.canInstall, "\(id.displayName) should remain installable")
            XCTAssertTrue(status.needsUpdate, "\(id.displayName) should be marked as updateable")
            XCTAssertEqual(status.actionTitle, "Update")
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
            XCTAssertTrue(status.needsUpdate, "\(id.displayName) should be marked as updateable")
            XCTAssertEqual(status.actionTitle, "Update")

            try provisioner.install(id, settings: settings)
            XCTAssertTrue(provisioner.status(for: id, settings: settings).installed)
        }
    }

    func testStatusesRequireCompleteCodexAndVSCodeProviderShapes() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        let codexConfig = home.appending(path: ".codex/config.toml")
        let vscodeConfig = home.appending(path: "Library/Application Support/Code/User/chatLanguageModels.json")

        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [model_providers.cursorapi]
        name = "\(CursorAPIBrand.displayName)"
        base_url = "\(settings.baseURL.absoluteString)"
        """.write(to: codexConfig, atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: vscodeConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [
          {
            "name": "\(CursorAPIBrand.displayName)",
            "provider": "openai-compatible",
            "baseUrl": "\(settings.baseURL.absoluteString)",
            "models": ["composer-2.5"]
          }
        ]
        """.write(to: vscodeConfig, atomically: true, encoding: .utf8)

        for id in [AgentIntegrationID.codex, .vscode] {
            let status = provisioner.status(for: id, settings: settings)
            XCTAssertFalse(status.installed, "\(id.displayName) should require complete provider metadata")
            XCTAssertTrue(status.detail.contains("update"), "\(id.displayName) should explain stale metadata")
            XCTAssertTrue(status.needsUpdate, "\(id.displayName) should be marked as updateable")
            XCTAssertEqual(status.actionTitle, "Update")

            try provisioner.install(id, settings: settings)
            XCTAssertTrue(provisioner.status(for: id, settings: settings).installed)
        }
    }

    func testUnavailableIntegrationActionIsExplicit() {
        let status = AgentIntegrationStatus(id: .cline, installed: false, configPath: nil, detail: "Extension state not found", canInstall: false)

        XCTAssertFalse(status.needsUpdate)
        XCTAssertEqual(status.actionTitle, "Unavailable")
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

    private func allGeneratedConfigText(under home: URL) throws -> String {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil))
        var chunks: [String] = []
        for case let url as URL in enumerator where !url.hasDirectoryPath {
            chunks.append(try String(contentsOf: url, encoding: .utf8))
        }
        return chunks.joined(separator: "\n")
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
