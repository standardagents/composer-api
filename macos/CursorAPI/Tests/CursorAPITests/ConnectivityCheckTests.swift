@testable import CursorAPICore
import Foundation
import XCTest

final class ConnectivityCheckTests: XCTestCase {
    func testConnectivityCheckUsesHarness() async throws {
        let recorder = ConnectivityRecorder()
        let check = CursorSDKConnectivityCheck(harness: ConnectivityHarness(recorder: recorder))
        let settings = CursorAPISettings(
            cursorAPIKey: "crsr_test",
            backendBaseURL: "https://transport.example",
            localAgentEndpoint: "/sdk/run"
        )

        let output = try await check.run(settings: settings, timeoutNanoseconds: 1_000_000_000)

        XCTAssertEqual(output.text, "OK")
        let recorded = await recorder.recordedRequest()
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.model, "composer-2.5-fast")
        XCTAssertTrue(request.prompt.contains("Connectivity check"))
        XCTAssertTrue(request.sessionKey?.hasPrefix("diagnostics:") == true)
    }

    func testSDKSessionStoreReusesAndBoundsAgentIDs() async throws {
        let store = CursorSDKSessionStore(maxEntries: 2)

        let first = await store.agentID(for: "project-a")
        let second = await store.agentID(for: "project-b")
        let firstAgain = await store.agentID(for: "project-a")
        let third = await store.agentID(for: "project-c")
        let secondAfterEviction = await store.agentID(for: "project-b")
        let count = await store.count()

        XCTAssertEqual(first, firstAgain)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(third, first)
        XCTAssertNotEqual(secondAfterEviction, second)
        XCTAssertEqual(count, 2)
    }

    func testSDKSessionStoreDoesNotPersistAnonymousSessions() async throws {
        let store = CursorSDKSessionStore(maxEntries: 2)

        let first = await store.agentID(for: nil)
        let second = await store.agentID(for: nil)
        let empty = await store.agentID(for: "")
        let count = await store.count()

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, empty)
        XCTAssertEqual(count, 0)
    }

    func testSDKHarnessUsesSavedKeyForLocalPlaceholderTokens() {
        let settings = CursorAPISettings(cursorAPIKey: "crsr_saved")

        XCTAssertEqual(LocalCursorSDKHarness.resolvedCursorAPIKey(from: nil, settings: settings), "crsr_saved")
        XCTAssertEqual(LocalCursorSDKHarness.resolvedCursorAPIKey(from: "Bearer cursor-local", settings: settings), "crsr_saved")
        XCTAssertEqual(LocalCursorSDKHarness.resolvedCursorAPIKey(from: "Bearer CURSOR_API_KEY", settings: settings), "crsr_saved")
        XCTAssertEqual(LocalCursorSDKHarness.resolvedCursorAPIKey(from: "Bearer {env:CURSOR_API_KEY}", settings: settings), "crsr_saved")
    }

    func testSDKHarnessAllowsDirectBearerKeys() {
        let settings = CursorAPISettings(cursorAPIKey: "crsr_saved")

        XCTAssertEqual(LocalCursorSDKHarness.resolvedCursorAPIKey(from: "Bearer crsr_direct", settings: settings), "crsr_direct")
    }

    func testSDKHarnessReportsLockedKeyForLocalPlaceholderTokens() throws {
        let settings = CursorAPISettings(keychainCursorAPIKeyAvailable: true)

        XCTAssertThrowsError(try LocalCursorSDKHarness.resolvedCursorAPIKeyForRequest(from: "Bearer cursor-local", settings: settings)) { error in
            XCTAssertEqual(error as? CursorAPIError, .keychainLocked)
        }
        XCTAssertEqual(try LocalCursorSDKHarness.resolvedCursorAPIKeyForRequest(from: "Bearer crsr_direct", settings: settings), "crsr_direct")

        let payload = OpenAICompatibility.openAIError(CursorAPIError.keychainLocked)
        let error = try XCTUnwrap(payload["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "keychain_locked")
        XCTAssertTrue((error["message"] as? String)?.contains("Unlock Key") == true)
    }

    func testSDKHarnessMapsBridgeStreamAuthErrorsToUnauthorized() {
        XCTAssertEqual(
            LocalCursorSDKHarness.bridgeStreamError(from: [
                "message": "Error",
                "code": "unauthorized",
                "status": 401
            ]),
            .unauthorized
        )
        XCTAssertEqual(
            LocalCursorSDKHarness.bridgeStreamError(from: [
                "message": "Error",
                "code": "internal",
                "status": "401"
            ]),
            .unauthorized
        )
    }

    func testBridgeRecoveryRetriesAndRecyclesForRetryablePreOutputFailure() async throws {
        let probe = BridgeRecoveryProbe()

        let value = try await LocalCursorSDKHarness.executeBridgeRecoveryRetry(
            operation: { attempt in
                await probe.recordAttempt(attempt)
                if attempt == 1 {
                    throw LocalCursorSDKHarness.BridgeRecoveryError(
                        outwardError: .upstream("stale bridge"),
                        status: nil,
                        code: "  CURSOR_SDK_UNAVAILABLE ",
                        emittedOutput: false
                    )
                }
                return "ok"
            },
            recycle: {
                await probe.recordRecycle()
            },
            delay: {
                await probe.recordDelay()
            }
        )

        XCTAssertEqual(value, "ok")
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.attempts, [1, 2])
        XCTAssertEqual(snapshot.recycleCount, 1)
        XCTAssertEqual(snapshot.delayCount, 1)
    }

    func testBridgeRecoveryDoesNotRetryAfterOutputEmission() async throws {
        let probe = BridgeRecoveryProbe()

        do {
            _ = try await LocalCursorSDKHarness.executeBridgeRecoveryRetry(
                operation: { attempt in
                    await probe.recordAttempt(attempt)
                    throw LocalCursorSDKHarness.BridgeRecoveryError(
                        outwardError: .upstream("stream failed after output"),
                        status: 503,
                        code: "cursor_sdk_unavailable",
                        emittedOutput: true
                    )
                },
                recycle: {
                    await probe.recordRecycle()
                },
                delay: {
                    await probe.recordDelay()
                }
            )
            XCTFail("Expected bridge recovery to fail after emitted output.")
        } catch {
            XCTAssertEqual(error as? CursorAPIError, .upstream("stream failed after output"))
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.attempts, [1])
        XCTAssertEqual(snapshot.recycleCount, 0)
        XCTAssertEqual(snapshot.delayCount, 0)
    }

    func testBridgeRecoveryUnauthorizedDoesNotRecycleOrRetry() async throws {
        let probe = BridgeRecoveryProbe()

        do {
            _ = try await LocalCursorSDKHarness.executeBridgeRecoveryRetry(
                operation: { attempt in
                    await probe.recordAttempt(attempt)
                    throw LocalCursorSDKHarness.BridgeRecoveryError(
                        outwardError: .unauthorized,
                        status: 401,
                        code: "unauthorized",
                        emittedOutput: false
                    )
                },
                recycle: {
                    await probe.recordRecycle()
                },
                delay: {
                    await probe.recordDelay()
                }
            )
            XCTFail("Expected unauthorized bridge error.")
        } catch {
            XCTAssertEqual(error as? CursorAPIError, .unauthorized)
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.attempts, [1])
        XCTAssertEqual(snapshot.recycleCount, 0)
        XCTAssertEqual(snapshot.delayCount, 0)
    }

    func testBridgeRecoveryShutdownErrorDoesNotRecycleOrRetry() async throws {
        let probe = BridgeRecoveryProbe()

        do {
            _ = try await LocalCursorSDKHarness.executeBridgeRecoveryRetry(
                operation: { attempt in
                    await probe.recordAttempt(attempt)
                    throw LocalCursorSDKHarness.BridgeRecoveryError(
                        outwardError: .upstream("Bridge is shutting down"),
                        status: 503,
                        code: "bridge_shutting_down",
                        emittedOutput: false
                    )
                },
                recycle: {
                    await probe.recordRecycle()
                },
                delay: {
                    await probe.recordDelay()
                }
            )
            XCTFail("Expected bridge shutdown error.")
        } catch {
            XCTAssertEqual(error as? CursorAPIError, .upstream("Bridge is shutting down"))
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.attempts, [1])
        XCTAssertEqual(snapshot.recycleCount, 0)
        XCTAssertEqual(snapshot.delayCount, 0)
    }

    func testBridgeServerRefusesEndpointAfterShutdown() async throws {
        let settings = CursorAPISettings(cursorAPIKey: "crsr_test")

        await CursorSDKBridgeServer.shared.shutdown()

        do {
            _ = try await CursorSDKBridgeServer.shared.endpoint(settings: settings)
            XCTFail("Expected shutdown to block bridge launch.")
        } catch let error as CursorAPIError {
            XCTAssertEqual(error, .transport("Cursor SDK bridge is shutting down."))
        }

        await CursorSDKBridgeServer.shared.resetShutdownStateForTesting()
    }

    func testBridgeRecoveryNonRetryableUpstreamDoesNotRecycleOrRetry() async throws {
        let probe = BridgeRecoveryProbe()

        do {
            _ = try await LocalCursorSDKHarness.executeBridgeRecoveryRetry(
                operation: { attempt in
                    await probe.recordAttempt(attempt)
                    throw LocalCursorSDKHarness.BridgeRecoveryError(
                        outwardError: .upstream("internal failure"),
                        status: 500,
                        code: "internal",
                        emittedOutput: false
                    )
                },
                recycle: {
                    await probe.recordRecycle()
                },
                delay: {
                    await probe.recordDelay()
                }
            )
            XCTFail("Expected non-retryable upstream bridge error.")
        } catch {
            XCTAssertEqual(error as? CursorAPIError, .upstream("internal failure"))
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.attempts, [1])
        XCTAssertEqual(snapshot.recycleCount, 0)
        XCTAssertEqual(snapshot.delayCount, 0)
    }

    func testBridgeRecoveryTwoRetryableFailuresRecyclesOnceAndPreservesFinalUpstream() async throws {
        let probe = BridgeRecoveryProbe()

        do {
            _ = try await LocalCursorSDKHarness.executeBridgeRecoveryRetry(
                operation: { attempt in
                    await probe.recordAttempt(attempt)
                    throw LocalCursorSDKHarness.BridgeRecoveryError(
                        outwardError: .upstream("retryable failure \(attempt)"),
                        status: 503,
                        code: nil,
                        emittedOutput: false
                    )
                },
                recycle: {
                    await probe.recordRecycle()
                },
                delay: {
                    await probe.recordDelay()
                }
            )
            XCTFail("Expected retryable bridge recovery to fail after final attempt.")
        } catch {
            XCTAssertEqual(error as? CursorAPIError, .upstream("retryable failure 2"))
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.attempts, [1, 2])
        XCTAssertEqual(snapshot.recycleCount, 1)
        XCTAssertEqual(snapshot.delayCount, 1)
    }

    func testBridgeStopWaitForExitPollingSleepsUntilProcessStops() async {
        var runningStates = [true, true, false]
        var sleepDurations: [UInt64] = []

        let stopped = await CursorSDKBridgeServer.waitForExitPolling(
            timeoutNanoseconds: 1_000,
            pollIntervalNanoseconds: 100,
            isRunning: {
                guard !runningStates.isEmpty else { return false }
                return runningStates.removeFirst()
            },
            sleep: { duration in
                sleepDurations.append(duration)
            }
        )

        XCTAssertTrue(stopped)
        XCTAssertEqual(sleepDurations, [100, 100])
    }

    func testBridgeStopWaitForExitPollingTimesOutWhenProcessKeepsRunning() async {
        var sleepDurations: [UInt64] = []

        let stopped = await CursorSDKBridgeServer.waitForExitPolling(
            timeoutNanoseconds: 250,
            pollIntervalNanoseconds: 100,
            isRunning: { true },
            sleep: { duration in
                sleepDurations.append(duration)
            }
        )

        XCTAssertFalse(stopped)
        XCTAssertEqual(sleepDurations, [100, 100, 50])
    }

    func testBridgeStreamReadFailureMapsURLErrorToRetryableTransport() {
        let source = URLError(.networkConnectionLost)

        let mapped = LocalCursorSDKHarness.bridgeStreamReadFailure(from: source)

        let failure = mapped as? LocalCursorSDKHarness.BridgeRecoveryError
        XCTAssertEqual(
            failure?.outwardError,
            .transport("Cursor SDK bridge stream failed: \(source.localizedDescription)")
        )
        XCTAssertTrue(failure?.isRetryableBeforeOutput == true)
    }

    func testBridgeStreamReadFailurePreservesWrappedBridgeRecoveryError() {
        let wrapped = LocalCursorSDKHarness.BridgeRecoveryError(
            outwardError: .upstream("already wrapped"),
            status: 503,
            code: "cursor_sdk_unavailable",
            emittedOutput: true
        )

        let mapped = LocalCursorSDKHarness.bridgeStreamReadFailure(from: wrapped)

        XCTAssertEqual(mapped as? LocalCursorSDKHarness.BridgeRecoveryError, wrapped)
    }

    func testBridgeStreamReadFailurePreservesCancellation() {
        let mapped = LocalCursorSDKHarness.bridgeStreamReadFailure(from: CancellationError())

        XCTAssertTrue(mapped is CancellationError)
    }

    func testBridgeForceTerminationGraceExceedsNodeShutdownTimeout() {
        XCTAssertGreaterThan(
            CursorSDKBridgeServer.forceTerminationGraceMilliseconds,
            CursorSDKBridgeServer.bridgeShutdownTimeoutMilliseconds
        )
    }
}

private actor ConnectivityRecorder {
    private var request: PreparedChatRequest?

    func record(_ request: PreparedChatRequest) {
        self.request = request
    }

    func recordedRequest() -> PreparedChatRequest? {
        request
    }
}

private struct ConnectivityHarness: CursorSDKHarness {
    let recorder: ConnectivityRecorder

    func stream(prepared: PreparedChatRequest, settings: CursorAPISettings, authorization: String?) -> AsyncThrowingStream<CursorSDKStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recorder.record(prepared)
                continuation.yield(.text("OK"))
                continuation.yield(.done(CursorSDKOutput(text: "OK", agentID: "agent-diagnostics", runID: "run-diagnostics")))
                continuation.finish()
            }
        }
    }
}

private actor BridgeRecoveryProbe {
    private var attempts: [Int] = []
    private var recycleCount = 0
    private var delayCount = 0

    func recordAttempt(_ attempt: Int) {
        attempts.append(attempt)
    }

    func recordRecycle() {
        recycleCount += 1
    }

    func recordDelay() {
        delayCount += 1
    }

    func snapshot() -> (attempts: [Int], recycleCount: Int, delayCount: Int) {
        (attempts, recycleCount, delayCount)
    }
}
