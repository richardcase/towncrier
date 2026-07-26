# Implementation Plan: Zig Core — Poll Engine + GitHub

**Branch**: `002-zig-core-poll-engine-github` | **Date**: 2026-04-17 | **Spec**: [spec.md](spec.md)

**Status**: ✅ Complete (2026-04-27). Historical record migrated from GSD; executed across five GSD
plans (waves). Shipped as tag `phase-02-complete`.

## Summary

Turn the Phase 1 stubs into a working poll engine inside `libtowncrier`: one `std.Thread` per
account fetches GitHub notifications, persists state in SQLite (WAL), and delivers deep-copied
snapshots to the shell via the ABI callbacks. A headless Zig test binary with an embedded, stateful
mock HTTP server validates all 11 requirements without touching the live GitHub API.

## Technical Context

**Language/Version**: Zig 0.14 target; **executed on Zig 0.16.0** (~7 API adaptations applied)

**Primary Dependencies**: `std.http.Client`, `std.json`, `std.Thread`; **SQLite** via a custom
`src/sqlite.zig` wrapper over the vendored SQLite 3.49.2 amalgamation (`vendor/sqlite/`) — see the
deviation note below.

**Storage**: SQLite, WAL mode, `synchronous = NORMAL`; tables for notifications + poll_state + schema_version.

**Testing**: `zig build test-poll` (integration, mock HTTP server) + `zig build test-unit` + `zig build test-c` (Phase 1 regression).

**Target Platform**: macOS + Linux (SQLite is cross-platform — no build gating needed).

**Project Type**: Zig core library (libcore); no shell/UI in this phase.

**Constraints**: no token in any SQL/on disk; ABI signatures frozen (stubs replaced only); poll thread must drain the action queue and exit cleanly on stop/remove.

**Scale/Scope**: 2–5 accounts; 6 source files created/expanded + 1 integration test.

## Constitution Check

- **I. Zig Core, C-ABI Boundary** — ✅ Stubs replaced with real logic; no signature changes to `towncrier.h`.
- **II. Thin Shells** — ✅ N/A (no shell); all logic stays in core.
- **III. Build-Time Platform Isolation** — ✅ SQLite is cross-platform; no GTK/macOS references introduced.
- **IV. Tokens in Keychain** — ✅ Token held in memory only for the poll session; never persisted (verified by binary-searching the DB). Full keychain integration deferred to Phases 004/003.
- **V. Poll, Don't Push** — ✅ Background polling with `If-Modified-Since`/304 and dynamic `X-Poll-Interval`; no webhooks.

No violations — Complexity Tracking not required.

## Locked Decisions (from GSD CONTEXT/RESEARCH)

- **D-01**: One `std.Thread` per account (not a shared coordinator) — matches CORE-04 "independent" at 2–5 account scale.
- **D-02**: On `remove_account`, the poll thread finishes its current cycle, checks the stop flag, exits; the main thread joins before removing account state. No abandoned in-flight connections.
- **D-03**: Validation is a **stateful mock HTTP server** in a headless Zig test binary (`tests/core/poll_test.zig`) — hermetic, no live API, no real tokens.
- **D-04**: The mock simulates real GitHub: per-account `If-Modified-Since` tracking, `304` on unchanged data, `X-Poll-Interval` header. Required to verify GH-03 without live access.
- **D-05**: `towncrier_mark_read` (main thread) appends to a Mutex-protected `ArrayList` action queue on the handle; each poll thread drains it at cycle start, filtering by its own `account_id`.
- **D-06**: SQLite via a Zig binding — *planned* `vrischmann/zig-sqlite`; *shipped* a custom wrapper (deviation below).

## Project Structure

```text
src/
├── types.zig     # Service, NotifType, Account, Notification, Action, PollContext,
│                 #   AccountState, TowncrierSnapshot, TowncrierHandle (expanded)
├── http.zig      # HttpClient: GET/PATCH; Last-Modified + X-Poll-Interval extraction; 10MB cap
├── github.zig    # fetchNotifications (participating=true), 15 reason→type mappings,
│                 #   apiUrlToWebUrl, markRead PATCH, If-Modified-Since, 304/401 fast-paths
├── poller.zig    # PollContext, start/stopPollThread, pollThread: drain→fetch→snapshot→sleep
├── store.zig     # SQLite: open/migrate/upsert/markRead/markAllRead/queryUnread/save+loadPollState
├── sqlite.zig    # Custom wrapper over the SQLite amalgamation (replaces zig-sqlite)
└── c_api.zig     # All 12 ABI functions wired to real poller/store/snapshot logic
vendor/sqlite/    # SQLite 3.49.2 amalgamation (sqlite3.c / sqlite3.h)
tests/core/
└── poll_test.zig # Mock server + 11 requirement checks → `zig build test-poll`
build.zig         # + test-poll step
```

**Structure Decision**: expand `src/types.zig`'s `TowncrierHandle` into the central state object
(accounts, per-account thread handles, action queue, snapshot lock, callbacks copy); add the four
new service/utility modules named in `docs/research/ARCHITECTURE.md`.

## Execution record (waves)

Executed as five GSD plans, each a wave:

1. **Wave 1 (02-01)** — data model + SQLite store: `types.zig` expanded, `store.zig` (schema, WAL, upsert, poll-state), token-isolation guard.
2. **Wave 2 (02-02)** — HTTP + GitHub client: `http.zig` (`std.http.Client` wrapper, header extraction), `github.zig` (fetch, reason→type, API→web URL rewrite, PATCH mark-read, If-Modified-Since).
3. **Wave 3 (02-03)** — poll engine: `poller.zig` per-account thread (drain→fetch→persist→snapshot→interruptible sleep honoring `X-Poll-Interval`).
4. **Wave 4 (02-04)** — wire the C ABI: replaced every `c_api.zig` stub with real calls into poller/store; snapshot deep-copy with pointer rebasing.
5. **Wave 5 (02-05)** — integration test: `tests/core/poll_test.zig` mock server + 11 checks; `test-poll` build step.

**Verification:** 5/5 roadmap success criteria VERIFIED; all 11 requirement IDs SATISFIED; `zig build`,
`test-c`, `test-unit` (7/7), and `test-poll` all green. Human UAT signed off.

## Complexity Tracking / Deviations

| Deviation | Why | Note |
|-----------|-----|------|
| Custom `src/sqlite.zig` instead of `vrischmann/zig-sqlite` | The binding was incompatible with Zig 0.16 | Identical API surface; SQLite bundled via `vendor/sqlite/`; `build.zig.zon` keeps **zero** external deps |
| ~7 Zig 0.16 API adaptations | Plans authored for 0.14, executed on 0.16.0 | Unmanaged `ArrayList`, `std.Io` Mutex/RwLock, `std.http.Client` pipeline change, `std.time` removals — behavior preserved |
| `std.process.exit(0)` at end of the test | `std.Io.Threaded` background threads have no public shutdown API → process hung after `ALL TESTS PASSED` | Surfaced in human UAT; fixed |

## Carried forward

- Full keychain token storage (CORE-08 remainder) → Phases 004 (macOS Keychain) and 003 (libsecret).
- `libstray` v0.4.0 production-readiness evaluation → Phase 003 (`/speckit-plan`).
