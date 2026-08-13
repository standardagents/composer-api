# Cursor API Lifecycle Stability

## Goal

Eliminate recurring local Responses API failures caused by stale or incompletely disposed Cursor SDK bridge state, while preserving the existing OpenAI-compatible API and security boundaries.

## Scope

- Trace the macOS app, local API, SDK harness, Node/Bun bridge, and `@cursor/sdk` lifecycle end to end.
- Reproduce cleanup and restart behavior with local fixtures only.
- Fix bridge ownership, asynchronous SDK disposal, and retry-time bridge recycling.
- Keep current public request and response shapes unchanged.
- Document the lifecycle contract and dependency decision.

## Non-goals

- No credentialed model calls, real app restarts, or termination of user-owned processes.
- No hosted Worker, auth, persistence, routing, or schema changes.
- No dependency update without evidence that it addresses the observed failure.
- No commit, push, pull request, deployment, or release.

## Acceptance criteria

- SDK agents are asynchronously disposed before replacement or bridge exit.
- A bridge exits when its launching parent disappears.
- The macOS owner allows enough time for graceful bridge cleanup before force termination.
- A retryable pre-output SDK bridge failure recycles the bridge once and preserves the existing outward error contract if recovery fails.
- Focused lifecycle fixtures fail before the fix and pass after it.
- Repository-native JS and Swift checks pass.
- Required local security gates pass, or unavailable tooling is reported as a blocker.

## Assumptions and boundaries

- The observed `run.wait()` result with `status=error` and no details is retryable only before any response content has been emitted.
- `@cursor/sdk` 1.0.13 exposes `Symbol.asyncDispose`; its documented `close()` starts asynchronous disposal without waiting.
- The bridge runtime is a direct child of the macOS app in packaged operation.
- Bridge recycling is intentionally process-wide because all local SDK sessions share one owned bridge process. A recycle disposes every cached agent and may interrupt unrelated concurrent requests; complete removal of poisoned bridge state takes precedence, and affected callers retain the existing retryable public error contract.
- Live behavior still requires an explicitly approved credentialed proof after local verification.

## Stop conditions

- Stop implementation if the local fixture falsifies the asynchronous-disposal or parent-ownership hypothesis.
- Stop after the same verifier rejection key occurs twice and report the evidence instead of stacking another speculative fix.
- Stop before any live call, app restart, or termination of an existing process unless the coordinating parent explicitly approves it.

## Root-cause evidence

### Known facts

- Before the fix, the bridge called `agent.close()` when evicting agents and during process shutdown.
- In `@cursor/sdk` 1.0.13, `close()` calls the asynchronous executor-release path without awaiting it; `Symbol.asyncDispose` awaits that path.
- Before the fix, the bridge forced `process.exit()` after 500 ms.
- Before the fix, the macOS bridge owner sent `SIGTERM` and force-killed the bridge after one second.
- Before the fix, the bridge had no parent-loss watchdog, so an abnormal app exit could leave it running.
- The SDK dependency was introduced at 1.0.13 and remains lockfile-resolved to 1.0.13; current official release is 1.0.23.
- Version 1.0.23 retains the same non-awaiting `close()` semantics and raises the Node requirement to 22.13, so an update alone does not address cleanup.

### Confirmed repository root cause

The bridge did not await SDK executor disposal before agent replacement or process exit, and it did not terminate when its launching parent disappeared. The macOS retry path also reused the same bridge after a retryable pre-output SDK failure. Deterministic fixtures proved each lifecycle gap: cleanup resolved before delayed disposal, replacement started before old disposal, parent loss did not request shutdown, and retry did not recycle the bridge. These defects explain how stale helper or executor state could survive app lifecycles and why terminating orphan helpers temporarily restored service. A credentialed live run is still required to prove the complete production failure chain against Cursor's upstream service.

### Minimal falsification tests

- A fake SDK agent whose async disposal completes after a delay must be fully disposed before bridge resource shutdown resolves.
- Parent PID change detection must request bridge shutdown exactly once.
- A retryable bridge stream error emitted before output must recycle the bridge before the second attempt.

## Feature / Verification Matrix

| Change | Verification | Status | Evidence |
| --- | --- | --- | --- |
| Await SDK disposal | Focused Vitest lifecycle fixture | Pass | 65 focused tests pass; cleanup awaits delayed disposal, in-flight creation, and pending per-key eviction |
| Parent-loss cleanup | Focused Vitest watchdog fixture | Pass | PID change requests the shared graceful shutdown path once; PID 1 parent disables the watchdog |
| Graceful macOS ownership | Swift lifecycle test | Pass with substitute | Core build, standalone verifier, and permanent-test typecheck prove 15-second bridge cleanup plus 1-second force-kill grace |
| Retry-time bridge recycle | Swift harness policy test | Pass with substitute | Five recovery scenarios prove one pre-output recycle and unchanged outward errors |
| Public API preservation | Existing Responses API tests | Pass | Full Vitest suite passes 236 tests; public request, response, auth, routing, schema, and outward error contracts are unchanged |

