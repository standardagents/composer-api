# Stable SDK Bridge Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reuse the last healthy internal Cursor SDK bridge port across clean macOS app restarts and retain bounded fallback when that port is occupied.

**Architecture:** Add a bridge-only preference object backed by a dedicated `UserDefaults` key; it validates persisted values against the existing 8792...8892 range and puts the remembered port first without changing the range. Give `CursorSDKBridgeServer` narrow injectable port-check, launch, health-check, and sleep dependencies so deterministic tests exercise its real startup loop without spawning Node. The server records a candidate only after its health check succeeds, leaving `CursorAPISettings.port` and bridge authentication untouched.

**Tech Stack:** Swift 6, Foundation `UserDefaults`, XCTest, Swift Package Manager

**Commit Policy:** The current request authorizes a local commit. Keep implementation changes uncommitted until final verifier acceptance and let the mandatory `prep-merge-to-local-main` phase run security gates, stage only task-owned files, and create the Conventional Commit with the required Copilot co-author trailer.

**Source of truth:** `docs/todos/stable-sdk-bridge-port/todo.md` and the current user request. No separate specification exists.

**Task-owned files:**

- Create `macos/CursorAPI/Sources/CursorAPICore/CursorSDKBridgePortPreference.swift` for bridge-only preference persistence and candidate ordering.
- Create `macos/CursorAPI/Tests/CursorAPITests/CursorSDKBridgeServerTests.swift` for server-level restart, collision, health-gating, bounds, and separation regressions.
- Modify `macos/CursorAPI/Sources/CursorAPICore/CursorSDKBridgeServer.swift` to add internal test dependencies, choose remembered-first candidates, and record only a healthy port.
- Update `docs/todos/stable-sdk-bridge-port/todo.md` and this plan with verification/review evidence.

**Preserved boundaries:**

- Do not add the bridge port to `CursorAPISettings` or `AppSettingsStore`.
- Do not persist or change the bridge token, API/auth/routing behavior, public API port, dependencies, scripts, or external services.
- Do not inspect or modify another worktree, launch the installed app, terminate user processes, make live model calls, or perform remote writes.
- The app lifecycle fix is outside this branch. If clean bridge shutdown cannot be established from `main`, report that integration dependency rather than expanding scope.
- Same verifier `rejection_key` twice stops implementation and surfaces the rejection.

**Feature / Verification Matrix:**

| Change | Verification | Status | Evidence |
| --- | --- | --- | --- |
| Reuse healthy bridge port across server instances | `testCleanRestartReusesLastHealthyBridgePort` | Pass | Real startup-loop harness selected and reused 8793 after 8792 became free |
| Fall back when the preferred port is occupied | `testOccupiedPersistedPreferenceFallsBackAndRewritesPreference` | Pass | Occupied 8841 fell back to 8792; 101 unique candidates remained within 8792...8892 |
| Persist only health-confirmed ports | `testHealthGateOnlyPersistsPortAfterHealthyLaunch` | Pass | Preference stayed 8841 for 40 unhealthy polls and changed only after healthy 8792 |
| Keep public and bridge port persistence separate | `testBridgePreferencePersistenceDoesNotOverwritePublicSettings` plus diff review | Pass | Dedicated bridge-key write left `CursorAPI.settings.v1` unchanged |

**Subagent Ledger:**

| Workstream | Scope | Edits | Expected output | Verification responsibility |
| --- | --- | --- | --- | --- |
| Pre-implementation evaluator | Task record, plan, current bridge server, neighboring settings tests | No | Acceptance/boundary/sequence findings with inspected files and residual risks | Test reviewer rejected helper-only coverage with `missing-production-wiring-regression`; plan corrected to server-level injected tests |
| Implementation worker | Three task-owned Swift files | Yes, only assigned Swift files | TDD evidence, changed files, commands, uncertainties, residual risks | DONE_WITH_CONCERNS: build passed; XCTest unavailable in local Command Line Tools |
| Independent verifier | Current task-owned diff and fresh command output | No | Accept or reject with a stable `rejection_key` and evidence | ACCEPT: builds passed; temporary real-code harness passed 21 assertions |
| Spec reviewer | Current task-owned diff and Sprint Contract | No | Requirement and scope decision | ACCEPT |
| Code-quality reviewer | Entire task-owned diff after simplification | No | High-confidence correctness findings only | ACCEPT; no simplification edit warranted |
| Final verifier | Final task-owned diff and fresh evidence | No | Final acceptance before completion | ACCEPT: builds passed; current production-path harness passed 23 assertions |

---

### Task 1: Persist and Reuse the Internal Bridge Port

**Files:**

