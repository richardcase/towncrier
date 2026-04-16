---
phase: 01-core-scaffolding-abi-contract
verified: 2026-04-16T14:30:00Z
status: human_needed
score: 3/4 must-haves verified
overrides_applied: 0
human_verification:
  - test: "Run `zig build` on a macOS machine (Apple Silicon or Intel) and confirm `zig-out/lib/libtowncrier.a` is produced without errors"
    expected: "Exit 0; `nm zig-out/lib/libtowncrier.a | grep -i gtk` produces no matches; `nm zig-out/lib/libtowncrier.a | grep -i linux` produces no matches"
    why_human: "Roadmap Success Criteria 1 requires verification on macOS. This verification was performed on Linux only. The Linux platform guard is in build.zig, but it cannot be proven from a Linux host that a macOS build is actually free of Linux/GTK symbols."
---

# Phase 1: Core Scaffolding + ABI Contract Verification Report

**Phase Goal:** Build system, static library, and C ABI header proven on both platforms
**Verified:** 2026-04-16T14:30:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `zig build` on macOS produces `libtowncrier.a` without GTK/Linux-specific symbols | ? UNCERTAIN | Verified on Linux only. Platform guard `if (target.result.os.tag == .linux)` is present in build.zig (line 27). No GTK symbols found via `nm` on Linux build. macOS build requires human verification on a macOS host. |
| 2 | `zig build` on Linux produces `libtowncrier.a` without macOS-specific symbols | VERIFIED | `nm zig-out/lib/libtowncrier.a \| grep -i "CoreFoundation\|NSObject\|objc_"` produces no output. Confirmed via live run. |
| 3 | C test binary links against `libtowncrier.a`, calls init/tick/free lifecycle, exits clean under ASAN with no leaks | VERIFIED | `zig build test-c` exits 0 printing `c_abi_test: PASS`. ASAN run via `clang -fsanitize=address,undefined` confirmed zero errors (documented in 01-02-SUMMARY.md). Lifecycle path calls init, start, tick, add_account, snapshot_get, mark_read, remove_account, stop, free. |
| 4 | `towncrier.h` documents string ownership rules and callback context lifecycle | VERIFIED | Header contains STRINGS (inbound), STRINGS (outbound), CALLBACKS, and THREAD SAFETY documentation blocks. Per-function docs cover allocation ownership, null-termination, pointer validity windows, and thread marshaling requirements (DispatchQueue.main.async / g_idle_add guidance). |

**Score:** 3/4 truths verified (SC-1 requires macOS host)

### Deferred Items

None.

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `.mise.toml` | Local Zig version pin | VERIFIED | Contains `zig = "0.16.0"` |
| `build.zig` | Static lib step + test-c step + platform guard | VERIFIED | `addLibrary` (line 14), `test-c` step (line 46), Linux guard (line 27), no `addStaticLibrary` |
| `build.zig.zon` | Zig 0.14.0 version pin | VERIFIED | Contains `minimum_zig_version = "0.14.0"` |
| `include/towncrier.h` | Full C ABI contract with ownership docs | VERIFIED | 13 function declarations, 3 structs, full ownership/threading documentation |
| `src/c_api.zig` | Stub export fn implementations (all 13) | VERIFIED | 13 `export fn towncrier_` declarations, `std.heap.c_allocator` used, no Zig slices in export fn signatures |
| `src/root.zig` | Library root with comptime export-forcing | VERIFIED | `comptime { _ = c_api; }` present to force export symbol emission |
| `src/types.zig` | Phase 1 placeholder TowncrierHandle | VERIFIED | Present, 340 bytes |
| `tests/c_abi_test.c` | C linkage integration test | VERIFIED | Contains `c_abi_test: PASS`, `towncrier_init`, `TOWNCRIER_SERVICE_GITHUB` |
| `zig-out/lib/libtowncrier.a` | Static library deliverable | VERIFIED | Exists at 9.2M |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `build.zig` | `src/root.zig` | `root_source_file` in `createModule` | VERIFIED | Line 9: `.root_source_file = b.path("src/root.zig")` |
| `build.zig` | `tests/c_abi_test.c` | `addCSourceFile` in c_test_mod | VERIFIED | Line 36: `c_test_mod.addCSourceFile(.{ .file = b.path("tests/c_abi_test.c") ... })` |
| `src/c_api.zig` | `include/towncrier.h` | 13 `export fn towncrier_` match header declarations | VERIFIED | All 13 exported symbols confirmed via `nm zig-out/lib/libtowncrier.a \| grep " T towncrier_"` — 13 uppercase-T symbols present |

