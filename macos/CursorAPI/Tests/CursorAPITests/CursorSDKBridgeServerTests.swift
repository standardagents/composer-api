@testable import CursorAPICore
import XCTest

final class CursorSDKBridgeServerTests: XCTestCase {
    func testCleanRestartReusesLastHealthyBridgePort() async throws {
        let defaults = isolatedDefaults()
        let preference = CursorSDKBridgePortPreference(defaults: defaults)
        let firstLaunches = LockedLaunchRecorder()

        let firstServer = CursorSDKBridgeServer(
            portPreference: preference,
            dependencies: CursorSDKBridgeServerDependencies(
                portIsOpen: { $0 == 8792 },
                launch: { _, port, _ in firstLaunches.recordLaunch(port) },
                healthCheck: { _ in true },
                sleep: { }
            )
        )

        let firstPort = try await firstServer.start(script: URL(fileURLWithPath: "/dev/null"), settings: CursorAPISettings())
        XCTAssertEqual(firstPort, 8793)
        XCTAssertEqual(firstLaunches.launchedPorts(), [8793])
        XCTAssertEqual(preference.preferredPort(), 8793)

        let secondLaunches = LockedLaunchRecorder()
        let secondServer = CursorSDKBridgeServer(
            portPreference: preference,
            dependencies: CursorSDKBridgeServerDependencies(
                portIsOpen: { _ in false },
                launch: { _, port, _ in secondLaunches.recordLaunch(port) },
                healthCheck: { _ in true },
                sleep: { }
            )
        )

        let secondPort = try await secondServer.start(script: URL(fileURLWithPath: "/dev/null"), settings: CursorAPISettings())
        XCTAssertEqual(secondPort, 8793)
        XCTAssertEqual(secondLaunches.launchedPorts(), [8793])
    }

    func testOccupiedPersistedPreferenceFallsBackAndRewritesPreference() async throws {
        let defaults = isolatedDefaults()
        defaults.set(8841, forKey: CursorSDKBridgePortPreference.defaultsKey)
        let preference = CursorSDKBridgePortPreference(defaults: defaults)

        let initialCandidates = preference.candidatePorts()
        XCTAssertEqual(initialCandidates.count, 101)
        XCTAssertEqual(Set(initialCandidates).count, 101)
        XCTAssertEqual(initialCandidates.first, 8841)
        XCTAssertEqual(initialCandidates.last, 8892)
        XCTAssertTrue(initialCandidates.allSatisfy { (8792...8892).contains(Int($0)) })

        let launches = LockedLaunchRecorder()
        let firstServer = CursorSDKBridgeServer(
            portPreference: preference,
            dependencies: CursorSDKBridgeServerDependencies(
                portIsOpen: { $0 == 8841 },
                launch: { _, port, _ in launches.recordLaunch(port) },
                healthCheck: { _ in true },
                sleep: { }
            )
        )

        let firstPort = try await firstServer.start(script: URL(fileURLWithPath: "/dev/null"), settings: CursorAPISettings())
        XCTAssertEqual(firstPort, 8792)
        XCTAssertEqual(launches.launchedPorts(), [8792])
        XCTAssertEqual(preference.preferredPort(), 8792)

        let secondServer = CursorSDKBridgeServer(
            portPreference: preference,
            dependencies: CursorSDKBridgeServerDependencies(
                portIsOpen: { _ in false },
                launch: { _, _, _ in },
                healthCheck: { _ in true },
                sleep: { }
            )
        )

        let secondPort = try await secondServer.start(script: URL(fileURLWithPath: "/dev/null"), settings: CursorAPISettings())
        XCTAssertEqual(secondPort, 8792)

        let updatedCandidates = preference.candidatePorts()
        XCTAssertEqual(updatedCandidates.count, 101)
        XCTAssertEqual(Set(updatedCandidates).count, 101)
        XCTAssertTrue(updatedCandidates.allSatisfy { (8792...8892).contains(Int($0)) })
    }

