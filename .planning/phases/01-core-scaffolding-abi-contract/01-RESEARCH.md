# Phase 1: Core Scaffolding + ABI Contract - Research

**Researched:** 2026-04-16
**Domain:** Zig static library, C ABI design, multi-platform build.zig, C test binary linkage
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Define the **full API surface** in `towncrier.h` in Phase 1, with stub implementations for all functions. Lifecycle functions (`init`, `tick`, `free`, `start`, `stop`) get real stubs (allocate/free handle, no-ops). All other functions (`add_account`, `remove_account`, `snapshot_get`, `snapshot_free`, `snapshot_count`, `snapshot_get_item`, `mark_read`, `mark_all_read`) return `0` or `NULL`. The header is the contract — locking the full surface now prevents ABI-breaking changes in Phases 2–5.
- **D-02:** The ABI design from `.planning/research/ARCHITECTURE.md` § "C ABI Design" is the source of truth for function signatures, struct layouts, and callback model. Downstream planner must implement exactly those signatures.
- **D-03:** Use **build.zig target detection** (`target.result.os.tag == .linux`) to conditionally add GTK/libstray dependencies. Platform isolation is a build concern, not a source concern — Zig library code should not contain `@import("builtin")` OS checks for build-time dependency selection. macOS builds never reference GTK symbols.
- **D-04:** The Phase 1 validation test is a **C source file** (`tests/c_abi_test.c`) compiled via a `b.addExecutable` step in `build.zig` and linked against `libtowncrier.a`. Invoked with `zig build test-c`. This proves the C linkage path that the Swift shell will actually use — not a Zig `@cImport` test.
- **D-05:** `towncrier.h` uses **rich inline C comments** to document: who allocates each string, who frees it, null-termination guarantees, callback thread-safety rules, and handle lifecycle. No SAL annotations, no companion doc — ownership documentation lives directly in the header.
- **D-06:** Source file layout: `src/c_api.zig` (C ABI surface), `include/towncrier.h` (C header), `tests/c_abi_test.c` (C test binary source).
- **D-07:** The opaque handle allocated in `towncrier_init` uses `std.heap.c_allocator`. No arena, no GPA — delegates to system malloc so the C caller can reason about it.

### Claude's Discretion

- Internal Zig module layout beyond `src/c_api.zig` (e.g., stub helpers, internal types for Phase 1) — Claude decides based on Zig conventions.
- Exact `build.zig` step naming for any additional steps beyond `test-c` — Claude decides.

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CORE-01 | Zig core library builds as a static library with a stable C ABI header | `b.addLibrary(.{ .linkage = .static })` in Zig 0.14 produces `libtowncrier.a`; `include/towncrier.h` is the ABI header |
| CORE-02 | C ABI exposes lifecycle functions (init, tick, free) and a snapshot pattern for safe cross-thread data access | Full ABI surface defined in ARCHITECTURE.md § C ABI Design; snapshot pattern uses opaque handle + copy-on-read semantics |
| CORE-09 | build.zig supports multi-platform compilation; GTK/Linux-specific dependencies are OS-gated (macOS build never references GTK) | `target.result.os.tag == .linux` guard in build.zig; core library has zero platform-specific deps |
</phase_requirements>

---

## Summary

Phase 1 is a greenfield Zig project bootstrapping task: create the directory structure, build.zig with platform gating, the complete C header with full ownership documentation, stub Zig implementations, and a C test binary that exercises the ABI via linking. No real logic — just the skeleton that all later phases fill in.

The ABI design is fully specified in `.planning/research/ARCHITECTURE.md` § "C ABI Design". The function signatures, struct layouts, opaque handle pattern, and callback registration model are locked by D-02 and must be transcribed exactly into `towncrier.h` and `src/c_api.zig`. The planner's primary job is sequencing the file creation and build system wiring tasks.

The highest-risk item in this phase is the build.zig multi-platform gating. Even though Phase 1 has no GTK code, the build.zig scaffold must be written correctly from day one so later phases can add Linux dependencies without touching platform guards. The second risk is the C test binary's ability to link against the static library via `b.addExecutable` — this proves the exact linkage path the Swift shell will use and must be exercised before Phase 1 closes.

