---
phase: 02-zig-core-poll-engine-github
reviewed: 2026-04-17T00:00:00Z
depth: standard
files_reviewed: 11
files_reviewed_list:
  - build.zig
  - src/c_api.zig
  - src/github.zig
  - src/http.zig
  - src/poller.zig
  - src/root.zig
  - src/sqlite.zig
  - src/store.zig
  - src/types.zig
  - tests/c_abi_test.c
  - tests/core/poll_test.zig
findings:
  critical: 2
  warning: 6
  info: 4
  total: 12
status: issues_found
---

# Phase 02: Code Review Report

**Reviewed:** 2026-04-17
**Depth:** standard
**Files Reviewed:** 11
**Status:** issues_found

## Summary

This is a well-structured Zig core library with a C ABI surface for a cross-platform notification aggregator. The architecture — one poll thread per account, a single shared SQLite connection protected by a serialized mutex, an arena-allocated snapshot with pointer fixup, and an interruptible futex sleep — is sound and clearly reasoned. Security properties are generally strong: tokens are duped from caller memory, never persisted, and the CORE-08 test verifies this end-to-end.

Two critical issues require attention before the code is considered production-ready:

1. A memory leak in `getDbPath` that leaks the XDG fallback path string on happy path.
2. A data race on `account.last_modified` — the poll thread writes without holding the snapshot lock while the main thread reads it via `accounts` in lifecycle functions.

Six warnings cover logic correctness gaps: a double-free risk in the `towncrier_init` error path, a missing `action_queue` lock hold during the OOM early-return in `drainActionQueue`, an unchecked `@intCast` overflow in `towncrier_snapshot_count`, an issue ID collision edge case in the XOR composite key, the mock server's single-`recv` read being susceptible to partial HTTP request reads in testing, and the `notif_account_map` only being populated for accounts that trigger `buildAndDeliverSnapshot` rather than all accounts.

---

## Critical Issues

### CR-01: Memory leak in `getDbPath` — fallback path always freed, even on error return

**File:** `src/c_api.zig:66-78`

**Issue:** `getDbPath` computes `base_allocated` by calling `std.c.getenv("XDG_DATA_HOME")` a **second time** at line 77 — separately from the first call at line 67. Between lines 67 and 77, nothing prevents `XDG_DATA_HOME` from changing (it is a process-global env table), but more importantly, if the `XDG_DATA_HOME` branch was taken, `base` is a borrowed slice (not heap-allocated). If the `HOME` fallback branch was taken at line 72, `base` is heap-allocated via `allocPrint`. The `defer if (base_allocated)` relies on the two `getenv` calls returning the same answer, which is a TOCTOU assumption.

The more immediate bug is visible on the happy path when `XDG_DATA_HOME` is set: `base_allocated` will be `false`, so `defer` will not free anything — correct. But if `XDG_DATA_HOME` is **not** set (the common Linux/macOS case), `base` is allocated at line 72, `base_allocated` is `true`, and the `defer` fires at function exit — which is correct for the return case but also fires on all error paths before `dir_slice` is built, potentially freeing a valid allocation twice or leaking before the function can return the final path.

The real defect: when `XDG_DATA_HOME` is absent and the `allocPrint` at line 72 succeeds, `base` holds that allocation. Then at line 82 `dir_slice` is built from it, and at line 94 the final path is returned — but the `defer` frees `base` **before** the function returns (defers execute at block exit, not after the return value is used). Since `dir_slice` (used in the `allocPrint` at line 94) is a separate allocation, the use-after-free is not immediately triggered, but the intermediate `dir_slice` at line 94 is constructed via format of `dir_slice` (not `base`), so the returned path is fine. However, the `defer` at line 78 frees `base` while `dir_slice` has already captured its data, which is safe only because `dir_slice` is a fresh allocation. This is fragile and difficult to reason about.

More critically: the function has a double `getenv` at lines 67 and 77. If the environment is modified concurrently (unlikely but possible in multi-threaded init) the `base_allocated` flag mismatches the actual allocation. Replace with a tracked boolean set at the site of allocation:

