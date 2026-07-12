# Stable SDK Bridge Port

## Sprint Contract

**Goal:** Reuse the same internal Cursor SDK bridge port across clean macOS app restarts while retaining a bounded fallback when that port is occupied.

**Source of truth:** The current user request. No separate specification exists.

**Scope:**

- Keep an internal preferred bridge port separate from `CursorAPISettings.port`.
- Try the remembered bridge port first, then the existing bounded bridge range.
- Remember only a bridge port that launched and passed its health check.
- Add deterministic regression coverage for restart reuse and occupied-port fallback.

**Non-goals:**

- Do not change the public local API port, API/auth/routing behavior, bridge token handling, or external service configuration.
- Do not launch or replace the installed macOS app, terminate user processes, make live model calls, push, publish, deploy, or modify another worktree.
- Do not duplicate the separate app lifecycle fix that is absent from `main`.

**Acceptance criteria:**

1. A deterministic test reproduces the missing preferred-port reuse.
2. A clean restart uses the previously successful internal bridge port.
3. An occupied preferred port falls back within ports 8792 through 8892.
4. The successful fallback becomes the next preferred bridge port.
5. The public API port persistence remains unchanged.

**Assumptions:**

- A clean restart releases the prior bridge listener. On `main`, graceful app termination already awaits `model.shutdown()` and the bridge shutdown before replying to macOS; force-quit and crash recovery remain out of scope.
- `UserDefaults` is appropriate for a non-secret, app-local bridge port preference.

**Known boundaries:**

- Adds app-local persistence for a non-secret internal bridge preference under a dedicated key.
- Does not persist or change the bridge authentication token.
- Full feature-loop authorization includes task-owned merge preparation against the captured local `main`, but not fetch, pull, push, publish, deploy, or destructive cleanup.

**Intended verification:**

- Run the new focused Swift tests red before implementation and green afterward.
- Run the relevant CursorAPI Swift test target and build.
- Run the repository-required security gates for the touched persistence/code surface.
- Obtain independent implementation review and final verifier acceptance.

**Stop conditions:**

- Stop before any auth, routing, schema, external service, or public API persistence change.
- Stop if satisfying the behavior requires inspecting or modifying another worktree.
- Stop after the same verifier rejection occurs twice.
- Report any dependency on lifecycle code absent from `main`.

## Feature / Verification Matrix

| Change | Verification | Status | Evidence |
| --- | --- | --- | --- |
| Reuse successful bridge port after restart | `testCleanRestartReusesLastHealthyBridgePort` and production-path harness | Pass | Harness selected 8793 on the first run and reused 8793 after 8792 became free |
| Fall back when preferred bridge port is occupied | `testOccupiedPersistedPreferenceFallsBackAndRewritesPreference` and production-path harness | Pass | Occupied 8841 fell back to 8792; all 101 candidates stayed unique within 8792...8892 |
| Persist only a healthy bridge port | `testHealthGateOnlyPersistsPortAfterHealthyLaunch` and production-path harness | Pass | Preference remained 8841 for 40 failed polls and changed to 8792 only after healthy fallback |
| Keep public API port separate | `testBridgePreferencePersistenceDoesNotOverwritePublicSettings`, diff review, and harness | Pass | `CursorAPI.settings.v1`, `CursorAPISettings`, `AppSettingsStore`, auth, and routing remained unchanged |

## Subagent Ledger

| Workstream | Allowed scope | Edits | Expected output | Result | Residual risk |
| --- | --- | --- | --- | --- | --- |
| Pre-implementation test review | Task record, plan, bridge server, and tests | No | Acceptance and verification-gap findings | Rejected helper-only coverage with `missing-production-wiring-regression`; plan corrected to drive the real server startup loop | None after correction |
| Pre-implementation architecture review | Revised plan and current bridge lifecycle/settings code | No | Architecture and Swift 6 viability decision | ACCEPT; baseline build passed and equivalent dependency shapes compiled under Swift 6 | Clean-restart scope excludes crashes and force-quit |
| Implementation worker | Three task-owned Swift files | Yes | TDD implementation and focused evidence | DONE_WITH_CONCERNS; changed only assigned files, production build passed, XCTest unavailable | Repo XCTest commands need a full Xcode/XCTest toolchain |
| Initial independent verifier | Task-owned diff and fresh command evidence | No | Acceptance or actionable rejection | ACCEPT; both builds passed and a temporary harness executed the real startup loop with 21 passing assertions | XCTest remains unavailable locally |
| Spec-compliance review | Task-owned diff and Sprint Contract | No | Requirement coverage decision | ACCEPT | Installed app was not launched, per scope |
| Code-quality review | Task-owned Swift diff and neighboring conventions | No | Correctness, concurrency, and maintainability decision | ACCEPT; full build passed | XCTest remains unavailable locally |
| Final independent verifier | Final task-owned diff and fresh evidence | No | Final acceptance before completion | ACCEPT; both builds passed and a fresh real-code harness passed 23 assertions | Checked-in XCTest remains unexecuted until a full Xcode/XCTest toolchain is available |

## Verification Evidence

- `swift test --package-path macos/CursorAPI --filter CursorSDKBridgeServerTests` cannot compile on either `main` or this branch because the installed Command Line Tools lack the `XCTest` module.
- `swift build --package-path macos/CursorAPI --target CursorAPICore` passed.
- `swift build --package-path macos/CursorAPI` passed.
- The initial verifier's temporary no-XCTest harness exercised `CursorSDKBridgeServer.start` with 21 passing assertions. The final verifier repeated the current-diff check with 23 passing assertions, including three invalid-value cases. Both scratch harnesses were removed.
- `git diff --check` passed.
- Simplification pass found no behavior-preserving reduction that improved clarity enough to justify changing the accepted diff.

## Review And Security Evidence

- Focused Security/Privacy and Integration/Test reviews both returned ACCEPT.
- The authoritative fresh read-only implementation review returned `NO FINDINGS`.
- Passive secure-default review found no major or critical issue in the dedicated non-secret preference, loopback binding, token handling, subprocess path, or public API boundary.
- Task-scoped Semgrep scanned all three changed Swift files with 49 rules and returned zero findings.
- Whole-repository Semgrep reported 26 pre-existing findings only in unchanged files; none overlap the task-owned diff.
- OSV is not applicable because dependencies, lockfiles, containers, vendored code, and package surfaces did not change.
- Automated `codex review --uncommitted` could not run: the installed Codex CLI rejects the configured model as requiring a newer CLI, and its supported fallback rejects ChatGPT-account use. No CLI upgrade or login change was attempted.
- Staged Gitleaks scanned approximately 40.29 KB and found no leaks.
- Captured local `main` is `60906522e8cd620b5ad1a1823a1b20f92d0f2ab9`, identical to the branch base; local-main integration is expected to be a no-op after the task commit.