**Primary recommendation:** Transcribe the ARCHITECTURE.md ABI surface verbatim into `towncrier.h` and `src/c_api.zig`, wire up the `b.addLibrary` + `b.addExecutable test-c` build steps with the Linux OS guard, and validate with `zig build test-c` producing a clean-exit C binary.

---

## Standard Stack

### Core (Phase 1 Only)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Zig | 0.14.0 | Core language and build system | Locked by CLAUDE.md; `addLibrary()` static linkage API is stable in 0.14 |
| std.heap.c_allocator | stdlib | Opaque handle allocation in towncrier_init | Locked by D-07; delegates to system malloc, safe across C ABI boundary |
| GCC or Clang | system | C compiler for test binary | Used via `b.addExecutable`; `gcc 15.2.1` and `clang 22.1.2` confirmed available [VERIFIED: env probe] |

**No external Zig dependencies needed in Phase 1.** libstray and zig-gobject are Linux shell dependencies for Phase 3, not the core scaffolding phase.

**Installation:**
```bash
# Zig 0.14.0 must be installed manually — not available via system package manager on this machine
# Download from: https://ziglang.org/download/0.14.0/
# Recommended: extract to ~/zig-0.14.0/ and add to PATH
# Verify: zig version  # should print 0.14.0
```

Note: Zig is not currently installed on this machine [VERIFIED: env probe — `which zig` returned nothing]. Wave 0 must include a Zig installation step or document that the developer must install it manually before `zig build` works.

---

## Architecture Patterns

### Recommended Project Structure (Phase 1 output)

```
towncrier/
├── build.zig               # Static lib + test-c step; platform-gated
├── build.zig.zon           # Zig 0.14.0 minimum version pin; empty deps for Phase 1
├── include/
│   └── towncrier.h         # Full ABI surface with inline ownership docs
├── src/
│   ├── root.zig            # Library root; re-exports c_api
│   ├── c_api.zig           # All export fn stubs; the only file using `export`
│   └── types.zig           # Placeholder for Notification/Account structs (Phase 2 fills in)
└── tests/
    └── c_abi_test.c        # C binary that calls init/tick/free and exits cleanly
```

This matches D-06 and ARCHITECTURE.md § "Build System — Repo layout" exactly. [CITED: .planning/research/ARCHITECTURE.md]

### Pattern 1: Static Library Declaration (Zig 0.14)

**What:** `b.addLibrary()` with `.linkage = .static` replaces the older `addStaticLibrary()` call removed in 0.14.
**When to use:** Always — this is the only correct API in Zig 0.14.

```zig
// Source: Zig 0.14.0 release notes + STACK.md
const lib = b.addLibrary(.{
    .name = "towncrier",
    .root_source_file = b.path("src/root.zig"),
    .target = target,
    .optimize = optimize,
    .linkage = .static,
    .version = .{ .major = 0, .minor = 1, .patch = 0 },
});
lib.installHeader(b.path("include/towncrier.h"), "towncrier.h");
b.installArtifact(lib);
```

[CITED: .planning/research/STACK.md — build.zig conventions]

### Pattern 2: Platform Guard for Linux-Specific Dependencies

**What:** Gate all Linux-only `linkSystemLibrary` calls behind an OS tag check.
**When to use:** Any library that exists only on Linux (GTK, libstray, libsecret, libdbus).

```zig
// Source: PITFALLS.md Pitfall 8 + ARCHITECTURE.md build.zig structure
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});

// Core library — zero platform-specific deps
const lib = b.addLibrary(.{ .name = "towncrier", ... });

// Linux shell — only built on Linux
if (target.result.os.tag == .linux) {
    const exe = b.addExecutable(.{ .name = "towncrier-gtk", ... });
    exe.linkSystemLibrary("gtk-4");
    // exe.linkSystemLibrary("libstray") — Phase 3
    b.installArtifact(exe);
}
```

[CITED: .planning/research/PITFALLS.md — Pitfall 8]

### Pattern 3: C Test Binary via b.addExecutable

