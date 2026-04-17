//! c_api.zig — C ABI surface for libtowncrier.
//! This is the ONLY file in the library that uses `export`. All other files
//! use standard Zig declarations consumed by this module.
//!
//! Phase 2: All stub bodies replaced with real implementations wired to
//! poller, store, and types modules.
//!
//! API note: Zig 0.16 renamed callconv(.C) → callconv(.c) (lowercase).
//! export fn implicitly uses .c calling convention; explicit annotation kept
//! for clarity but uses the new lowercase form.
//!
//! Zig 0.16 notes:
//! - std.ArrayList is unmanaged — pass allocator to deinit/append/appendSlice.
//! - std.Io.Mutex and std.Io.RwLock require an Io parameter for lock/unlock.
//!   Use std.Io.Threaded.global_single_threaded.io() to obtain an Io context
//!   from the main thread (same approach as poller.zig).

const std = @import("std");
const types = @import("types.zig");
const poller = @import("poller.zig");
const store = @import("store.zig");
const sqlite = @import("sqlite");

/// Mirror of towncrier_runtime_s from towncrier.h. extern struct enforces C layout.
pub const RuntimeCallbacks = extern struct {
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

// ── Helpers ────────────────────────────────────────────────────────────────

/// Returns the io context for uncancelable lock/unlock calls from the main thread.
inline fn mainIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Build the SQLite database path: <XDG_DATA_HOME>/towncrier/state.db (Linux)
/// or <HOME>/.local/share/towncrier/state.db.  Caller must free returned slice.
/// std.fs.getAppDataDir does not exist in Zig 0.16; construct the path manually
/// using XDG_DATA_HOME or HOME environment variables via std.c.getenv.
fn getDbPath(allocator: std.mem.Allocator) ![]u8 {
    // Try XDG_DATA_HOME first; fall back to $HOME/.local/share.
    const base: []const u8 = blk: {
        if (std.c.getenv("XDG_DATA_HOME")) |p| {
            break :blk std.mem.span(p);
        }
        const home = std.c.getenv("HOME") orelse return error.NoHomeDir;
        const home_str = std.mem.span(home);
        const fallback = try std.fmt.allocPrint(allocator, "{s}/.local/share", .{home_str});
        break :blk fallback;
    };
    // If we used the fallback, we allocated it; otherwise we got a static pointer.
    // Track whether base was heap-allocated.
    const base_allocated = std.c.getenv("XDG_DATA_HOME") == null;
    defer if (base_allocated) allocator.free(base);

    // Build null-terminated dir path for std.c.mkdir.
    // std.fmt.allocPrintZ does not exist in Zig 0.16; use dupeZ on a normal allocation.
    const dir_slice = try std.fmt.allocPrint(allocator, "{s}/towncrier", .{base});
    defer allocator.free(dir_slice);
    const dir_z = try allocator.dupeZ(u8, dir_slice);
    defer allocator.free(dir_z);

    // Ensure directory exists; EEXIST is not an error.
    // std.c.mkdir returns 0 on success or -1 on error; check errno on failure.
    if (std.c.mkdir(dir_z, 0o755) != 0) {
        const errno = std.c._errno().*;
        if (errno != @as(c_int, @intFromEnum(std.posix.E.EXIST))) return error.MkdirFailed;
    }

    return std.fmt.allocPrint(allocator, "{s}/state.db", .{dir_slice});
}

// ── Lifecycle ──────────────────────────────────────────────────────────────

export fn towncrier_init(rt: ?*const RuntimeCallbacks) callconv(.c) ?*anyopaque {
    // T-01-01: null rt guard — caller passes NULL only in error; return NULL early.
    if (rt == null) return null;
    const alloc = std.heap.c_allocator;
    const handle = alloc.create(types.TowncrierHandle) catch return null;
    handle.* = .{
        .allocator = alloc,
        .callbacks = rt.?.*,
        .accounts = std.ArrayList(types.AccountState).empty,
        .action_mutex = .init,
        .action_queue = std.ArrayList(types.Action).empty,
        .notif_account_map = std.AutoHashMap(u64, u32).init(alloc),
        .snapshot_lock = .init,
        .snapshot = null,
        .db = null,
    };
    const db_path = getDbPath(alloc) catch {
        alloc.destroy(handle);
        return null;
    };
    defer alloc.free(db_path);
    handle.db = store.open(db_path) catch {
        handle.accounts.deinit(alloc);
        handle.action_queue.deinit(alloc);
        handle.notif_account_map.deinit();
        alloc.destroy(handle);
        return null;
    };
    return handle;
}

export fn towncrier_free(tc: ?*anyopaque) callconv(.c) void {
    if (tc) |ptr| {
        const handle: *types.TowncrierHandle = @ptrCast(@alignCast(ptr));
        // Per RESEARCH.md Pitfall 6: stop all poll threads before freeing handle.
        towncrier_stop(ptr);
        // Free snapshot if present.
        if (handle.snapshot) |snap| {
            snap.string_buf.deinit(snap.allocator);
            snap.allocator.free(snap.items);
            snap.allocator.destroy(snap);
            handle.snapshot = null;
        }
        // Free per-account heap copies (token, base_url, last_modified).
        for (handle.accounts.items) |*acct_state| {
            handle.allocator.free(acct_state.account.base_url);
            handle.allocator.free(acct_state.account.token);
            if (acct_state.account.last_modified) |lm| handle.allocator.free(lm);
        }
        handle.accounts.deinit(handle.allocator);
        handle.action_queue.deinit(handle.allocator);
        handle.notif_account_map.deinit();
        if (handle.db) |*db| db.deinit();
        handle.allocator.destroy(handle);
    }
}

export fn towncrier_start(tc: ?*anyopaque) callconv(.c) c_int {
    if (tc == null) return 1;
    const handle: *types.TowncrierHandle = @ptrCast(@alignCast(tc.?));
    for (handle.accounts.items) |*acct_state| {
        if (acct_state.thread == null) {
            poller.startPollThread(handle.allocator, acct_state, handle) catch return 1;
        }
    }
    return 0;
}

export fn towncrier_stop(tc: ?*anyopaque) callconv(.c) void {
    if (tc == null) return;
    const handle: *types.TowncrierHandle = @ptrCast(@alignCast(tc.?));
    for (handle.accounts.items) |*acct_state| {
        if (acct_state.thread != null) {
            poller.stopPollThread(handle.allocator, acct_state);
        }
    }
}

export fn towncrier_tick(_: ?*anyopaque) callconv(.c) void {
    // Phase 2: action queue drain happens on poll thread; tick is a no-op.
}

// ── Account management ─────────────────────────────────────────────────────

export fn towncrier_add_account(tc: ?*anyopaque, acct: ?*const AccountDesc) callconv(.c) c_int {
    if (tc == null or acct == null) return 1;
    const handle: *types.TowncrierHandle = @ptrCast(@alignCast(tc.?));
    const desc = acct.?;
    if (desc.token == null) return 1;

    // Copy all strings — caller retains ownership; core must not retain caller's pointers.
    // T-02-15: token and base_url are duped; caller can free their memory after return.
    const token_slice = std.mem.span(desc.token.?);
    const token_copy = handle.allocator.dupe(u8, token_slice) catch return 1;

    const base_url_slice: []const u8 = if (desc.base_url) |bu| std.mem.span(bu) else "https://api.github.com";
    const base_url_copy = handle.allocator.dupe(u8, base_url_slice) catch {
        handle.allocator.free(token_copy);
        return 1;
    };

    const service: types.Service = switch (desc.service) {
        0 => .github,
        1 => .gitlab,
        else => {
            handle.allocator.free(token_copy);
            handle.allocator.free(base_url_copy);
            return 1;
        },
    };

    const account = types.Account{
        .id = desc.id,
        .service = service,
        .base_url = base_url_copy,
        .token = token_copy,
        .poll_interval_secs = @max(desc.poll_interval_secs, 60),
        .last_modified = null,
    };

    const acct_state = types.AccountState{ .account = account };
    handle.accounts.append(handle.allocator, acct_state) catch {
        handle.allocator.free(token_copy);
        handle.allocator.free(base_url_copy);
        return 1;
    };
    return 0;
}

export fn towncrier_remove_account(tc: ?*anyopaque, account_id: u32) callconv(.c) c_int {
    if (tc == null) return 1;
    const handle: *types.TowncrierHandle = @ptrCast(@alignCast(tc.?));
    for (handle.accounts.items, 0..) |*acct_state, i| {
        if (acct_state.account.id == account_id) {
            // Per D-02: finish current poll cycle before removing.
            poller.stopPollThread(handle.allocator, acct_state);
            handle.allocator.free(acct_state.account.token);
            handle.allocator.free(acct_state.account.base_url);
            if (acct_state.account.last_modified) |lm| handle.allocator.free(lm);
            _ = handle.accounts.orderedRemove(i);
            return 0;
        }
    }
    return 1; // not found
}

// ── Snapshot API ───────────────────────────────────────────────────────────

export fn towncrier_snapshot_get(tc: ?*anyopaque) callconv(.c) ?*anyopaque {
    if (tc == null) return null;
    const handle: *types.TowncrierHandle = @ptrCast(@alignCast(tc.?));
    const io = mainIo();

    handle.snapshot_lock.lockSharedUncancelable(io);
    defer handle.snapshot_lock.unlockShared(io);

    const src = handle.snapshot orelse return null;

    // Deep copy — caller owns result; no lock held after return.
    // T-02-17: bounded copy, no multi-tenant risk.
    const new_snap = handle.allocator.create(types.TowncrierSnapshot) catch return null;
    var new_buf = std.ArrayList(u8).empty;
    new_buf.appendSlice(handle.allocator, src.string_buf.items) catch {
        handle.allocator.destroy(new_snap);
        return null;
    };

    const new_items = handle.allocator.dupe(NotificationC, src.items) catch {
        new_buf.deinit(handle.allocator);
        handle.allocator.destroy(new_snap);
        return null;
    };

    // Fix up string pointers to point into new_buf (not the original).
    // Safe: string_buf is a single contiguous allocation; offset rebases all pointers.
    if (src.string_buf.items.len > 0 and new_buf.items.len > 0) {
        const old_base = @intFromPtr(src.string_buf.items.ptr);
        const new_base = @intFromPtr(new_buf.items.ptr);
        for (new_items) |*item| {
            if (item.repo) |p| {
                const off = @intFromPtr(p) - old_base;
                item.repo = @ptrFromInt(new_base + off);
            }
            if (item.title) |p| {
                const off = @intFromPtr(p) - old_base;
                item.title = @ptrFromInt(new_base + off);
            }
            if (item.url) |p| {
                const off = @intFromPtr(p) - old_base;
                item.url = @ptrFromInt(new_base + off);
            }
        }
    }

    new_snap.* = .{
        .items = new_items,
        .string_buf = new_buf,
        .allocator = handle.allocator,
    };
    return new_snap;
}

export fn towncrier_snapshot_free(snap: ?*anyopaque) callconv(.c) void {
    if (snap) |ptr| {
        const s: *types.TowncrierSnapshot = @ptrCast(@alignCast(ptr));
        s.string_buf.deinit(s.allocator);
        s.allocator.free(s.items);
        s.allocator.destroy(s);
    }
}

export fn towncrier_snapshot_count(snap: ?*anyopaque) callconv(.c) u32 {
    if (snap == null) return 0;
    const s: *types.TowncrierSnapshot = @ptrCast(@alignCast(snap.?));
    return @intCast(s.items.len);
}

export fn towncrier_snapshot_get_item(snap: ?*anyopaque, index: u32) callconv(.c) ?*const NotificationC {
    if (snap == null) return null;
    const s: *types.TowncrierSnapshot = @ptrCast(@alignCast(snap.?));
    if (index >= s.items.len) return null;
    return &s.items[index];
}

// ── Actions ────────────────────────────────────────────────────────────────

export fn towncrier_mark_read(tc: ?*anyopaque, notif_id: u64) callconv(.c) c_int {
    if (tc == null) return 1;
    const handle: *types.TowncrierHandle = @ptrCast(@alignCast(tc.?));
    const io = mainIo();

    // T-02-18: account_id looked up from core-controlled map; caller cannot forge.
    handle.snapshot_lock.lockSharedUncancelable(io);
    const account_id_opt = handle.notif_account_map.get(notif_id);
    // Collect api_id from snapshot — GitHub thread IDs are numeric strings.
    var api_id_buf: [64]u8 = undefined;
    var api_id_len: usize = 0;
    if (handle.snapshot) |snap| {
        for (snap.items) |item| {
            if (item.id == notif_id) {
                // GitHub thread ID: format numeric id back to decimal string.
                const written = std.fmt.bufPrint(&api_id_buf, "{d}", .{item.id}) catch "";
                api_id_len = written.len;
                break;
            }
        }
    }
    handle.snapshot_lock.unlockShared(io);

    const account_id = account_id_opt orelse return 1;
    if (api_id_len == 0) return 1;

    const api_id_copy = handle.allocator.dupe(u8, api_id_buf[0..api_id_len]) catch return 1;

    const action = types.Action{
        .mark_read = .{
            .notif_id = notif_id,
            .account_id = account_id,
            .api_id = api_id_copy,
        },
    };

    handle.action_mutex.lockUncancelable(io);
    handle.action_queue.append(handle.allocator, action) catch {
        handle.action_mutex.unlock(io);
        handle.allocator.free(api_id_copy);
        return 1;
    };
    handle.action_mutex.unlock(io);
    return 0;
}

export fn towncrier_mark_all_read(tc: ?*anyopaque, account_id: u32) callconv(.c) c_int {
    if (tc == null) return 1;
    const handle: *types.TowncrierHandle = @ptrCast(@alignCast(tc.?));
    const io = mainIo();
    const action = types.Action{ .mark_all_read = .{ .account_id = account_id } };
    handle.action_mutex.lockUncancelable(io);
    handle.action_queue.append(handle.allocator, action) catch {
        handle.action_mutex.unlock(io);
        return 1;
    };
    handle.action_mutex.unlock(io);
    return 0;
}
