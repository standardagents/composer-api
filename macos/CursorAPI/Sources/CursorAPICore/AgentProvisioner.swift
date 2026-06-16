import Foundation

public final class AgentProvisioner: @unchecked Sendable {
    private static let backupMarker = "api-for-cursor-backup"
    private static let continueBlockStart = "# api-for-cursor-start"
    private static let continueBlockEnd = "# api-for-cursor-end"
    private static let aiderBlockStart = "# api-for-cursor-aider-start"
    private static let aiderBlockEnd = "# api-for-cursor-aider-end"
    private static let aiderSettingsBlockStart = "# api-for-cursor-aider-model-settings-start"
    private static let aiderSettingsBlockEnd = "# api-for-cursor-aider-model-settings-end"
    private static let rooProfileName = CursorAPIBrand.displayName
    private static let rooFastProfileName = "\(CursorAPIBrand.displayName) Fast"
    private static let rooProfileID = "api-for-cursor-composer"
    private static let rooFastProfileID = "api-for-cursor-composer-fast"
    public static let visibleIntegrationIDs: [AgentIntegrationID] = [
        .opencode,
        .codex,
        .vscode,
        .cline,
        .kilo,
        .pi,
        .factory
    ]

    /// Factory custom-model ids written by this app. Used to strip stale entries
    /// during install/re-install so users don't accumulate duplicates.
    private static let factoryModelIDPrefix = "custom:cursorapi:"