## Integrated verification

- `npm test`: 236 tests passed across 9 files.
- `npm run typecheck`: passed.
- `npm run build`: passed.
- Focused bridge suite: 65 tests passed; `node --check` passed.
- `swift build --target CursorAPICore`: passed.
- Standalone Swift recovery verifier: passed.
- `ConnectivityCheckTests.swift` typecheck with the scratch XCTest declaration module: passed.
- `swift test --filter ConnectivityCheckTests`: blocked because the host has Command Line Tools but no XCTest/Xcode runtime.
- Full Semgrep fallback: 26 pre-existing findings and exit 1.
- Semgrep baseline diff scan: 0 findings introduced by this task.
- OSV was not required because dependency and lockfile surfaces did not change.
- Three tracked scratch XCTest metadata files under `macos/CursorAPI` were removed during the authorized closure follow-up.
- No live credentialed model call was performed during the initial implementation verification.

## Authorized local installation follow-up

On 2026-07-12 the user explicitly authorized terminating the installed app and its helper processes, building the current worktree, and replacing `/Applications/API for Cursor.app`.

- Scope: terminate only processes running from the installed app bundle, package a development app from this worktree, verify the bundle, and replace the installed app.
- Non-goal: no credentialed model request, release signing, notarization, publication, or remote update.
- Acceptance: old helper PIDs are gone; the package verifier passes; the replacement keeps bundle id `ai.standardagents.cursorapi`, uses version `0.1.10` build `13`, contains the fixed bridge script and rebuilt Swift executable, and passes static code-signature verification.
- Boundary: do not launch the replacement or make a live API request unless separately requested.

### 2026-07-12 Task 5 execution evidence

- Process pre-check (before replacement): `python3` scan over `ps -axo pid,ppid,command` for `/Applications/API for Cursor.app` returned `matching_processes=none`; no termination was needed.
- Build command: `TMPDIR="$PWD/macos/CursorAPI/.build/tmp" CURSOR_API_APP_VERSION=0.1.10 CURSOR_API_APP_BUILD=13 macos/CursorAPI/Scripts/package-app.sh --development` → pass, produced `macos/CursorAPI/dist/API for Cursor.app`.
- Explicit package verifier: `TMPDIR="$PWD/macos/CursorAPI/.build/tmp" macos/CursorAPI/Scripts/verify-package.sh "macos/CursorAPI/dist/API for Cursor.app"` → pass.
- Dist metadata and signature: `CFBundleDisplayName=API for Cursor`, `CFBundleIdentifier=ai.standardagents.cursorapi`, `CFBundleShortVersionString=0.1.10`, `CFBundleVersion=13`; `codesign --verify --deep --strict` passed.
- Bridge payload integrity: `shasum -a 256` for `scripts/cursor-sdk-local-agent-bridge.mjs`, dist payload, and installed payload all matched: `b4c49350aba20a2ead1afae38bf660377dd36263297d29b47d224822e14cb033`.
- Swift executable evidence: `macos/CursorAPI/dist/API for Cursor.app/Contents/MacOS/API for Cursor` exists and is executable (`size=2571216`, `mtime=2026-07-12T12:10:44+0200`), newer than the prior installed executable (`size=2504144`, `mtime=2026-07-09T19:36:25+0200`).
- Atomic-style replacement: staged copy at `/Applications/API for Cursor.app.__stage_task5_20260712` verified (metadata/signature/checksum), current app moved to rollback sibling `/Applications/API for Cursor.app.__rollback_task5_20260712`, staged app promoted to `/Applications/API for Cursor.app`, installed app re-verified, then rollback sibling removed.
- Installed verification after promotion: bundle id `ai.standardagents.cursorapi`, version `0.1.10`, build `13`, `codesign --verify --deep --strict` pass, executable present/executable, and post-install process scan returned `post_install_matching_processes=none`.
- Boundary kept: no app launch and no live API/model request were performed.

### 2026-07-12 closure follow-up

