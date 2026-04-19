---
phase: 02-zig-core-poll-engine-github
plan: "05"
subsystem: core-poll-engine
tags: [zig, integration-test, mock-server, sqlite, github-api, polling]

dependency_graph:
  requires: [02-04]
  provides: [phase-2-gate, poll-engine-verified]
  affects: [libtowncrier-c-abi]

tech_stack:
  added: []
  patterns:
    - raw POSIX socket mock HTTP server (std.c.socket/bind/listen/accept)
    - std.Io.Mutex for mock server thread safety (Zig 0.16)
    - two-pass ArrayList string buffer to prevent dangling pointer on realloc
    - atomic wait loop replacing std.time.sleep (removed in 0.16)
    - std.c.clock_gettime for milliTimestamp (std.time.milliTimestamp removed in 0.16)
    - std.c.nanosleep for sleepNs (std.time.sleep removed in 0.16)

key_files:
  created:
    - tests/core/poll_test.zig
  modified:
    - build.zig
    - src/github.zig
    - src/http.zig
    - src/poller.zig
    - src/store.zig

decisions:
  - id: raw-posix-mock-server
    summary: Used raw POSIX socket API instead of std.net.Server for mock HTTP server due to Zig 0.16 API instability in std.net
  - id: serialized-sqlite
    summary: Changed SQLite threading mode to Serialized (-DSQLITE_THREADSAFE=1) — MultiThread mode caused misaligned memory crash when two poll threads shared one connection
  - id: id-uniqueness-xor
    summary: Notification u64 id is api_id_num XOR (account_id << 32) — ensures two accounts polling same notification produce different primary keys
  - id: two-pass-snapshot
    summary: buildAndDeliverSnapshot uses two passes over notifications — first stores string byte offsets, second fixes pointers after ArrayList is finalized — prevents dangling pointers on mid-loop reallocation

metrics:
  duration_minutes: 180
  completed_date: "2026-04-17"
  tasks_completed: 2
  tasks_total: 2
  files_changed: 6
---

# Phase 02 Plan 05: Poll Engine Integration Test Summary

**One-liner:** Headless integration test with in-process mock HTTP server verifying all 11 Phase 2 requirements (CORE-03..08, GH-01..05) against a stateful POSIX socket server.

## What Was Built

`tests/core/poll_test.zig` — a standalone Zig executable (not `zig test`) that:
- Starts a raw POSIX socket HTTP mock server on port 0 (OS-assigned ephemeral port)
- Initializes libtowncrier with two GitHub accounts pointing at the mock
- Exercises all 11 Phase 2 requirements via sequential assertion steps
- Exits 0 with "ALL TESTS PASSED" on success, exits 1 on any failure

`build.zig` — gained the `test-poll` step wiring `poll_test` as a `b.addExecutable` with `poll_test_mod.linkLibrary(lib)`.

## Requirements Verified

| Requirement | Test Coverage |
|-------------|---------------|
| CORE-03 | X-Poll-Interval: 2 sent by mock; timing verified by poll duration |
| CORE-04 | Two accounts each fire on_update; update_count >= 2 asserted |
| CORE-05 | Snapshot contains 4 notifications (2 per account); fields populated |
| CORE-06 | Snapshot items ordered owner/repo-a before owner/repo-b (alphabetical) |
| CORE-07 | Stop, re-init, restart: marked-read notification absent from new snapshot |
| CORE-08 | SQLite DB file binary-searched for token strings; assertion fails if found |
| GH-01 | Two accounts added via PAT; both poll independently |
| GH-02 | API URLs rewritten to web URLs (no api.github.com in snapshot) |
| GH-03 | Second poll receives 304; not_modified_count incremented in mock |
| GH-04 | mark_read enqueues action; PATCH issued to mock; notification absent from snapshot |
| GH-05 | Two accounts with distinct tokens and independent poll state |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] SQLite misaligned memory crash under two poll threads**
- **Found during:** Task 2 (test ran, crashed in store.zig)
- **Issue:** `sqlite.Db.init` used `.MultiThread` threading mode (`SQLITE_THREADSAFE=2` = no mutex). Two poll threads accessing shared connection caused `member access within misaligned address` SIGABRT.
- **Fix:** Changed `store.open()` to `.Serialized` and `build.zig` SQLite compile flag to `-DSQLITE_THREADSAFE=1`.
- **Files modified:** `src/store.zig`, `build.zig`
- **Commit:** 5b03aeb

**2. [Rule 1 - Bug] Primary key collision for two-account fixtures**
- **Found during:** Task 2 (snapshot had 2 items instead of 4)
- **Issue:** Both accounts parsed the same fixture JSON (`"id": "123456789"`). The numeric id produced identical u64 primary keys, causing SQLite upsert to deduplicate them.
- **Fix:** Changed id generation in `github.zig` to `api_id_num ^ (@as(u64, account.id) << 32)` — mixes account_id into high bits.
- **Files modified:** `src/github.zig`
- **Commit:** 5b03aeb