    func testHealthGateOnlyPersistsPortAfterHealthyLaunch() async throws {
        let defaults = isolatedDefaults()
        defaults.set(8841, forKey: CursorSDKBridgePortPreference.defaultsKey)
        let preference = CursorSDKBridgePortPreference(defaults: defaults)
        let recorder = LockedHealthFallbackRecorder()

        let server = CursorSDKBridgeServer(
            portPreference: preference,
            dependencies: CursorSDKBridgeServerDependencies(
                portIsOpen: { _ in false },
                launch: { _, port, _ in
                    recorder.recordLaunch(port: port, persistedPreference: preference.preferredPort())
                },
                healthCheck: { _ in
                    guard let current = recorder.currentLaunchPort() else { return false }
                    recorder.recordHealthPoll(for: current)
                    if current == 8841 {
                        return false
                    }
                    return current == 8792
                },
                sleep: { }
            )
        )

        let selected = try await server.start(script: URL(fileURLWithPath: "/dev/null"), settings: CursorAPISettings())

        XCTAssertEqual(selected, 8792)
        XCTAssertEqual(recorder.launchedPorts(), [8841, 8792])
        XCTAssertEqual(recorder.persistedPreferenceAtLaunch(), [8841, 8841])
        XCTAssertEqual(recorder.healthPollCount(for: 8841), 40)
        XCTAssertEqual(preference.preferredPort(), 8792)
    }

    func testBridgePreferencePersistenceDoesNotOverwritePublicSettings() throws {
        let defaults = isolatedDefaults()
        let settings = CursorAPISettings(port: 8822, cursorAPIBaseURL: "https://exchange.example")
        let persistedSettings = try JSONEncoder.cursorAPIPretty.encode(settings)
        defaults.set(persistedSettings, forKey: "CursorAPI.settings.v1")

        let preference = CursorSDKBridgePortPreference(defaults: defaults)
        preference.recordSuccessfulPort(8844)

        XCTAssertEqual(defaults.data(forKey: "CursorAPI.settings.v1"), persistedSettings)
        XCTAssertEqual(defaults.integer(forKey: CursorSDKBridgePortPreference.defaultsKey), 8844)
    }

    func testInvalidOrOutOfRangePersistedBridgePortFallsBackToDefault() {
        let defaults = isolatedDefaults()
        defaults.set(8791, forKey: CursorSDKBridgePortPreference.defaultsKey)

        let preference = CursorSDKBridgePortPreference(defaults: defaults)

        XCTAssertEqual(preference.preferredPort(), 8792)
        XCTAssertEqual(preference.candidatePorts().first, 8792)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "CursorAPI.CursorSDKBridgeServerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class LockedLaunchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var launches: [UInt16] = []

    func recordLaunch(_ port: UInt16) {
        lock.lock()
        launches.append(port)
        lock.unlock()
    }

    func launchedPorts() -> [UInt16] {
        lock.lock()
        let snapshot = launches
        lock.unlock()
        return snapshot
    }
}

private final class LockedHealthFallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var launches: [UInt16] = []
    private var preferenceSnapshots: [UInt16] = []
    private var healthPolls: [UInt16: Int] = [:]
    private var current: UInt16?

    func recordLaunch(port: UInt16, persistedPreference: UInt16) {
        lock.lock()
        launches.append(port)
        preferenceSnapshots.append(persistedPreference)
        current = port
        lock.unlock()
    }

    func currentLaunchPort() -> UInt16? {
        lock.lock()
        let value = current
        lock.unlock()
        return value
    }

    func recordHealthPoll(for port: UInt16) {
        lock.lock()
        healthPolls[port, default: 0] += 1
        lock.unlock()
    }

    func healthPollCount(for port: UInt16) -> Int {
        lock.lock()
        let value = healthPolls[port, default: 0]
        lock.unlock()
        return value
    }

    func launchedPorts() -> [UInt16] {
        lock.lock()
        let snapshot = launches
        lock.unlock()
        return snapshot
    }

    func persistedPreferenceAtLaunch() -> [UInt16] {
        lock.lock()
        let snapshot = preferenceSnapshots
        lock.unlock()
        return snapshot
    }
}
