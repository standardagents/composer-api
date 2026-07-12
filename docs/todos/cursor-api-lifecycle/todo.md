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
- Three scratch XCTest metadata files remain untracked under `macos/CursorAPI`; deletion was not authorized while the user was unavailable.
- No live credentialed model call, app restart, or termination of an existing process was performed.

## Authorized local installation follow-up

On 2026-07-12 the user explicitly authorized terminating the installed app and its helper processes, building the current worktree, and replacing `/Applications/API for Cursor.app`.

- Scope: terminate only processes running from the installed app bundle, package a development app from this worktree, verify the bundle, and replace the installed app.
- Non-goal: no credentialed model request, release signing, notarization, publication, or remote update.
- Acceptance: old helper PIDs are gone; the package verifier passes; the replacement keeps bundle id `ai.standardagents.cursorapi`, uses version `0.1.10` build `13`, contains the fixed bridge script and rebuilt Swift executable, and passes static code-signature verification.
- Boundary: do not launch the replacement or make a live API request unless separately requested.

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