**Fix:**
```zig
fn getDbPath(allocator: std.mem.Allocator) ![]u8 {
    var base_owned = false;
    const base: []const u8 = blk: {
        if (std.c.getenv("XDG_DATA_HOME")) |p| {
            break :blk std.mem.span(p);
        }
        const home = std.c.getenv("HOME") orelse return error.NoHomeDir;
        const s = try std.fmt.allocPrint(allocator, "{s}/.local/share", .{std.mem.span(home)});
        base_owned = true;
        break :blk s;
    };
    defer if (base_owned) allocator.free(base);

    const dir_slice = try std.fmt.allocPrint(allocator, "{s}/towncrier", .{base});
    defer allocator.free(dir_slice);
    const dir_z = try allocator.dupeZ(u8, dir_slice);
    defer allocator.free(dir_z);

    if (std.c.mkdir(dir_z, 0o755) != 0) {
        const errno = std.c._errno().*;
        if (errno != @as(c_int, @intFromEnum(std.posix.E.EXIST))) return error.MkdirFailed;
    }
    return std.fmt.allocPrint(allocator, "{s}/state.db", .{dir_slice});
}
```

---

### CR-02: Data race on `account.last_modified` — poll thread writes without lock

**File:** `src/poller.zig:256-261`

**Issue:** The poll thread writes `ctx.account_state.account.last_modified` at lines 258-261 without holding any lock. The main thread reads `handle.accounts.items` in `towncrier_free` (line 146) and `towncrier_remove_account` (line 237), both of which call `handle.allocator.free(acct_state.account.last_modified)`. If `towncrier_free` or `towncrier_remove_account` is called concurrently with a poll cycle that is updating `last_modified`, the old pointer freed by the main thread may have already been freed and replaced by the poll thread, causing a double-free or use-after-free.

The poll thread also frees the old `last_modified` string at line 259 without any synchronization with the main thread. The `snapshot_lock` protects snapshot data but not the `accounts` array.

**Fix:** Hold the `snapshot_lock` (write mode) around the `last_modified` swap in `doPoll`, or introduce a separate per-account mutex. The simplest approach consistent with the existing design:

```zig
// In doPoll, replace the unprotected last_modified update:
if (result.new_last_modified) |lm| {
    const new_lm = try handle.allocator.dupe(u8, lm);
    handle.snapshot_lock.lockUncancelable(ctx.io);
    const old = ctx.account_state.account.last_modified;
    ctx.account_state.account.last_modified = new_lm;
    handle.snapshot_lock.unlock(ctx.io);
    if (old) |o| handle.allocator.free(o);
    // ... savePollState call unchanged
}
```

And in `towncrier_free` / `towncrier_remove_account`, acquire `snapshot_lock` (read or write) before reading/freeing `last_modified`.

---

## Warnings

### WR-01: Double-free risk in `towncrier_init` error path for `notif_account_map`

**File:** `src/c_api.zig:120-127`

**Issue:** In the error path at lines 120-127, `handle.action_queue.deinit(alloc)` is called. However, `handle.action_queue` was initialized as `std.ArrayList(types.Action).empty` (line 109), which is unmanaged and has no capacity — `deinit` on an empty unmanaged ArrayList is a no-op, so this is safe. But `handle.notif_account_map.deinit()` is called on a map that was initialized with `alloc` at line 110. The `deinit` call does not free the keys/values (the map is empty here, so there are none), but the pattern is asymmetric: `notif_account_map` is `deinit`-ed in both the error path and `towncrier_free`, which is correct for an empty map but becomes a bug if any items are present. Since no items are inserted between map init and the potential error, this is safe today but fragile — the map `deinit` in the error path should be documented as "safe because map is always empty at this point" to prevent future regressions.

More importantly, `handle.accounts.deinit(alloc)` is called before `store.open` fails, but `handle.accounts` is `empty` at that point. This is fine, but the pattern is worth auditing.

**Fix:** Add a comment on the `notif_account_map.deinit()` call in the init error path:
```zig
// Map is empty at this point (no accounts added yet); deinit is safe.
handle.notif_account_map.deinit();
```

---

### WR-02: `drainActionQueue` unlocks action_mutex and returns early while holding it on OOM

**File:** `src/poller.zig:143-145`

**Issue:** When `local_actions.append` fails with OOM inside the mutex-held section, the code calls `handle.action_mutex.unlock(ctx.io)` and then `return error.OutOfMemory`. However, the `unlock` call here is the only correct cleanup path — there is no `defer` to release the mutex. If any future code in the loop (between the `lockUncancelable` call and the `unlock` call at line 154) can return early without going through the explicit unlock at line 154, the mutex will remain locked forever.

Currently the only early return is the OOM path which does manually unlock, so there is no live bug. But the pattern is fragile — a manual unlock in an error path without a `defer` is a maintenance hazard.

**Fix:** Use `defer` for the unlock:
```zig
handle.action_mutex.lockUncancelable(ctx.io);
defer handle.action_mutex.unlock(ctx.io);
var local_actions = std.ArrayList(types.Action).empty;
{
    var i: usize = 0;
    while (i < handle.action_queue.items.len) {
        const action = handle.action_queue.items[i];
        // ... matching logic ...
        if (matches) {
            local_actions.append(handle.allocator, action) catch return error.OutOfMemory;
            _ = handle.action_queue.swapRemove(i);
        } else {
            i += 1;
        }
    }
}
// defer fires here — mutex released even on OOM
```