**What:** Compile `tests/c_abi_test.c` as a C executable and link it against `libtowncrier.a` in build.zig.
**When to use:** Locked by D-04 — this is the Phase 1 validation path.

```zig
// Source: Zig build system docs + CONTEXT.md D-04
const c_test = b.addExecutable(.{
    .name = "c_abi_test",
    .target = target,
    .optimize = optimize,
});
c_test.addCSourceFile(.{ .file = b.path("tests/c_abi_test.c"), .flags = &.{"-std=c11"} });
c_test.linkLibrary(lib);
c_test.addIncludePath(b.path("include"));

const run_c_test = b.addRunArtifact(c_test);
const test_c_step = b.step("test-c", "Run C ABI integration test");
test_c_step.dependOn(&run_c_test.step);
```

[ASSUMED: exact `addCSourceFile` API shape for Zig 0.14 — needs verification against official docs once Zig is installed, as build API details shift between minor versions]

### Pattern 4: Opaque Handle with c_allocator

**What:** `towncrier_init` allocates a Zig struct on the heap using `std.heap.c_allocator`, returns `*anyopaque`. `towncrier_free` takes it back and frees it.
**When to use:** Locked by D-07.

```zig
// Source: ARCHITECTURE.md C ABI Design + D-07
const std = @import("std");

const TowncrierHandle = struct {
    // Phase 1: empty. Phase 2 adds: poller, accounts, snapshot mutex.
};

export fn towncrier_init(rt: ?*const towncrier_runtime_s) callconv(.C) ?*anyopaque {
    const handle = std.heap.c_allocator.create(TowncrierHandle) catch return null;
    handle.* = .{};
    _ = rt; // registered but unused in Phase 1
    return handle;
}

export fn towncrier_free(tc: ?*anyopaque) callconv(.C) void {
    if (tc) |ptr| {
        const handle: *TowncrierHandle = @ptrCast(@alignCast(ptr));
        std.heap.c_allocator.destroy(handle);
    }
}
```

### Pattern 5: Null-Terminated String Convention for ABI Boundary

**What:** All strings crossing the ABI use `[*:0]const u8` (null-terminated) in Zig, matching `const char *` in C. Stack-allocated strings must NEVER cross the boundary.
**When to use:** Every ABI function that touches a string.

```zig
// Source: PITFALLS.md Pitfall 2 + ARCHITECTURE.md Anti-Patterns
// CORRECT: string fields in the account descriptor are const char* in C,
// [*:0]const u8 in Zig. Core does not own them — caller retains ownership.
// Strings returned in towncrier_notification_s are owned by the snapshot;
// they are valid until towncrier_snapshot_free() is called.
```

### Pattern 6: towncrier.h Inline Ownership Documentation

**What:** Rich C comments document allocator ownership, null-termination, and callback thread rules directly in the header.
**When to use:** Locked by D-05. Every function and struct field with ownership semantics.

```c
// Source: CONTEXT.md D-05, pattern mirrors Ghostty's ghostty.h
/**
 * Initialize the towncrier core. Returns an opaque handle.
 *
 * The handle is heap-allocated by libtowncrier using the system allocator.
 * The caller MUST call towncrier_free() exactly once when done.
 * Returns NULL on allocation failure.
 *
 * @param rt  Runtime callbacks. The struct is copied; the pointer need not
 *            remain valid after this call returns. Callbacks within are
 *            retained for the lifetime of the handle.
 */
towncrier_t towncrier_init(const towncrier_runtime_s *rt);
```

### Anti-Patterns to Avoid

