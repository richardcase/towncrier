# Phase 1: Core Scaffolding + ABI Contract - Context

**Gathered:** 2026-04-16
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 1 delivers a working Zig build system and the complete C ABI contract. The Zig core builds as a static library (`libtowncrier.a`) on both macOS and Linux. The C header (`towncrier.h`) declares the full API surface with rich ownership documentation. A minimal C test binary exercises the lifecycle functions via the ABI. No polling, no HTTP, no SQLite, no UI — purely scaffolding and contract.

</domain>

<decisions>
## Implementation Decisions

### ABI Surface Completeness
- **D-01:** Define the **full API surface** in `towncrier.h` in Phase 1, with stub implementations for all functions. Lifecycle functions (`init`, `tick`, `free`, `start`, `stop`) get real stubs (allocate/free handle, no-ops). All other functions (`add_account`, `remove_account`, `snapshot_get`, `snapshot_free`, `snapshot_count`, `snapshot_get_item`, `mark_read`, `mark_all_read`) return `0` or `NULL`. The header is the contract — locking the full surface now prevents ABI-breaking changes in Phases 2–5.
- **D-02:** The ABI design from `.planning/research/ARCHITECTURE.md` (§ "C ABI Design") is the source of truth for function signatures, struct layouts, and callback model. Downstream planner must implement exactly those signatures.

### Multi-Platform Build Gating
- **D-03:** Use **build.zig target detection** (`target.result.os.tag == .linux`) to conditionally add GTK/libstray dependencies. Platform isolation is a build concern, not a source concern — Zig library code should not contain `@import("builtin")` OS checks for build-time dependency selection. macOS builds never reference GTK symbols.

### C Test Binary
- **D-04:** The Phase 1 validation test is a **C source file** (`tests/c_abi_test.c`) compiled via a `b.addExecutable` step in `build.zig` and linked against `libtowncrier.a`. Invoked with `zig build test-c`. This proves the C linkage path that the Swift shell will actually use — not a Zig `@cImport` test.

### Header Ownership Documentation
- **D-05:** `towncrier.h` uses **rich inline C comments** to document: who allocates each string, who frees it, null-termination guarantees, callback thread-safety rules, and handle lifecycle. No SAL annotations, no companion doc — ownership documentation lives directly in the header, same pattern as Ghostty's `ghostty.h`.

### Source File Layout
- **D-06:** Follow the file layout prescribed in `.planning/research/ARCHITECTURE.md`: `src/c_api.zig` (C ABI surface implementation), `include/towncrier.h` (the C header), `tests/c_abi_test.c` (C test binary source). This naming is established by the research and should not drift.

### Allocator for Opaque Handle
- **D-07:** The opaque handle allocated in `towncrier_init` uses `std.heap.c_allocator`. This is the correct choice for a C-ABI library — the caller is a non-Zig process (Swift or C), so an arena tied to Zig's lifetime would be confusing. `c_allocator` delegates to the system malloc, which the C caller can reason about.

### Claude's Discretion
- Internal Zig module layout beyond `src/c_api.zig` (e.g., stub helpers, internal types for Phase 1) — Claude decides based on Zig conventions
- Exact `build.zig` step naming for any additional steps beyond `test-c` — Claude decides

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### ABI Design
- `.planning/research/ARCHITECTURE.md` § "C ABI Design" — Complete function signatures, struct layouts, callback model, and ABI boundary rules. This is the authoritative design the header must implement.
- `.planning/research/ARCHITECTURE.md` § "Threading Model" — The poll thread / main thread split; explains why `wakeup` and `on_update` callbacks are fire-and-forget signals.

### Build System
- `.planning/research/STACK.md` — Zig 0.14.0 build system conventions, `b.addLibrary()` vs older APIs, multi-target compilation.
- `.planning/research/PITFALLS.md` — Known Zig ABI and build system pitfalls to avoid.

### Reference Implementation
- Ghostty build.zig (external): https://github.com/ghostty-org/ghostty/blob/main/build.zig — reference for multi-platform Zig build that produces a C-ABI library consumed by Swift
- Mitchell Hashimoto's blog post (external): https://mitchellh.com/writing/zig-and-swiftui — XCFramework integration pattern

### Requirements
- `.planning/REQUIREMENTS.md` §§ CORE-01, CORE-02, CORE-09 — The three requirements this phase must satisfy.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- None yet — this is a greenfield project. Phase 1 creates the foundational assets that all later phases consume.

### Established Patterns
- None yet. Phase 1 establishes the patterns (build.zig structure, ABI conventions, test organization) that subsequent phases follow.

### Integration Points
- `libtowncrier.a` produced here is consumed by:
  - Phase 3 (Linux shell) via direct Zig import of the static lib
  - Phase 4 (macOS shell) via XCFramework packaging (lipo + xcodebuild)
- `towncrier.h` is the contract all shells depend on — changes after Phase 1 are ABI breaks

</code_context>

<specifics>
## Specific Ideas

- The full ABI surface in `.planning/research/ARCHITECTURE.md` is the target shape — not a starting point to evolve from, but the shape Phase 1 should declare upfront.
- Ghostty's pattern is the explicit reference: opaque handle returned from init, runtime callbacks registered at init time, snapshot pattern for thread-safe data access.
- The C test binary specifically proves the linkage path Swift will use — this is intentional, not just convenience.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 01-core-scaffolding-abi-contract*
*Context gathered: 2026-04-16*