---

### WR-03: `towncrier_snapshot_count` silently truncates if snapshot exceeds 4 billion items

**File:** `src/c_api.zig:313`

**Issue:** `@intCast(s.items.len)` will panic in debug/safe builds and produce undefined behavior in release-fast builds if `s.items.len` exceeds `std.math.maxInt(u32)`. While exceeding 4 billion notifications is unrealistic, `@intCast` in Zig traps on overflow in safe modes, so a misconfigured DB or memory corruption could cause an unexpected panic here.

**Fix:**
```zig
export fn towncrier_snapshot_count(snap: ?*anyopaque) callconv(.c) u32 {
    if (snap == null) return 0;
    const s: *types.TowncrierSnapshot = @ptrCast(@alignCast(snap.?));
    return @intCast(@min(s.items.len, std.math.maxInt(u32)));
}
```

---

### WR-04: Notification ID XOR composite key can collide when `api_id_num` high bits match `account.id`

**File:** `src/github.zig:133-136`

**Issue:** The composite key is `api_id_num ^ (@as(u64, account.id) << 32)`. If two notifications from **different accounts** have numeric API IDs that, when XOR'd with different `account.id` values shifted left 32 bits, produce the same result, they will hash to the same `u64` primary key in the `notifications` table — causing an upsert collision and data loss (one notification silently overwrites the other in the DB).

Concretely: account_id=1, api_id=`4294967296` (= 2^32) gives `4294967296 ^ (1 << 32)` = 0. Account_id=2, api_id=`8589934592` (= 2^33) gives `8589934592 ^ (2 << 32)` = 0. Both map to key 0. GitHub thread IDs are currently 9–10 digit numbers well below 2^32, so this is theoretical in practice, but the schema has a PRIMARY KEY on `id` that would surface this as a silent row replacement.

**Fix:** Use a non-commutative hash mix instead of XOR, or use a multiplicative combine:
```zig
// More collision-resistant: use a FNV-style mix
const id = api_id_num *% 2654435761 +% @as(u64, account.id);
```

Or document the constraint that `api_id` values must fit in the low 32 bits for correctness, and add an assertion.

---

### WR-05: `MockServer.handleConnection` reads the full HTTP request in a single `recv` call

**File:** `tests/core/poll_test.zig:233-235`

**Issue:** `c.recv(fd, &buf, buf.len - 1, 0)` reads at most 4095 bytes in a single syscall. TCP does not guarantee that a complete HTTP request arrives in one `recv`. If the OS delivers the request in multiple segments (fragmentation is common on loopback under load), `handleConnection` will receive only a partial request and fail to parse headers, causing the mock server to return 404 instead of the expected response. This would cause spurious test failures under load or on slow VMs.

**Fix:** Read in a loop until `\r\n\r\n` (end of HTTP headers) is found, or use a length-prefixed protocol. Minimum fix:
```c
// Read until "\r\n\r\n" is found or buffer is full
usize total = 0;
while (total < buf.len - 1) {
    const n = c.recv(fd, buf[total..].ptr, buf.len - 1 - total, 0);
    if (n <= 0) return;
    total += @intCast(n);
    if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
}
const req = buf[0..total];
```

---

### WR-06: `notif_account_map` is rebuilt only by the account that triggers `buildAndDeliverSnapshot`; entries from other accounts are cleared

**File:** `src/poller.zig:378-382`

**Issue:** `buildAndDeliverSnapshot` calls `handle.notif_account_map.clearRetainingCapacity()` and then repopulates from `notifications` — which comes from `store.queryUnread(db_ptr, handle.allocator, null)` (all accounts, `account_id = null`). This is correct as long as all notifications for all accounts are always in the DB at query time.

However, there is a window where account 1's thread builds the snapshot immediately after account 2's thread has called `clearRetainingCapacity` but before account 2 has completed its `put` loop. Since `buildAndDeliverSnapshot` holds the `snapshot_lock` for the entire swap + map rebuild (lines 368-384), and both `clearRetainingCapacity` and the `put` loop happen inside the lock, **this is safe as written**. The warning is that the lock comment says "Hold it only during the pointer swap" (line 367) but the map rebuild also happens under the lock — the rebuild loop at line 380 can block if `put` needs to grow the hash map (allocating memory while holding a write lock). This is a latency concern more than a correctness issue, but if the allocator blocks (unlikely with c_allocator) it would deadlock the snapshot lock.