- **`addStaticLibrary()` / `addSharedLibrary()`:** Removed in Zig 0.14. Use `addLibrary(.{ .linkage = .static })`. [CITED: STACK.md]
- **Zig slices (`[]u8`) in export fn signatures:** Undefined behavior across C ABI. Use `[*:0]const u8` for strings, `?*anyopaque` for handles. [CITED: ARCHITECTURE.md Anti-Patterns]
- **`@import("builtin")` OS checks in library source:** Platform isolation belongs in build.zig, not in `src/` files. [CITED: D-03]
- **Storing the `rt` pointer directly:** The runtime struct must be copied at init time. The callback function pointers and `userdata` are retained; the `towncrier_runtime_s *` from the caller is not. [CITED: ARCHITECTURE.md C ABI Design]
- **Unconditional GTK `linkSystemLibrary` in build.zig:** Breaks macOS builds immediately. Always gate with `target.result.os.tag == .linux`. [CITED: PITFALLS.md Pitfall 8]

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Memory allocation in C-ABI library | Custom allocator | `std.heap.c_allocator` | Locked D-07; delegates to system malloc that C callers understand |
| C test compilation | Custom Makefile | `b.addExecutable` in build.zig | Keeps everything in one build system; Zig can compile C sources directly |
| Multi-arch static lib (Phase 4, not Phase 1) | Manual lipo scripts | `xcodebuild -create-xcframework` + `lipo` via `b.addSystemCommand` | XCFramework is the proven Ghostty pattern; manual scripts break CI |
| Null-termination enforcement | Runtime length checks | `[*:0]const u8` Zig type | Compiler-enforced; no runtime overhead |

---

## Common Pitfalls

### Pitfall 1: Using Removed Zig 0.14 Build APIs
**What goes wrong:** Writing `b.addStaticLibrary(...)` instead of `b.addLibrary(.{ .linkage = .static })` causes a compile error on the build script itself. Similarly, `addSystemLibrary` was renamed in 0.14.
**Why it happens:** Web search results and AI training data reflect older Zig versions.
**How to avoid:** Verify every `build.zig` API call against Zig 0.14 release notes before writing.
**Warning signs:** `error: no field 'addStaticLibrary' in struct 'Build'` during `zig build`.

### Pitfall 2: Linux-Specific Symbols Leaking into macOS Build
**What goes wrong:** If `build.zig` references GTK or libstray without the `.linux` OS guard, macOS builds fail immediately with a linker error. This is a permanent daily tax on macOS development.
**Why it happens:** Easy to forget the guard when first wiring up build.zig.
**How to avoid:** Phase 1 build.zig should add the Linux guard even with no Linux deps yet, establishing the pattern for Phase 3.
**Warning signs:** `error: library not found for -lgtk-4` on macOS.

### Pitfall 3: Stack-Allocated Strings Returned Across ABI
**What goes wrong:** Returning a `[*:0]const u8` pointer to a local variable (stack) in an `export fn`. The pointer is valid only during the function call; the C caller gets a dangling pointer.
**Why it happens:** Zig's compiler does not warn about this in all cases for exported functions.
**How to avoid:** Phase 1 stub implementations that return strings (notification fields inside snapshots) must return `null` — not empty string literals on the stack. Real heap-allocated strings come in Phase 2.
**Warning signs:** Valgrind "use of uninitialized value" or ASAN "stack-use-after-return".

### Pitfall 4: Zig Not Installed — Build Fails at Step 0
**What goes wrong:** `zig build` is the first command in every plan task. If Zig 0.14.0 is not installed, nothing works.
**Why it happens:** Zig is not available via the system package manager on this machine [VERIFIED: env probe].
**How to avoid:** Wave 0 must include a verification step: `zig version` should print `0.14.0`. If not, the developer must install it from https://ziglang.org/download/0.14.0/ before proceeding.
**Warning signs:** `command not found: zig`.

### Pitfall 5: Valgrind Not Available for Leak Validation
**What goes wrong:** The Phase 1 success criteria include "exits cleanly under Valgrind / ASAN with no leaks". Valgrind is not installed on this machine [VERIFIED: env probe].
**Why it happens:** Valgrind is not a default system tool on Arch Linux.
**How to avoid:** Use ASAN (AddressSanitizer) as the primary leak/corruption tool — it is built into clang/gcc (both available). Add `-fsanitize=address,undefined` to the C test compilation flags in build.zig. Valgrind is secondary.
**Warning signs:** `valgrind: command not found` — fall back to ASAN which is available.

