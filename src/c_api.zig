//! c_api.zig — C ABI surface for libtowncrier.
//! This is the ONLY file in the library that uses `export`. All other files
//! use standard Zig declarations consumed by this module.
//!
//! Phase 1: All functions are stubs. Phase 2 wires real implementations.
//!
//! API note: Zig 0.16 renamed callconv(.C) → callconv(.c) (lowercase).
//! export fn implicitly uses .c calling convention; explicit annotation kept
//! for clarity but uses the new lowercase form.

const std = @import("std");
const types = @import("types.zig");

/// Mirror of towncrier_runtime_s from towncrier.h. extern struct enforces C layout.
const RuntimeCallbacks = extern struct {
    userdata: ?*anyopaque,
    on_update: ?*const fn (?*anyopaque, u32) callconv(.c) void,
    wakeup: ?*const fn (?*anyopaque) callconv(.c) void,
    on_error: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void,
};

/// Mirror of towncrier_account_s from towncrier.h.
const AccountDesc = extern struct {
    id: u32,
    service: u8,
    base_url: ?[*:0]const u8,
    token: ?[*:0]const u8,
    poll_interval_secs: u32,
};

/// Mirror of towncrier_notification_s from towncrier.h.
pub const NotificationC = extern struct {
    id: u64,
    account_id: u32,
    type: u8,
    state: u8,
    repo: ?[*:0]const u8,
    title: ?[*:0]const u8,
    url: ?[*:0]const u8,
    updated_at: i64,
};

// ── Lifecycle ──────────────────────────────────────────────────────────────

export fn towncrier_init(rt: ?*const RuntimeCallbacks) callconv(.c) ?*anyopaque {
    // T-01-01: null rt guard — caller passes NULL only in error; return NULL early.
    if (rt == null) return null;
    // rt is non-null; callbacks registered but unused in Phase 1 (Phase 2 wires them in).
    const handle = std.heap.c_allocator.create(types.TowncrierHandle) catch return null;
    handle.* = .{};
    return handle;
}

export fn towncrier_free(tc: ?*anyopaque) callconv(.c) void {
    if (tc) |ptr| {
        const handle: *types.TowncrierHandle = @ptrCast(@alignCast(ptr));
        std.heap.c_allocator.destroy(handle);
    }
}

export fn towncrier_start(tc: ?*anyopaque) callconv(.c) c_int {
    _ = tc;
    return 0; // Phase 2: start poll thread
}

export fn towncrier_stop(tc: ?*anyopaque) callconv(.c) void {
    _ = tc; // Phase 2: signal poll thread to exit and join
}

export fn towncrier_tick(tc: ?*anyopaque) callconv(.c) void {
    _ = tc; // Phase 2: drain action queue
}

// ── Account management ─────────────────────────────────────────────────────

export fn towncrier_add_account(tc: ?*anyopaque, acct: ?*const AccountDesc) callconv(.c) c_int {
    _ = tc;
    _ = acct;
    return 0; // Phase 2: add to accounts list
}

export fn towncrier_remove_account(tc: ?*anyopaque, account_id: u32) callconv(.c) c_int {
    _ = tc;
    _ = account_id;
    return 0; // Phase 2: remove from accounts list
}

// ── Snapshot API ───────────────────────────────────────────────────────────

export fn towncrier_snapshot_get(tc: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = tc;
    return null; // Phase 1 stub: no notifications yet
}

export fn towncrier_snapshot_free(snap: ?*anyopaque) callconv(.c) void {
    _ = snap; // Phase 2: free deep-copied notification data
}

export fn towncrier_snapshot_count(snap: ?*anyopaque) callconv(.c) u32 {
    _ = snap;
    return 0; // Phase 1 stub
}

export fn towncrier_snapshot_get_item(snap: ?*anyopaque, index: u32) callconv(.c) ?*const NotificationC {
    _ = snap;
    _ = index;
    return null; // Phase 1 stub
}

// ── Actions ────────────────────────────────────────────────────────────────

export fn towncrier_mark_read(tc: ?*anyopaque, notif_id: u64) callconv(.c) c_int {
    _ = tc;
    _ = notif_id;
    return 0; // Phase 2: enqueue mark-read mutation
}

export fn towncrier_mark_all_read(tc: ?*anyopaque, account_id: u32) callconv(.c) c_int {
    _ = tc;
    _ = account_id;
    return 0; // Phase 2: enqueue mark-all-read mutation
}
