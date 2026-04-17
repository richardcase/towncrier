---
phase: 02-zig-core-poll-engine-github
plan: "01"
subsystem: database
tags: [zig, sqlite, types, data-model, persistence]

# Dependency graph
requires:
  - phase: 01-zig-core-foundation
    provides: "src/c_api.zig with RuntimeCallbacks and NotificationC extern structs"
provides:
  - "src/types.zig: full Phase 2 data model (Service, NotifType, Account, Notification, Action, AccountState, TowncrierHandle, TowncrierSnapshot)"
  - "src/store.zig: SQLite persistence layer with open/migrate/upsert/query/mark-read"
  - "src/sqlite.zig: minimal Zig wrapper over sqlite3 C API (Zig 0.16 compatible)"
  - "vendor/sqlite/: SQLite 3.49.2 amalgamation compiled directly into libtowncrier"
affects:
  - 02-02 (http.zig + github.zig use types.Notification, types.Account)
  - 02-03 (poller.zig uses store.upsertNotification, store.queryUnread, types.TowncrierHandle)
  - 02-04 (c_api.zig uses types.TowncrierHandle, store.open)

# Tech tracking
tech-stack:
  added:
    - "SQLite 3.49.2 amalgamation (vendor/sqlite/sqlite3.c + sqlite3.h)"
    - "src/sqlite.zig: custom minimal Zig wrapper (replaces vrischmann/zig-sqlite)"
  patterns:
    - "sqlite.Db.exec(comptime sql, .{}, .{args}) for parameterized queries"
    - "sqlite.Db.execMulti(sql) for multi-statement DDL"
    - "sqlite.Db.oneAlloc / allAlloc for typed row reading with allocator"
    - "std.Io.Mutex / std.Io.RwLock for sync primitives (Zig 0.16)"

key-files:
  created:
    - src/types.zig
    - src/store.zig
    - src/sqlite.zig
    - vendor/sqlite/sqlite3.c
    - vendor/sqlite/sqlite3.h
  modified:
    - build.zig
    - build.zig.zon
    - src/c_api.zig
    - src/root.zig

key-decisions:
  - "Replaced vrischmann/zig-sqlite with direct SQLite amalgamation + custom src/sqlite.zig: zig-sqlite's build.zig and sqlite.zig are incompatible with Zig 0.16 (ArrayList API changed)"
  - "std.Io.Mutex and std.Io.RwLock used in TowncrierHandle fields (Zig 0.16 moved these from std.Thread)"
  - "RuntimeCallbacks made pub in c_api.zig so types.zig can import it without re-declaration"
  - "SQLite compiled with SQLITE_THREADSAFE=2 (MultiThread mode) to match Zig 0.16 threading model"

patterns-established:
  - "Pattern 1: sqlite.Db wrapper API — exec/execMulti/oneAlloc/allAlloc with comptime SQL strings"
  - "Pattern 2: store.zig security assertion — no token field in any SQL statement (grep-verifiable)"
  - "Pattern 3: upsert preserves is_read=1 via CASE WHEN (T-02-02 mitigation)"

requirements-completed: [CORE-04, CORE-05, CORE-07, CORE-08]

# Metrics
duration: 45min
completed: 2026-04-17
---

# Phase 02 Plan 01: Types + SQLite Persistence Layer Summary

**SQLite 3.49.2 persistence layer with WAL mode, schema migration, and full Phase 2 data model types via custom Zig 0.16-compatible wrapper**

## Performance

- **Duration:** ~45 min
- **Started:** 2026-04-17T09:00:00Z
- **Completed:** 2026-04-17T09:45:00Z
- **Tasks:** 3
- **Files modified:** 9

## Accomplishments
- Expanded `src/types.zig` with all Phase 2 types: Service, NotifType, Account, Notification, Action, PollContext, AccountState, TowncrierSnapshot, TowncrierHandle
- Created `src/store.zig` with full CRUD layer: open/migrate/upsert/markRead/markAllRead/queryUnread/savePollState/loadPollState
- Created `src/sqlite.zig` — a minimal Zig 0.16-compatible SQLite wrapper compiled from the sqlite3 amalgamation
- All security assertions pass: no token field in any SQL statement, ON CONFLICT preserves is_read=1

## Task Commits

1. **Task 1: Expand types.zig with full Phase 2 data model** - `6275217` (feat)
2. **Task 2: Add SQLite dependency and build wiring** - `93580c9` (feat)
3. **Task 3: Implement src/store.zig — SQLite persistence layer** - `358b5c8` (feat)

