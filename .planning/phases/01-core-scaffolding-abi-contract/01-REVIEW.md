---
phase: 01-core-scaffolding-abi-contract
reviewed: 2026-04-16T00:00:00Z
depth: standard
files_reviewed: 8
files_reviewed_list:
  - build.zig
  - build.zig.zon
  - include/towncrier.h
  - .mise.toml
  - src/c_api.zig
  - src/root.zig
  - src/types.zig
  - tests/c_abi_test.c
findings:
  critical: 0
  warning: 3
  info: 4
  total: 7
status: issues_found
---

# Phase 01: Code Review Report

**Reviewed:** 2026-04-16
**Depth:** standard
**Files Reviewed:** 8
**Status:** issues_found

## Summary

The Phase 1 scaffolding is well-structured. The C ABI contract in `towncrier.h` is thorough, the memory ownership rules are clearly documented, and the Zig implementation correctly uses `extern struct` for C layout compatibility. The `build.zig` uses the correct Zig 0.14 API (`b.addLibrary` with `.linkage = .static`). The C ABI integration test exercises the full lifecycle correctly.

Three issues warrant attention before Phase 2 work begins: a Zig version mismatch between `.mise.toml` and the project's stated pinned version, a contradictory ownership contract in the header for `token`, and a misleading comment about callback registration that could cause a Phase 2 regression. Four lower-priority items are noted for awareness.

---

## Warnings

### WR-01: Zig version mismatch — `.mise.toml` specifies 0.16.0 but project pins 0.14.0

**File:** `.mise.toml:2`

**Issue:** `.mise.toml` specifies `zig = "0.16.0"`, but `build.zig.zon` sets `minimum_zig_version = "0.14.0"` and CLAUDE.md explicitly requires Zig 0.14.0: "Use 0.14, not master — master breaks APIs between releases." Zig 0.16 may have introduced build system API changes (e.g., `addLibrary` parameter changes, `callconv` naming) that silently break the build for contributors using the `.zon`-pinned version. Additionally, the `c_api.zig` comment on line 8 says "Zig 0.16 renamed `callconv(.C)` → `callconv(.c)`" — confirming 0.16 behavior is already being assumed in the source while the manifest claims 0.14 compatibility.

**Fix:** Choose one version and use it consistently across both files. If 0.16 is the intended baseline (and the `callconv(.c)` usage implies it is), update `build.zig.zon`:

```diff
-    .minimum_zig_version = "0.14.0",
+    .minimum_zig_version = "0.16.0",
```

If 0.14 is still the target, revert `.mise.toml` to `zig = "0.14.0"` and verify `callconv(.c)` is valid in 0.14 (it is not — 0.14 uses `callconv(.C)`; fix accordingly in `c_api.zig`).

---

### WR-02: Contradictory token ownership contract in `towncrier.h`

**File:** `include/towncrier.h:117-119`

**Issue:** The file-level comment block states: "The core reads them only during the function call; it does NOT retain pointers to caller-owned strings after the call returns." However, the `token` field comment in `towncrier_account_s` says: "The shell must not free it while the account is active." These two rules directly contradict each other. The `token` comment implies the core retains the pointer for the account's lifetime; the global rule says no string pointer is retained past the call. A shell implementer reading one section but not the other will have incorrect expectations — either leaking memory or using a freed pointer.

**Fix:** Resolve the contradiction explicitly. If the intent is that `token` is copied into the core (like `base_url`), update the field comment:

```c
/** Personal Access Token or OAuth access token. NOT stored by the core —
 *  the core copies the token during add_account. The caller may free
 *  this memory immediately after towncrier_add_account returns.
 *  Null-terminated. Must not be NULL or empty. */
const char *token;
```

If instead the token is intentionally retained as a pointer (for security, to keep one copy in memory), document this as an explicit exception to the global rule in the file-level comment block, and clarify how Phase 2's implementation will satisfy this.

---

### WR-03: `towncrier_init` does not store callbacks — misleading comment risks Phase 2 regression

**File:** `src/c_api.zig:48-51`

**Issue:** The comment on line 48 says "callbacks registered but unused in Phase 1 (Phase 2 wires them in)." In fact, the callbacks are not registered at all — the `rt` pointer is read only to perform the null check, and then discarded. The `TowncrierHandle` (Phase 1 stub) has no field to store them. The word "registered" implies they are stored somewhere. If a Phase 2 developer adds a poll thread to `towncrier_start` without revisiting `towncrier_init`, the callbacks will remain inaccessible, and `on_update`/`wakeup`/`on_error` will never fire. This is a silent correctness failure.

