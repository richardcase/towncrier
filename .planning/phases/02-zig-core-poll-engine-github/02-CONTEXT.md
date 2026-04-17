# Phase 2: Zig Core — Poll Engine + GitHub - Context

**Gathered:** 2026-04-17
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 2 delivers a working poll engine and GitHub integration inside `libtowncrier`. The background poll engine runs one `std.Thread` per account, fetches GitHub notifications, persists state in SQLite, and delivers snapshots to the shell via ABI callbacks. All stub implementations from Phase 1 (`towncrier_start`, `towncrier_stop`, `towncrier_tick`, `towncrier_add_account`, `towncrier_remove_account`, `towncrier_snapshot_get`, `towncrier_snapshot_free`, `towncrier_snapshot_count`, `towncrier_snapshot_get_item`, `towncrier_mark_read`, `towncrier_mark_all_read`) get real implementations. A headless Zig test binary with an embedded mock HTTP server validates all success criteria without hitting the live GitHub API.

No UI, no Linux/macOS shell work, no GitLab — those are Phases 3–5.

</domain>

<decisions>
## Implementation Decisions

### Poll Threading Model
- **D-01:** Each account gets its own `std.Thread`. One thread per account, not a shared coordinator. Matches CORE-04's "independent" wording and is the simplest mental model at the expected 2–5 account scale (~8MB stack per thread is acceptable).
- **D-02:** When `towncrier_remove_account` is called, the account's poll thread finishes its current HTTP request/parse cycle before checking the stop flag and exiting. Clean exit — no abandoned in-flight connections. Main thread joins the thread before removing the account from state.

### Test Harness
- **D-03:** The Phase 2 validation test is a **mock HTTP server** embedded in a headless Zig test binary (`tests/core/poll_test.zig`). No live GitHub API calls, no real tokens required. Runs hermetically in CI.
- **D-04:** The mock server **simulates real GitHub behavior**: tracks `If-Modified-Since` per account, returns `304 Not Modified` when the notification list hasn't changed, includes `X-Poll-Interval` header in responses. This is the only way to verify GH-03 (conditional polling) without live API access. The mock must return 304 on unchanged data — not just a static 200 replay.

### Mark-Read Mutation Queue
- **D-05:** `towncrier_mark_read` (called from main thread) appends to a **Mutex-protected `ArrayList` action queue** on the `TowncrierHandle`. Each account's poll thread drains the queue at the start of each poll cycle, filtering for its own `account_id`. Simple, proven at this concurrency scale, matches the pattern described in `ARCHITECTURE.md`.

### SQLite Binding
- **D-06:** Use **`vrischmann/zig-sqlite`** as the SQLite wrapper. Adds a `build.zig.zon` dependency. Type-safe comptime query binding, error unions, maintained for Zig 0.13+. Fetch and pin the version at plan time; verify 0.14 compatibility before locking the plan.

### Claude's Discretion
- Exact HTTP connection reuse strategy within `src/http.zig` (single `std.http.Client` shared across poll cycles for an account, or new client per poll) — Claude decides based on Zig 0.14 `std.http.Client` docs
- Internal module layout beyond the files named in `ARCHITECTURE.md` (e.g., helper structs, error types)
- Mock server port selection and startup/shutdown sequencing in the test binary
- Specific `zig-sqlite` version to pin (latest compatible with Zig 0.14)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Architecture & Threading
- `.planning/research/ARCHITECTURE.md` § "Threading Model" — The poll thread / main thread split, wakeup callback pattern, snapshot ownership rules. Source of truth for the concurrency design.
- `.planning/research/ARCHITECTURE.md` § "C ABI Design" — Function signatures and data structures that Phase 2 must implement (not define — those are locked in Phase 1).
- `.planning/research/ARCHITECTURE.md` § "Data Model" — `Notification`, `Account`, `Service`, `NotifType` Zig structs. Phase 2 fills these into `src/types.zig`.
- `.planning/research/ARCHITECTURE.md` § "State Persistence: SQLite" — Schema (notifications + poll_state + schema_version tables), WAL mode, `synchronous = NORMAL`, DB file paths.

### Build System
- `.planning/research/STACK.md` — Zig 0.14.0 conventions, `std.http.Client` usage, dependency management via `zig fetch --save`.
- `.planning/research/PITFALLS.md` — Known Zig ABI and `std.http` pitfalls to avoid.

### Existing ABI (Phase 1 output)
- `include/towncrier.h` — The C header that Phase 2 must implement. Function signatures and ownership rules are frozen.
- `src/c_api.zig` — All stub implementations that Phase 2 replaces with real logic.
- `src/types.zig` — Empty `TowncrierHandle` that Phase 2 expands with poll engine fields.

### Requirements
- `.planning/REQUIREMENTS.md` §§ CORE-03, CORE-04, CORE-05, CORE-06, CORE-07, CORE-08, GH-01, GH-02, GH-03, GH-04, GH-05 — The 11 requirements this phase must satisfy.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `src/c_api.zig` — All stubs are in place with Phase 2 TODO comments. The ABI structure (`RuntimeCallbacks`, `AccountDesc`, `NotificationC` extern structs) is already defined and correct. Phase 2 replaces stub bodies only — no signature changes.
- `src/types.zig` — `TowncrierHandle` exists as an empty struct. Phase 2 adds: accounts list, per-account thread handles, action queue (Mutex + ArrayList), snapshot RwLock, callbacks copy.
- `include/towncrier.h` — Full ownership docs already written. No changes needed.

### Established Patterns
- `std.heap.c_allocator` is the allocator for the opaque handle (D-07 from Phase 1). Consistent with the C-ABI caller model.
- `extern struct` with `callconv(.c)` is the ABI convention in `c_api.zig`. Phase 2 adds internal Zig structs (non-extern) for the poll engine.
- Build gating via `target.result.os.tag` is established. Phase 2 SQLite dependency (`zig-sqlite`) is cross-platform — no gating needed.

### Integration Points
- `TowncrierHandle` in `src/types.zig` is the central state object. Phase 2 grows it significantly — poll threads, account list, action queue, snapshot lock.
- New source files to create: `src/github.zig`, `src/http.zig`, `src/poller.zig`, `src/store.zig` — all named in `ARCHITECTURE.md`.
- Test binary: `tests/core/poll_test.zig` — new file, added as a `b.addExecutable` step in `build.zig` (same pattern as Phase 1's `tests/c_abi_test.c`).

</code_context>

<specifics>
## Specific Ideas

- The mock HTTP server in the test harness must track `If-Modified-Since` state per account to return 304 correctly. This means the mock needs to be stateful, not just a static response replayer.
- Phase 1 `main.zig` is a Zig 0.16 draft scaffold (uses `std.Io`, `std.process.Init`) — this is the test-executable entry point, not the library. Phase 2 test binary should be a separate `b.addExecutable` step, not modify `main.zig`.
- `zig-sqlite` version must be verified for Zig 0.14.0 compatibility before the plan is locked. PITFALLS.md likely has relevant warnings.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 02-zig-core-poll-engine-github*
*Context gathered: 2026-04-17*
