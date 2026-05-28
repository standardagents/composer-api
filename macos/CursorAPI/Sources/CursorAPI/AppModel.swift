import Combine
import CursorAPICore
import Foundation
import ServiceManagement

struct LocalAPIActivitySnapshot: Equatable {
    var totalRequests = 0
    var successfulRequests = 0
    var failedRequests = 0
    var streamingRequests = 0
    var inputTokens = 0
    var outputTokens = 0
    var cachedInputTokens = 0
    var costDollars = 0.0
    var recentRequests: [LocalAPIRequestEvent] = []

    var lastRequest: LocalAPIRequestEvent? {
        recentRequests.first
    }
}

@MainActor
final class CursorAPIAppModel: ObservableObject {
    private static let portFallbackLimit = 20
    private static let recentRequestLimit = 6

    @Published var settings: CursorAPISettings
    @Published var isRunning = false
    @Published var statusText = "Stopped"
    @Published var integrations: [AgentIntegrationStatus] = []
    @Published var lastError: String?
    @Published var needsKeychainPermission = false
    @Published var sdkCheckState: SDKCheckState = .idle
    @Published var isCheckingSDK = false
    @Published var apiActivity = LocalAPIActivitySnapshot()

    private let store = AppSettingsStore()
    private let provisioner = AgentProvisioner()
    private let connectivityCheck = CursorSDKConnectivityCheck()
    private lazy var server = LocalAPIServer(settingsProvider: { [weak self] in
        DispatchQueue.main.sync {
            self?.settings ?? CursorAPISettings()
        }
    }, requestObserver: { [weak self] event in
        Task { @MainActor [weak self] in
            self?.recordRequest(event)
        }
    })

    enum SDKCheckState: Equatable {
        case idle
        case success(String)
        case failure(String)
    }

    init() {
        var loaded = store.load()
        loaded.launchAtLogin = SMAppService.mainApp.status == .enabled
        settings = loaded
        integrations = provisioner.statuses(settings: loaded)
        updateStatusText()
    }

    var baseURL: String {
        settings.baseURL.absoluteString
    }

    var chatCompletionsURL: String {
        "\(baseURL)/chat/completions"
    }

    var responsesURL: String {
        "\(baseURL)/responses"
    }

    var modelsURL: String {
        "\(baseURL)/models"
    }

    var hasCursorAPIKey: Bool {
        settings.hasCursorAPIKey
    }

    var canStartServer: Bool {
        hasCursorAPIKey && sdkConfigured
    }

    var sdkConfigured: Bool {
        settings.hasCursorSDKConfiguration
    }

    var sdkStatusText: String {
        if !sdkConfigured {
            return "SDK Bridge Missing"
        }
        if needsKeychainPermission {
            return "Needs Unlock"
        }
        if !hasCursorAPIKey {
            return "Needs API Key"
        }
        return "Ready"
    }

    var canCheckSDK: Bool {
        hasCursorAPIKey && sdkConfigured && !isCheckingSDK
    }

    var sdkCheckNeedsAPIKeyAction: Bool {
        guard case .failure(let message) = sdkCheckState else {
            return false
        }
        return message == (CursorAPIError.unauthorized.errorDescription ?? "")
            || message.localizedCaseInsensitiveContains("authorization")
    }

    var sdkCheckSucceeded: Bool {
        if case .success = sdkCheckState {
            return true
        }
        return false
    }

    var sdkCheckFailed: Bool {
        if case .failure = sdkCheckState {
            return true
        }
        return false
    }

    var pendingIntegrationInstallCount: Int {
        integrations.filter { $0.canInstall && !$0.installed }.count
    }

    var canInstallAllIntegrations: Bool {
        pendingIntegrationInstallCount > 0 && canPrepareAgentConfigs
    }

    var installAllIntegrationsTitle: String {
        Self.installAllIntegrationsTitle(
            for: integrations,
            isRunning: isRunning,
            needsKeychainPermission: needsKeychainPermission
        )
    }

    nonisolated static func installAllIntegrationsTitle(
        for integrations: [AgentIntegrationStatus],
        isRunning: Bool,
        needsKeychainPermission: Bool
    ) -> String {
        let pending = integrations.filter { $0.canInstall && !$0.installed }
        if pending.isEmpty {
            return "Installed"
        }
        let action = pending.contains(where: \.needsUpdate) ? "Update All" : "Install All"
        return isRunning ? action : "Start & \(action)"
    }

