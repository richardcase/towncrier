---
phase: 01-core-scaffolding-abi-contract
plan: "01"
subsystem: core-build
tags: [zig, build-system, c-abi, static-library]
dependency_graph:
  requires: []
  provides: [libtowncrier.a, towncrier.h, c_abi_test]
  affects: [phase-02-github-api, phase-03-linux-shell, phase-04-macos-shell]
tech_stack:
  added: [zig-0.16.0, mise]
  patterns: [ghostty-libcore-pattern, static-lib-c-abi, comptime-export-forcing]
key_files:
  created:
    - .mise.toml
    - build.zig
    - build.zig.zon
    - include/towncrier.h
    - src/root.zig
    - src/c_api.zig
    - src/types.zig
    - tests/c_abi_test.c
  modified: []
decisions:
  - "callconv(.C) renamed to callconv(.c) in Zig 0.16 — use lowercase throughout"
  - "build.zig uses createModule+addLibrary pattern (Zig 0.16 root_module API)"
  - "lib_mod.link_libc = true required for std.heap.c_allocator in static lib"
  - "comptime { _ = c_api; } in root.zig forces export symbol emission"
  - "build.zig.zon requires fingerprint field in Zig 0.16 (auto-generated value)"
  - "addCSourceFile uses .file field (correct in Zig 0.16 — no rename needed)"
  - "T-01-01 mitigated: null rt guard in towncrier_init returns NULL early"
metrics:
  duration_minutes: 25
  completed_date: "2026-04-16"
  tasks_completed: 3
  files_created: 8
  files_modified: 0
---

# Phase 01 Plan 01: Build System + C ABI Contract Summary

**One-liner:** Static Zig library with 13-function C ABI, ownership-documented header, and C integration test proving Swift linkage path — all using Zig 0.16 API adaptations.

## What Was Built

A complete Phase 1 foundation for `libtowncrier`:

- **`.mise.toml`** — pins Zig 0.16.0 for all contributors via mise
- **`build.zig.zon`** — package manifest with `minimum_zig_version = "0.14.0"` and Zig 0.16 required `fingerprint` field
- **`build.zig`** — static library step, Linux platform guard, `test-c` step using Zig 0.16 `createModule` + `addLibrary` API
- **`include/towncrier.h`** — locked ABI contract: 13 functions, 3 structs, ownership/threading docs in inline C comments
- **`src/types.zig`** — Phase 1 placeholder `TowncrierHandle` struct (Phase 2 fills in poll engine)
- **`src/c_api.zig`** — stub `export fn` for all 13 ABI functions; `c_allocator` for opaque handle; null-rt guard per T-01-01
- **`src/root.zig`** — library root with `comptime { _ = c_api; }` to force export symbol emission
- **`tests/c_abi_test.c`** — C integration test exercising full lifecycle; prints `c_abi_test: PASS`

## Verification Results

```
# zig build — exit 0
zig-out/lib/libtowncrier.a  (exists)

# nm — all 13 exported symbols
T towncrier_add_account
T towncrier_free
T towncrier_init
T towncrier_mark_all_read
T towncrier_mark_read
T towncrier_remove_account
T towncrier_snapshot_count
T towncrier_snapshot_free
T towncrier_snapshot_get
T towncrier_snapshot_get_item
T towncrier_start
T towncrier_stop
T towncrier_tick

# zig build test-c
c_abi_test: PASS

# GTK symbols check
PASS: no GTK symbols

# include guard count
3 (TOWNCRIER_H appears in #ifndef, #define, #endif)

# minimum_zig_version
.minimum_zig_version = "0.14.0"

# Linux platform guard
if (target.result.os.tag == .linux) {
```

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| 1 | `9e59afb` | Build system: .mise.toml, build.zig, build.zig.zon |
| 2 | `ed46154` | C ABI header + stub Zig implementations |
| 3 | `bc8cd91` | C ABI integration test |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Zig 0.16 build.zig.zon requires `fingerprint` field**
- **Found during:** Task 1 — `zig build` error: "missing top-level 'fingerprint' field; suggested value: 0xa79fae38f79f31b1"
- **Fix:** Added `.fingerprint = 0xa79fae38f79f31b1` to `build.zig.zon`; also changed `.name = "towncrier"` string to `.name = .towncrier` identifier per Zig 0.16 format
- **Files modified:** `build.zig.zon`

