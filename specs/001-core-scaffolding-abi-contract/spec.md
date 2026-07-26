# Feature Specification: Core Scaffolding + ABI Contract

**Feature Branch**: `001-core-scaffolding-abi-contract`

**Created**: 2026-04-16 · **Migrated to Spec Kit**: 2026-07-26

**Status**: ✅ Complete (2026-04-16) — human sign-off on all success criteria

**Requirements**: CORE-01, CORE-02, CORE-09

**Input**: Roadmap Phase 1. The Zig core builds as a static library on both macOS and Linux,
the C ABI header documents ownership rules, and a minimal test binary exercises the lifecycle
functions.

## User Scenarios & Testing *(mandatory)*

This is foundation work: the "user" is a downstream shell developer (and later phases) who must be
able to build and link the core. Each story is independently verifiable via the build system.

### User Story 1 - Core builds as a static library on both platforms (Priority: P1)

A developer runs `zig build` on macOS and on Linux and gets `libtowncrier.a` with no
platform-specific symbol leakage.

**Why this priority**: Nothing downstream exists until the core compiles to a linkable artifact on
both targets. This is the MVP of the whole project.

**Independent Test**: `zig build` on each platform produces `zig-out/lib/libtowncrier.a`; `nm` shows
no GTK/Linux symbols in the macOS build and no macOS symbols in the Linux build.

**Acceptance Scenarios**:

1. **Given** a clean checkout on macOS, **When** `zig build` runs, **Then** `libtowncrier.a` is produced with no GTK/Linux-specific symbol references. *(SC-001)*
2. **Given** a clean checkout on Linux, **When** `zig build` runs, **Then** `libtowncrier.a` is produced with no macOS-specific symbol references. *(SC-002)*

### User Story 2 - C ABI contract is complete, documented, and linkable (Priority: P1)

A minimal C program includes `towncrier.h`, links `libtowncrier.a`, and drives the lifecycle
(`init` → `tick` → `free`) cleanly — proving the exact linkage path the Swift shell will use.

**Why this priority**: The C header is the project's central design surface (Constitution Principle I).
It must be locked and proven before any feature code so later phases don't cause ABI breaks.

**Independent Test**: `zig build test-c` compiles `tests/c_abi_test.c` against the library and exits 0
printing `c_abi_test: PASS`; the same binary built with `-fsanitize=address,undefined` exits cleanly
with no sanitizer output.

**Acceptance Scenarios**:

1. **Given** the built library, **When** the C test binary calls `towncrier_init`/`towncrier_tick`/`towncrier_free`, **Then** it exits cleanly under ASAN with no leaks. *(SC-003)*
2. **Given** `include/towncrier.h`, **When** a developer reads it, **Then** string ownership (who allocates, who frees, null-termination) and callback context lifecycle are documented inline. *(SC-004)*

### Edge Cases

- `towncrier_snapshot_get` returns `NULL` in Phase 1 (no notifications yet) — callers must handle NULL; the C test exercises this path.
- A NULL runtime pointer to `towncrier_init` is documented as not permitted; stubs must not crash.
- Stack-allocated strings must never cross the ABI — string-returning stubs return `NULL`, never stack pointers.

## Requirements *(mandatory)*

### Functional Requirements

- **CORE-01**: The Zig core library MUST build as a static library (`libtowncrier.a`) exposing a stable C ABI header (`include/towncrier.h`), via `b.addLibrary(.{ .linkage = .static })` (Zig 0.14).
- **CORE-02**: The C ABI MUST expose lifecycle functions (`init`, `tick`, `free`, plus `start`/`stop`) and a snapshot pattern (opaque handle + deep-copy read) for safe cross-thread data access. The full 13-function surface is declared up front so it does not change across Phases 2–5.
- **CORE-09**: `build.zig` MUST support multi-platform compilation with GTK/Linux-specific dependencies OS-gated (`target.result.os.tag == .linux`); the macOS build MUST never reference GTK.

### Key Entities

- **`towncrier_t`** — opaque core handle; heap-allocated (system allocator), freed exactly once.
- **`towncrier_snapshot_t`** — opaque immutable snapshot; deep copy; all string fields valid until `snapshot_free`.
- **`towncrier_runtime_s`** — callbacks (`on_update`, `wakeup`, `on_error`) + `userdata`, copied by value at init.
- **`towncrier_account_s`** — account descriptor (id, service, base_url, token, poll_interval); strings not retained.
- **`towncrier_notification_s`** — flat notification (id, account_id, type, state, repo, title, url, updated_at).

Full signatures and ownership rules are the locked contract — see `contracts/towncrier.h` and `plan.md`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `zig build` on macOS produces `libtowncrier.a` with zero GTK/Linux symbol references. ✅
- **SC-002**: `zig build` on Linux produces `libtowncrier.a` with zero macOS symbol references. ✅ (Linux host verified; macOS-host isolation check remains a manual UAT item — see plan.md.)
- **SC-003**: A C test binary links the library, drives `init`/`tick`/`free`, and exits cleanly under ASAN/Valgrind with no leaks. ✅ (ASAN via clang-22; Valgrind substituted by ASAN per environment.)
- **SC-004**: `towncrier.h` documents string ownership (allocate/free/null-termination) and callback context lifecycle inline. ✅

## Assumptions

- Zig 0.14.0+ is available (0.16.0 accepted); pinned via `.mise.toml` and `build.zig.zon`.
- Valgrind is unavailable on the dev machine; ASAN (`-fsanitize=address,undefined`) provides equivalent leak/corruption coverage for this test scope.
- The full ABI surface is declared with stub implementations now; Phases 2–5 fill in behavior without changing signatures.