**3. [Rule 1 - Bug] PATCH sendBodiless panic**
- **Found during:** Task 2 (GH-04 mark_read caused panic in http.zig)
- **Issue:** `req.sendBodiless()` asserts `!r.method.requestHasBody()`. PATCH returns true, causing panic.
- **Fix:** Changed `http.zig` PATCH to `sendBodyComplete(&empty_body)` with a zero-length byte array.
- **Files modified:** `src/http.zig`
- **Commit:** 5b03aeb

**4. [Rule 1 - Bug] Dangling pointer integer overflow in snapshot_get**
- **Found during:** Task 2 (towncrier_snapshot_get triggered overflow at c_api.zig:279)
- **Issue:** `buildAndDeliverSnapshot` assigned `item.repo = @ptrCast(string_buf.items[offset..].ptr)` mid-loop. When `string_buf` grew and reallocated, earlier pointers were invalidated. The pointer rebasing arithmetic in `snapshot_get` then underflowed.
- **Fix:** Changed `poller.zig` to two-pass: first pass stores byte offsets into `string_buf`, items get null pointers; second pass after loop assigns final stable pointers from `string_buf.items.ptr`.
- **Files modified:** `src/poller.zig`
- **Commit:** 5b03aeb

**5. [Rule 3 - Blocking] Zig 0.16 API removals blocked compilation**
- **Found during:** Task 2 (multiple compile errors)
- **Issues:**
  - `std.heap.GeneralPurposeAllocator` renamed to `DebugAllocator` — used `std.heap.c_allocator` instead
  - `std.Thread.Mutex` moved to `std.Io.Mutex` — added `io: std.Io` field to MockServer
  - `std.time.milliTimestamp()` removed — added `milliTimestamp()` helper via `std.c.clock_gettime`
  - `std.time.sleep()` removed — added `sleepNs()` helper via `std.c.nanosleep`
  - `std.fs.openFileAbsolute` removed — replaced with `std.posix.openat(AT.FDCWD, ...)`
  - `[*c]const T` field access requires `ptr[0].field` not `ptr.field`
  - `onError` callback: `[*c]const u8` not `[*:0]const u8` (C ABI translation)
- **Files modified:** `tests/core/poll_test.zig`
- **Commit:** 5b03aeb

**6. [Rule 1 - Bug] Race condition: snapshot had 3 items instead of 4**
- **Found during:** Task 2 (CORE-05 assertion failed)
- **Issue:** Waiting for `update_count >= 2` doesn't guarantee both threads stored all notifications before snapshot was taken; one thread may have fired its callback before persisting.
- **Fix:** Added second wait: `lastUnreadAtLeast(4)` with 10s timeout before snapshot assertions.
- **Files modified:** `tests/core/poll_test.zig`
- **Commit:** 5b03aeb

**7. [Rule 1 - Bug] Stale DB from previous test run caused count mismatch**
- **Found during:** Task 2 (is_read=1 rows from prior run reducing unread count)
- **Fix:** Added `cleanupTestDb()` at test start to delete `~/.local/share/towncrier/state.db` if it exists.
- **Files modified:** `tests/core/poll_test.zig`
- **Commit:** 5b03aeb

**8. [Rule 1 - Bug] HttpConnectionClosing on second poll cycle**
- **Found during:** Task 2 (GH-03 304 check failing)
- **Issue:** Zig HTTP client tries to reuse keep-alive connection; mock closes socket after each response.
- **Fix:** Added `Connection: close\r\n` header to all mock HTTP responses.
- **Files modified:** `tests/core/poll_test.zig`
- **Commit:** 5b03aeb

## Test Run Output

```
poll_test: starting Phase 2 integration test
poll_test: cleaned up test DB
poll_test: mock server listening on port 46709
poll_test: GH-01 — init and add two accounts
poll_test: CORE-04/GH-05 — start and wait for two on_update callbacks
poll_test: CORE-04/GH-05 PASS — update_count=2
poll_test: CORE-05/GH-02 — snapshot content check
poll_test: CORE-05/GH-02 PASS — 4 notifications, URLs rewritten
poll_test: CORE-06 — notifications grouped by repo
poll_test: CORE-06 PASS — notifications ordered by repo
poll_test: GH-03 — 304 Not Modified on second poll
poll_test: GH-03 PASS — 2 304 responses received
poll_test: GH-04 — mark_read issues PATCH; notification absent from next snapshot
poll_test: GH-04 PASS — PATCH issued, notification removed from snapshot
poll_test: CORE-07 — state persists across restart
poll_test: CORE-07 PASS — is_read=1 persisted across restart
poll_test: CORE-08 — token never on disk
poll_test: CORE-08 PASS — no tokens found in DB file
poll_test: CORE-03 PASS — X-Poll-Interval: 2 used (verified by poll timing)
ALL TESTS PASSED
```

## Self-Check: PASSED

- `tests/core/poll_test.zig` — FOUND
- `build.zig` contains `test-poll` — FOUND
- Task 2 commit `5b03aeb` — FOUND
- Task 1 commit `adc8e81` — FOUND