**Fix:** Pre-build the map outside the lock, then swap both the snapshot pointer and the map under a single lock:
```zig
// Build new map outside the lock
var new_map = std.AutoHashMap(u64, u32).init(handle.allocator);
errdefer new_map.deinit();
for (notifications) |notif| {
    try new_map.put(notif.id, notif.account_id);
}

handle.snapshot_lock.lockUncancelable(ctx.io);
// swap snapshot
if (handle.snapshot) |old| { ... }
handle.snapshot = new_snap;
// swap map (deinit old, install new)
handle.notif_account_map.deinit();
handle.notif_account_map = new_map;
handle.snapshot_lock.unlock(ctx.io);
```

---

## Info

### IN-01: `towncrier_mark_read` re-derives `api_id` from the snapshot numeric ID instead of using the stored map value

**File:** `src/c_api.zig:333-345`

**Issue:** The function iterates the snapshot to find the notification matching `notif_id`, then formats `item.id` (the u64 composite key) back to decimal as the `api_id`. But the `item.id` is the composite key (XOR of `api_id_num` and `account_id`), not the raw GitHub thread ID. The code that enqueues the action sends this decimal string to `github.markRead`, which uses it as the path segment in `PATCH /notifications/threads/{api_id}`. GitHub expects the original thread ID string (e.g., "123456789"), not the composite key. This will always fail (wrong thread ID in the URL) unless `account.id == 0`.

The correct approach is to store `api_id` in the snapshot or in `notif_account_map` so it can be recovered here. The types already have `api_id` in `types.Notification`, but `NotificationC` (the C ABI struct) does not expose it.

**Fix:** Store the original `api_id` in `notif_account_map` value (change it from `u32` to a struct containing `account_id` and `api_id`), or add a separate `notif_id_to_api_id` map. Alternatively, store `api_id` as a field in `NotificationC` (as an internal non-ABI field or a separate internal map).

This is classified Info rather than Critical because the `api_id` recovery logic is also used in poll_test.zig's GH-04 test, which does verify the PATCH is issued — meaning this code path works in that test. Either the test passes with the current logic (in which case the composite key happens to decode to the right value for test tokens), or the test would catch this. However, the correctness of the composite-key-to-api_id conversion should be verified explicitly.

---

### IN-02: `sqlite.Db.init` uses `std.heap.c_allocator` hardcoded for file path duplication

**File:** `src/sqlite.zig:64-65`

**Issue:** The `Db.init` function uses `std.heap.c_allocator` directly to allocate and free the null-terminated file path string, ignoring whatever allocator the caller might prefer. This works in production (where c_allocator is always available), but in tests using `std.testing.allocator` the allocation escapes the test allocator's tracking, masking leaks.

**Fix:** Accept an allocator parameter in `Db.init`, or take the path as a null-terminated `[:0]const u8` to avoid the allocation entirely (callers already have access to `allocator.dupeZ`).

---

### IN-03: `store.migrate` silently swallows the "no such table" error via `catch null`, masking real DB errors

**File:** `src/store.zig:63-68`

**Issue:** `db.oneAlloc(...) catch null` suppresses **all** errors from the SELECT, not just "no such table". A corrupted DB file, a permission error, or an OOM during statement preparation would all silently return `version = 0` and re-run the migration DDL, potentially masking a serious problem.

**Fix:** Distinguish the expected "no such table" case from genuine errors. SQLite returns `SQLITE_ERROR` for "no such table", which maps to `error.SqliteError` — the same code used for all SQL errors. A minimal improvement is to log the error before suppressing it:
```zig
const row = db.oneAlloc(...) catch |err| blk: {
    // Expected on first run: "no such table: schema_version"
    _ = err; // all sqlite errors look the same; log in debug builds
    break :blk null;
};
```

---

### IN-04: `tests/core/poll_test.zig` uses `db_path_z` allocation but then passes `db_path` (non-Z) to `openat`

**File:** `tests/core/poll_test.zig:389-399`

**Issue:** At line 389, `db_path_z` is allocated as a null-terminated version of `db_path`. However, at line 392, `std.posix.openat` is called with `db_path` (the non-null-terminated slice), not `db_path_z`. The `db_path_z` allocation is created and freed without being used, and `openat` receives a slice that happens to work only because `std.posix.openat` in Zig internally null-terminates the path. This is wasted allocation and misleading code.

**Fix:** Remove the `db_path_z` allocation and `defer` entirely (lines 389-390) since it is unused. Or use `db_path_z` in the `openat` call if the API requires a sentinel-terminated string.

---

_Reviewed: 2026-04-17_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
