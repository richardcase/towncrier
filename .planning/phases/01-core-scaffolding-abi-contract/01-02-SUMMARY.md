---
phase: 01-core-scaffolding-abi-contract
plan: "02"
subsystem: core-build
tags: [zig, asan, c-abi, validation, symbol-verification]

dependency_graph:
  requires:
    - phase: 01-core-scaffolding-abi-contract
      plan: "01"
      provides: [libtowncrier.a, towncrier.h, c_abi_test.c, build.zig]
  provides:
    - ASAN-validated C ABI integration test (zero memory errors)
    - Symbol table confirmed: 13 exported towncrier_ functions
    - Platform isolation confirmed: no GTK or macOS symbols in libtowncrier.a
    - Phase 1 validation gate passed — human signed off, nyquist_compliant: true
    - ROADMAP.md Phase 1 marked Complete (2/2 plans)
  affects: [phase-02-github-api, phase-03-linux-shell, phase-04-macos-shell]

tech-stack:
  added: [clang-22 (ASAN/UBSAN)]
  patterns: [asan-validation-via-direct-clang-compile, nm-symbol-table-audit]

key-files:
  created: []
  modified: []

key-decisions:
  - "ASAN validation done via direct clang compile (not zig build) — allows -fsanitize=address,undefined flags without modifying build.zig"
  - "nm output shows 26 lines for 13 symbols: each exported fn appears as both internal Zig 't' symbol and exported 'T' C symbol — this is expected and correct per T-02-03"
  - "clang-22 available on system (Arch Linux) — no ASAN deferral needed"
  - "Human approved all four ROADMAP Phase 1 success criteria after reviewing zig build test-c output, nm symbol table, and header ownership comments"

key-files:
  created: []
  modified:
    - .planning/phases/01-core-scaffolding-abi-contract/01-VALIDATION.md
    - .planning/ROADMAP.md

requirements-completed: [CORE-01, CORE-02, CORE-09]

duration: 15min
completed: 2026-04-16
---

# Phase 01 Plan 02: ASAN Validation + Phase 1 Sign-Off Summary

**ASAN-validated libtowncrier.a with 13 confirmed C ABI exports, zero memory errors, and no platform symbol leakage — Phase 1 build foundation cleared for Phase 2.**

## Performance

- **Duration:** ~10 min
- **Started:** 2026-04-16T13:45:00Z
- **Completed:** 2026-04-16T13:49:39Z
- **Tasks completed:** 3 of 3
- **Files modified:** 2 (VALIDATION.md, ROADMAP.md)

## Accomplishments

- `zig build` exits 0; `zig-out/lib/libtowncrier.a` present (9.2M)
- `zig build test-c` exits 0; output: `c_abi_test: PASS`
- ASAN binary compiled with clang-22 (`-fsanitize=address,undefined`); exits 0 with `c_abi_test: PASS`, no ASAN/UBSan error output
- `nm` confirms exactly 13 uppercase-T (exported) `towncrier_` symbols in archive
- No GTK symbols; no macOS symbols (CoreFoundation, NSObject, objc_)
- Linux platform guard confirmed: `if (target.result.os.tag == .linux)` present in build.zig

## Task Commits

1. **Task 1: Run ASAN-enabled C test and verify symbol table** — `c90ada5` (chore, verification-only, no file changes)
2. **Task 2: Human sign-off on Phase 1 deliverables** — (checkpoint — no commit, human approved with "approved")
3. **Task 3: Update VALIDATION.md and ROADMAP.md** — `4e98a2b` (chore)

## Verification Command Outputs (Task 1 record)

**Step 1: zig build**
```
zig-out/lib/libtowncrier.a  9.2M
```
Exit: 0

**Step 2: zig build test-c**
```
c_abi_test: PASS
```
Exit: 0

**Step 3: ASAN run**
```
clang -std=c11 -fsanitize=address,undefined \
  -I include/ tests/c_abi_test.c zig-out/lib/libtowncrier.a \
  -o /tmp/c_abi_test_asan

/tmp/c_abi_test_asan
c_abi_test: PASS
```
Exit: 0. No `AddressSanitizer:` or `UndefinedBehaviorSanitizer:` lines in stderr.