- The installed build launched successfully and reported `ready` on its localhost health endpoint with the saved key unlocked and one SDK bridge child.
- A live streaming `/v1/responses` request using `composer-2.5` returned `response.created`, `response.in_progress`, output events, `response.completed`, and the expected `LIVE_OK` text.
- The same request using `composer-2.5-fast` reproducibly returned `response.created`, `response.in_progress`, then `upstream_error` without output.
- Bridge logs confirmed all four Node SDK-run attempts and one Swift bridge recycle to a fresh bridge before the final fast-model failure. This proves the lifecycle recovery path executes, but does not make the upstream fast variant succeed.
- Changing `composer-2.5-fast` to fall back to the non-fast variant would alter externally visible model behavior and requires an explicit product decision.
- The three unintended tracked `xctest-shim` compiler metadata files were removed.

### 2026-07-12 combined lifecycle and stable-port installation

- The stable bridge-port fix was integrated on top of the lifecycle fix: `9d71542` followed by `febf69b`.
- Combined verification passed: 236/236 JavaScript tests, TypeScript typecheck, `swift build --package-path macos/CursorAPI --target CursorAPICore`, and `swift build --package-path macos/CursorAPI`.
- Build command: `TMPDIR="$PWD/macos/CursorAPI/.build/tmp" CURSOR_API_APP_VERSION=0.1.10 CURSOR_API_APP_BUILD=14 macos/CursorAPI/Scripts/package-app.sh --development` passed.
- The package verifier and `codesign --verify --deep --strict` passed; the packaged bridge script matched the worktree checksum `b4c49350aba20a2ead1afae38bf660377dd36263297d29b47d224822e14cb033`.
- `/Applications/API for Cursor.app` was replaced using a verified staged copy and rollback sibling, then re-verified as version `0.1.10` build `14`.
- Real restart proof passed: the first clean start used app PID `49390`, bridge PID `49561`, and internal port `8792`; the second used app PID `49695`, bridge PID `49735`, and the same internal port `8792`.
- Both app exits were requested through the bundle identifier, and both the app and bridge processes exited after each run. No credentialed model request was made during the build 14 restart check.
- Final combined review found no Critical issue. Its one Important concurrency observation was accepted and documented explicitly: bridge recycling is process-wide and can interrupt unrelated concurrent requests because all SDK sessions share the owned bridge process. The focused follow-up review returned `ACCEPT`.
- Final Semgrep scanning of all seven changed JavaScript and Swift code/test files reported three blocking findings. All three are unchanged `main` findings at the JSON pointer/schema validation code (`d67dbf54` and `bb0515eb`); none was introduced by this task.

## Subagent ledger

| Workstream | Scope | Edits | Result | Residual risk |
| --- | --- | --- | --- | --- |
| RED lifecycle fixture | Bridge script and focused Vitest file | Allowed | Deterministic early-resolution failure reproduced | Test seam expands the module export surface |
| RED verifier and reviews | Same two files and focused command evidence | Read-only | Verifier accepted; spec and quality reviews passed | Green phase must make `closeAndExit` await cleanup |
| Deterministic bridge cleanup | Bridge script and focused Vitest file | Allowed | Async disposal, serialized replacement, parent watchdog, shutdown drain, and LRU behavior implemented | Real SDK disposal latency remains bounded by the 15-second force-exit fallback |
| Bridge cleanup verification | Current task-owned diff and focused commands | Read-only | Final verifier accepted 65 tests and syntax check; no Critical/Important review findings | Live recovery still requires explicit approval |
| Swift bridge recovery | Harness, bridge owner, connectivity tests, standalone verifier | Allowed | Retryable pre-output failures recycle once; stop polling is async and reentrancy-safe | Real bridge process behavior remains unproved without live-call approval |
| Swift recovery verification | Current Swift diff, core build, standalone verifier, test typecheck | Read-only | Final verifier accepted all nine requirements; no Critical/Important review findings | `swift test` cannot load XCTest because only Command Line Tools are installed |
| Lifecycle documentation | README and production runbook | Allowed | Ownership, two retry layers, timeout derivation, verification limits, and dependency decision documented | Historical dependency note must be re-evaluated with SDK or runtime changes |
| Documentation verification | Current documentation diff | Read-only | Final verifier accepted implementation facts, privacy boundaries, and diff hygiene | None |
| Simplification pass | Active Node and Swift production diff | Allowed | Removed dead branching and narrowed shutdown state without changing behavior | Focused checks passed after cleanup |
| Final implementation review | Production lifecycle and test coverage lanes | Read-only | Both lanes accepted with no Critical/Important findings | XCTest runtime and live upstream behavior remain unverified |
| Integrated verification | Entire task-owned diff and repo-native commands | Read-only | All task-owned checks passed; Semgrep diff introduced zero findings | Full XCTest unavailable; full Semgrep remains red on 26 pre-existing findings |
