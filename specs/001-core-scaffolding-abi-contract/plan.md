# Implementation Plan: Core Scaffolding + ABI Contract

**Branch**: `001-core-scaffolding-abi-contract` | **Date**: 2026-04-16 | **Spec**: [spec.md](spec.md)

**Status**: ✅ Complete (2026-04-16). This plan is a historical record migrated from GSD; it was
executed across two GSD plans (build + ABI, then ASAN validation + sign-off).

## Summary

Bootstrap a greenfield Zig project: directory structure, `build.zig` with platform gating, the
complete C header with full ownership documentation, stub Zig implementations for all 13 ABI
functions, and a C test binary that exercises the ABI via real linking. No runtime logic — the
skeleton every later phase fills in. The ABI surface is transcribed verbatim from
[`docs/research/ARCHITECTURE.md`](../../docs/research/ARCHITECTURE.md) § C ABI Design and is the
locked contract (`contracts/towncrier.h`).

## Technical Context

**Language/Version**: Zig 0.14.0+ (0.16.0 used locally; pinned in `.mise.toml` + `build.zig.zon`)

**Primary Dependencies**: none (stdlib only; `std.heap.c_allocator` for the opaque handle)

**Storage**: N/A in Phase 1 (SQLite arrives in Phase 2)

**Testing**: `zig build test-c` — a C binary compiled via `b.addExecutable` + `addCSourceFile`, linked against `libtowncrier.a`. ASAN via direct `clang -fsanitize=address,undefined`.

**Target Platform**: macOS (aarch64) + Linux (x86_64), cross-compiled from one machine

**Project Type**: Static C-ABI library (libcore) + platform shells (later phases)

**Constraints**: macOS build must not reference GTK; strings crossing the ABI use `[*:0]const u8`; no Zig slices in `export fn` signatures; no `@import("builtin")` OS checks in library source.

**Scale/Scope**: 13 ABI functions, ~6 source files, `build.zig` under ~60 lines.

## Constitution Check

- **I. Zig Core, C-ABI Boundary** — ✅ Core is Zig; the full C ABI is declared and locked in `include/towncrier.h`; ownership rules documented inline.
- **II. Thin Shells** — ✅ N/A yet (no shell), but the boundary that keeps shells thin is established here.
- **III. Build-Time Platform Isolation** — ✅ `build.zig` gates Linux deps behind `target.result.os.tag == .linux`; `nm` confirms no GTK/macOS symbol leakage.
- **IV. Tokens in Keychain** — ✅ Header documents that the `token` field is NOT retained/persisted by the core.
- **V. Poll, Don't Push** — N/A (no polling in Phase 1); the poll-thread callback model (`on_update`/`wakeup`) is declared for Phase 2.

No violations — Complexity Tracking not required.

## Locked Decisions (from GSD CONTEXT/RESEARCH)

- **D-01**: Declare the full API surface now, with stubs. Lifecycle fns get real stubs (alloc/free handle, no-ops); all others return `0`/`NULL`.
- **D-02**: `docs/research/ARCHITECTURE.md` § C ABI Design is the source of truth for signatures/structs/callbacks — transcribed exactly.
- **D-03**: Platform gating via `build.zig` target detection, not source-level OS checks.
- **D-04**: Validation is a **C** source file (`tests/c_abi_test.c`) compiled + linked via `zig build test-c` — proves the Swift linkage path, not a Zig `@cImport` test.
- **D-05**: Rich inline C ownership comments in the header (Ghostty `ghostty.h` style) — no companion doc.
- **D-06**: File layout: `src/c_api.zig` (only file using `export`), `src/root.zig`, `src/types.zig`, `include/towncrier.h`, `tests/c_abi_test.c`.
- **D-07**: Opaque handle allocated with `std.heap.c_allocator` (system malloc; C caller can reason about it).

## Project Structure

```text
towncrier/
├── build.zig               # Static lib + test-c step; Linux platform guard
├── build.zig.zon           # minimum_zig_version = "0.14.0"; empty deps
├── .mise.toml              # Zig toolchain pin
├── include/
│   └── towncrier.h         # Full ABI surface + inline ownership docs (the contract)
├── src/
│   ├── root.zig            # Library root; re-exports c_api
│   ├── c_api.zig           # All export fn stubs (the only file using `export`)
│   └── types.zig           # Placeholder for Notification/Account structs (Phase 2)
└── tests/
    └── c_abi_test.c        # C binary: init/tick/free lifecycle + NULL-snapshot path
```

**Structure Decision**: libcore + platform-shell (Ghostty pattern). Phase 1 delivers only the core
library and its C test harness; shells are Phases 3 (Linux) and 4 (macOS).

## Execution record (what actually happened)

Executed as two GSD plans; both landed clean:

- **Plan 01 — build + ABI**: created `build.zig`/`build.zig.zon`/`.mise.toml`, `include/towncrier.h`, `src/{root,c_api,types}.zig`, `tests/c_abi_test.c`. `zig build` → `libtowncrier.a`; `zig build test-c` → `c_abi_test: PASS`. `addCSourceFile(.{ .file = ... })` was the correct Zig field name.
- **Plan 02 — ASAN + sign-off**: ASAN binary via `clang-22 -fsanitize=address,undefined` exited clean (`c_abi_test: PASS`, no sanitizer output, 6.3M binary confirming ASAN linked). `nm` confirmed exactly 13 exported `T towncrier_*` symbols; no GTK, no macOS (CoreFoundation/NSObject/objc_) symbols. Human approved all four success criteria.

See [tasks.md](tasks.md) for the task-level breakdown and [research.md](research.md) for the full
technical research (patterns, pitfalls, environment, threat model).

## Open items carried forward

- **SC-002 macOS-host isolation** is the one remaining *manual* UAT check — the symbol-leakage check was run on a Linux host; re-running `zig build` + `nm` on a macOS host confirms no GTK/Linux symbols there too. Tracked as a UAT item, not a blocker for Phase 2.
- Research flags for later phases (not Phase 1 work): `std.Thread` sufficiency for per-account pollers (Phase 2); `libstray` v0.4.0 production readiness (Phase 3).