ASAN binary size: 6.3M (non-zero — confirmed ASAN actually linked per T-02-01 mitigation).

**Step 4: nm symbol count**
```
nm zig-out/lib/libtowncrier.a | grep " T towncrier_" | wc -l
13
```

All 13 expected symbols present:
- towncrier_add_account
- towncrier_free
- towncrier_init
- towncrier_mark_all_read
- towncrier_mark_read
- towncrier_remove_account
- towncrier_snapshot_count
- towncrier_snapshot_free
- towncrier_snapshot_get
- towncrier_snapshot_get_item
- towncrier_start
- towncrier_stop
- towncrier_tick

Note: `nm | grep -c towncrier_` returns 26 — expected. Each exported fn appears as both an internal Zig 't' symbol (`c_api.towncrier_*`) and the exported 'T' C symbol. Per T-02-03, internal Zig symbols are not part of the ABI and are harmless.

**Step 5: Platform isolation**
```
nm zig-out/lib/libtowncrier.a | grep -i gtk || echo "PASS: no GTK symbols"
PASS: no GTK symbols

nm zig-out/lib/libtowncrier.a | grep -i "CoreFoundation\|NSObject\|objc_" || echo "PASS: no macOS symbols"
PASS: no macOS symbols
```

**Step 6: Linux platform guard**
```
grep "os.tag == .linux" build.zig
if (target.result.os.tag == .linux) {
```
Guard present at line 27 of build.zig.

## Files Created/Modified

- `.planning/phases/01-core-scaffolding-abi-contract/01-VALIDATION.md` — nyquist_compliant: true, wave_0_complete: true, all task statuses green, all sign-off checkboxes checked, approval marked complete
- `.planning/ROADMAP.md` — Phase 1 checkbox checked, progress table row updated to 2/2 / Complete / 2026-04-16, plan list checked off

## Decisions Made

- Used direct `clang -fsanitize=address,undefined` compile (not `zig build`) for ASAN validation. This avoids modifying build.zig and is consistent with the plan's recommended approach (Pitfall 5 reference).
- `nm | grep -c towncrier_` returning 26 is correct behavior (13 exported + 13 internal Zig names). Acceptance criteria `>= 13` is satisfied by the 13 exported T symbols.

## Deviations from Plan

None — plan executed exactly as written. All six verification steps passed on first attempt.

## Issues Encountered

None. Build was clean; ASAN found no issues; all 13 symbols present.

## Known Stubs

Not applicable — this plan is validation-only.

## Threat Flags

None.

## Status

**Task 1:** Complete — all acceptance criteria met.
**Task 2:** Complete — human approved ("approved").
**Task 3:** Complete — VALIDATION.md and ROADMAP.md updated.

## Next Phase Readiness

Phase 1 is fully complete. Phase 2 (Zig Core — Poll Engine + GitHub) can begin.
- `libtowncrier.a` builds cleanly, ASAN-validated, 13 ABI symbols confirmed
- `include/towncrier.h` locks the C ABI contract with full ownership documentation
- VALIDATION.md: `nyquist_compliant: true`
- ROADMAP.md: Phase 1 marked Complete (2/2 plans)

Open research flags carried forward (documented in STATE.md):
- Phase 2: Verify `std.Thread` sufficiency for per-account poll workers in Zig 0.16
- Phase 3: Evaluate `libstray` v0.4.0 production readiness vs. hand-rolling D-Bus SNI

## Self-Check: PASSED

- ASAN binary at `/tmp/c_abi_test_asan`: confirmed non-zero size (6.3M), confirmed output `c_abi_test: PASS`
- `zig-out/lib/libtowncrier.a`: confirmed present
- `nm` symbol count: 13 exported T symbols confirmed

---
*Phase: 01-core-scaffolding-abi-contract*
*Completed: 2026-04-16*