    func actionTitle(for status: AgentIntegrationStatus) -> String {
        Self.actionTitle(
            for: status,
            isRunning: isRunning,
            needsKeychainPermission: needsKeychainPermission
        )
    }

    nonisolated static func actionTitle(
        for status: AgentIntegrationStatus,
        isRunning: Bool,
        needsKeychainPermission: Bool
    ) -> String {
        status.actionTitle
    }

    var canPrepareAgentConfigs: Bool {
        hasCursorAPIKey && sdkConfigured
    }

    var agentSetupNoticeText: String? {
        if !hasCursorAPIKey {
            return "Save a Cursor API key before installing agent configs."
        }
        if !sdkConfigured {
            return "This build is missing the bundled SDK bridge, so agent setup is disabled."
        }
        if needsKeychainPermission {
            return "Configs can be updated now; unlock the saved key before agents make Composer requests."
        }
        if !isRunning {
            return "Installing configs starts the local API first so generated URLs match the active port."
        }
        return nil
    }

    func startServer(allowKeychainPrompt: Bool = true, resolveSavedKey: Bool = true) {
        guard hasCursorAPIKey else {
            isRunning = false
            statusText = "Enter a Cursor API key to start the local API"
            lastError = nil
            return
        }
        guard sdkConfigured else {
            isRunning = false
            statusText = "This app build is missing the bundled SDK bridge"
            lastError = nil
            return
        }
        do {
            if resolveSavedKey {
                settings = try store.resolvingCursorAPIKey(in: settings, allowUserPrompt: allowKeychainPrompt)
                settings.keychainCursorAPIKeyAvailable = true
                needsKeychainPermission = false
            } else {
                needsKeychainPermission = settings.keychainCursorAPIKeyAvailable && !settings.hasInlineCursorAPIKey
            }
            let requestedPort = settings.port
            let activePort = try server.start(preferredPort: requestedPort, fallbackLimit: Self.portFallbackLimit)
            settings.port = activePort
            isRunning = true
            updateStatusText()
            LocalCursorSDKHarness.warmUpBridge(settings: settings)
            if activePort != requestedPort {
                store.save(settings)
                statusText = "Port \(requestedPort) was busy; listening on \(baseURL)"
                refreshIntegrations()
            }
            lastError = nil
        } catch AppSettingsStoreError.keychainPermissionRequired {
            isRunning = false
            needsKeychainPermission = true
            statusText = "Click Start to allow \(CursorAPIBrand.displayName) to read the saved key from Keychain"
            lastError = nil
        } catch AppSettingsStoreError.missingCursorAPIKey {
            isRunning = false
            settings.keychainCursorAPIKeyAvailable = false
            statusText = "Enter a Cursor API key to start the local API"
            lastError = nil
        } catch {
            isRunning = false
            statusText = "Could not start"
            lastError = error.localizedDescription
        }
    }

    func stopServer() {
        server.stop()
        isRunning = false
        needsKeychainPermission = false
        updateStatusText()
    }

    func shutdown() async {
        server.stop()
        isRunning = false
        needsKeychainPermission = false
        await LocalCursorSDKHarness.shutdownBridge()
        updateStatusText()
    }

    func restartServer() {
        guard canStartServer else {
            stopServer()
            updateStatusText()
            return
        }
        let shouldResolveSavedKey = settings.hasInlineCursorAPIKey && !needsKeychainPermission
        stopServer()
        startServer(allowKeychainPrompt: shouldResolveSavedKey, resolveSavedKey: shouldResolveSavedKey)
    }

    func startServerWithoutPromptIfReady() {
        guard canStartServer, !isRunning else {
            return
        }
        startServer(allowKeychainPrompt: false, resolveSavedKey: false)
    }

    func saveKeyAndStartIfReady() {
        saveSettings()
        if canStartServer {
            startServer()
        }
    }

    func saveKeyStartAndCheckIfReady() {
        saveKeyAndStartIfReady()
        if canCheckSDK {
            checkSDKConnectivity()
        }
    }

    func setMenuBarOnly(_ enabled: Bool) {
        guard settings.menuBarOnly != enabled else { return }
        var updated = settings
        updated.menuBarOnly = enabled
        settings = updated
        store.save(updated)
    }