**2. [Rule 3 - Blocking] Zig 0.16 `addLibrary`/`addExecutable` require `root_module: *Module`**
- **Found during:** Task 1 — error: "no field named 'root_source_file' in struct 'Build.LibraryOptions'"
- **Fix:** Rewrote `build.zig` to use `b.createModule(.{ .root_source_file = ..., .target = ..., .optimize = ... })` then pass `root_module` to `addLibrary`/`addExecutable`. `addCSourceFile`, `addIncludePath`, `linkLibrary` are now methods on `*Module`, not `*Step.Compile`.
- **Files modified:** `build.zig`
- **addCSourceFile field name:** `.file` (unchanged from Zig 0.14 — no rename needed in 0.16)

**3. [Rule 1 - Bug] Zig 0.16 "pointless discard" error for already-used parameter**
- **Found during:** Task 2 (first compile attempt) — error: "pointless discard of function parameter" on `_ = rt` after `if (rt == null) return null`
- **Fix:** Removed `_ = rt;` from `towncrier_init` — the null check already constitutes a use of `rt`
- **Files modified:** `src/c_api.zig`

**4. [Rule 3 - Blocking] Zig 0.16 `callconv(.C)` renamed to `callconv(.c)` (lowercase)**
- **Found during:** Task 2 — 13 errors: "union 'builtin.CallingConvention' has no member named 'C'"
- **Fix:** Replaced all `callconv(.C)` with `callconv(.c)` throughout `src/c_api.zig` (export fns and extern struct fn pointer types)
- **Files modified:** `src/c_api.zig`

**5. [Rule 3 - Blocking] `std.heap.c_allocator` requires `link_libc` in build.zig**
- **Found during:** Task 2 — error: "C allocator is only available when linking against libc"
- **Fix:** Added `lib_mod.link_libc = true` in `build.zig` before `installArtifact`
- **Files modified:** `build.zig`

**6. [Rule 2 - Missing critical] `export fn` symbols not emitted without comptime reference**
- **Found during:** Task 2 — `nm` showed only `builtin.*` symbols; no `towncrier_*` exports despite `pub const c_api = @import("c_api.zig")` in root.zig
- **Fix:** Added `comptime { _ = c_api; }` to `src/root.zig` to force Zig's lazy compiler to analyze `c_api.zig` and emit all `export fn` symbols into the archive
- **Files modified:** `src/root.zig`

**7. [Rule 2 - Security] T-01-01 null rt guard**
- **Found during:** Task 2 threat model review — T-01-01 requires `if (rt == null) return null` in `towncrier_init`
- **Fix:** Added null guard as first statement in `towncrier_init` per threat model mitigation requirement
- **Files modified:** `src/c_api.zig`

## Known Stubs

All stubs are intentional Phase 1 placeholders — the plan explicitly defines them and they do not prevent the plan's goal (ABI contract + linkage proof):

| Stub | File | Reason |
|------|------|--------|
| `TowncrierHandle` empty struct | `src/types.zig` | Phase 2 adds poll engine, accounts list, snapshot RwLock |
| All ABI functions return 0/NULL | `src/c_api.zig` | Phase 2-5 replace stubs with real implementations |

## Threat Flags

None — all files created in this plan are the ABI scaffold itself. The threat model was reviewed as part of plan execution; T-01-01 through T-01-07 dispositions were applied as documented in the Deviations section above.

## Self-Check: PASSED

All 9 artifact files confirmed present on disk. All 3 task commits confirmed in git history:
- `9e59afb` — build system
- `ed46154` — C ABI header + Zig stubs
- `bc8cd91` — C integration test
