# Phase 1: Core Scaffolding + ABI Contract - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-16
**Phase:** 01-core-scaffolding-abi-contract
**Areas discussed:** ABI surface completeness, Multi-platform build gating, Test binary approach, Header ownership docs

---

## ABI Surface Completeness

| Option | Description | Selected |
|--------|-------------|----------|
| Full surface, stub impls | Declare all functions from research design; implement only init/tick/free as real stubs, rest return 0/null. Locks the contract now, prevents ABI breaks in later phases. | ✓ |
| Minimal — 3 lifecycle only | Only declare init/tick/free in Phase 1; API surface grows as later phases need it. Less commitment, more evolution. | |
| Full surface, no stubs | Write complete header as pure declarations; no implementation at all in Phase 1. | |

**User's choice:** Full surface, stub impls
**Notes:** Recommended option selected. The rationale: the header is the contract — locking the full API surface in Phase 1 prevents ABI-breaking changes in Phases 2–5.

---

## Multi-Platform Build Gating

| Option | Description | Selected |
|--------|-------------|----------|
| build.zig target detection | `target.result.os.tag == .linux` in build.zig; platform isolation is a build concern, not a source concern. | ✓ |
| Comptime in Zig source | `@import("builtin").os.tag` checks inside library source files. | |
| Separate build targets | Explicit `zig build macos` / `zig build linux` steps with no conditional logic. | |

**User's choice:** build.zig target detection
**Notes:** Recommended option selected. Keeps platform logic in the build system, not in library code.

---

## Test Binary Approach

| Option | Description | Selected |
|--------|-------------|----------|
| zig build step | `b.addExecutable` compiling a C test file; invoked with `zig build test-c`. | ✓ |
| Standalone Makefile | Separate Makefile target; adds a second build system alongside build.zig. | |
| zig test with @cImport | Test in Zig using @cImport; doesn't prove the C linkage path Swift will use. | |

**User's choice:** zig build step
**Notes:** Recommended option selected. Explicitly chosen because it proves the C linkage path the Swift shell will use — not just Zig-side calling conventions.

---

## Header Ownership Docs

| Option | Description | Selected |
|--------|-------------|----------|
| Rich C comments in-header | Inline comments documenting allocation ownership, null-termination, and callback thread safety. Ghostty pattern. | ✓ |
| SAL / __attribute__ annotations | Static-analysis annotations alongside comments. Adds clang-analyzer value but noisy. | |
| Companion HEADER-GUIDE.md | Minimal header + separate doc. Cleaner header but ownership rules are out-of-band. | |

**User's choice:** Rich C comments in-header
**Notes:** Recommended option selected. Explicit reference to Ghostty pattern.

---

## Claude's Discretion

- Internal Zig module layout (`src/` structure, file naming)
- Whether stubs use `std.heap.c_allocator` or a simple arena for the opaque handle
- Exact `build.zig` step naming and structure

## Deferred Ideas

None raised during discussion.