### Pitfall 6: towncrier_snapshot_get/snapshot_free Memory Model Ambiguity
**What goes wrong:** If `towncrier_snapshot_get` returns a pointer into core-owned memory (not a copy), the shell could hold a dangling pointer after `snapshot_free`. If it copies, it must copy all string data too — not just the struct.
**Why it happens:** Phase 1 stubs return NULL; but the memory model must be established in the header comments now so Phase 2 implements it correctly.
**How to avoid:** Document in `towncrier.h` that the snapshot is a **deep copy** — all `const char *` fields inside `towncrier_notification_s` point into memory owned by the snapshot and are valid until `towncrier_snapshot_free` is called. This is the correct choice (confirmed by ARCHITECTURE.md anti-pattern note on snapshot memory model).

---

## Code Examples

### Full ABI Surface (from ARCHITECTURE.md, locked by D-02)

```c
/* towncrier.h — authoritative ABI contract */
/* Source: .planning/research/ARCHITECTURE.md § C ABI Design */

/* Opaque handles */
typedef void *towncrier_t;
typedef void *towncrier_snapshot_t;

/* Runtime callbacks — registered at towncrier_init time */
typedef struct {
    void *userdata;
    /* Called from poll thread. Shell MUST marshal to main thread before UI access. */
    void (*on_update)(void *userdata, uint32_t unread_count);
    /* Core requests main-thread wakeup so towncrier_tick() can be called. */
    void (*wakeup)(void *userdata);
    /* Unrecoverable error. message is valid only during this call. */
    void (*on_error)(void *userdata, const char *message);
} towncrier_runtime_s;

/* Account descriptor — shell fills and passes to towncrier_add_account */
typedef struct {
    uint32_t    id;
    uint8_t     service;         /* TOWNCRIER_SERVICE_GITHUB or _GITLAB */
    const char *base_url;        /* NULL = default; non-NULL for self-hosted */
    const char *token;           /* PAT or OAuth token; NOT stored by core */
    uint32_t    poll_interval_secs;
} towncrier_account_s;

/* Flat notification returned inside a snapshot */
typedef struct {
    uint64_t    id;
    uint32_t    account_id;
    uint8_t     type;
    uint8_t     state;
    const char *repo;            /* "owner/name"; valid until snapshot_free */
    const char *title;           /* valid until snapshot_free */
    const char *url;             /* web URL; valid until snapshot_free */
    int64_t     updated_at;      /* Unix timestamp */
} towncrier_notification_s;

/* Service constants */
#define TOWNCRIER_SERVICE_GITHUB 0
#define TOWNCRIER_SERVICE_GITLAB 1

/* Lifecycle */
towncrier_t towncrier_init(const towncrier_runtime_s *rt);
void        towncrier_free(towncrier_t tc);
int         towncrier_start(towncrier_t tc);
void        towncrier_stop(towncrier_t tc);
void        towncrier_tick(towncrier_t tc);

/* Account management */
int towncrier_add_account(towncrier_t tc, const towncrier_account_s *acct);
int towncrier_remove_account(towncrier_t tc, uint32_t account_id);

/* Snapshot — thread-safe read */
towncrier_snapshot_t towncrier_snapshot_get(towncrier_t tc);
void                 towncrier_snapshot_free(towncrier_snapshot_t snap);
uint32_t             towncrier_snapshot_count(towncrier_snapshot_t snap);
const towncrier_notification_s *towncrier_snapshot_get_item(
    towncrier_snapshot_t snap, uint32_t index);

/* Actions */
int towncrier_mark_read(towncrier_t tc, uint64_t notif_id);
int towncrier_mark_all_read(towncrier_t tc, uint32_t account_id);
```

### Minimal C Test Binary (tests/c_abi_test.c)

