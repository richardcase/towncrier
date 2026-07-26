# Research: Zig Core — Poll Engine + GitHub

**Researched:** 2026-04-17 · **Migrated to Spec Kit:** 2026-07-26
**Domain:** Background poll threads, `std.http.Client`, GitHub notifications API, SQLite persistence, mock-server test harness
**Confidence:** HIGH

> Ported from the GSD Phase-2 research + pattern map. Cross-references point to
> [`docs/research/`](../../docs/research/) (project research) and this feature's `plan.md`/`spec.md`.

## Phase Requirements

CORE-03 (background poll thread, dynamic `X-Poll-Interval`), CORE-04 (per-account independent
state), CORE-05 (unified notification model), CORE-06 (group by repository), CORE-07 (SQLite WAL
persistence), CORE-08 (token not on disk — Phase 2 scope), GH-01..05 (add PAT account, all types,
conditional 304 polling, mark-read PATCH, multi-account).

## Architectural Responsibility Map

| File | Role | Responsibility |
|------|------|----------------|
| `src/types.zig` | model | Service, NotifType, Account, Notification, Action; `TowncrierHandle` central state |
| `src/http.zig` | utility | `std.http.Client` wrapper; GET/PATCH; `Last-Modified` + `X-Poll-Interval` extraction; 10MB cap |
| `src/github.zig` | service | Fetch + parse notifications; reason→type; API→web URL; mark-read PATCH; conditional requests |
| `src/poller.zig` | service (event-driven) | Per-account thread: drain action queue → fetch → persist → build snapshot → interruptible sleep |
| `src/store.zig` | service (CRUD) | SQLite schema/migration/upsert/mark-read/query/poll-state |
| `src/c_api.zig` | controller | Replace Phase 1 stub bodies with real logic; snapshot deep-copy |

## Standard Stack

| Library | Purpose | Notes |
|---------|---------|-------|
| `std.http.Client` | GitHub REST polling | Shared per-account; custom headers; **do not** use `.fetch()` (see Pitfall 2) |
| `std.json` | Parse notification JSON | `parseFromSlice` into typed structs |
| `std.Thread` + interruptible timed wait | Per-account poll loop | One thread per account (D-01) |
| SQLite (amalgamation) via custom `src/sqlite.zig` | State persistence | **Deviation:** replaced `vrischmann/zig-sqlite` (Zig 0.16 incompatible); bundled in `vendor/sqlite/`, zero external deps |

## Architecture Patterns

- **Pattern 1 — Per-account poll thread with interruptible sleep:** each account owns a `PollContext`, `HttpClient`, and `AccountState`; the loop drains the mark-read queue, fetches, persists, rebuilds the snapshot, then waits up to `poll_interval_secs` on a timed wait that a stop signal can interrupt (clean exit for `remove_account`/`free`).
- **Pattern 2 — `std.http.Client` shared per account, custom headers:** one client reused across cycles; sets `Authorization`, `If-Modified-Since`; reads `Last-Modified` and `X-Poll-Interval` from responses.
- **Pattern 3 — Schema migration + upsert:** `schema_version` table gates migrations; WAL + `synchronous = NORMAL`; upsert on notification id.
- **Pattern 4 — Stateful mock HTTP server (D-03/D-04):** the test harness binds a POSIX socket on `127.0.0.1:0`, tracks `If-Modified-Since` per token, returns `304` on unchanged data, and includes `X-Poll-Interval` — the only way to verify GH-03 hermetically.

**Shared patterns:** handle null-guard on every ABI entry; `std.heap.c_allocator` for the handle;
error-union returns; fire-and-forget callback invocation (never call back into the ABI from a callback).

**Anti-patterns avoided:** storing tokens in any SQL/row; returning stack strings across the ABI;
calling `towncrier_free` without first stopping poll threads; using `std.http.Client.fetch` (loses
response headers).

## Common Pitfalls (and how they were handled)

1. **zig-sqlite pinning / compatibility** → the binding was Zig-0.16-incompatible; replaced with a custom wrapper over the amalgamation.
2. **`std.http.Client.fetch` doesn't expose response headers** → used the lower-level request API so `Last-Modified`/`X-Poll-Interval` are readable.
3. **GitHub `subject.url` is an API URL, not a web URL** → `apiUrlToWebUrl` rewrites it so clicks open the browser page.
4. **Snapshot string lifetime** → snapshot is a deep copy; all `const char *` fields owned by the snapshot, valid until `snapshot_free` (pointer rebasing on copy).
5. **Action-queue filter needs `account_id` on the record** → notifications carry `account_id` so each thread drains only its own mark-read actions.
6. **`towncrier_free` must stop poll threads before freeing** → free path signals + joins threads first.

## Security Domain

- **ASVS V5 (input validation), V6 (crypto/transport):** tokens travel only over TLS to the API and live in process memory for the poll session; never written to SQLite or logs (verified by binary-searching the DB file).
- **Threat notes:** token-in-DB (mitigated: no token column, test asserts absence), stack-string-across-ABI (mitigated: deep copy), use-after-free on snapshot (mitigated: ownership + `snapshot_free`), thread not joined on free (mitigated: stop+join before destroy).

## Outcome vs. plan

All 11 requirements SATISFIED and 5/5 success criteria VERIFIED via `zig build test-poll`
(`ALL TESTS PASSED`), plus `test-c` (Phase 1 regression) and `test-unit` (7/7) green. Deviations:
custom SQLite wrapper, ~7 Zig 0.16 API adaptations, and a `std.process.exit(0)` fix for a
post-test hang (background event-loop threads have no shutdown API) — all recorded in `plan.md`.

## Sources

- `docs/research/ARCHITECTURE.md` — Threading Model, C ABI Design, Data Model, SQLite state persistence
- `docs/research/PITFALLS.md` — Zig `std.http` and ABI pitfalls
- CLAUDE.md § Technology Stack — `std.http`/`std.json` rationale
- GitHub Notifications REST API (participating, thread PATCH, conditional requests)