### Data-Flow Trace (Level 4)

Not applicable. Phase 1 produces a static library with stub implementations — no dynamic data flows. All stubs return 0/NULL by design as documented in the plan. Phase 2 replaces stubs with real implementations.

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| `zig build` exits 0 and produces libtowncrier.a | `zig build` | Exit 0, file exists at 9.2M | PASS |
| `zig build test-c` exits 0 printing PASS | `zig build test-c` | `c_abi_test: PASS`, exit 0 | PASS |
| All 13 ABI symbols exported | `nm zig-out/lib/libtowncrier.a \| grep " T towncrier_" \| wc -l` | 13 | PASS |
| No platform symbol leakage | `nm ... \| grep -i "gtk\|CoreFoundation\|NSObject\|objc_"` | No output | PASS |
| Linux platform guard in build.zig | `grep "os.tag == .linux" build.zig` | Line 27 matches | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| CORE-01 | 01-01-PLAN.md, 01-02-PLAN.md | Zig core library builds as a static library with a stable C ABI header | SATISFIED | `zig-out/lib/libtowncrier.a` exists (9.2M); `include/towncrier.h` with 13 function declarations present |
| CORE-02 | 01-01-PLAN.md, 01-02-PLAN.md | C ABI exposes lifecycle functions (init, tick, free) and snapshot pattern for safe cross-thread data access | SATISFIED | `towncrier_init`, `towncrier_tick`, `towncrier_free`, `towncrier_snapshot_get/count/get_item/free` all exported; snapshot API documented with thread-safety notes |
| CORE-09 | 01-01-PLAN.md, 01-02-PLAN.md | build.zig supports multi-platform compilation; GTK/Linux-specific dependencies are OS-gated | SATISFIED (Linux confirmed; macOS needs human) | `if (target.result.os.tag == .linux)` guard present; no GTK symbols in library on Linux build |

No orphaned requirements — REQUIREMENTS.md maps CORE-01, CORE-02, CORE-09 to Phase 1, matching both plans' `requirements` fields exactly.

### Anti-Patterns Found

Intentional stubs only — all `return 0` / `return null` patterns in `src/c_api.zig` are Phase 1 placeholders with explicit `// Phase 2:` comments documenting what replaces them. These are not bugs. The plan explicitly defines stub behavior as the Phase 1 deliverable.

| File | Pattern | Severity | Impact |
|------|---------|----------|--------|
| `src/c_api.zig` | 11 stub functions returning 0/null | Info | Intentional Phase 1 scaffolding — Phase 2 replaces each with real implementation |
| `src/types.zig` | Empty `TowncrierHandle` struct | Info | Intentional Phase 1 placeholder — Phase 2 adds poll engine fields |

No blockers, no warnings. No `TODO`/`FIXME`/`PLACEHOLDER` comments found (stubs use `// Phase 2:` convention which is appropriate planning annotation).

### Human Verification Required

#### 1. macOS Platform Isolation (Roadmap Success Criteria 1)

**Test:** On a macOS host (Apple Silicon or Intel), clone the repo, run `zig build`, then run:
```
nm zig-out/lib/libtowncrier.a | grep -i gtk || echo "PASS: no GTK symbols"
nm zig-out/lib/libtowncrier.a | grep -i linux || echo "PASS: no Linux symbols"
```
**Expected:** Both commands print the PASS message. `zig build` exits 0.
**Why human:** This verification was performed on a Linux host. Roadmap Success Criteria 1 specifically requires the macOS build to be clean. The `if (target.result.os.tag == .linux)` guard exists in build.zig and is confirmed, but the actual macOS compiler output can only be verified on a macOS machine.

### Gaps Summary

No gaps. All artifacts exist, are substantive, and are correctly wired. The single unverified item (SC-1 macOS build) requires a macOS host and is routed to human verification — it is not a code defect.

The phase goal is achieved on Linux: build system works, static library is produced, 13-function C ABI header has complete ownership documentation, C test passes under ASAN with zero errors. macOS build cannot be confirmed from this environment.

---

_Verified: 2026-04-16T14:30:00Z_
_Verifier: Claude (gsd-verifier)_
