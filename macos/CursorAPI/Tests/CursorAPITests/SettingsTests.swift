import CursorAPICore
import XCTest

final class SettingsTests: XCTestCase {
    func testSettingsDecodeOldPersistedShapeWithoutKeychainMarker() throws {
        let data = Data("""
        {
          "port": 9999,
          "cursorAPIBaseURL": "",
          "backendBaseURL": "",
          "localAgentEndpoint": "",
          "clientVersion": "sdk-1.0.13",
          "launchAtLogin": false
        }
        """.utf8)

        let settings = try JSONDecoder().decode(CursorAPISettings.self, from: data)

        XCTAssertEqual(settings.port, 9999)
        XCTAssertFalse(settings.hasCursorAPIKey)
        XCTAssertFalse(settings.keychainCursorAPIKeyAvailable)
        XCTAssertFalse(settings.menuBarOnly)
    }

    func testKeychainAvailabilityCountsAsSavedAPIKeyWithoutSecretInMemory() {
        let settings = CursorAPISettings(cursorAPIKey: "", keychainCursorAPIKeyAvailable: true)

        XCTAssertTrue(settings.hasCursorAPIKey)
        XCTAssertFalse(settings.hasInlineCursorAPIKey)
    }

    func testRoutingConfigurationDoesNotRequireAPIKey() {
        let settings = CursorAPISettings(
            cursorAPIKey: "",
            cursorAPIBaseURL: "https://exchange.example",
            backendBaseURL: "https://routing.example",
            localAgentEndpoint: "/sdk/run"
        )

        XCTAssertFalse(settings.hasCursorAPIKey)
        XCTAssertTrue(settings.hasCursorSDKConfiguration)
    }

    func testSDKConfigurationNoLongerRequiresKeyExchangeOrigin() {
        let settings = CursorAPISettings(
            cursorAPIKey: "",
            backendBaseURL: "https://routing.example",
            localAgentEndpoint: "/sdk/run"
        )

        XCTAssertFalse(settings.hasCursorAPIExchangeConfiguration)
        XCTAssertTrue(settings.hasCursorSDKConfiguration)
    }

    func testLegacyCursorAPIBaseURLDoesNotBlockLocalSDKBridge() {
        let settings = CursorAPISettings(
            cursorAPIKey: "",
            cursorAPIBaseURL: CursorAPISettings.legacyCursorAPIBaseURL,
            backendBaseURL: "https://routing.example",
            localAgentEndpoint: "/sdk/run"
        )

        XCTAssertFalse(settings.hasCursorAPIExchangeConfiguration)
        XCTAssertTrue(settings.hasCursorSDKConfiguration)
    }

    func testSettingsEncodingDoesNotPersistKeychainAvailabilityMarker() throws {
        var settings = CursorAPISettings(keychainCursorAPIKeyAvailable: true)
        settings.cursorAPIKey = ""

        let data = try JSONEncoder.cursorAPIPretty.encode(settings)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(text.contains("keychainCursorAPIKeyAvailable"))
        XCTAssertTrue(text.contains("\"menuBarOnly\""))
    }

    func testBundledTransportDefaultsFillMissingSDKSettings() {
        let defaults = isolatedDefaults()
        let store = AppSettingsStore(
            defaults: defaults,
            environment: [:],
            bundledTransportDefaults: {
                [
                    "cursorAPIBaseURL": "https://exchange.example",
                    "backendBaseURL": "https://bundled.example",
                    "localAgentEndpoint": "/sdk/run",
                    "clientVersion": "sdk-test"
                ]
            }
        )

        let settings = store.load()

        XCTAssertEqual(settings.cursorAPIBaseURL, "https://exchange.example")
        XCTAssertEqual(settings.backendBaseURL, "https://bundled.example")
        XCTAssertEqual(settings.localAgentEndpoint, "/sdk/run")
        XCTAssertEqual(settings.clientVersion, "sdk-test")
        XCTAssertTrue(settings.hasCursorSDKConfiguration)
    }

    func testEnvironmentOverridesBundledTransportDefaults() {
        let defaults = isolatedDefaults()
        let store = AppSettingsStore(
            defaults: defaults,
            environment: [
                "CURSOR_API_BASE": "https://exchange-env.example",
                "CURSOR_BACKEND_BASE_URL": "https://env.example",
                "CURSOR_LOCAL_AGENT_ENDPOINT": "/env/run",
                "CURSOR_SDK_CLIENT_VERSION": "sdk-env"
            ],
            bundledTransportDefaults: {
                [
                    "cursorAPIBaseURL": "https://exchange-bundled.example",
                    "backendBaseURL": "https://bundled.example",
                    "localAgentEndpoint": "/sdk/run",
                    "clientVersion": "sdk-test"
                ]
            }
        )

        let settings = store.load()

        XCTAssertEqual(settings.cursorAPIBaseURL, "https://exchange-env.example")
        XCTAssertEqual(settings.backendBaseURL, "https://env.example")
        XCTAssertEqual(settings.localAgentEndpoint, "/env/run")
        XCTAssertEqual(settings.clientVersion, "sdk-env")
    }