**Fix:** Update the comment to accurately reflect what Phase 1 does and what Phase 2 must do:

```zig
// T-01-01: null rt guard — caller passes NULL only in error; return NULL early.
if (rt == null) return null;
// Phase 1: rt is validated but NOT stored (TowncrierHandle has no callback field yet).
// Phase 2 MUST: add a `callbacks: RuntimeCallbacks` field to TowncrierHandle and
// copy rt.* into handle.callbacks here before starting the poll thread.
```

---

## Info

### IN-01: `c_test_mod` does not explicitly link libc

**File:** `build.zig:32-43`

**Issue:** The C test module (`c_test_mod`) uses `<stdio.h>` and `<assert.h>` from libc but does not set `c_test_mod.link_libc = true`. It links against `lib` (which has `link_libc = true`), so libc symbols are transitively available on most linkers. This is implicit behavior — if the link order or module structure changes in a future Zig version, the transitive dependency may not resolve. Explicit is better than implicit for C interop.

**Fix:**
```zig
const c_test_mod = b.createModule(.{
    .target = target,
    .optimize = optimize,
});
c_test_mod.link_libc = true; // explicit: test uses <stdio.h>, <assert.h>
c_test_mod.addCSourceFile(.{ .file = b.path("tests/c_abi_test.c"), .flags = &.{"-std=c11"} });
```

---

### IN-02: `type` as a struct field name in `NotificationC` shadows Zig keyword

**File:** `src/c_api.zig:35`

**Issue:** The field `type: u8` in `NotificationC` uses `type`, which is a Zig keyword. Zig permits it as a struct field identifier, but accessing it from Zig code requires the `@"type"` escape syntax (e.g., `notif.@"type"`). This is not a bug in Phase 1 since `NotificationC` is populated from C and read by C consumers — the Zig code never constructs or accesses this field directly yet. In Phase 2, when Zig code builds `NotificationC` values to return to C, the keyword collision will require the escape syntax throughout, which is easy to forget and will produce confusing compiler errors.

**Fix:** Consider renaming to `notif_type` in both the Zig struct and the C header, or add a comment on the field warning about the escape requirement:

```zig
/// NOTE: Zig keyword collision — access via notif.@"type" in Zig code.
type: u8,
```

---

### IN-03: `tests/c_abi_test.c` — `towncrier_mark_read` called with ID 0 will need updating in Phase 2

**File:** `tests/c_abi_test.c:79-80`

**Issue:** The test calls `towncrier_mark_read(tc, 0)` with `notif_id = 0` and asserts the return is 0 (success). The header documents that `towncrier_mark_read` should return non-zero if `notif_id` is not found. In Phase 1 the stub returns 0 unconditionally, so the assert passes. In Phase 2, when real validation is added, this call should return non-zero (ID 0 is never a valid notification ID — the header implies IDs are derived from API responses). The test will then fail, requiring an update. This is expected but worth flagging to avoid surprise.

**Fix:** Add a comment to the assertion making the Phase 2 expectation explicit:

```c
/* Phase 1: stub returns 0 always. Phase 2: this call SHOULD return non-zero
   (ID 0 is never a valid notification). Update assertion and use a real
   notif_id obtained from a snapshot when Phase 2 is implemented. */
int mark_result = towncrier_mark_read(tc, 0);
assert(mark_result == 0 && "towncrier_mark_read stub must return 0");
```

---

### IN-04: No `zig build test` step wired in `build.zig`

**File:** `build.zig`

**Issue:** `build.zig` defines a `test-c` step for the C ABI integration test but no `zig build test` step for Zig unit tests. Even with no Zig test cases in Phase 1, the absence of this step means the default `zig build test` does nothing useful. When Phase 2 adds Zig logic (account management, snapshot locking, etc.), having a test step already scaffolded reduces the barrier to writing unit tests.

**Fix:** Add a minimal test step now so `zig build test` is a meaningful target:

```zig
// ── Zig unit tests (zig build test) ──────────────────────────────────────
const unit_tests = b.addTest(.{
    .root_module = lib_mod,
});
const run_unit_tests = b.addRunArtifact(unit_tests);
const test_step = b.step("test", "Run Zig unit tests");
test_step.dependOn(&run_unit_tests.step);
```

---

_Reviewed: 2026-04-16_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