- Create: `macos/CursorAPI/Sources/CursorAPICore/CursorSDKBridgePortPreference.swift`
- Create: `macos/CursorAPI/Tests/CursorAPITests/CursorSDKBridgeServerTests.swift`
- Modify: `macos/CursorAPI/Sources/CursorAPICore/CursorSDKBridgeServer.swift:11-61`
- Modify: `docs/todos/stable-sdk-bridge-port/todo.md`
- Modify: `docs/todos/stable-sdk-bridge-port/plan.md`

**Verifier:**

- Commands that must be fresh:
  - `swift test --package-path macos/CursorAPI --filter CursorSDKBridgeServerTests`
  - `swift test --package-path macos/CursorAPI --filter SettingsTests`
  - `swift test --package-path macos/CursorAPI`
  - `swift build --package-path macos/CursorAPI`
- Expected evidence: server-level tests fail before the preference and injected startup seams exist, then pass against the production startup loop; the full Swift suite and build pass; and the final independent verifier accepts the task-owned diff.
- Notes: the verifier must confirm that `CursorAPISettings.port`, bridge token handling, and the allowed port range are unchanged. The same `rejection_key` twice stops and surfaces the task.

- [x] **Step 1: Run the focused existing baseline**

Run:

```bash
swift test --package-path macos/CursorAPI --filter ConnectivityCheckTests
swift test --package-path macos/CursorAPI --filter SettingsTests
```

Expected: both existing suites pass before task-owned Swift changes.

Actual: both commands were attempted, but package test compilation is blocked on `main` and this branch because the installed Command Line Tools lack the `XCTest` module. This is an environment blocker, not a regression.

- [x] **Step 2: Write the failing regression tests**

Create `macos/CursorAPI/Tests/CursorAPITests/CursorSDKBridgeServerTests.swift`:

```swift
@testable import CursorAPICore
import Foundation
import XCTest

final class CursorSDKBridgeServerTests: XCTestCase {
    func testCleanRestartReusesLastHealthyBridgePort() async throws {
        let defaults = isolatedDefaults()
        let firstRun = testServer(
            defaults: defaults,
            portIsOpen: { $0 == 8792 },
            healthCheck: { _ in true }
        )

        let firstPort = try await firstRun.start(script: scriptURL, settings: CursorAPISettings())
        await firstRun.shutdown()
        let restarted = testServer(
            defaults: defaults,
            portIsOpen: { _ in false },
            healthCheck: { _ in true }
        )
        let restartedPort = try await restarted.start(script: scriptURL, settings: CursorAPISettings())
        await restarted.shutdown()

        XCTAssertEqual(firstPort, 8793)
        XCTAssertEqual(restartedPort, firstPort)
    }

    func testOccupiedPreferredPortFallsBackAndRemembersHealthyPort() async throws {
        let defaults = isolatedDefaults()
        let preference = CursorSDKBridgePortPreference(defaults: defaults)
        preference.recordSuccessfulPort(8841)
        let server = testServer(
            defaults: defaults,
            portIsOpen: { $0 == 8841 },
            healthCheck: { _ in true }
        )

        let selected = try await server.start(script: scriptURL, settings: CursorAPISettings())
        await server.shutdown()
        let nextRun = CursorSDKBridgePortPreference(defaults: defaults)

        XCTAssertEqual(selected, 8792)
        XCTAssertEqual(nextRun.candidatePorts().first, selected)
        XCTAssertEqual(nextRun.candidatePorts().count, 101)
        XCTAssertEqual(Set(nextRun.candidatePorts()), Set(CursorSDKBridgePortPreference.allowedPorts))
    }

    func testUnhealthyPreferredPortIsNotRecordedBeforeFallback() async throws {
        let defaults = isolatedDefaults()
        let preference = CursorSDKBridgePortPreference(defaults: defaults)
        preference.recordSuccessfulPort(8841)
        let observedPreferenceBeforeFallback = LockedPort()
        let server = CursorSDKBridgeServer(
            portPreference: preference,
            dependencies: CursorSDKBridgeServerDependencies(
                portIsOpen: { _ in false },
                launch: { _, port, _ in
                    if port == 8792 {
                        observedPreferenceBeforeFallback.set(preference.candidatePorts().first)
                    }
                },
                healthCheck: { url in url.port == 8792 },
                sleep: {}
            )
        )

        let selected = try await server.start(script: scriptURL, settings: CursorAPISettings())
        await server.shutdown()

        XCTAssertEqual(observedPreferenceBeforeFallback.value(), 8841)
        XCTAssertEqual(selected, 8792)
        XCTAssertEqual(CursorSDKBridgePortPreference(defaults: defaults).candidatePorts().first, selected)
    }

    func testBridgePreferenceDoesNotOverwritePublicAPISettings() {
        let defaults = isolatedDefaults()
        let publicSettings = Data(#"{"port":8787}"#.utf8)
        defaults.set(publicSettings, forKey: "CursorAPI.settings.v1")

        CursorSDKBridgePortPreference(defaults: defaults).recordSuccessfulPort(8841)

        XCTAssertEqual(defaults.data(forKey: "CursorAPI.settings.v1"), publicSettings)
    }

    private var scriptURL: URL {
        URL(fileURLWithPath: "/tmp/cursor-sdk-local-agent-bridge.mjs")
    }

    private func testServer(
        defaults: UserDefaults,
        portIsOpen: @escaping @Sendable (UInt16) async -> Bool,
        healthCheck: @escaping @Sendable (URL) async -> Bool
    ) -> CursorSDKBridgeServer {
        CursorSDKBridgeServer(
            portPreference: CursorSDKBridgePortPreference(defaults: defaults),
            dependencies: CursorSDKBridgeServerDependencies(
                portIsOpen: portIsOpen,
                launch: { _, _, _ in },
                healthCheck: healthCheck,
                sleep: {}
            )
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "CursorAPI.BridgePortTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class LockedPort: @unchecked Sendable {
    private let lock = NSLock()
    private var port: UInt16?

    func set(_ port: UInt16?) {
        lock.withLock {
            self.port = port
        }
    }

    func value() -> UInt16? {
        lock.withLock {
            port
        }
    }
}
```