    func saveSettings() {
        store.save(settings)
        if settings.hasInlineCursorAPIKey {
            settings.keychainCursorAPIKeyAvailable = true
        }
        sdkCheckState = .idle
        let launchAtLoginError = applyLaunchAtLogin()
        refreshIntegrations()
        if !hasCursorAPIKey || !sdkConfigured {
            stopServer()
        } else if isRunning {
            restartServer()
        } else {
            updateStatusText()
        }
        if let launchAtLoginError {
            lastError = launchAtLoginError
        }
    }

    func apiKeyDidChange() {
        if settings.hasInlineCursorAPIKey {
            needsKeychainPermission = false
        }
        if !canStartServer, isRunning {
            stopServer()
        } else if !isRunning {
            updateStatusText()
        }
    }

    func refreshIntegrations() {
        integrations = provisioner.statuses(settings: settings)
    }

    func install(_ id: AgentIntegrationID) {
        guard prepareLocalAPIForAgentConfigs() else {
            return
        }
        do {
            try provisioner.install(id, settings: settings)
            refreshIntegrations()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func installAllIntegrations() {
        guard prepareLocalAPIForAgentConfigs() else {
            return
        }
        do {
            integrations = try provisioner.installAll(settings: settings)
            lastError = nil
        } catch {
            refreshIntegrations()
            lastError = error.localizedDescription
        }
    }

    func dismissError() {
        lastError = nil
    }

    func clearAPIActivity() {
        apiActivity = LocalAPIActivitySnapshot()
    }

    func checkSDKConnectivity() {
        guard canCheckSDK else {
            sdkCheckState = .failure(sdkConfigured ? "Enter a Cursor API key before checking Composer." : "This app build is missing the bundled SDK bridge.")
            return
        }
        isCheckingSDK = true
        sdkCheckState = .idle
        Task {
            do {
                let resolved = try store.resolvingCursorAPIKey(in: settings, allowUserPrompt: true)
                settings = resolved
                settings.keychainCursorAPIKeyAvailable = true
                needsKeychainPermission = false
                _ = try await connectivityCheck.run(settings: resolved)
                sdkCheckState = .success("Composer routing responded.")
                lastError = nil
            } catch AppSettingsStoreError.keychainPermissionRequired {
                needsKeychainPermission = true
                sdkCheckState = .failure("Allow Keychain access, then run the check again.")
            } catch {
                sdkCheckState = .failure(error.localizedDescription)
            }
            isCheckingSDK = false
            updateStatusText()
        }
    }

    private func updateStatusText() {
        if isRunning {
            if needsKeychainPermission {
                statusText = "Listening on \(baseURL); unlock the saved key for one-click agents"
            } else {
                statusText = sdkConfigured ? "Listening on \(baseURL)" : "Listening on \(baseURL); bundled SDK bridge missing"
            }
        } else if needsKeychainPermission {
            statusText = "Click Start to allow \(CursorAPIBrand.displayName) to read the saved key from Keychain"
        } else if !hasCursorAPIKey {
            statusText = "Enter a Cursor API key to start the local API"
        } else if !sdkConfigured {
            statusText = "This app build is missing the bundled SDK bridge"
        } else {
            statusText = "Ready to start local API"
        }
    }

    private func recordRequest(_ event: LocalAPIRequestEvent) {
        var activity = apiActivity
        activity.totalRequests += 1
        if event.status >= 400 {
            activity.failedRequests += 1
        } else {
            activity.successfulRequests += 1
        }
        if event.streaming {
            activity.streamingRequests += 1
        }
        if let usage = event.usage {
            activity.inputTokens += usage.inputTokens
            activity.outputTokens += usage.outputTokens
            activity.cachedInputTokens += usage.cachedInputTokens
            activity.costDollars += usage.costDollars
        }
        activity.recentRequests.insert(event, at: 0)
        if activity.recentRequests.count > Self.recentRequestLimit {
            activity.recentRequests.removeLast(activity.recentRequests.count - Self.recentRequestLimit)
        }
        apiActivity = activity
    }

    private func prepareLocalAPIForAgentConfigs() -> Bool {
        guard hasCursorAPIKey else {
            lastError = "Enter a Cursor API key before installing agent configs."
            return false
        }
        guard sdkConfigured else {
            lastError = "This app build is missing the bundled SDK bridge."
            return false
        }
        if !isRunning {
            startServer(allowKeychainPrompt: false, resolveSavedKey: false)
        }
        return isRunning
    }

    private func applyLaunchAtLogin() -> String? {
        do {
            if settings.launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Could not update launch at login: \(error.localizedDescription)"
        }
    }
}
