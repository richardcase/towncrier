---
description: "Task list for Zig Core — Poll Engine + GitHub (COMPLETE)"
---

# Tasks: Zig Core — Poll Engine + GitHub

**Input**: Design documents from `/specs/002-zig-core-poll-engine-github/`

**Status**: ✅ All tasks complete (2026-04-27). Executed as five GSD plans (waves); ported to Spec Kit
format 2026-07-26. Checkboxes reflect the completed record. Shipped as tag `phase-02-complete`.

**Tests**: A headless integration test with a mock HTTP server was explicitly requested (D-03/D-04)
and is included.

## Phase 1: Foundational — data model + persistence (Wave 1 / 02-01)

**Blocks all downstream work.**

- [x] T001 Expand `src/types.zig` — `Service`, `NotifType`, `Account`, `Notification`, `Action`, `PollContext`, `AccountState`, `TowncrierSnapshot`, and the grown `TowncrierHandle` (accounts, thread handles, Mutex action queue, snapshot lock, callbacks copy). *(CORE-04, CORE-05)*
- [x] T002 [P] Vendor SQLite 3.49.2 amalgamation (`vendor/sqlite/sqlite3.{c,h}`) and author `src/sqlite.zig` — custom wrapper (replaces `vrischmann/zig-sqlite`, incompatible with Zig 0.16). *(CORE-07)*
- [x] T003 Implement `src/store.zig` — open/migrate (schema_version), WAL + `synchronous=NORMAL`, `upsert`/`markRead`/`markAllRead`/`queryUnread`/`save`+`loadPollState`; **no token column**. *(CORE-07, CORE-08)*

## Phase 2: HTTP + GitHub client (Wave 2 / 02-02)

- [x] T004 Implement `src/http.zig` — `HttpClient` GET/PATCH over `std.http.Client`; extract `Last-Modified` + `X-Poll-Interval`; 10MB body cap; **not** `.fetch()`. *(GH-01, GH-03)*
- [x] T005 Implement `src/github.zig` — `fetchNotifications` (`participating=true`), all 15 reason→`NotifType` mappings, `apiUrlToWebUrl`, `markRead` PATCH, `If-Modified-Since` + 304/401 fast-paths. *(GH-01, GH-02, GH-04)*

## Phase 3: Poll engine (Wave 3 / 02-03)

- [x] T006 Implement `src/poller.zig` — `PollContext`, `start`/`stopPollThread`, and `pollThread`: drain action queue → fetch → persist → build+deliver snapshot → interruptible timed wait honoring `X-Poll-Interval`; clean stop/join. *(CORE-03, CORE-04, CORE-06)*

## Phase 4: Wire the C ABI (Wave 4 / 02-04)

- [x] T007 Replace every stub in `src/c_api.zig` with real logic — `add_account`/`start` spin up poll threads, `store.open`, snapshot deep-copy with pointer rebasing, `mark_read` enqueues an action; no `_ = tc;` stubs remain. ABI signatures unchanged. *(CORE-03..08, GH-01, GH-04, GH-05)*

## Phase 5: Integration test + verification (Wave 5 / 02-05)

- [x] T008 Author `tests/core/poll_test.zig` — stateful `MockServer` (per-token `If-Modified-Since`, 304, `X-Poll-Interval`) + 11 requirement checks; add the `test-poll` build step. *(CORE-03..08, GH-01..05)*
- [x] T009 Verify end-to-end: `zig build`, `zig build test-c` (Phase 1 regression), `zig build test-unit` (7/7), `zig build test-poll` (`ALL TESTS PASSED`) all green; DB binary-searched for token strings (none found). *(all)*
- [x] T010 Human UAT sign-off — confirmed `test-poll` passes. **Issue found & fixed:** process hung after `ALL TESTS PASSED` (background event-loop threads have no shutdown API) → added `std.process.exit(0)`. *(checkpoint)*

## Dependencies & Notes

- Wave 1 (types + store) blocks Waves 2–5; Wave 4 (ABI wiring) depends on Waves 1–3; Wave 5 (test) depends on Wave 4.
- `[P]` tasks touch different files with no ordering dependency.
- Requirements satisfied: **CORE-03, CORE-04, CORE-05, CORE-06, CORE-07, CORE-08, GH-01, GH-02, GH-03, GH-04, GH-05** (all 11).
- Deviations (see `plan.md`): custom `src/sqlite.zig` over the amalgamation; ~7 Zig 0.16 API adaptations; `std.process.exit(0)` test fix.
- CORE-08 in this phase = "no token written to disk in plaintext"; full keychain storage lands in Phases 004/003.
