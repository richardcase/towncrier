# Research: Core Scaffolding + ABI Contract

**Researched:** 2026-04-16 · **Migrated to Spec Kit:** 2026-07-26
**Domain:** Zig static library, C ABI design, multi-platform build.zig, C test binary linkage
**Confidence:** HIGH

> Ported verbatim (with path fixes) from the GSD Phase-1 research. Cross-references now point to
> [`docs/research/`](../../docs/research/) (project research) and this feature's `plan.md`/`spec.md`.

## User Constraints (Locked Decisions)

- **D-01:** Define the **full API surface** in `towncrier.h` in Phase 1, with stub implementations for all functions. Lifecycle functions (`init`, `tick`, `free`, `start`, `stop`) get real stubs (allocate/free handle, no-ops). All others (`add_account`, `remove_account`, `snapshot_get`, `snapshot_free`, `snapshot_count`, `snapshot_get_item`, `mark_read`, `mark_all_read`) return `0` or `NULL`. The header is the contract — locking the full surface now prevents ABI-breaking changes in Phases 2–5.
- **D-02:** The ABI design from `docs/research/ARCHITECTURE.md` § "C ABI Design" is the source of truth for signatures, struct layouts, and callback model.
- **D-03:** Use `build.zig` target detection (`target.result.os.tag == .linux`) to conditionally add GTK/libstray deps. Platform isolation is a build concern, not a source concern. macOS builds never reference GTK symbols.
- **D-04:** The Phase 1 validation test is a **C source file** (`tests/c_abi_test.c`) compiled via `b.addExecutable` and linked against `libtowncrier.a`, invoked with `zig build test-c`. Proves the C linkage path Swift will use — not a Zig `@cImport` test.
- **D-05:** `towncrier.h` uses **rich inline C comments** for ownership: who allocates each string, who frees it, null-termination guarantees, callback thread-safety, handle lifecycle. No SAL, no companion doc.
- **D-06:** Source layout: `src/c_api.zig` (C ABI surface), `include/towncrier.h`, `tests/c_abi_test.c` (+ `src/root.zig`, `src/types.zig`).
- **D-07:** The opaque handle uses `std.heap.c_allocator` — no arena, no GPA; delegates to system malloc so the C caller can reason about it.

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CORE-01 | Zig core builds as a static library with a stable C ABI header | `b.addLibrary(.{ .linkage = .static })` produces `libtowncrier.a`; `include/towncrier.h` is the ABI header |
| CORE-02 | C ABI exposes lifecycle fns + a snapshot pattern for safe cross-thread data access | Full surface in `docs/research/ARCHITECTURE.md` § C ABI Design; snapshot = opaque handle + deep-copy read |
| CORE-09 | build.zig multi-platform; GTK/Linux deps OS-gated (macOS never references GTK) | `target.result.os.tag == .linux` guard; core has zero platform-specific deps |

## Summary

Greenfield Zig bootstrap: directory structure, `build.zig` with platform gating, the complete C
header with ownership docs, stub Zig implementations, and a C test binary that exercises the ABI via
linking. No real logic — the skeleton later phases fill in. The ABI design is fully specified in
`docs/research/ARCHITECTURE.md`; signatures/structs/handle pattern/callback model are locked by D-02
and transcribed exactly. Highest risk: `build.zig` multi-platform gating written correctly from day
one so later phases add Linux deps without touching guards. Second risk: the C test binary linking
against the static library via `b.addExecutable` (the exact path Swift uses).

## Standard Stack (Phase 1 only)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Zig | 0.14.0+ | Core language + build system | Locked by CLAUDE.md; `addLibrary()` static linkage is stable in 0.14 |
| `std.heap.c_allocator` | stdlib | Opaque handle allocation in `towncrier_init` | Locked by D-07; delegates to system malloc, safe across the C ABI |
| GCC / Clang | system | C compiler for the test binary | Via `b.addExecutable`; gcc 15.2.1 and clang 22.1.2 confirmed available |

No external Zig dependencies in Phase 1. libstray and zig-gobject are Phase 3 (Linux shell) concerns.

## Architecture Patterns

- **Static library (Zig 0.14):** `b.addLibrary(.{ .linkage = .static })` replaces removed `addStaticLibrary()`. Install header via `lib.installHeader(b.path("include/towncrier.h"), "towncrier.h")`.
- **Platform guard:** gate all Linux-only `linkSystemLibrary` calls behind `if (target.result.os.tag == .linux) { ... }`. In Phase 1 the block holds only a comment placeholder.
- **C test binary:** `b.addExecutable` + `addCSourceFile(.{ .file = b.path("tests/c_abi_test.c"), .flags = &.{"-std=c11"} })` + `linkLibrary(lib)` + `addIncludePath` → wired to a `test-c` step.
- **Opaque handle:** `towncrier_init` allocates `TowncrierHandle` with `std.heap.c_allocator`, returns `?*anyopaque`; `towncrier_free` casts back and destroys.
- **Null-terminated strings:** `[*:0]const u8` in Zig ↔ `const char *` in C; stack strings never cross the boundary.
- **Inline ownership docs:** rich C comments per function/field, mirroring Ghostty's `ghostty.h`.

