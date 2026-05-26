import Foundation

public final class AgentProvisioner: @unchecked Sendable {
    private static let backupMarker = "api-for-cursor-backup"
    private static let continueBlockStart = "# api-for-cursor-start"
    private static let continueBlockEnd = "# api-for-cursor-end"
    private static let aiderBlockStart = "# api-for-cursor-aider-start"
    private static let aiderBlockEnd = "# api-for-cursor-aider-end"

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
        AgentIntegrationID.allCases.map { status(for: $0, settings: settings) }
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
        case .continueDev:
            return continueStatus(settings: settings)
        case .aider:
            return aiderStatus(settings: settings)
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
        case .continueDev:
            try installContinue(settings: settings)
        case .aider:
            try installAider(settings: settings)
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
        if root["model"] == nil {
            root["model"] = "cursorapi/composer-2.5"
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

        [profiles.cursorapi]
        model_provider = "cursorapi"
        model = "composer-2.5"

        [profiles.cursorapi-fast]
        model_provider = "cursorapi"
        model = "composer-2.5-fast"
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

    private func continueStatus(settings: CursorAPISettings) -> AgentIntegrationStatus {
        let url = continueConfigURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return AgentIntegrationStatus(id: .continueDev, installed: false, configPath: url.path, detail: "Continue config not found")
        }
        let text = fileText(url)
        let installed = continueConfigMatches(text, settings: settings)
        let detail = installed
            ? "Composer models installed"
            : (text.contains(Self.continueBlockStart) ? "Provider found with a different local URL" : providerStatusDetail(text: text, settings: settings))
        return AgentIntegrationStatus(id: .continueDev, installed: installed, configPath: url.path, detail: detail)
    }

    private func aiderStatus(settings: CursorAPISettings) -> AgentIntegrationStatus {
        let url = aiderConfigURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return AgentIntegrationStatus(id: .aider, installed: false, configPath: url.path, detail: "Aider config not found")
        }
        let text = fileText(url)
        let installed = aiderConfigMatches(text, settings: settings)
        let detail = installed ? "OpenAI-compatible provider installed" : providerStatusDetail(text: text, settings: settings)
        return AgentIntegrationStatus(id: .aider, installed: installed, configPath: url.path, detail: detail)
    }

    private func codexConfigMatches(_ text: String, settings: CursorAPISettings) -> Bool {
        text.contains("[model_providers.cursorapi]")
            && text.contains("name = \"\(CursorAPIBrand.displayName)\"")
            && text.contains("base_url = \"\(settings.baseURL.absoluteString)\"")
            && text.contains("wire_api = \"responses\"")
            && text.contains("[model_providers.cursorapi.auth]")
            && text.contains("command = \"/bin/echo\"")
            && text.contains("args = [\"cursor-local\"]")
            && text.contains("[profiles.cursorapi]")
            && text.contains("model_provider = \"cursorapi\"")
            && text.contains("model = \"composer-2.5\"")
            && text.contains("[profiles.cursorapi-fast]")
            && text.contains("model = \"composer-2.5-fast\"")
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
        let url = aiderConfigURL()
        var text = removeMarkedAiderBlock(from: fileText(url))
        text = removeTopLevelYAMLKeys(
            ["model", "weak-model", "editor-model", "openai-api-base", "openai-api-key"],
            from: text
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if !text.isEmpty {
            text += "\n\n"
        }
        text += aiderConfigBlock(settings: settings)
        text += "\n"
        try writeText(text, to: url)
    }

    private func opencodeConfigURL() -> URL {
        configHomeDirectory().appending(path: "opencode/opencode.json")
    }

    private func codexConfigURL() -> URL {
        homeDirectory.appending(path: ".codex/config.toml")
    }

    private func vscodeLanguageModelsURL() -> URL {
        selectedVSCodeProfile().languageModelsURL(homeDirectory: homeDirectory)
    }

    private func vscodeLanguageModelsURLs() -> [URL] {
        vscodeProfiles().map { $0.languageModelsURL(homeDirectory: homeDirectory) }
    }

    private func selectedVSCodeProfile() -> VSCodeUserDataProfile {
        let profiles = vscodeProfiles()
        if let profile = profiles.first(where: { fileManager.fileExists(atPath: $0.languageModelsURL(homeDirectory: homeDirectory).path) }) {
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

    private func continueConfigURL() -> URL {
        homeDirectory.appending(path: ".continue/config.yaml")
    }

    private func aiderConfigURL() -> URL {
        homeDirectory.appending(path: ".aider.conf.yml")
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
            Self.aiderBlockEnd
        ].joined(separator: "\n")
    }

    private func removeMarkedContinueBlock(from text: String) -> String {
        removeMarkedBlock(from: text, start: Self.continueBlockStart, end: Self.continueBlockEnd)
    }

    private func removeMarkedAiderBlock(from text: String) -> String {
        removeMarkedBlock(from: text, start: Self.aiderBlockStart, end: Self.aiderBlockEnd)
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
        if text.contains("http://127.0.0.1:") || text.contains("http://localhost:") {
            return "Provider found with a different local URL"
        }
        if text.contains("cursorapi") || text.contains("api-for-cursor") || text.contains(CursorAPIBrand.displayName) || text.contains("CursorAPI") {
            return "Provider found with a different local URL"
        }
        return "Ready to install"
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
}