- [x] **Step 3: Run the new tests to prove the behavior is missing**

Run:

```bash
swift test --package-path macos/CursorAPI --filter CursorSDKBridgeServerTests
```

Expected: compilation fails because `CursorSDKBridgePortPreference`, `CursorSDKBridgeServerDependencies`, and the injectable server initializer/startup seam do not exist on `main`; preserve the concise compiler error as deterministic red-test evidence for missing production behavior.

Actual: tests were written before production code, but the red command stopped earlier at the pre-existing missing-`XCTest` toolchain error. The final verifier therefore uses a no-XCTest harness against the actual startup loop as the executable substitute.

- [x] **Step 4: Implement the bridge-only port preference**

Create `macos/CursorAPI/Sources/CursorAPICore/CursorSDKBridgePortPreference.swift`:

```swift
import Foundation

final class CursorSDKBridgePortPreference: @unchecked Sendable {
    static let defaultPort: UInt16 = 8792
    static let allowedPorts: ClosedRange<UInt16> = 8792...8892

    private static let defaultsKey = "CursorAPI.sdkBridgePort.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func candidatePorts() -> [UInt16] {
        let preferred = storedPort ?? Self.defaultPort
        return [preferred] + Self.allowedPorts.filter { $0 != preferred }
    }

    func recordSuccessfulPort(_ port: UInt16) {
        precondition(Self.allowedPorts.contains(port))
        defaults.set(Int(port), forKey: Self.defaultsKey)
    }

    private var storedPort: UInt16? {
        guard let number = defaults.object(forKey: Self.defaultsKey) as? NSNumber,
              let port = UInt16(exactly: number.intValue),
              Self.allowedPorts.contains(port) else {
            return nil
        }
        return port
    }
}
```

This stores only a non-secret internal bridge preference. Invalid or out-of-range persisted values fall back to 8792, and candidate ordering remains bounded to the existing 101 ports.

- [x] **Step 5: Wire the preference into healthy bridge startup**

In `macos/CursorAPI/Sources/CursorAPICore/CursorSDKBridgeServer.swift`, add narrow internal dependencies before the actor:

```swift
struct CursorSDKBridgeServerDependencies: Sendable {
    var portIsOpen: (@Sendable (UInt16) async -> Bool)?
    var launch: (@Sendable (URL, UInt16, CursorAPISettings) throws -> Void)?
    var healthCheck: (@Sendable (URL) async -> Bool)?
    var sleep: (@Sendable () async throws -> Void)?
}
```

Add stored state and an internal initializer to the actor:

```swift
private let portPreference: CursorSDKBridgePortPreference
private let dependencies: CursorSDKBridgeServerDependencies

init(
    portPreference: CursorSDKBridgePortPreference = CursorSDKBridgePortPreference(),
    dependencies: CursorSDKBridgeServerDependencies = CursorSDKBridgeServerDependencies()
) {
    self.portPreference = portPreference
    self.dependencies = dependencies
}
```

Make `start(script:settings:)` internal so `@testable` server-level tests can exercise it, and replace the hard-coded integer scan with:

```swift
for candidate in portPreference.candidatePorts() {
    let isOpen = if let portIsOpen = dependencies.portIsOpen {
        await portIsOpen(candidate)
    } else {
        await tcpPortIsOpen(candidate)
    }
    guard !isOpen else {
        continue
    }
    do {
        if let launch = dependencies.launch {
            try launch(script, candidate, settings)
        } else {
            try launch(script: script, port: candidate, settings: settings)
        }
        let health = URL(string: "http://127.0.0.1:\(candidate)/health")!
        for _ in 0..<40 {
            let healthy = if let healthCheck = dependencies.healthCheck {
                await healthCheck(health)
            } else {
                await isHealthy(health)
            }
            if healthy {
                portPreference.recordSuccessfulPort(candidate)
                return candidate
            }
            if let sleep = dependencies.sleep {
                try await sleep()
            } else {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        stop()
        lastError = CursorAPIError.transport("Cursor SDK bridge did not become ready.")
    } catch {
        stop()
        lastError = error
    }
}
```

The injected closures default to `nil`, so production keeps the existing process launch, TCP probe, 40 health checks, 50 ms polling delay, shutdown, and error behavior. Do not alter token generation or the public API port setting.

- [x] **Step 6: Run focused green tests**

Run:

```bash
swift test --package-path macos/CursorAPI --filter CursorSDKBridgeServerTests
swift test --package-path macos/CursorAPI --filter SettingsTests
```

Expected: both suites pass. The first drives the production server startup loop with deterministic fakes to prove clean-restart reuse, occupied-port fallback, health-gated recording, bounded candidates, and separate persistence; the second guards existing public settings behavior.

Actual: both remain blocked by missing `XCTest`. A temporary substitute compiled the actual core sources with testing enabled and passed all 21 assertions over the same startup-loop behaviors.

- [x] **Step 7: Run the independent task verifier**

Verifier input:

- Requirements: remember only a healthy internal bridge port; try it first on a fresh app instance; skip it safely when occupied; retain ports 8792...8892; do not touch the public API port or auth/routing.
- Commands that must be fresh:
  - `swift test --package-path macos/CursorAPI --filter CursorSDKBridgeServerTests`
  - `swift test --package-path macos/CursorAPI --filter SettingsTests`
- Expected evidence: verifier accepts the current task-owned diff and confirms the production startup loop consumes the tested ordering.
- Rejection policy: same `rejection_key` twice stops and surfaces the task.

Result: ACCEPT. No task-verifier rejection keys were recorded.

- [x] **Step 8: Simplify touched code without changing behavior**

Review only the new preference, server test dependencies, startup integration, and tests. Remove duplication or needless abstraction while preserving the dedicated key, validated range, production defaults, remembered-first order, and health-gated write. Re-run both focused test commands afterward.

Result: no edit. The explicit dependency seam and lock-protected test recorders reduce rather than increase reader risk; shortening them would obscure the production-path assertions.

- [x] **Step 9: Run full local verification**

Run:

```bash
swift test --package-path macos/CursorAPI
swift build --package-path macos/CursorAPI
```

Expected: the full CursorAPI Swift test suite and debug build pass. OSV is not required because no dependency, lockfile, container, or vendored surface changes.

Actual: `swift build --package-path macos/CursorAPI --target CursorAPICore` and `swift build --package-path macos/CursorAPI` passed. Swift tests are blocked by missing `XCTest`; the focused real-code harness passed 21 assertions. OSV remains not required.

- [x] **Step 10: Update task evidence and obtain final review**

Update `docs/todos/stable-sdk-bridge-port/todo.md` and this plan:

- Mark each Feature / Verification Matrix row passing with exact command evidence.
- Record files inspected/changed, review results, verifier acceptance, rejection count, lifecycle dependency, and residual risks.
- Record that the implementation worker changed only task-owned files.

Then request a read-only final review of the current task-owned diff. Resolve any high-confidence issue and repeat the focused/full commands affected by the fix.

Result: spec-compliance and code-quality reviewers both returned ACCEPT. Final task-verifier acceptance remains required before Step 11.

Final verifier result: ACCEPT. Both builds passed, the known missing-`XCTest` blocker was unchanged, and a fresh harness against the current production startup path passed 23 assertions.

- [ ] **Step 11: Run mandatory merge preparation and commit**

Invoke `prep-merge-to-local-main` with the task record, this plan, preserved dirty paths, verification evidence, persistence boundary, and the stable task-owned diff. It must:

- capture and merge the current local `refs/heads/main` within feature-loop authorization;
- run the repo-native security gate if one exists, otherwise run required Semgrep for the persistence/code change;
- stage only the task-owned files and run `gitleaks protect --staged --redact`;
- skip OSV with the recorded no-dependency-change reason;
- create a Conventional Commit such as `fix: reuse sdk bridge port` with `Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>`;
- run post-merge focused and full verification before reporting success.

No fetch, pull, push, publish, deploy, installed-app launch, user-process termination, or remote write is authorized.
