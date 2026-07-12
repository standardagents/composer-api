# Cursor API Lifecycle Stability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the local Cursor SDK bridge self-cleaning and recoverable without changing the OpenAI-compatible API.

**Architecture:** The Node/Bun bridge owns SDK agents and must await their asynchronous disposal before replacement or exit. The bridge also watches its launching parent, while the Swift owner coordinates graceful termination and recycles the bridge once for retryable pre-output failures.

**Tech Stack:** Node.js ESM, `@cursor/sdk`, Vitest, Swift 6, Foundation `Process`, Swift Testing/XCTest.

**Commit Policy:** Commits are not authorized. The handoff must list all uncommitted task-owned changes.

---

### Task 1: Prove the cleanup failure locally

**Files:**
- Modify: `scripts/cursor-sdk-local-agent-bridge.test.mjs`
- Modify: `scripts/cursor-sdk-local-agent-bridge.mjs`

**Verifier:**
- Commands that must be fresh: `npm test -- --run scripts/cursor-sdk-local-agent-bridge.test.mjs`
- Expected evidence: the new fixture initially fails because shutdown returns before asynchronous SDK disposal completes.
- Notes: the same `rejection_key` twice stops and surfaces the task.

- [x] **Step 1: Export a test seam for bridge resource cleanup**

Expose a cleanup function that accepts explicit fake agent entries and an HTTP-server close callback without starting a real SDK agent.

- [x] **Step 2: Write the failing delayed-disposal fixture**

Use a fake agent with `Symbol.asyncDispose` that resolves only after the test releases it, then assert bridge cleanup remains pending until that release.

- [x] **Step 3: Run the focused test and record the expected failure**

Run: `npm test -- --run scripts/cursor-sdk-local-agent-bridge.test.mjs`

Expected: FAIL because the current implementation calls `close()` and does not await SDK disposal.

### Task 2: Implement deterministic bridge ownership

**Files:**
- Modify: `scripts/cursor-sdk-local-agent-bridge.mjs`
- Modify: `scripts/cursor-sdk-local-agent-bridge.test.mjs`

**Verifier:**
- Commands that must be fresh: `npm test -- --run scripts/cursor-sdk-local-agent-bridge.test.mjs`
- Expected evidence: delayed disposal, eviction ordering, and parent-loss fixtures pass.
- Notes: the same `rejection_key` twice stops and surfaces the task.

- [x] **Step 1: Await SDK disposal**

Prefer `await agent[Symbol.asyncDispose]()` and fall back to `agent.close()` only when the async protocol is unavailable.

- [x] **Step 2: Serialize eviction with cleanup**

Make retry and cache-eviction paths await disposal before creating a replacement SDK agent.

- [x] **Step 3: Add parent-loss detection**

Capture the initial parent PID and request one graceful shutdown if the parent changes; disable this check when the bridge starts as PID 1's child.

- [x] **Step 4: Coordinate process exit**

Stop accepting new HTTP work, dispose all cached agents, close the server, and retain a bounded force-exit fallback.

- [x] **Step 5: Run the focused verifier**

Run: `npm test -- --run scripts/cursor-sdk-local-agent-bridge.test.mjs`

Expected: PASS.

### Task 3: Recycle poisoned bridge state in the macOS harness

**Files:**
- Modify: `macos/CursorAPI/Sources/CursorAPICore/CursorSDKHarness.swift`
- Modify: `macos/CursorAPI/Sources/CursorAPICore/CursorSDKBridgeServer.swift`
- Modify: `macos/CursorAPI/Tests/CursorAPITests/ConnectivityCheckTests.swift`

**Verifier:**
- Commands that must be fresh: `cd macos/CursorAPI && swift test --filter ConnectivityCheckTests`
- Expected evidence: a retryable 503 or `cursor_sdk_unavailable` event is marked for one pre-output recycle, while auth and non-retryable upstream errors retain their existing mappings.
- Notes: the same `rejection_key` twice stops and surfaces the task.

- [x] **Step 1: Write retry-policy tests**

Cover retryable opaque SDK failures, explicit authentication failures, and non-retryable upstream failures.

- [x] **Step 2: Preserve the outward error contract**

Wrap retryable bridge failures internally, recycle the bridge before the second attempt, and unwrap the existing `CursorAPIError.upstream` if the retry also fails.

- [x] **Step 3: Extend graceful process shutdown**

Allow the bridge's bounded asynchronous cleanup window to finish before the existing force-kill fallback.

- [x] **Step 4: Run the focused Swift verifier**

Run: `cd macos/CursorAPI && swift test --filter ConnectivityCheckTests`

Expected: PASS.

### Task 4: Document and verify the integrated fix

**Files:**
- Modify: `README.md`
- Modify: `docs/production.md`
- Modify: `docs/todos/cursor-api-lifecycle/todo.md`

**Verifier:**
- Commands that must be fresh: `npm test`, `npm run typecheck`, `npm run build`, `cd macos/CursorAPI && swift test`
- Expected evidence: all repository-native checks pass and lifecycle documentation matches the implemented behavior.
- Notes: run the repository security gate if present; otherwise run required Semgrep. OSV is not required unless dependency files change. The same `rejection_key` twice stops and surfaces the task.

- [x] **Step 1: Document bridge ownership and recovery**

Explain that the bridge follows the app parent, awaits SDK disposal, and is recycled once for retryable pre-output failures.

- [x] **Step 2: Record the dependency intake decision**

Document that 1.0.23 keeps non-awaiting `close()` semantics, requires Node 22.13, and is deferred because it is not the root-cause fix.

- [x] **Step 3: Run focused and full verification**

Run the verifier commands plus the available security gates, then update the task matrix with exact evidence.

- [x] **Step 4: Prepare the parent handoff**

Report root cause, changed files, commands, residual uncertainty, and that a credentialed live proof still requires explicit approval.

### Task 5: Install the fixed local app

**Files and paths:**
- Build: `macos/CursorAPI/dist/API for Cursor.app`
- Replace: `/Applications/API for Cursor.app`

**Verifier:**
- Commands that must be fresh: `macos/CursorAPI/Scripts/verify-package.sh`, `codesign --verify --deep --strict`, bundle metadata checks, and installed bridge checksum comparison.
- Expected evidence: version `0.1.10` build `13`, fixed bridge payload matches the worktree, and no old helper process remains.

- [ ] **Step 1: Stop the installed app and orphan helpers**
- [ ] **Step 2: Build and verify the development package**
- [ ] **Step 3: Replace and statically verify the installed app**