```c
/* Source: CONTEXT.md D-04 — proves C linkage path Swift will use */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "towncrier.h"

static void on_update(void *ud, uint32_t count) { (void)ud; (void)count; }
static void wakeup(void *ud) { (void)ud; }
static void on_error(void *ud, const char *msg) { (void)ud; (void)msg; }

int main(void) {
    towncrier_runtime_s rt = {
        .userdata = NULL,
        .on_update = on_update,
        .wakeup = wakeup,
        .on_error = on_error,
    };

    towncrier_t tc = towncrier_init(&rt);
    assert(tc != NULL);

    towncrier_tick(tc);

    towncrier_snapshot_t snap = towncrier_snapshot_get(tc);
    /* snap is NULL in Phase 1 stub — that is acceptable */
    if (snap) {
        uint32_t count = towncrier_snapshot_count(snap);
        (void)count;
        towncrier_snapshot_free(snap);
    }

    towncrier_free(tc);

    printf("c_abi_test: PASS\n");
    return 0;
}
```

### build.zig.zon (Phase 1 — no external deps)

```zig
// Source: STACK.md Zig version pinning
.{
    .name = "towncrier",
    .version = "0.1.0",
    .minimum_zig_version = "0.14.0",
    .dependencies = .{},
    .paths = .{"."},
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `b.addStaticLibrary()` | `b.addLibrary(.{ .linkage = .static })` | Zig 0.14.0 (March 2025) | Build scripts targeting 0.13 or earlier fail to compile on 0.14 |
| `b.addSystemLibrary("name")` | `exe.linkSystemLibrary("name")` | Zig 0.13+ | Step must be called on the artifact, not the builder |
| `addCSourceFile(.{ .source = ... })` | `addCSourceFile(.{ .file = ... })` | Zig 0.13/0.14 | Field rename; old code gives a compile error |

[CITED: .planning/research/STACK.md, .planning/research/PITFALLS.md Pitfall 13]

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `b.addCSourceFile(.{ .file = b.path(...), .flags = &.{...} })` is the correct Zig 0.14 API for adding C source files to an executable | Code Examples — Pattern 3 | Build step fails to compile; need to check `zig build --help` or official docs once Zig is installed |
| A2 | `lib.installHeader(b.path("include/towncrier.h"), "towncrier.h")` is the correct Zig 0.14 API for installing a header alongside the library artifact | Standard Stack | Header not installed to zig-out/include; C test may not find it without explicit `addIncludePath` |
| A3 | `-fsanitize=address,undefined` flags work with Zig's `addCSourceFile` for the C test binary | Common Pitfalls — Pitfall 5 | ASAN not active; memory errors in test binary go undetected |

---

## Open Questions

1. **Exact `addCSourceFile` API in Zig 0.14**
   - What we know: Field was renamed from `.source` to `.file` between 0.12 and 0.13/0.14. [CITED: PITFALLS.md Pitfall 13]
   - What's unclear: Whether `.file` takes `b.path(...)` or a raw string in 0.14's final stable API.
   - Recommendation: `zig build --help` or read `std/Build.zig` source once Zig 0.14 is installed. The first `zig build test-c` invocation will surface any API mismatch immediately.

2. **Zig installation on this machine**
   - What we know: Zig is not installed [VERIFIED]. gcc 15.2.1 and clang 22.1.2 are available.
   - What's unclear: Whether the developer will install Zig before execution starts, or whether Wave 0 should include an explicit install step.
   - Recommendation: Wave 0 includes a task: "Verify `zig version` prints `0.14.0`; install from https://ziglang.org/download/0.14.0/ if not present."

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Zig 0.14.0 | All build tasks | ✗ | — | Must install — no fallback |
| gcc | C test compilation (via Zig's C backend) | ✓ | 15.2.1 | — |
| clang | ASAN for leak validation | ✓ | 22.1.2 | — |
| valgrind | Phase 1 success criteria "Valgrind clean" | ✗ | — | ASAN via clang (available) |

**Missing dependencies with no fallback:**
- Zig 0.14.0 — blocks all build tasks. Must be installed before execution. Download: https://ziglang.org/download/0.14.0/

**Missing dependencies with fallback:**
- valgrind — use ASAN (`-fsanitize=address,undefined`) via clang instead. Equivalent coverage for the Phase 1 test binary scope.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Zig build system test step (`b.addRunArtifact`) + C binary exit code |
| Config file | `build.zig` (test-c step) |
| Quick run command | `zig build test-c` |
| Full suite command | `zig build test-c` (Phase 1 has only this test) |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CORE-01 | `libtowncrier.a` produced by `zig build` | smoke | `zig build && ls zig-out/lib/libtowncrier.a` | ❌ Wave 0 |
| CORE-01 | macOS build has no GTK/Linux symbol refs | smoke | `zig build -Dtarget=aarch64-macos && nm zig-out/lib/libtowncrier.a \| grep -c gtk \|\| true` | ❌ Wave 0 |
| CORE-02 | C binary calls init/tick/free and exits 0 | integration | `zig build test-c` | ❌ Wave 0 |
| CORE-02 | C binary exits with no ASAN errors | integration | `zig build test-c` (with ASAN flags in build.zig) | ❌ Wave 0 |
| CORE-09 | Linux build.zig OS guard present and effective | smoke | `zig build -Dtarget=x86_64-linux` (on Linux) or inspect build.zig | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `zig build test-c`
- **Per wave merge:** `zig build test-c`
- **Phase gate:** `zig build test-c` exits 0 + `ls zig-out/lib/libtowncrier.a` succeeds

### Wave 0 Gaps

- [ ] `tests/c_abi_test.c` — covers CORE-02 (C linkage + lifecycle)
- [ ] `include/towncrier.h` — covers CORE-01, CORE-02 (ABI header)
- [ ] `src/c_api.zig` — covers CORE-01, CORE-02 (stub implementations)
- [ ] `build.zig` — covers CORE-01, CORE-09 (static lib + platform guard)
- [ ] `build.zig.zon` — covers CORE-09 (Zig version pin)
- [ ] Zig 0.14.0 installation — prerequisite for all build tasks

---

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | No auth in Phase 1 (stubs only) |
| V3 Session Management | no | No sessions |
| V4 Access Control | no | No access control |
| V5 Input Validation | partial | Null-pointer checks on ABI inputs (towncrier_init, towncrier_free) |
| V6 Cryptography | no | No crypto in Phase 1 |

### Known Threat Patterns for C ABI / Zig FFI

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Null pointer dereference on ABI boundary | Tampering | Explicit null checks before dereferencing `towncrier_t` parameters |
| Callback context use-after-free (Swift ARC) | Tampering | Document in header: caller is responsible for keeping userdata alive; Unmanaged<T>.passRetained pattern for Swift (Phase 4 concern) |
| Double-free of opaque handle | Tampering | `towncrier_free` sets internal state to indicate freed; document "call exactly once" in header |
| Stack pointer returned as string across ABI | Information Disclosure | Use only heap-allocated strings or NULL returns in stub implementations |

---

## Sources

### Primary (HIGH confidence)
- `.planning/research/ARCHITECTURE.md` — Full ABI design, struct layouts, function signatures, threading model, build.zig structure
- `.planning/research/STACK.md` — Zig 0.14 build API conventions, `addLibrary` usage
- `.planning/research/PITFALLS.md` — Phase 1 specific pitfalls (Pitfall 2, 8, 13) with root causes
- `.planning/phases/01-core-scaffolding-abi-contract/01-CONTEXT.md` — Locked decisions D-01 through D-07

### Secondary (MEDIUM confidence)
- Zig 0.14.0 Release Notes: https://ziglang.org/download/0.14.0/release-notes.html — `addLibrary` API confirmation [CITED: STACK.md reference]
- Ghostty build.zig: https://github.com/ghostty-org/ghostty/blob/main/build.zig — reference implementation for multi-platform Zig static library + C ABI [CITED: ARCHITECTURE.md sources]

### Tertiary (LOW confidence)
- `b.addCSourceFile` exact API shape for Zig 0.14 [ASSUMED — verify once Zig installed]

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — fully defined by CLAUDE.md + ARCHITECTURE.md + STACK.md; no ambiguity
- Architecture: HIGH — ABI surface locked by D-02; file layout locked by D-06; build pattern locked by D-03
- Pitfalls: HIGH — documented in PITFALLS.md with root causes; environment gaps verified by env probe

**Research date:** 2026-04-16
**Valid until:** 2026-07-16 (stable domain; Zig 0.14 API will not change for the pinned version)
