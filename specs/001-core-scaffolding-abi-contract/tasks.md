---
description: "Task list for Core Scaffolding + ABI Contract (COMPLETE)"
---

# Tasks: Core Scaffolding + ABI Contract

**Input**: Design documents from `/specs/001-core-scaffolding-abi-contract/`

**Status**: ✅ All tasks complete (2026-04-16). Executed as two GSD plans; ported to Spec Kit format
2026-07-26. Checkboxes reflect the completed record.

**Tests**: A C ABI integration test was explicitly requested (D-04) and is included below.

## Phase 1: Setup (Shared Infrastructure)

- [x] T001 Create the build system: `.mise.toml` (Zig pin), `build.zig.zon` (`minimum_zig_version = "0.14.0"`, empty deps), and `build.zig` (static lib via `b.addLibrary(.{ .linkage = .static })`, header install, `test-c` step, Linux platform guard). → `zig build` exits 0, `zig-out/lib/libtowncrier.a` produced.

## Phase 2: Foundational (the ABI contract — blocks everything downstream)

**⚠️ The header is the locked contract; all later phases depend on it.**

- [x] T002 [P] Author `include/towncrier.h` — full 13-function ABI surface + structs (`towncrier_runtime_s`, `towncrier_account_s`, `towncrier_notification_s`) + service constants, with rich inline ownership documentation (D-05). → `#ifndef TOWNCRIER_H` guard, all 13 fns declared.
- [x] T003 [P] Author `src/types.zig` — `TowncrierHandle` placeholder struct (Phase 2 fills it in).
- [x] T004 Author `src/c_api.zig` — `export fn` stubs for all 13 functions using only C-compatible types (`?*anyopaque`, `extern struct` mirrors, `callconv(.C)`); `towncrier_init` allocates the handle with `std.heap.c_allocator` (D-01, D-07). The only file using `export`.
- [x] T005 Author `src/root.zig` — library root re-exporting `c_api`. → `zig build` exits 0; `nm` shows `towncrier_init`/`towncrier_free`; no GTK symbols.

## Phase 3: User Story 2 — C ABI is linkable & driven end-to-end (P1) 🎯

**Goal**: Prove the exact C linkage path the Swift shell will use.

### Test for User Story 2

- [x] T006 [US2] Author `tests/c_abi_test.c` — define the three runtime callbacks, drive `init` → `start` → `tick` → `add_account` → `snapshot_get` (NULL-safe) → `mark_read` → `remove_account` → `stop` → `free`, assert `init` non-NULL, print `c_abi_test: PASS`. Wired to `zig build test-c`. → exits 0 with `c_abi_test: PASS`.

## Phase 4: User Story 1 — Cross-platform build & isolation validation (P1)

- [x] T007 [US1] Verify `zig build` produces `libtowncrier.a` (9.2M) and `zig build test-c` passes.
- [x] T008 [US1] ASAN validation: compile the C test with `clang-22 -fsanitize=address,undefined`, run → `c_abi_test: PASS`, no sanitizer output (6.3M binary confirms ASAN linked). *(Valgrind substituted by ASAN per environment.)*
- [x] T009 [US1] Symbol-table audit: `nm zig-out/lib/libtowncrier.a` shows exactly 13 exported `T towncrier_*` symbols; no GTK; no macOS (CoreFoundation/NSObject/objc_) symbols; Linux guard present in `build.zig`.

## Phase 5: Sign-off

- [x] T010 Human sign-off — reviewed `zig build test-c` output, `nm` symbol table, and header ownership comments; approved all four success criteria (SC-001…SC-004).

## Remaining manual UAT (not blocking Phase 2)

- [ ] T011 [US1] Re-run SC-002 on a **macOS host**: `zig build` then `nm ... | grep -i gtk`/`grep -i linux` → confirm no GTK/Linux symbols in the macOS-built library. *(Symbol isolation was verified on a Linux host; the macOS-host check is the one open UAT item carried into Phase 2.)*

## Dependencies & Notes

- T001 → T002–T005 (build system before the library compiles) → T006 (test needs the header) → T007–T009 (validation needs the built lib + test) → T010 (sign-off after validation).
- `[P]` tasks touch different files with no ordering dependency.
- Requirements satisfied: **CORE-01, CORE-02, CORE-09**.
- Execution note: `addCSourceFile(.{ .file = ... })` is the correct Zig 0.14 field name (not `.source`).
