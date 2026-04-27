---
phase: 02-zig-core-poll-engine-github
verified: 2026-04-17T17:30:00Z
status: human_needed
score: 5/5
overrides_applied: 0
deferred:
  - truth: "Token storage via system keychain (CORE-08 full requirement)"
    addressed_in: "Phase 3 and Phase 4"
    evidence: "Phase 3 goal: 'stores tokens in libsecret'; Phase 4 goal: 'stores tokens in Keychain'. Phase 2 ROADMAP success criterion scopes CORE-08 to 'no token written to disk in plaintext' — fully verified."
human_verification:
  - test: "Run zig build test-poll and confirm exit 0 + ALL TESTS PASSED"
    expected: "All 11 requirement checks print PASS; final line is ALL TESTS PASSED; process exits 0"
    why_human: "Test spawns real background threads and a real mock HTTP server; requires the build environment and ~20 seconds runtime. Cannot run inline in CI-less verification. Already confirmed passing in this verification session."
---

# Phase 2: Zig Core — Poll Engine + GitHub Verification Report

**Phase Goal:** The background poll engine runs per-account threads that fetch GitHub notifications, persist state in SQLite, and deliver snapshots to the shell via ABI callbacks
**Verified:** 2026-04-17T17:30:00Z
**Status:** human_needed (all automated checks pass; one runtime integration test needs human sign-off)
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (Roadmap Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Headless test harness adds two GitHub accounts; each polls independently; on_update fires with notifications grouped by repo | VERIFIED | `zig build test-poll` passed: CORE-04/GH-05 PASS, CORE-05/GH-02 PASS, CORE-06 PASS. Two accounts fire on_update, snapshot 4 items, alphabetical repo order. |
| 2 | Polling uses If-Modified-Since / Last-Modified; 304 does not re-process notifications | VERIFIED | `zig build test-poll` passed: GH-03 PASS — mock tracks Last-Modified per token, returns 304 on second poll, not_modified_count incremented. github.zig line 72 sends If-Modified-Since; FetchResult.not_modified=true skips upsert. |
| 3 | Marking read issues PATCH /notifications/threads/:id; subsequent snapshot excludes that notification | VERIFIED | `zig build test-poll` passed: GH-04 PASS — patch_count incremented, notification absent from next snapshot. |
| 4 | Read/unread state survives process restart | VERIFIED | `zig build test-poll` passed: CORE-07 PASS — SQLite is_read=1 persisted; marked-read notification absent after stop/reinit/restart sequence. |
| 5 | Token not written to disk in plaintext (Phase 2 scope of CORE-08) | VERIFIED | `zig build test-poll` passed: CORE-08 PASS — DB binary searched for "test-token-1" and "test-token-2"; neither found. grep confirms no token field in any SQL in store.zig. |

**Score:** 5/5 truths verified

### Deferred Items

| # | Item | Addressed In | Evidence |
|---|------|-------------|----------|
| 1 | Full keychain storage (CORE-08: macOS Security.framework + Linux libsecret) | Phase 3, Phase 4 | Phase 3 goal: "stores tokens in libsecret"; Phase 4 goal: "stores tokens in Keychain". Phase 2 ROADMAP SC 5 scopes this to "no token written to disk in plaintext" — fully met. |

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/types.zig` | All Phase 2 types | VERIFIED | Contains Service, NotifType, Account, Notification, Action, PollContext (opaque), AccountState, TowncrierSnapshot, TowncrierHandle with all required fields |
| `src/store.zig` | SQLite persistence layer | VERIFIED | open/migrate/upsert/markRead/markAllRead/queryUnread/savePollState/loadPollState all present; WAL mode + schema migration |
| `src/sqlite.zig` | Custom SQLite wrapper | VERIFIED | Created as replacement for vrischmann/zig-sqlite (incompatible with Zig 0.16); wraps sqlite3 amalgamation |
| `vendor/sqlite/sqlite3.c` | SQLite 3.49.2 amalgamation | VERIFIED | Present (8.8 MB) |
| `src/http.zig` | HTTP client wrapper | VERIFIED | HttpClient with GET/PATCH; Last-Modified + X-Poll-Interval header extraction; 10 MB cap; does NOT use .fetch() |
| `src/github.zig` | GitHub API client | VERIFIED | fetchNotifications with participating=true; 15 reason mappings; apiUrlToWebUrl; markRead PATCH; If-Modified-Since; 304/401 fast-paths |
| `src/poller.zig` | Poll thread engine | VERIFIED | PollContext; startPollThread; stopPollThread; pollThread drain→fetch→snapshot→sleep; timedWait (futexWaitTimeout); snapshot_lock |
| `src/c_api.zig` | C ABI — all stubs replaced | VERIFIED | All 12 functions have real implementations; no `_ = tc;` stubs; poller.startPollThread, store.open, snapshot deep-copy with pointer rebasing |
| `tests/core/poll_test.zig` | Integration test | VERIFIED | MockServer; 11 requirement checks; `zig build test-poll` exits 0 with ALL TESTS PASSED |
| `build.zig` | test-poll step | VERIFIED | Contains poll_test_mod, poll_test.linkLibrary(lib), test-poll step |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `src/store.zig` | sqlite wrapper | `@import("sqlite")` | VERIFIED | store.zig line 5: `const sqlite = @import("sqlite");` |
| `src/types.zig` | sqlite | `db: ?sqlite.Db` | VERIFIED | types.zig line 96: `db: ?sqlite.Db = null` |
| `src/github.zig` | `src/http.zig` | `http.HttpClient` | VERIFIED | github.zig imports http, uses `http.HttpClient` in fetchNotifications and markRead |
| `src/github.zig` | `src/types.zig` | `types.Notification` | VERIFIED | github.zig returns `[]types.Notification` from fetchNotifications |
| `src/poller.zig` | `src/github.zig` | `github.fetchNotifications` | VERIFIED | poller.zig line 206 |
| `src/poller.zig` | `src/store.zig` | `store.upsertNotification` | VERIFIED | poller.zig line 249 |
| `src/poller.zig` | `src/types.zig` | `snapshot_lock` | VERIFIED | poller.zig line 368 |
| `src/c_api.zig` | `src/poller.zig` | `poller.startPollThread` | VERIFIED | c_api.zig line 161 |
| `src/c_api.zig` | `src/store.zig` | `store.open` | VERIFIED | c_api.zig line 120 |
| `towncrier_snapshot_get` | `types.TowncrierSnapshot` | `snapshot_lock.lockSharedUncancelable` | VERIFIED | c_api.zig line 252 |
| `tests/core/poll_test.zig` | libtowncrier C ABI | `@cImport(towncrier.h)` | VERIFIED | poll_test.zig line 11-13 |
| `MockServer` | poll engine | `http://127.0.0.1:{port}` | VERIFIED | poll_test.zig line 487-490; POSIX socket binds to 127.0.0.1:0 |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `src/poller.zig` buildAndDeliverSnapshot | `notifications []types.Notification` | `store.queryUnread(db, handle.allocator, null)` | Yes — SELECT from SQLite populated by upsertNotification | FLOWING |
| `src/c_api.zig` towncrier_snapshot_get | `src.items []NotificationC` | Deep copy of handle.snapshot built by poller | Yes — items populated from real DB query | FLOWING |
| `src/github.zig` fetchNotifications | `parsed.value []NotificationJson` | `std.json.parseFromSlice` from HTTP response body | Yes — body from real HTTP GET (or mock in tests) | FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| zig build passes | `zig build` | Exit 0, no output | PASS |
| Phase 1 C ABI test | `zig build test-c` | c_abi_test: PASS | PASS |
| Unit tests | `zig build test-unit` | Exit 0 (7/7 tests) | PASS |
| Phase 2 integration test | `zig build test-poll` | ALL TESTS PASSED, exit 0 | PASS |
| No token in store.zig SQL | `grep -i token src/store.zig \| grep -v '//'` | 0 matches | PASS |
| No stubs in c_api.zig | `grep '_ = tc;' src/c_api.zig` | 0 matches | PASS |
| participating=true in github.zig | grep check | Line 56 confirmed | PASS |
| All 15 reason values handled | grep for security_advisory_credit | Line 269 confirmed | PASS |
| No .fetch() in http.zig | grep check | 0 matches | PASS |

### Requirements Coverage

| Requirement | Source Plan(s) | Description | Status | Evidence |
|-------------|---------------|-------------|--------|----------|
| CORE-03 | 02-03, 02-05 | Poll engine background thread, X-Poll-Interval respected | SATISFIED | poller.zig doPoll updates poll_interval_secs from result; timedWait uses it; test verifies X-Poll-Interval:2 is used |
| CORE-04 | 02-01, 02-03, 02-05 | Per-account polling, independent state | SATISFIED | Two poll threads, each with own PollContext, HttpClient, AccountState; test confirms update_count>=2 |
| CORE-05 | 02-01, 02-05 | Unified notification data model | SATISFIED | types.Notification is service-agnostic; github.zig maps to it; snapshot contains correct fields |
| CORE-06 | 02-03, 02-05 | Notifications grouped by repository | SATISFIED | buildAndDeliverSnapshot sorts by repo via compareByRepo; test verifies alphabetical order |
| CORE-07 | 02-01, 02-05 | Read/unread state persisted via SQLite WAL | SATISFIED | store.open sets WAL mode; is_read=1 persisted; restart test confirms state survives |
| CORE-08 | 02-01, 02-03, 02-05 | Token not written to disk (Phase 2 scope) | SATISFIED | No token in any SQL statement; test binary-searches DB file for token strings |
| GH-01 | 02-02, 02-04, 02-05 | Add GitHub account with PAT | SATISFIED | towncrier_add_account copies token; test adds two accounts and polls both |
| GH-02 | 02-02, 02-05 | All GitHub notification types handled | SATISFIED | reasonToNotifType handles all 15 values; apiUrlToWebUrl rewrites API URLs; test verifies no api.github.com in URLs |
| GH-03 | 02-02, 02-05 | If-Modified-Since / 304 conditional requests | SATISFIED | github.zig sends If-Modified-Since; returns not_modified on 304; mock verifies 304 count increments |
| GH-04 | 02-02, 02-04, 02-05 | Mark read issues PATCH; removed from snapshot | SATISFIED | towncrier_mark_read enqueues action; drainActionQueue calls github.markRead + store.markRead; test verifies PATCH and absence |
| GH-05 | 02-02, 02-04, 02-05 | Multiple GitHub accounts poll independently | SATISFIED | Each AccountState has own PollContext; test confirms two independent accounts both fire callbacks |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `src/c_api.zig` | 177 | `towncrier_tick` is intentionally empty with comment | Info | Not a stub — documented design decision: action drain happens on poll thread in Phase 2 |
| `src/store.zig` | 83 | `_ = allocator;` in test | Info | Test discard of unused variable; not a stub |

No blockers or warnings found.

### Human Verification Required

#### 1. Full Integration Test Run

**Test:** Run `zig build test-poll` in the towncrier project directory  
**Expected:** Output shows all 11 requirement checks passing, final line is "ALL TESTS PASSED", process exits 0  
**Why human:** Test spawns real background threads and a mock HTTP server, waits for polling cycles (~15–20 seconds total). Already confirmed passing in this verification session (output recorded above). Human sign-off documents the confirmation.

### Gaps Summary

No gaps found. All 5 ROADMAP success criteria are verified. All 11 requirement IDs (CORE-03 through CORE-08, GH-01 through GH-05) are satisfied by substantive, wired implementations with passing automated assertions.

**Notable implementation deviation from plan:** vrischmann/zig-sqlite was replaced with a custom `src/sqlite.zig` wrapper over the SQLite 3.49.2 amalgamation (incompatible with Zig 0.16 API). The replacement provides an identical API surface and was correctly auto-fixed during execution. The build.zig.zon has no external dependencies; sqlite is bundled via `vendor/sqlite/`.

**Zig version note:** All plans were written for Zig 0.14 but execution ran on Zig 0.16.0. Seven auto-fixed Zig 0.16 API adaptations were made across the execution plans (ArrayList unmanaged, std.Io.Mutex/RwLock, std.http.Client pipeline change, std.time API removals, etc.). All adaptations preserve functional behavior.

---

_Verified: 2026-04-17T17:30:00Z_
_Verifier: Claude (gsd-verifier)_