    private let homeDirectory: URL
    private let fileManager: FileManager
    private let environment: [String: String]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.environment = environment
    }

    public func statuses(settings: CursorAPISettings) -> [AgentIntegrationStatus] {
        Self.visibleIntegrationIDs.map { status(for: $0, settings: settings) }
    }

    public func status(for id: AgentIntegrationID, settings: CursorAPISettings) -> AgentIntegrationStatus {
        switch id {
        case .opencode:
            return opencodeStatus(settings: settings)
        case .codex:
            return codexStatus(settings: settings)
        case .vscode:
            return vscodeStatus(settings: settings)
        case .cline:
            return extensionStatus(id: .cline, settings: settings)
        case .kilo:
            return extensionStatus(id: .kilo, settings: settings)
        case .pi:
            return piStatus(settings: settings)
        case .factory:
            return factoryStatus(settings: settings)
        case .continueDev:
            return continueStatus(settings: settings)
        case .aider:
            return aiderStatus(settings: settings)
        case .roo:
            return rooStatus(settings: settings)
        }
    }

    public func install(_ id: AgentIntegrationID, settings: CursorAPISettings) throws {
        switch id {
        case .opencode:
            try installOpenCode(settings: settings)
        case .codex:
            try installCodex(settings: settings)
        case .vscode:
            try installVSCode(settings: settings)
        case .cline:
            try installCline(settings: settings)
        case .kilo:
            try installKilo(settings: settings)
        case .pi:
            try installPi(settings: settings)
        case .factory:
            try installFactory(settings: settings)
        case .continueDev:
            try installContinue(settings: settings)
        case .aider:
            try installAider(settings: settings)
        case .roo:
            try installRoo(settings: settings)
        }
    }

    public func installAll(settings: CursorAPISettings) throws -> [AgentIntegrationStatus] {
        for status in statuses(settings: settings) where status.canInstall && !status.installed {
            try install(status.id, settings: settings)
        }
        return statuses(settings: settings)
    }

    private func opencodeStatus(settings: CursorAPISettings) -> AgentIntegrationStatus {
        let url = opencodeConfigURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return AgentIntegrationStatus(id: .opencode, installed: false, configPath: url.path, detail: "OpenCode config not found")
        }
        let text = fileText(url)
        let installed = opencodeConfigMatches(settings: settings)
        let detail = installed ? "Composer models installed" : providerStatusDetail(text: text, settings: settings)
        return AgentIntegrationStatus(id: .opencode, installed: installed, configPath: url.path, detail: detail)
    }

    private func installOpenCode(settings: CursorAPISettings) throws {
        let url = opencodeConfigURL()
        var root = try readJSONObject(url, defaultValue: [:])
        var provider = root["provider"] as? [String: Any] ?? [:]
        provider.removeValue(forKey: "cursor")
        provider.removeValue(forKey: "cursorsdk")
        provider["cursorapi"] = [
            "npm": "@ai-sdk/openai-compatible",
            "name": CursorAPIBrand.displayName,
            "options": [
                "baseURL": settings.baseURL.absoluteString,
                "apiKey": "cursor-local"
            ],
            "models": opencodeModelDefinitions()
        ]
        root["provider"] = provider
        if let model = stringValue(root["model"]),
           model.hasPrefix("cursor/") || model.hasPrefix("cursorsdk/") {
            root["model"] = "cursorapi/composer-2.5-fast"
        } else if root["model"] == nil {
            root["model"] = "cursorapi/composer-2.5-fast"
        }
        try writeJSONObject(root, to: url)
    }

    private func codexStatus(settings: CursorAPISettings) -> AgentIntegrationStatus {
        let url = codexConfigURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return AgentIntegrationStatus(id: .codex, installed: false, configPath: url.path, detail: "Codex config not found")
        }
        let text = fileText(url)
        let installed = codexConfigMatches(text, settings: settings)
        let detail = installed ? "Custom provider installed" : providerStatusDetail(text: text, settings: settings)
        return AgentIntegrationStatus(id: .codex, installed: installed, configPath: url.path, detail: detail)
    }

    private func installCodex(settings: CursorAPISettings) throws {
        let url = codexConfigURL()
        try ensureParentDirectory(url)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let block = """

        [model_providers.cursorapi]
        name = "\(CursorAPIBrand.displayName)"
        base_url = "\(settings.baseURL.absoluteString)"
        wire_api = "responses"

        [model_providers.cursorapi.auth]
        command = "/bin/echo"
        args = ["cursor-local"]
        refresh_interval_ms = 300000
        """
        text = replaceTOMLBlock(named: "model_providers.cursorapi.auth", in: text, replacement: "")
        text = replaceTOMLBlock(named: "model_providers.cursorapi", in: text, replacement: "")
        text = replaceTOMLBlock(named: "profiles.cursorapi", in: text, replacement: "")
        text = replaceTOMLBlock(named: "profiles.cursorapi-fast", in: text, replacement: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            text += "\n"
        }
        text += block.trimmingCharacters(in: .whitespacesAndNewlines)
        text += "\n"
        try writeText(text, to: url)
        try writeCodexProfile(name: "cursorapi", model: "composer-2.5")
        try writeCodexProfile(name: "cursorapi-fast", model: "composer-2.5-fast")
    }

    private func writeCodexProfile(name: String, model: String) throws {
        let text = """
        model_provider = "cursorapi"
        model = "\(model)"
        """
        try writeText(text + "\n", to: codexProfileConfigURL(name))
    }

    private func vscodeStatus(settings: CursorAPISettings) -> AgentIntegrationStatus {
        let url = vscodeLanguageModelsURL()
        if let installedURL = vscodeLanguageModelsURLs().first(where: { vscodeConfigMatches($0, settings: settings) }) {
            return AgentIntegrationStatus(id: .vscode, installed: true, configPath: installedURL.path, detail: "Model metadata installed")
        }
        guard fileManager.fileExists(atPath: url.path) else {
            return AgentIntegrationStatus(id: .vscode, installed: false, configPath: url.path, detail: "VS Code chatLanguageModels.json not found")
        }
        let text = fileText(url)
        return AgentIntegrationStatus(id: .vscode, installed: false, configPath: url.path, detail: providerStatusDetail(text: text, settings: settings))
    }

    private func installVSCode(settings: CursorAPISettings) throws {
        let url = vscodeLanguageModelsURL()
        var array = try readJSONArray(url, defaultValue: [])
        array.removeAll { item in
            guard let record = item as? [String: Any] else { return false }
            let name = record["name"] as? String
            return name == "CursorAPI" || name == CursorAPIBrand.displayName
        }
        array.append([
            "name": CursorAPIBrand.displayName,
            "provider": "openai-compatible",
            "baseUrl": settings.baseURL.absoluteString,
            "models": ["composer-2.5", "composer-2.5-fast"]
        ])
        try writeJSONValue(array, to: url)
    }

    private func extensionStatus(id: AgentIntegrationID, settings: CursorAPISettings) -> AgentIntegrationStatus {
        if id == .cline {
            let url = clineGlobalStateURL()
            let installed = clineConfigMatches(settings: settings)
            let detail = installed ? "Provider profile installed" : providerStatusDetail(text: fileText(url), settings: settings)
            return AgentIntegrationStatus(id: id, installed: installed, configPath: url.path, detail: detail)
        }
        if id == .kilo {
            let url = kiloConfigURL()
            let installed = kiloConfigMatches(settings: settings)
            let detail = installed ? "Provider profile installed" : providerStatusDetail(text: fileText(url), settings: settings)
            return AgentIntegrationStatus(id: id, installed: installed, configPath: url.path, detail: detail)
        }
        let roots = vscodeExtensionStateRoots(for: id)
        let existing = roots.first { fileManager.fileExists(atPath: $0.path) }
        guard let existing else {
            return AgentIntegrationStatus(id: id, installed: false, configPath: nil, detail: "Extension state not found", canInstall: false)
        }
        let installed = directoryContains(existing, needle: settings.baseURL.absoluteString)
        return AgentIntegrationStatus(id: id, installed: installed, configPath: existing.path, detail: installed ? "Local provider detected" : "Detected; configure through extension UI", canInstall: false)
    }

    private func piStatus(settings: CursorAPISettings) -> AgentIntegrationStatus {
        let url = piModelsURL()
        let installed = piConfigMatches(settings: settings)
        let detail = installed ? "Custom models installed" : providerStatusDetail(text: fileText(url), settings: settings)
        return AgentIntegrationStatus(id: .pi, installed: installed, configPath: url.path, detail: detail)
    }

    private func factoryStatus(settings: CursorAPISettings) -> AgentIntegrationStatus {
        let url = factorySettingsURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return AgentIntegrationStatus(id: .factory, installed: false, configPath: url.path, detail: "Factory settings not found")
        }
        let installed = factoryConfigMatches(settings: settings)
        let detail = installed ? "Custom models installed" : providerStatusDetail(text: fileText(url), settings: settings)
        return AgentIntegrationStatus(id: .factory, installed: installed, configPath: url.path, detail: detail)
    }

    private func installFactory(settings: CursorAPISettings) throws {
        let url = factorySettingsURL()
        var root = try readJSONObject(url, defaultValue: [:])
        var models = (root["customModels"] as? [[String: Any]]) ?? []
        models.removeAll { item in
            guard let id = item["id"] as? String else { return false }
            return id.hasPrefix(Self.factoryModelIDPrefix)
        }
        for entry in factoryModelEntries(settings: settings) {
            var entry = entry
            entry["index"] = models.count
            models.append(entry)
        }
        root["customModels"] = models
        try writeJSONObject(root, to: url)
    }

    private func factoryConfigMatches(settings: CursorAPISettings) -> Bool {
        let url = factorySettingsURL()
        guard fileManager.fileExists(atPath: url.path),
              let root = try? readJSONObject(url, defaultValue: [:]),
              let models = root["customModels"] as? [[String: Any]] else {
            return false
        }
        return ComposerModels.all.allSatisfy { model in
            models.contains { factoryModelEntryMatches($0, model: model, settings: settings) }
        }
    }

    private func factoryModelEntryMatches(_ entry: [String: Any], model: ComposerModel, settings: CursorAPISettings) -> Bool {
        stringValue(entry["id"]) == "\(Self.factoryModelIDPrefix)\(model.id)"
            && stringValue(entry["model"]) == model.id
            && stringValue(entry["baseUrl"]) == settings.baseURL.absoluteString
            && stringValue(entry["apiKey"]) == "cursor-local"
            && stringValue(entry["provider"]) == "generic-chat-completion-api"
            && stringValue(entry["displayName"]) == "\(CursorAPIBrand.displayName): \(model.name)"
            && intValue(entry["maxOutputTokens"]) == model.outputLimit
            && boolValue(entry["noImageSupport"]) == false
    }

    private func factoryModelEntries(settings: CursorAPISettings) -> [[String: Any]] {
        ComposerModels.all.map { model in
            [
                "model": model.id,
                "id": "\(Self.factoryModelIDPrefix)\(model.id)",
                "baseUrl": settings.baseURL.absoluteString,
                "apiKey": "cursor-local",
                "displayName": "\(CursorAPIBrand.displayName): \(model.name)",
                "maxOutputTokens": model.outputLimit,
                "noImageSupport": false,
                "provider": "generic-chat-completion-api"
            ]
        }
    }

    private func continueStatus(settings: CursorAPISettings) -> AgentIntegrationStatus {
        let url = continueConfigURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return AgentIntegrationStatus(id: .continueDev, installed: false, configPath: url.path, detail: "Continue config not found")
        }
        let text = fileText(url)
        let installed = continueConfigMatches(text, settings: settings)
        let detail = installed
            ? "Composer models installed"
            : continueProviderStatusDetail(text: text, settings: settings)
        return AgentIntegrationStatus(id: .continueDev, installed: installed, configPath: url.path, detail: detail)
    }

    private func aiderStatus(settings: CursorAPISettings) -> AgentIntegrationStatus {
        let url = aiderConfigURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return AgentIntegrationStatus(id: .aider, installed: false, configPath: url.path, detail: "Aider config not found")
        }
        let text = fileText(url)
        let installed = aiderConfigMatches(text, settings: settings)
            && aiderModelMetadataMatches(settings: settings)
            && aiderModelSettingsMatches(settings: settings)
        let detail = installed ? "OpenAI-compatible provider installed" : providerStatusDetail(text: text, settings: settings)
        return AgentIntegrationStatus(id: .aider, installed: installed, configPath: url.path, detail: detail)
    }

    private func rooStatus(settings: CursorAPISettings) -> AgentIntegrationStatus {
        let importURL = rooImportSettingsURL()
        let settingsURL = rooAutoImportSettingsURL() ?? selectedVSCodeProfile().settingsURL(homeDirectory: homeDirectory)
        let importMatches = rooImportSettingsMatches(settings: settings)
        let autoImportMatches = rooAutoImportSettingsURL() != nil

        if importMatches && autoImportMatches {
            return AgentIntegrationStatus(id: .roo, installed: true, configPath: importURL.path, detail: "Auto-import profile installed")
        }

        let text = fileText(importURL) + "\n" + vscodeSettingsURLs().map(fileText).joined(separator: "\n")
        let detail: String
        if !fileManager.fileExists(atPath: importURL.path) {
            detail = "Roo Code auto-import profile not found"
        } else if importMatches {
            detail = "Roo Code auto-import setting not configured"
        } else {
            detail = providerStatusDetail(text: text, settings: settings)
        }
        return AgentIntegrationStatus(id: .roo, installed: false, configPath: settingsURL.path, detail: detail)
    }

    private func codexConfigMatches(_ text: String, settings: CursorAPISettings) -> Bool {
        text.contains("[model_providers.cursorapi]")
            && text.contains("name = \"\(CursorAPIBrand.displayName)\"")
            && text.contains("base_url = \"\(settings.baseURL.absoluteString)\"")
            && text.contains("wire_api = \"responses\"")
            && text.contains("[model_providers.cursorapi.auth]")
            && text.contains("command = \"/bin/echo\"")
            && text.contains("args = [\"cursor-local\"]")
            && codexProfileConfigMatches(name: "cursorapi", model: "composer-2.5")
            && codexProfileConfigMatches(name: "cursorapi-fast", model: "composer-2.5-fast")
    }

    private func codexProfileConfigMatches(name: String, model: String) -> Bool {
        let text = fileText(codexProfileConfigURL(name))
        return text.contains("model_provider = \"cursorapi\"")
            && text.contains("model = \"\(model)\"")
    }

    private func vscodeConfigMatches(_ url: URL, settings: CursorAPISettings) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let array = try? readJSONArray(url, defaultValue: []) else {
            return false
        }
        return array.contains { item in
            guard let record = item as? [String: Any],
                  stringValue(record["name"]) == CursorAPIBrand.displayName,
                  stringValue(record["provider"]) == "openai-compatible",
                  stringValue(record["baseUrl"]) == settings.baseURL.absoluteString,
                  let models = record["models"] as? [String] else {
                return false
            }
            return Set(models).isSuperset(of: Set(ComposerModels.all.map(\.id)))
        }
    }

    private func opencodeConfigMatches(settings: CursorAPISettings) -> Bool {
        let url = opencodeConfigURL()
        guard fileManager.fileExists(atPath: url.path),
              let root = try? readJSONObject(url, defaultValue: [:]),
              let providers = root["provider"] as? [String: Any],
              let provider = providers["cursorapi"] as? [String: Any] else {
            return false
        }
        return localProviderMatches(provider, settings: settings)
    }

    private func clineConfigMatches(settings: CursorAPISettings) -> Bool {
        let globalStateURL = clineGlobalStateURL()
        let secretsURL = clineSecretsURL()
        guard fileManager.fileExists(atPath: globalStateURL.path),
              let globalState = try? readJSONObject(globalStateURL, defaultValue: [:]) else {
            return false
        }
        return globalState["actModeApiProvider"] as? String == "openai"
            && globalState["planModeApiProvider"] as? String == "openai"
            && globalState["actModeOpenAiModelId"] as? String == "composer-2.5"
            && globalState["planModeOpenAiModelId"] as? String == "composer-2.5-fast"
            && globalState["openAiBaseUrl"] as? String == settings.baseURL.absoluteString
            && clineModelInfoMatches(globalState["actModeOpenAiModelInfo"], model: ComposerModels.all[0])
            && clineModelInfoMatches(globalState["planModeOpenAiModelInfo"], model: ComposerModels.all[1])
            && jsonFileContains(secretsURL, needle: "cursor-local")
    }

    private func kiloConfigMatches(settings: CursorAPISettings) -> Bool {
        let url = kiloConfigURL()
        guard fileManager.fileExists(atPath: url.path),
              let root = try? readJSONObject(url, defaultValue: [:]),
              let providers = root["provider"] as? [String: Any],
              let provider = providers["cursorapi"] as? [String: Any] else {
            return false
        }
        return localProviderMatches(provider, settings: settings)
    }

    private func piConfigMatches(settings: CursorAPISettings) -> Bool {
        let url = piModelsURL()
        guard fileManager.fileExists(atPath: url.path),
              let root = try? readJSONObject(url, defaultValue: [:]),
              let providers = root["providers"] as? [String: Any],
              let provider = providers["cursorapi"] as? [String: Any],
              stringValue(provider["baseUrl"]) == settings.baseURL.absoluteString,
              stringValue(provider["apiKey"]) == "cursor-local",
              boolValue(provider["authHeader"]) == true,
              stringValue(provider["api"]) == "openai-completions",
              let models = provider["models"] as? [[String: Any]] else {
            return false
        }
        return ComposerModels.all.allSatisfy { model in
            models.contains { piModelDefinitionMatches($0, model: model) }
        }
    }

    private func continueConfigMatches(_ text: String, settings: CursorAPISettings) -> Bool {
        text.contains(Self.continueBlockStart)
            && text.contains(Self.continueBlockEnd)
            && text.contains("provider: openai")
            && text.contains("apiBase: \(settings.baseURL.absoluteString)")
            && text.contains("apiKey: cursor-local")
            && ComposerModels.all.allSatisfy { model in
                text.contains("name: \(model.name)")
                    && text.contains("model: \(model.id)")
            }
    }

    private func aiderConfigMatches(_ text: String, settings: CursorAPISettings) -> Bool {
        topLevelYAMLValue("model", in: text) == "openai/composer-2.5"
            && topLevelYAMLValue("weak-model", in: text) == "openai/composer-2.5-fast"
            && topLevelYAMLValue("editor-model", in: text) == "openai/composer-2.5-fast"
            && topLevelYAMLValue("openai-api-base", in: text) == settings.baseURL.absoluteString
            && topLevelYAMLValue("openai-api-key", in: text) == "cursor-local"
            && topLevelYAMLValue("model-settings-file", in: text) == aiderModelSettingsURL().path
            && topLevelYAMLValue("model-metadata-file", in: text) == aiderModelMetadataURL().path
            && topLevelYAMLValue("show-model-warnings", in: text)?.lowercased() == "false"
            && topLevelYAMLValue("check-model-accepts-settings", in: text)?.lowercased() == "false"
    }

    private func aiderModelMetadataMatches(settings: CursorAPISettings) -> Bool {
        let url = aiderModelMetadataURL()
        guard fileManager.fileExists(atPath: url.path),
              let root = try? readJSONObject(url, defaultValue: [:]) else {
            return false
        }
        return ComposerModels.all.allSatisfy { model in
            guard let metadata = root["openai/\(model.id)"] as? [String: Any] else {
                return false
            }
            return stringValue(metadata["litellm_provider"]) == "openai"
                && stringValue(metadata["mode"]) == "chat"
                && intValue(metadata["max_tokens"]) == model.outputLimit
                && intValue(metadata["max_input_tokens"]) == model.contextWindow
                && intValue(metadata["max_output_tokens"]) == model.outputLimit
                && doubleValue(metadata["input_cost_per_token"]) == model.inputCost / 1_000_000
                && doubleValue(metadata["output_cost_per_token"]) == model.outputCost / 1_000_000
        }
    }

    private func aiderModelSettingsMatches(settings: CursorAPISettings) -> Bool {
        let text = fileText(aiderModelSettingsURL())
        return text.contains(Self.aiderSettingsBlockStart)
            && text.contains(Self.aiderSettingsBlockEnd)
            && ComposerModels.all.allSatisfy { model in
                text.contains("- name: openai/\(model.id)")
                    && text.contains("edit_format: diff")
                    && text.contains("weak_model_name: openai/composer-2.5-fast")
                    && text.contains("editor_model_name: openai/composer-2.5-fast")
                    && text.contains("editor_edit_format: editor-diff")
                    && text.contains("use_repo_map: true")
                    && text.contains("use_temperature: false")
            }
    }

    private func rooImportSettingsMatches(settings: CursorAPISettings) -> Bool {
        let url = rooImportSettingsURL()
        guard fileManager.fileExists(atPath: url.path),
              let root = try? readJSONObject(url, defaultValue: [:]),
              let providerProfiles = root["providerProfiles"] as? [String: Any],
              stringValue(providerProfiles["currentApiConfigName"]) == Self.rooProfileName,
              let apiConfigs = providerProfiles["apiConfigs"] as? [String: Any],
              let primary = apiConfigs[Self.rooProfileName] as? [String: Any],
              let fast = apiConfigs[Self.rooFastProfileName] as? [String: Any],
              let modeApiConfigs = providerProfiles["modeApiConfigs"] as? [String: Any] else {
            return false
        }

        let primaryModel = ComposerModels.all[0]
        let fastModel = ComposerModels.all[1]
        return rooProfileMatches(primary, model: primaryModel, id: Self.rooProfileID, settings: settings)
            && rooProfileMatches(fast, model: fastModel, id: Self.rooFastProfileID, settings: settings)
            && stringValue(modeApiConfigs["architect"]) == Self.rooProfileID
            && stringValue(modeApiConfigs["code"]) == Self.rooProfileID
            && stringValue(modeApiConfigs["ask"]) == Self.rooFastProfileID
            && stringValue(modeApiConfigs["debug"]) == Self.rooProfileID
            && stringValue(modeApiConfigs["orchestrator"]) == Self.rooProfileID
    }

    private func rooProfileMatches(_ profile: [String: Any], model: ComposerModel, id: String, settings: CursorAPISettings) -> Bool {
        guard stringValue(profile["id"]) == id,
              stringValue(profile["apiProvider"]) == "openai",
              stringValue(profile["openAiBaseUrl"]) == settings.baseURL.absoluteString,
              stringValue(profile["openAiApiKey"]) == "cursor-local",
              stringValue(profile["openAiModelId"]) == model.id,
              boolValue(profile["openAiStreamingEnabled"]) == true,
              boolValue(profile["includeMaxTokens"]) == true,
              boolValue(profile["todoListEnabled"]) == true,
              intValue(profile["modelMaxTokens"]) == model.outputLimit,
              intValue(profile["consecutiveMistakeLimit"]) == 3,
              let info = profile["openAiCustomModelInfo"] as? [String: Any] else {
            return false
        }
        return rooModelInfoMatches(info, model: model)
    }

    private func installCline(settings: CursorAPISettings) throws {
        let globalStateURL = clineGlobalStateURL()
        var globalState = try readJSONObject(globalStateURL, defaultValue: [:])
        globalState["actModeApiProvider"] = "openai"
        globalState["planModeApiProvider"] = "openai"
        globalState["actModeOpenAiModelId"] = "composer-2.5"
        globalState["planModeOpenAiModelId"] = "composer-2.5-fast"
        globalState["actModeOpenAiModelInfo"] = clineModelInfo(for: "composer-2.5")
        globalState["planModeOpenAiModelInfo"] = clineModelInfo(for: "composer-2.5-fast")
        globalState["openAiHeaders"] = [String: String]()
        globalState["openAiBaseUrl"] = settings.baseURL.absoluteString
        globalState["welcomeViewCompleted"] = true
        if globalState["remoteRulesToggles"] == nil {
            globalState["remoteRulesToggles"] = [:]
        }
        if globalState["remoteWorkflowToggles"] == nil {
            globalState["remoteWorkflowToggles"] = [:]
        }
        try writeJSONObject(globalState, to: globalStateURL)

        let secretsURL = clineSecretsURL()
        var secrets = try readJSONObject(secretsURL, defaultValue: [:])
        secrets["openAiApiKey"] = "cursor-local"
        try writeJSONObject(secrets, to: secretsURL)
    }

    private func clineModelInfo(for id: String) -> [String: Any] {
        let model = ComposerModels.model(for: id) ?? ComposerModels.all[0]
        return [
            "maxTokens": model.outputLimit,
            "contextWindow": model.contextWindow,
            "supportsImages": true,
            "supportsPromptCache": false,
            "inputPrice": model.inputCost,
            "outputPrice": model.outputCost,
            "temperature": 0,
            "supportsTools": true,
            "supportsStreaming": true,
            "systemRole": "system"
        ]
    }

    private func installKilo(settings: CursorAPISettings) throws {
        let url = kiloConfigURL()
        var root = try readJSONObject(url, defaultValue: ["$schema": "https://app.kilo.ai/config.json"])
        var provider = root["provider"] as? [String: Any] ?? [:]
        provider["cursorapi"] = [
            "options": [
                "baseURL": settings.baseURL.absoluteString,
                "apiKey": "cursor-local"
            ],
            "models": [
                "composer-2.5": agentModelDefinition(ComposerModels.all[0]),
                "composer-2.5-fast": agentModelDefinition(ComposerModels.all[1])
            ]
        ]
        root["provider"] = provider
        if root["model"] == nil {
            root["model"] = "cursorapi/composer-2.5"
        }
        try writeJSONObject(root, to: url)
    }

    private func installPi(settings: CursorAPISettings) throws {
        let url = piModelsURL()
        var root = try readJSONObject(url, defaultValue: ["providers": [:]])
        var providers = root["providers"] as? [String: Any] ?? [:]
        providers["cursorapi"] = [
            "baseUrl": settings.baseURL.absoluteString,
            "apiKey": "cursor-local",
            "authHeader": true,
            "api": "openai-completions",
            "models": piModelDefinitions()
        ]
        root["providers"] = providers
        try writeJSONObject(root, to: url)
    }

    private func installContinue(settings: CursorAPISettings) throws {
        let url = continueConfigURL()
        var text = removeMarkedContinueBlock(from: fileText(url))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let blockLines = continueModelsBlock(settings: settings).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let modelsIndex = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "models:" && !line.hasPrefix(" ") && !line.hasPrefix("\t")
        }) {
            lines.insert(contentsOf: blockLines, at: modelsIndex + 1)
            text = lines.joined(separator: "\n")
        } else {
            if !text.isEmpty {
                text += "\n\n"
            }
            text += "models:\n"
            text += continueModelsBlock(settings: settings)
        }
        if !text.hasSuffix("\n") {
            text += "\n"
        }
        try writeText(text, to: url)
    }

    private func installAider(settings: CursorAPISettings) throws {
        try installAiderModelMetadata()
        try installAiderModelSettings()

        let url = aiderConfigURL()
        var text = removeMarkedAiderBlock(from: fileText(url))
        text = removeTopLevelYAMLKeys(
            [
                "model",
                "weak-model",
                "editor-model",
                "openai-api-base",
                "openai-api-key",
                "model-settings-file",
                "model-metadata-file",
                "show-model-warnings",
                "check-model-accepts-settings"
            ],
            from: text
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if !text.isEmpty {
            text += "\n\n"
        }
        text += aiderConfigBlock(settings: settings)
        text += "\n"
        try writeText(text, to: url)
    }

    private func installAiderModelMetadata() throws {
        let url = aiderModelMetadataURL()
        var root = try readJSONObject(url, defaultValue: [:])
        for model in ComposerModels.all {
            root["openai/\(model.id)"] = [
                "max_tokens": model.outputLimit,
                "max_input_tokens": model.contextWindow,
                "max_output_tokens": model.outputLimit,
                "input_cost_per_token": model.inputCost / 1_000_000,
                "output_cost_per_token": model.outputCost / 1_000_000,
                "litellm_provider": "openai",
                "mode": "chat"
            ]
        }
        try writeJSONObject(root, to: url)
    }

    private func installAiderModelSettings() throws {
        let url = aiderModelSettingsURL()
        let names = Set(ComposerModels.all.map { "openai/\($0.id)" })
        var text = removeMarkedAiderSettingsBlock(from: fileText(url))
        text = removeTopLevelYAMLListItems(named: names, from: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            text += "\n\n"
        }
        text += aiderModelSettingsBlock()
        text += "\n"
        try writeText(text, to: url)
    }

    private func installRoo(settings: CursorAPISettings) throws {
        try writeJSONObject(rooImportSettings(settings: settings), to: rooImportSettingsURL())

        let settingsURL = rooAutoImportSettingsURL() ?? selectedVSCodeProfile().settingsURL(homeDirectory: homeDirectory)
        var vscodeSettings = try readJSONObject(settingsURL, defaultValue: [:])
        vscodeSettings["roo-cline.autoImportSettingsPath"] = rooImportSettingsURL().path
        try writeJSONObject(vscodeSettings, to: settingsURL)
    }

    private func opencodeConfigURL() -> URL {
        configHomeDirectory().appending(path: "opencode/opencode.json")
    }

    private func codexConfigURL() -> URL {
        homeDirectory.appending(path: ".codex/config.toml")
    }

    private func codexProfileConfigURL(_ name: String) -> URL {
        homeDirectory.appending(path: ".codex/\(name).config.toml")
    }

    private func vscodeLanguageModelsURL() -> URL {
        selectedVSCodeProfile().languageModelsURL(homeDirectory: homeDirectory)
    }

    private func vscodeLanguageModelsURLs() -> [URL] {
        vscodeProfiles().map { $0.languageModelsURL(homeDirectory: homeDirectory) }
    }

    private func vscodeSettingsURLs() -> [URL] {
        vscodeProfiles().map { $0.settingsURL(homeDirectory: homeDirectory) }
    }

    private func rooAutoImportSettingsURL() -> URL? {
        vscodeSettingsURLs().first { url in
            guard fileManager.fileExists(atPath: url.path),
                  let settings = try? readJSONObject(url, defaultValue: [:]) else {
                return false
            }
            return stringValue(settings["roo-cline.autoImportSettingsPath"]) == rooImportSettingsURL().path
        }
    }

    private func selectedVSCodeProfile() -> VSCodeUserDataProfile {
        let profiles = vscodeProfiles()
        if let profile = profiles.first(where: { fileManager.fileExists(atPath: $0.languageModelsURL(homeDirectory: homeDirectory).path) }) {
            return profile
        }
        if let profile = profiles.first(where: { fileManager.fileExists(atPath: $0.settingsURL(homeDirectory: homeDirectory).path) }) {
            return profile
        }
        if let profile = profiles.first(where: { fileManager.fileExists(atPath: $0.userDirectory(homeDirectory: homeDirectory).path) }) {
            return profile
        }
        if let profile = profiles.first(where: { fileManager.fileExists(atPath: $0.applicationSupportDirectory(homeDirectory: homeDirectory).path) }) {
            return profile
        }
        return profiles[0]
    }

    private func vscodeProfiles() -> [VSCodeUserDataProfile] {
        [
            VSCodeUserDataProfile(applicationSupportName: "Code"),
            VSCodeUserDataProfile(applicationSupportName: "Code - Insiders"),
            VSCodeUserDataProfile(applicationSupportName: "VSCodium"),
            VSCodeUserDataProfile(applicationSupportName: "Cursor"),
            VSCodeUserDataProfile(applicationSupportName: "Windsurf")
        ]
    }

    private func clineGlobalStateURL() -> URL {
        homeDirectory.appending(path: ".cline/data/globalState.json")
    }

    private func clineSecretsURL() -> URL {
        homeDirectory.appending(path: ".cline/data/secrets.json")
    }

    private func kiloConfigURL() -> URL {
        configHomeDirectory().appending(path: "kilo/kilo.jsonc")
    }

    private func piModelsURL() -> URL {
        homeDirectory.appending(path: ".pi/agent/models.json")
    }

    private func factorySettingsURL() -> URL {
        homeDirectory.appending(path: ".factory/settings.json")
    }

    private func continueConfigURL() -> URL {
        homeDirectory.appending(path: ".continue/config.yaml")
    }

    private func aiderConfigURL() -> URL {
        homeDirectory.appending(path: ".aider.conf.yml")
    }

    private func aiderModelMetadataURL() -> URL {
        homeDirectory.appending(path: ".aider.model.metadata.json")
    }

    private func aiderModelSettingsURL() -> URL {
        homeDirectory.appending(path: ".aider.model.settings.yml")
    }

    private func rooImportSettingsURL() -> URL {
        configHomeDirectory().appending(path: "api-for-cursor/roo-code-settings.json")
    }

    private func configHomeDirectory() -> URL {
        if let value = environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty,
           value.hasPrefix("/") {
            return URL(fileURLWithPath: value)
        }
        return homeDirectory.appending(path: ".config")
    }

    private func piModelDefinitions() -> [[String: Any]] {
        ComposerModels.all.map { model in
            var definition = agentModelDefinition(model)
            definition["id"] = model.id
            definition["api"] = "openai-completions"
            definition["reasoning"] = false
            definition["input"] = ["text"]
            definition["contextWindow"] = model.contextWindow
            definition["maxTokens"] = model.outputLimit
            definition["cost"] = [
                "input": model.inputCost,
                "output": model.outputCost,
                "cacheRead": 0,
                "cacheWrite": 0
            ]
            definition["compat"] = [
                "supportsUsageInStreaming": true,
                "maxTokensField": "max_tokens",
                "requiresAssistantAfterToolResult": false
            ]
            return definition
        }
    }

    private func opencodeModelDefinitions() -> [String: Any] {
        Dictionary(uniqueKeysWithValues: ComposerModels.all.map { model in
            (model.id, agentModelDefinition(model))
        })
    }

    private func agentModelDefinition(_ model: ComposerModel) -> [String: Any] {
        [
            "name": model.name,
            "cost": [
                "input": model.inputCost,
                "output": model.outputCost
            ],
            "limit": [
                "context": model.contextWindow,
                "output": model.outputLimit
            ]
        ]
    }

    private func continueModelsBlock(settings: CursorAPISettings) -> String {
        var lines = [
            "  \(Self.continueBlockStart)"
        ]
        for model in ComposerModels.all {
            lines.append(contentsOf: [
                "  - name: \(model.name)",
                "    provider: openai",
                "    model: \(model.id)",
                "    apiBase: \(settings.baseURL.absoluteString)",
                "    apiKey: cursor-local",
                "    roles:",
                "      - chat",
                "      - edit",
                "      - apply",
                "    capabilities:",
                "      - tool_use",
                "      - image_input"
            ])
        }
        lines.append("  \(Self.continueBlockEnd)")
        return lines.joined(separator: "\n")
    }

    private func aiderConfigBlock(settings: CursorAPISettings) -> String {
        [
            Self.aiderBlockStart,
            "model: openai/composer-2.5",
            "weak-model: openai/composer-2.5-fast",
            "editor-model: openai/composer-2.5-fast",
            "openai-api-base: \(settings.baseURL.absoluteString)",
            "openai-api-key: cursor-local",
            "model-settings-file: \(yamlQuoted(aiderModelSettingsURL().path))",
            "model-metadata-file: \(yamlQuoted(aiderModelMetadataURL().path))",
            "show-model-warnings: false",
            "check-model-accepts-settings: false",
            Self.aiderBlockEnd
        ].joined(separator: "\n")
    }

    private func aiderModelSettingsBlock() -> String {
        var lines = [Self.aiderSettingsBlockStart]
        for model in ComposerModels.all {
            lines.append(contentsOf: [
                "- name: openai/\(model.id)",
                "  edit_format: diff",
                "  weak_model_name: openai/composer-2.5-fast",
                "  editor_model_name: openai/composer-2.5-fast",
                "  editor_edit_format: editor-diff",
                "  use_repo_map: true",
                "  use_temperature: false"
            ])
        }
        lines.append(Self.aiderSettingsBlockEnd)
        return lines.joined(separator: "\n")
    }

    private func rooImportSettings(settings: CursorAPISettings) -> [String: Any] {
        let primaryModel = ComposerModels.all[0]
        let fastModel = ComposerModels.all[1]
        return [
            "providerProfiles": [
                "currentApiConfigName": Self.rooProfileName,
                "apiConfigs": [
                    Self.rooProfileName: rooProfile(for: primaryModel, id: Self.rooProfileID, settings: settings),
                    Self.rooFastProfileName: rooProfile(for: fastModel, id: Self.rooFastProfileID, settings: settings)
                ],
                "modeApiConfigs": [
                    "architect": Self.rooProfileID,
                    "code": Self.rooProfileID,
                    "ask": Self.rooFastProfileID,
                    "debug": Self.rooProfileID,
                    "orchestrator": Self.rooProfileID
                ]
            ],
            "globalSettings": [
                "mode": "code"
            ]
        ]
    }

    private func rooProfile(for model: ComposerModel, id: String, settings: CursorAPISettings) -> [String: Any] {
        [
            "id": id,
            "apiProvider": "openai",
            "openAiBaseUrl": settings.baseURL.absoluteString,
            "openAiApiKey": "cursor-local",
            "openAiModelId": model.id,
            "openAiStreamingEnabled": true,
            "includeMaxTokens": true,
            "modelMaxTokens": model.outputLimit,
            "consecutiveMistakeLimit": 3,
            "todoListEnabled": true,
            "openAiCustomModelInfo": rooModelInfo(for: model)
        ]
    }

    private func rooModelInfo(for model: ComposerModel) -> [String: Any] {
        [
            "maxTokens": model.outputLimit,
            "contextWindow": model.contextWindow,
            "supportsImages": true,
            "supportsPromptCache": false,
            "supportsTools": true,
            "supportsStreaming": true,
            "supportsTemperature": false,
            "inputPrice": model.inputCost,
            "outputPrice": model.outputCost
        ]
    }

    private func rooModelInfoMatches(_ info: [String: Any], model: ComposerModel) -> Bool {
        intValue(info["maxTokens"]) == model.outputLimit
            && intValue(info["contextWindow"]) == model.contextWindow
            && boolValue(info["supportsImages"]) == true
            && boolValue(info["supportsPromptCache"]) == false
            && boolValue(info["supportsTools"]) == true
            && boolValue(info["supportsStreaming"]) == true
            && boolValue(info["supportsTemperature"]) == false
            && doubleValue(info["inputPrice"]) == model.inputCost
            && doubleValue(info["outputPrice"]) == model.outputCost
    }

    private func removeMarkedContinueBlock(from text: String) -> String {
        removeMarkedBlock(from: text, start: Self.continueBlockStart, end: Self.continueBlockEnd)
    }

    private func removeMarkedAiderBlock(from text: String) -> String {
        removeMarkedBlock(from: text, start: Self.aiderBlockStart, end: Self.aiderBlockEnd)
    }

    private func removeMarkedAiderSettingsBlock(from text: String) -> String {
        removeMarkedBlock(from: text, start: Self.aiderSettingsBlockStart, end: Self.aiderSettingsBlockEnd)
    }

    private func removeMarkedBlock(from text: String, start: String, end: String) -> String {
        var output: [String] = []
        var skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == start {
                skipping = true
                continue
            }
            if trimmed == end {
                skipping = false
                continue
            }
            if !skipping {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }

    private func removeTopLevelYAMLKeys(_ keys: Set<String>, from text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      !trimmed.hasPrefix("#"),
                      !line.hasPrefix(" "),
                      !line.hasPrefix("\t"),
                      let colon = trimmed.firstIndex(of: ":") else {
                    return true
                }
                let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                return !keys.contains(key)
            }
            .joined(separator: "\n")
    }

    private func removeTopLevelYAMLListItems(named names: Set<String>, from text: String) -> String {
        var output: [String] = []
        var skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let startsItem = !line.hasPrefix(" ") && !line.hasPrefix("\t") && trimmed.hasPrefix("- ")
            if startsItem {
                skipping = false
                if let name = yamlListItemName(trimmed), names.contains(name) {
                    skipping = true
                    continue
                }
            }
            if !skipping {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }

    private func yamlListItemName(_ trimmedLine: String) -> String? {
        let prefix = "- name:"
        guard trimmedLine.hasPrefix(prefix) else {
            return nil
        }
        let value = String(trimmedLine.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return unquotedYAMLScalar(value)
    }

    private func topLevelYAMLValue(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"),
                  !line.hasPrefix(" "),
                  !line.hasPrefix("\t"),
                  let colon = trimmed.firstIndex(of: ":") else {
                continue
            }
            let currentKey = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            guard currentKey == key else { continue }
            let rawValue = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return unquotedYAMLScalar(rawValue)
        }
        return nil
    }

    private func unquotedYAMLScalar(_ value: String) -> String {
        var value = value
        if let comment = value.range(of: " #") {
            value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.count >= 2,
           let first = value.first,
           let last = value.last,
           (first == "\"" && last == "\"" || first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func localProviderMatches(_ provider: [String: Any], settings: CursorAPISettings) -> Bool {
        guard let options = provider["options"] as? [String: Any],
              stringValue(options["baseURL"]) == settings.baseURL.absoluteString,
              stringValue(options["apiKey"]) == "cursor-local",
              let models = provider["models"] as? [String: Any] else {
            return false
        }
        return ComposerModels.all.allSatisfy { model in
            modelDefinitionMatches(models[model.id], model: model)
        }
    }

    private func modelDefinitionMatches(_ value: Any?, model: ComposerModel) -> Bool {
        guard let definition = value as? [String: Any],
              stringValue(definition["name"]) == model.name,
              let cost = definition["cost"] as? [String: Any],
              doubleValue(cost["input"]) == model.inputCost,
              doubleValue(cost["output"]) == model.outputCost,
              let limit = definition["limit"] as? [String: Any],
              intValue(limit["context"]) == model.contextWindow,
              intValue(limit["output"]) == model.outputLimit else {
            return false
        }
        return true
    }

    private func piModelDefinitionMatches(_ definition: [String: Any], model: ComposerModel) -> Bool {
        modelDefinitionMatches(definition, model: model)
            && stringValue(definition["id"]) == model.id
            && stringValue(definition["api"]) == "openai-completions"
            && boolValue(definition["reasoning"]) == false
            && intValue(definition["contextWindow"]) == model.contextWindow
            && intValue(definition["maxTokens"]) == model.outputLimit
    }

    private func clineModelInfoMatches(_ value: Any?, model: ComposerModel) -> Bool {
        guard let info = value as? [String: Any] else { return false }
        return intValue(info["maxTokens"]) == model.outputLimit
            && intValue(info["contextWindow"]) == model.contextWindow
            && doubleValue(info["inputPrice"]) == model.inputCost
            && doubleValue(info["outputPrice"]) == model.outputCost
            && boolValue(info["supportsTools"]) == true
            && boolValue(info["supportsStreaming"]) == true
    }

    private func providerStatusDetail(text: String, settings: CursorAPISettings) -> String {
        if text.contains(settings.baseURL.absoluteString) {
            return "Provider needs update"
        }
        if containsHostedCursorAPIURL(text) {
            return "Provider points at a hosted API"
        }
        if text.contains("http://127.0.0.1:") || text.contains("http://localhost:") {
            return "Provider found with a different local URL"
        }
        if text.contains("cursorapi") || text.contains("api-for-cursor") || text.contains(CursorAPIBrand.displayName) || text.contains("CursorAPI") {
            return "Provider found with a different local URL"
        }
        return "Ready to install"
    }

    private func continueProviderStatusDetail(text: String, settings: CursorAPISettings) -> String {
        let detail = providerStatusDetail(text: text, settings: settings)
        if detail != "Ready to install" {
            return detail
        }
        return text.contains(Self.continueBlockStart) ? "Provider found with a different local URL" : detail
    }

    private func containsHostedCursorAPIURL(_ text: String) -> Bool {
        text.contains("cursor-api.standardagents.ai")
            || text.contains("/opencode/v1")
            || text.contains("/opencodev2/v1")
    }

    private func stringValue(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = stringValue(value) {
            return Double(string)
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = stringValue(value) {
            return Int(string)
        }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = stringValue(value)?.lowercased() {
            if ["true", "yes", "1"].contains(string) { return true }
            if ["false", "no", "0"].contains(string) { return false }
        }
        return nil
    }

    private func vscodeExtensionStateRoots(for id: AgentIntegrationID) -> [URL] {
        let base = homeDirectory.appending(path: "Library/Application Support/Code/User/globalStorage")
        switch id {
        case .cline:
            return [
                base.appending(path: "saoudrizwan.claude-dev"),
                base.appending(path: "cline.cline")
            ]
        case .kilo:
            return [
                base.appending(path: "kilocode.kilo-code"),
                base.appending(path: "kilocode.kilo")
            ]
        case .roo:
            return [
                base.appending(path: "rooveterinaryinc.roo-cline"),
                base.appending(path: "roo-cline.roo-cline")
            ]
        default:
            return []
        }
    }

    private func readJSONObject(_ url: URL, defaultValue: [String: Any]) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return defaultValue }
        let value = try readJSONValue(url)
        guard let object = value as? [String: Any] else {
            throw CursorAPIError.badRequest("\(url.lastPathComponent) must contain a JSON object.")
        }
        return object
    }

    private func readJSONArray(_ url: URL, defaultValue: [Any]) throws -> [Any] {
        guard fileManager.fileExists(atPath: url.path) else { return defaultValue }
        let value = try readJSONValue(url)
        guard let array = value as? [Any] else {
            throw CursorAPIError.badRequest("\(url.lastPathComponent) must contain a JSON array.")
        }
        return array
    }

    private func readJSONValue(_ url: URL) throws -> Any {
        let data = try Data(contentsOf: url)
        let raw = String(data: data, encoding: .utf8) ?? ""
        let parseData = Data(stripJSONComments(raw).utf8)
        do {
            return try JSONSerialization.jsonObject(with: parseData)
        } catch {
            throw CursorAPIError.badRequest("Could not parse \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try writeJSONValue(object, to: url)
    }

    private func writeJSONValue(_ value: Any, to url: URL) throws {
        try ensureParentDirectory(url)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try backupIfChanged(url, replacementData: data)
        try data.write(to: url, options: .atomic)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try ensureParentDirectory(url)
        let data = Data(text.utf8)
        try backupIfChanged(url, replacementData: data)
        try data.write(to: url, options: .atomic)
    }

    private func ensureParentDirectory(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private func jsonFileContains(_ url: URL, needle: String) -> Bool {
        guard fileManager.fileExists(atPath: url.path), !needle.isEmpty else { return false }
        return fileText(url).contains(needle)
    }

    private func fileText(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func backupIfChanged(_ url: URL, replacementData: Data) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let current = try Data(contentsOf: url)
        guard current != replacementData else { return }
        let backupURL = backupURL(for: url)
        try fileManager.copyItem(at: url, to: backupURL)
    }

    private func backupURL(for url: URL) -> URL {
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let parent = url.deletingLastPathComponent()
        let baseName = "\(url.lastPathComponent).\(Self.backupMarker).\(stamp)"
        var candidate = parent.appending(path: baseName)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parent.appending(path: "\(baseName).\(index)")
            index += 1
        }
        return candidate
    }

    private func directoryContains(_ url: URL, needle: String) -> Bool {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil), !needle.isEmpty else { return false }
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "json" {
            if jsonFileContains(fileURL, needle: needle) {
                return true
            }
        }
        return false
    }

    private func replaceTOMLBlock(named name: String, in text: String, replacement: String) -> String {
        let section = NSRegularExpression.escapedPattern(for: "[\(name)]")
        let pattern = #"(?ms)^"# + section + #"\n.*?(?=^\[|\z)"#
        return text.replacingOccurrences(of: pattern, with: replacement.isEmpty ? "" : replacement + "\n", options: .regularExpression)
    }

    private func stripJSONComments(_ text: String) -> String {
        var output = ""
        var index = text.startIndex
        var inString = false
        var isEscaped = false
        while index < text.endIndex {
            let character = text[index]
            let nextIndex = text.index(after: index)
            let next = nextIndex < text.endIndex ? text[nextIndex] : nil

            if inString {
                output.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = nextIndex
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                index = nextIndex
                continue
            }

            if character == "/", next == "/" {
                index = text.index(after: nextIndex)
                while index < text.endIndex, text[index] != "\n" {
                    index = text.index(after: index)
                }
                if index < text.endIndex {
                    output.append("\n")
                    index = text.index(after: index)
                }
                continue
            }

            if character == "/", next == "*" {
                index = text.index(after: nextIndex)
                while index < text.endIndex {
                    let closeNext = text.index(after: index)
                    if text[index] == "*", closeNext < text.endIndex, text[closeNext] == "/" {
                        index = text.index(after: closeNext)
                        break
                    }
                    if text[index] == "\n" {
                        output.append("\n")
                    }
                    index = text.index(after: index)
                }
                continue
            }

            output.append(character)
            index = nextIndex
        }
        return output
    }
}

private struct VSCodeUserDataProfile {
    var applicationSupportName: String

    func applicationSupportDirectory(homeDirectory: URL) -> URL {
        homeDirectory.appending(path: "Library/Application Support/\(applicationSupportName)")
    }

    func userDirectory(homeDirectory: URL) -> URL {
        applicationSupportDirectory(homeDirectory: homeDirectory).appending(path: "User")
    }

    func languageModelsURL(homeDirectory: URL) -> URL {
        userDirectory(homeDirectory: homeDirectory).appending(path: "chatLanguageModels.json")
    }

    func settingsURL(homeDirectory: URL) -> URL {
        userDirectory(homeDirectory: homeDirectory).appending(path: "settings.json")
    }
}