## Files Created/Modified
- `src/types.zig` - All Phase 2 data model types; TowncrierHandle with sqlite.Db field
- `src/store.zig` - SQLite persistence layer: schema migration, CRUD, poll state
- `src/sqlite.zig` - Minimal Zig wrapper over sqlite3 C API; replaces vrischmann/zig-sqlite
- `src/c_api.zig` - Made RuntimeCallbacks pub so types.zig can import it
- `src/root.zig` - Added `pub const store = @import("store.zig")`
- `build.zig` - Added sqlite_mod with SQLite amalgamation C source; wired to lib_mod
- `build.zig.zon` - Reverted to empty dependencies (SQLite bundled directly)
- `vendor/sqlite/sqlite3.c` - SQLite 3.49.2 amalgamation (8.8 MB)
- `vendor/sqlite/sqlite3.h` - SQLite 3.49.2 header

## Decisions Made
- Used direct SQLite amalgamation instead of vrischmann/zig-sqlite (see deviation 1)
- Made RuntimeCallbacks pub in c_api.zig to avoid duplicating the extern struct definition
- Used `std.Io.Mutex` and `std.Io.RwLock` for Zig 0.16 compatibility

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Replaced vrischmann/zig-sqlite with direct SQLite amalgamation**
- **Found during:** Task 2 (Add zig-sqlite dependency)
- **Issue:** vrischmann/zig-sqlite's `build.zig` and `sqlite.zig` use `std.ArrayList` with `= .{}` initialization, which is invalid in Zig 0.16 (ArrayList no longer has a zero-value init; requires explicit `items` and `capacity` fields, plus the `addIncludePath` build API moved from `Compile` to `Module`). The library is incompatible with the installed Zig 0.16.0.
- **Fix:** Created `src/sqlite.zig` — a minimal wrapper over the sqlite3 C API using `@cImport`. Bundled the SQLite 3.49.2 amalgamation in `vendor/sqlite/`. Updated `build.zig` to compile `sqlite3.c` directly and expose `sqlite_mod` as the "sqlite" import. The `sqlite.Db`, `sqlite.DbMode`, `sqlite.InitOptions`, and `sqlite.Db.exec` API is functionally identical to what `store.zig` needs.
- **Files modified:** src/sqlite.zig (created), vendor/sqlite/ (created), build.zig, build.zig.zon
- **Verification:** `zig build` and `zig build test-c` both pass
- **Committed in:** 93580c9 (Task 2 commit)

**2. [Rule 1 - Bug] Zig 0.16 moved Mutex/RwLock from std.Thread to std.Io**
- **Found during:** Task 1 (types.zig expansion)
- **Issue:** Plan specified `std.Thread.Mutex` and `std.Thread.RwLock` for TowncrierHandle fields; Zig 0.16 removed these from `std.Thread` entirely (they now live under `std.Io` as async-I/O-aware primitives).
- **Fix:** Changed field types to `std.Io.Mutex = .init` and `std.Io.RwLock = .init` in TowncrierHandle. These support the same `.init` constant initializer syntax and are structurally equivalent for field storage.
- **Files modified:** src/types.zig
- **Verification:** `zig build` passes
- **Committed in:** 6275217 (Task 1 commit)

**3. [Rule 2 - Missing Critical] Made RuntimeCallbacks pub in c_api.zig**
- **Found during:** Task 1 (types.zig importing c_api.RuntimeCallbacks)
- **Issue:** Plan specified `callbacks: c_api.RuntimeCallbacks` in TowncrierHandle, but `RuntimeCallbacks` was declared `const` (private) in c_api.zig.
- **Fix:** Changed to `pub const RuntimeCallbacks` in c_api.zig.
- **Files modified:** src/c_api.zig
- **Verification:** `zig build` passes
- **Committed in:** 6275217 (Task 1 commit)

---

**Total deviations:** 3 auto-fixed (1 blocking dependency incompatibility, 1 bug fix, 1 missing pub visibility)
**Impact on plan:** All fixes necessary. The zig-sqlite replacement is the most significant — it required creating a custom SQLite wrapper, but the API surface store.zig depends on is identical. No functional scope creep.

## Issues Encountered
- Zig 0.16 has extensive stdlib API changes vs 0.14 (which the plan was written for): ArrayList init syntax, Thread.Mutex/RwLock location, addIncludePath on Module vs Compile. All encountered issues were auto-fixed via deviation rules.

## Threat Surface Scan

No new network endpoints, auth paths, or trust boundary changes introduced. SQLite DB file is a local data store — T-02-01 through T-02-04 all addressed as specified in the plan's threat model.

## Next Phase Readiness
- `types.zig` provides all types needed by 02-02 (http.zig, github.zig) and 02-03 (poller.zig)
- `store.zig` provides persistence for 02-03 (poll loop upserts) and 02-04 (c_api.zig init opens DB)
- `sqlite.zig` API is stable for this plan's needs; future plans that need more SQLite features (e.g. transactions) can extend it

## Self-Check
- [x] src/types.zig exists with all required types
- [x] src/store.zig exists with all required functions
- [x] src/sqlite.zig exists (Zig 0.16 compatible wrapper)
- [x] vendor/sqlite/sqlite3.c bundled
- [x] zig build exits 0
- [x] zig build test-c exits 0

---
*Phase: 02-zig-core-poll-engine-github*
*Completed: 2026-04-17*