**Anti-patterns:** removed `addStaticLibrary`/`addSharedLibrary`; Zig slices in `export fn`; `@import("builtin")` OS checks in library source; storing the `rt` pointer instead of copying; unconditional GTK `linkSystemLibrary`.

The full ABI surface, the C test binary, and `build.zig.zon` are reproduced in [`plan.md`](plan.md)
and the locked header lives in [`contracts/towncrier.h`](contracts/towncrier.h).

## Common Pitfalls

1. **Removed Zig 0.14 build APIs** — `addStaticLibrary`/`addSystemLibrary` cause build-script compile errors. Verify every call against 0.14 release notes.
2. **Linux symbols leaking into the macOS build** — GTK/libstray without the `.linux` guard breaks macOS immediately (`library not found for -lgtk-4`). Add the guard in Phase 1 even with no Linux deps.
3. **Stack strings returned across the ABI** — string-returning stubs return `NULL`, never stack pointers; ASAN catches `stack-use-after-return`.
4. **Zig not installed** — `zig build` is step 0 of everything; `.mise.toml` pins the toolchain.
5. **Valgrind unavailable** — use ASAN (`-fsanitize=address,undefined`) via clang; equivalent coverage for this test scope.
6. **Snapshot memory model ambiguity** — document that the snapshot is a **deep copy**: all `const char *` fields are owned by the snapshot and valid until `towncrier_snapshot_free`.

## State of the Art

| Old Approach | Current Approach | When | Impact |
|--------------|------------------|------|--------|
| `b.addStaticLibrary()` | `b.addLibrary(.{ .linkage = .static })` | Zig 0.14.0 (Mar 2025) | Build scripts for ≤0.13 fail on 0.14 |
| `b.addSystemLibrary("name")` | `exe.linkSystemLibrary("name")` | Zig 0.13+ | Called on the artifact, not the builder |
| `addCSourceFile(.{ .source = ... })` | `addCSourceFile(.{ .file = ... })` | Zig 0.13/0.14 | Field rename; `.file` confirmed correct during execution |

## Assumptions Log (resolved)

- **A1** — `addCSourceFile(.{ .file = ... })` is the correct 0.14 API → **confirmed** during Plan 01 execution.
- **A2** — `lib.installHeader(b.path(...), "towncrier.h")` installs the header → confirmed (C test found it via `addIncludePath`).
- **A3** — `-fsanitize=address,undefined` works for the C test binary → confirmed via direct clang-22 compile (6.3M ASAN binary, clean run).

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Zig 0.14.0+ | All build tasks | ✓ (0.16.0) | 0.16.0 | — |
| gcc | C test compilation | ✓ | 15.2.1 | — |
| clang | ASAN validation | ✓ | 22.1.2 | — |
| valgrind | "Valgrind clean" criterion | ✗ | — | ASAN via clang (used) |

## Validation Architecture

| Property | Value |
|----------|-------|
| Framework | Zig build step (`b.addRunArtifact`) + C binary exit code |
| Quick run | `zig build test-c` |
| Phase gate | `zig build test-c` exits 0 + `ls zig-out/lib/libtowncrier.a` succeeds + ASAN clean + 13 `T` symbols + no GTK/macOS symbols |

## Security Domain (Phase 1 scope)

- **V5 Input Validation (partial):** null-pointer checks on ABI inputs. Header documents NULL `rt` is not permitted.
- **Threat register (STRIDE):** null-pointer deref on the boundary (mitigate: null guards), double-free of the handle (accept in Phase 1, documented "call exactly once"; freed-flag in Phase 2), stack-string-across-ABI (mitigate: stubs return NULL), callback-pointer replacement (accept: registered once from trusted caller), toolchain supply chain (mitigate: pin + checksum Zig), `extern struct` layout mismatch (mitigate: `extern struct` + ASAN/test catch).

## Sources

- `docs/research/ARCHITECTURE.md` — full ABI design, struct layouts, threading model, build.zig structure
- `docs/research/PITFALLS.md` — Phase-1 pitfalls with root causes
- CLAUDE.md § Technology Stack — Zig 0.14 build API conventions, version pinning
- Zig 0.14.0 Release Notes — `addLibrary` API; Ghostty `build.zig` — multi-platform static-lib + C ABI reference