    func testEnvironmentDoesNotLoadCursorAPIKey() {
        let defaults = isolatedDefaults()
        let store = AppSettingsStore(
            defaults: defaults,
            environment: [
                "CURSOR_API_KEY": "crsr_env_should_not_be_loaded"
            ],
            bundledTransportDefaults: { [:] },
            keychainService: "CursorAPI.SettingsTests.\(UUID().uuidString)",
            legacyKeychainServices: [],
            keychainAccount: "cursor-api-key"
        )

        let settings = store.load()

        XCTAssertEqual(settings.cursorAPIKey, "")
        XCTAssertFalse(settings.hasCursorAPIKey)
    }

    func testSavedAPIKeyUsesRenamedKeychainService() throws {
        let defaults = isolatedDefaults()
        let keychainService = "ai.standardagents.apiforcursor.SettingsTests.\(UUID().uuidString)"
        let legacyKeychainService = "ai.standardagents.cursorapi.SettingsTests.\(UUID().uuidString)"
        let account = "cursor-api-key-\(UUID().uuidString)"
        let store = AppSettingsStore(
            defaults: defaults,
            environment: [:],
            bundledTransportDefaults: { [:] },
            keychainService: keychainService,
            legacyKeychainServices: [legacyKeychainService],
            keychainAccount: account
        )
        defer { store.save(CursorAPISettings(cursorAPIKey: "", keychainCursorAPIKeyAvailable: false)) }

        store.save(CursorAPISettings(cursorAPIKey: " crsr_saved "))

        let settings = store.load()
        XCTAssertEqual(settings.cursorAPIKey, "")
        XCTAssertTrue(settings.hasCursorAPIKey)

        let resolved = try store.resolvingCursorAPIKey(in: settings, allowUserPrompt: false)
        XCTAssertEqual(resolved.cursorAPIKey, "crsr_saved")

        let primaryOnlyStore = AppSettingsStore(
            defaults: isolatedDefaults(),
            environment: [:],
            bundledTransportDefaults: { [:] },
            keychainService: keychainService,
            legacyKeychainServices: [],
            keychainAccount: account
        )
        XCTAssertTrue(primaryOnlyStore.load().hasCursorAPIKey)

        let legacyOnlyStore = AppSettingsStore(
            defaults: isolatedDefaults(),
            environment: [:],
            bundledTransportDefaults: { [:] },
            keychainService: legacyKeychainService,
            legacyKeychainServices: [],
            keychainAccount: account
        )
        XCTAssertFalse(legacyOnlyStore.load().hasCursorAPIKey)
    }

    func testLegacyKeychainServiceMigratesToRenamedService() throws {
        let keychainService = "ai.standardagents.apiforcursor.SettingsTests.\(UUID().uuidString)"
        let legacyKeychainService = "ai.standardagents.cursorapi.SettingsTests.\(UUID().uuidString)"
        let account = "cursor-api-key-\(UUID().uuidString)"
        let legacyStore = AppSettingsStore(
            defaults: isolatedDefaults(),
            environment: [:],
            bundledTransportDefaults: { [:] },
            keychainService: legacyKeychainService,
            legacyKeychainServices: [],
            keychainAccount: account
        )
        let store = AppSettingsStore(
            defaults: isolatedDefaults(),
            environment: [:],
            bundledTransportDefaults: { [:] },
            keychainService: keychainService,
            legacyKeychainServices: [legacyKeychainService],
            keychainAccount: account
        )
        defer { store.save(CursorAPISettings(cursorAPIKey: "", keychainCursorAPIKeyAvailable: false)) }

        legacyStore.save(CursorAPISettings(cursorAPIKey: "crsr_legacy"))

        let settings = store.load()
        XCTAssertTrue(settings.hasCursorAPIKey)

        let resolved = try store.resolvingCursorAPIKey(in: settings, allowUserPrompt: false)
        XCTAssertEqual(resolved.cursorAPIKey, "crsr_legacy")

        let primaryOnlyStore = AppSettingsStore(
            defaults: isolatedDefaults(),
            environment: [:],
            bundledTransportDefaults: { [:] },
            keychainService: keychainService,
            legacyKeychainServices: [],
            keychainAccount: account
        )
        XCTAssertTrue(primaryOnlyStore.load().hasCursorAPIKey)
        XCTAssertFalse(legacyStore.load().hasCursorAPIKey)
    }

    func testSavedTransportSettingsOverrideBundledDefaults() throws {
        let defaults = isolatedDefaults()
        let saved = CursorAPISettings(
            port: 8787,
            cursorAPIKey: "",
            cursorAPIBaseURL: "https://exchange-saved.example",
            backendBaseURL: "https://saved.example",
            localAgentEndpoint: "/saved/run",
            clientVersion: "sdk-saved",
            launchAtLogin: false
        )
        let data = try JSONEncoder.cursorAPIPretty.encode(saved)
        defaults.set(data, forKey: "CursorAPI.settings.v1")
        let store = AppSettingsStore(
            defaults: defaults,
            environment: [:],
            bundledTransportDefaults: {
                [
                    "cursorAPIBaseURL": "https://exchange-bundled.example",
                    "backendBaseURL": "https://bundled.example",
                    "localAgentEndpoint": "/sdk/run",
                    "clientVersion": "sdk-test"
                ]
            }
        )

        let settings = store.load()

        XCTAssertEqual(settings.cursorAPIBaseURL, "https://exchange-saved.example")
        XCTAssertEqual(settings.backendBaseURL, "https://saved.example")
        XCTAssertEqual(settings.localAgentEndpoint, "/saved/run")
        XCTAssertEqual(settings.clientVersion, "sdk-saved")
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "CursorAPI.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
