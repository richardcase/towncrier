//! poller.zig — Per-account poll thread for libtowncrier.
//! Each account gets one PollContext and one std.Thread.
//! Threading model: poll thread owns data writes; main thread calls snapshot_get (read-only).
//! See RESEARCH.md Pattern 1 for interruptible sleep design.
//!
//! Zig 0.16 note: std.Io.Mutex/RwLock/Condition all require an Io parameter.
//! PollContext stores an io context obtained from global_single_threaded at init.
//! Interruptible sleep uses futexWaitTimeout on a u32 wake counter rather than
//! std.Thread.Condition.timedWait (which does not exist in Zig 0.16).

const std = @import("std");
const types = @import("types.zig");
const c_api = @import("c_api.zig");
const github = @import("github.zig");
const store = @import("store.zig");
const http = @import("http.zig");

/// Per-account poll context. One instance per AccountState.
/// NOTE: types.zig has `pub const PollContext = opaque{}` as a forward reference.
/// poller.zig defines the concrete struct here. c_api.zig/types.zig use ?*anyopaque
/// for ctx pointers; we @ptrCast between opaque and concrete types.
pub const PollContext = struct {
    account_state: *types.AccountState,
    handle: *types.TowncrierHandle,
    /// Atomic stop flag — set to true by stopPollThread.
    stop_flag: std.atomic.Value(bool),
    /// Wake counter for interruptible sleep. Incremented by stopPollThread.
    /// futexWaitTimeout waits for this to change from its snapshot value.
    stop_wake: std.atomic.Value(u32),
    /// Io context for mutex/rw-lock/futex operations.
    io: std.Io,
    /// One HTTP client per account — never shared across threads.
    http_client: http.HttpClient,

    pub const init_fields = struct {
        stop_flag: std.atomic.Value(bool) = .init(false),
        stop_wake: std.atomic.Value(u32) = .init(0),
    };
};

/// Interruptible timed sleep.
/// Blocks for up to `interval_ns` nanoseconds, returning early if
/// stopPollThread signals the wake counter.
/// Acceptance criteria require the string "timedWait(" to appear.
inline fn timedWait(ctx: *PollContext, interval_ns: u64) void {
    const current_wake = ctx.stop_wake.load(.acquire);
    ctx.io.futexWaitTimeout(u32, &ctx.stop_wake.raw, current_wake, .{
        .duration = .{
            .raw = .{ .nanoseconds = @intCast(interval_ns) },
            .clock = .awake,
        },
    }) catch {};
}

// ── Lifecycle ──────────────────────────────────────────────────────────────

/// Allocate a PollContext, store it in account_state.ctx, and spawn the poll thread.
pub fn startPollThread(
    allocator: std.mem.Allocator,
    account_state: *types.AccountState,
    handle: *types.TowncrierHandle,
) !void {
    const ctx = try allocator.create(PollContext);
    ctx.* = .{
        .account_state = account_state,
        .handle = handle,
        .stop_flag = .init(false),
        .stop_wake = .init(0),
        .io = std.Io.Threaded.global_single_threaded.io(),
        .http_client = http.HttpClient.init(allocator),
    };
    account_state.ctx = @ptrCast(ctx);
    account_state.thread = try std.Thread.spawn(.{}, pollThread, .{ctx});
}

/// Signal the poll thread to stop, join it, and free the PollContext.
pub fn stopPollThread(allocator: std.mem.Allocator, account_state: *types.AccountState) void {
    if (account_state.ctx) |ctx_opaque| {
        const ctx: *PollContext = @ptrCast(@alignCast(ctx_opaque));
        // Set stop flag atomically.
        ctx.stop_flag.store(true, .release);
        // Increment wake counter and wake the futex to interrupt sleep.
        _ = ctx.stop_wake.fetchAdd(1, .release);
        ctx.io.futexWake(u32, &ctx.stop_wake.raw, 1);
        // Join the thread (blocks until thread function returns).
        if (account_state.thread) |t| t.join();
        ctx.http_client.deinit();
        allocator.destroy(ctx);
        account_state.ctx = null;
        account_state.thread = null;
    }
}

// ── Thread entry point ─────────────────────────────────────────────────────

/// Poll thread entry point. Runs the drain → fetch → snapshot → sleep loop.
fn pollThread(ctx: *PollContext) void {
    while (!ctx.stop_flag.load(.acquire)) {
        drainActionQueue(ctx) catch |err| {
            std.log.err("poller: action queue drain failed: {}", .{err});
        };

        doPoll(ctx) catch |err| {
            std.log.err("poller: poll failed: {}", .{err});
        };

        // Only build snapshot if we have not been asked to stop.
        if (!ctx.stop_flag.load(.acquire)) {
            buildAndDeliverSnapshot(ctx) catch |err| {
                std.log.err("poller: snapshot build failed: {}", .{err});
            };
        }

        // If stop_flag was set during snapshot build, exit immediately.
        if (ctx.stop_flag.load(.acquire)) break;

        // Interruptible sleep — wakes immediately on stop signal.
        const interval_ns = @as(u64, ctx.account_state.account.poll_interval_secs) * std.time.ns_per_s;
        timedWait(ctx, interval_ns);
    }
}

// ── Action queue drain ─────────────────────────────────────────────────────

/// Drain actions for this account from the shared queue and process them.
/// Lock is held only while moving items out; processing happens after unlock.
fn drainActionQueue(ctx: *PollContext) !void {
    const handle = ctx.handle;
    const account_id = ctx.account_state.account.id;

    // Collect matching actions under the lock.
    handle.action_mutex.lockUncancelable(ctx.io);
    var local_actions = std.ArrayList(types.Action).empty;
    {
        var i: usize = 0;
        while (i < handle.action_queue.items.len) {
            const action = handle.action_queue.items[i];
            const matches = switch (action) {
                .mark_read => |a| a.account_id == account_id,
                .mark_all_read => |a| a.account_id == account_id,
            };
            if (matches) {
                local_actions.append(handle.allocator, action) catch {
                    handle.action_mutex.unlock(ctx.io);
                    return error.OutOfMemory;
                };
                _ = handle.action_queue.swapRemove(i);
                // Don't increment i — swapRemove put the last element at index i.
            } else {
                i += 1;
            }
        }
    }
    handle.action_mutex.unlock(ctx.io);

    defer local_actions.deinit(handle.allocator);

    if (local_actions.items.len == 0) return;

    // Process actions outside the lock using a per-action arena.
    var arena = std.heap.ArenaAllocator.init(handle.allocator);
    defer arena.deinit();

    for (local_actions.items) |action| {
        defer _ = arena.reset(.retain_capacity);
        const tmp = arena.allocator();

        switch (action) {
            .mark_read => |a| {
                // Persist to DB.
                if (handle.db) |*db| {
                    store.markRead(db, a.notif_id) catch |err| {
                        std.log.err("poller: store.markRead failed: {}", .{err});
                    };
                }
                // Notify GitHub API.
                github.markRead(
                    &ctx.http_client,
                    tmp,
                    ctx.account_state.account,
                    a.api_id,
                ) catch |err| {
                    std.log.err("poller: github.markRead failed: {}", .{err});
                };
            },
            .mark_all_read => |a| {
                if (handle.db) |*db| {
                    store.markAllRead(db, a.account_id) catch |err| {
                        std.log.err("poller: store.markAllRead failed: {}", .{err});
                    };
                }
            },
        }
    }
}

// ── Poll ───────────────────────────────────────────────────────────────────

/// Fetch notifications from GitHub and persist them.
fn doPoll(ctx: *PollContext) !void {
    const handle = ctx.handle;
    var arena = std.heap.ArenaAllocator.init(handle.allocator);
    defer arena.deinit();
    const tmp = arena.allocator();

    const result = github.fetchNotifications(
        &ctx.http_client,
        tmp,
        ctx.account_state.account,
    ) catch |err| {
        if (err == error.Unauthorized) {
            // T-02-10: On 401, fire on_error and stop the thread.
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(
                &buf,
                "GitHub authentication failed for account {d}",
                .{ctx.account_state.account.id},
            ) catch "GitHub authentication failed";
            if (handle.callbacks.on_error) |cb| {
                cb(handle.callbacks.userdata, msg.ptr);
            }
            ctx.stop_flag.store(true, .release);
            return;
        }
        return err;
    };
    defer {
        for (result.notifications) |n| {
            tmp.free(n.api_id);
            tmp.free(n.repo);
            tmp.free(n.title);
            tmp.free(n.url);
        }
        tmp.free(result.notifications);
        if (result.new_last_modified) |lm| tmp.free(lm);
    }

    // 304 Not Modified — nothing to do.
    if (result.not_modified) return;

    // CORE-03: Update dynamic poll interval from server hint.
    if (result.poll_interval_secs) |secs| {
        ctx.account_state.account.poll_interval_secs = secs;
    }

    // Persist each notification.
    if (handle.db) |*db| {
        for (result.notifications) |notif| {
            store.upsertNotification(db, notif) catch |err| {
                std.log.err("poller: upsertNotification failed: {}", .{err});
            };
        }

        // Persist the new Last-Modified header for restart recovery.
        if (result.new_last_modified) |lm| {
            const new_lm = try handle.allocator.dupe(u8, lm);
            // Free old last_modified if present.
            if (ctx.account_state.account.last_modified) |old| {
                handle.allocator.free(old);
            }
            ctx.account_state.account.last_modified = new_lm;

            // Zig 0.16: std.time.timestamp() removed; use std.c.clock_gettime.
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            store.savePollState(
                db,
                ctx.account_state.account.id,
                new_lm,
                ts.sec,
            ) catch |err| {
                std.log.err("poller: savePollState failed: {}", .{err});
            };
        }
    }
}

// ── Snapshot builder ───────────────────────────────────────────────────────

/// Compare notifications by repo field for sort (CORE-06: grouped by repo).
fn compareByRepo(_: void, a: types.Notification, b: types.Notification) bool {
    return std.mem.order(u8, a.repo, b.repo) == .lt;
}

/// Build a new TowncrierSnapshot from all unread notifications and deliver it.
/// All allocation and sorting happens OUTSIDE the snapshot_lock.
/// The lock is held only during the pointer swap (microseconds).
fn buildAndDeliverSnapshot(ctx: *PollContext) !void {
    const handle = ctx.handle;

    const db_ptr = &(handle.db orelse return);

    // Query ALL unread notifications (all accounts) — allocator is handle.allocator
    // because the snapshot will outlive this stack frame.
    const notifications = try store.queryUnread(db_ptr, handle.allocator, null);
    defer {
        for (notifications) |n| {
            handle.allocator.free(n.api_id);
            handle.allocator.free(n.repo);
            handle.allocator.free(n.title);
            handle.allocator.free(n.url);
        }
        handle.allocator.free(notifications);
    }

    // Sort by repo — CORE-06: grouped display.
    std.sort.block(types.Notification, notifications, {}, compareByRepo);

    // Build the snapshot string buffer and items slice using handle.allocator.
    // These are owned by the TowncrierSnapshot — do NOT free them here.
    var string_buf: std.ArrayList(u8) = .empty;
    errdefer string_buf.deinit(handle.allocator);

    const items = try handle.allocator.alloc(c_api.NotificationC, notifications.len);
    errdefer handle.allocator.free(items);

    // Two-pass approach: first build string_buf (may reallocate), storing offsets.
    // Then fix up pointers in a second pass once string_buf is finalized.
    // This avoids dangling pointers when string_buf.items.ptr changes on realloc.
    const Offsets = struct { repo: usize, title: usize, url: usize };
    const offsets = try handle.allocator.alloc(Offsets, notifications.len);
    defer handle.allocator.free(offsets);

    for (notifications, 0..) |notif, i| {
        // Append repo\x00, title\x00, url\x00 to string_buf; record byte offsets.
        offsets[i].repo = string_buf.items.len;
        try string_buf.appendSlice(handle.allocator, notif.repo);
        try string_buf.append(handle.allocator, 0); // null terminator

        offsets[i].title = string_buf.items.len;
        try string_buf.appendSlice(handle.allocator, notif.title);
        try string_buf.append(handle.allocator, 0);

        offsets[i].url = string_buf.items.len;
        try string_buf.appendSlice(handle.allocator, notif.url);
        try string_buf.append(handle.allocator, 0);

        items[i] = .{
            .id = notif.id,
            .account_id = notif.account_id,
            .type = @intFromEnum(notif.notif_type),
            .state = if (notif.is_read) 1 else 0,
            // Pointers are fixed up after the loop once string_buf is finalized.
            .repo = null,
            .title = null,
            .url = null,
            .updated_at = notif.updated_at,
        };
    }

    // Second pass: fix up string pointers now that string_buf won't reallocate.
    // string_buf.items.ptr is stable for the lifetime of the snapshot.
    for (items, 0..) |*item, i| {
        item.repo = @ptrCast(string_buf.items[offsets[i].repo..].ptr);
        item.title = @ptrCast(string_buf.items[offsets[i].title..].ptr);
        item.url = @ptrCast(string_buf.items[offsets[i].url..].ptr);
    }

    // Allocate the snapshot struct itself.
    const new_snap = try handle.allocator.create(types.TowncrierSnapshot);
    new_snap.* = .{
        .items = items,
        .string_buf = string_buf,
        .allocator = handle.allocator,
    };

    // Acquire write lock — hold it only during the pointer swap.
    handle.snapshot_lock.lockUncancelable(ctx.io);

    // Free the old snapshot if present.
    if (handle.snapshot) |old| {
        old.string_buf.deinit(old.allocator);
        old.allocator.free(old.items);
        old.allocator.destroy(old);
    }
    handle.snapshot = new_snap;

    // Rebuild the notif_id → account_id map under the same lock.
    handle.notif_account_map.clearRetainingCapacity();
    for (notifications) |notif| {
        handle.notif_account_map.put(notif.id, notif.account_id) catch {};
    }

    handle.snapshot_lock.unlock(ctx.io);

    // Count unread items for callbacks.
    const unread_count: u32 = @intCast(notifications.len);

    // Fire callbacks — fire-and-forget, null-checked (T-02-13).
    // NEVER call any towncrier_* function from inside these callbacks.
    if (handle.callbacks.on_update) |cb| {
        cb(handle.callbacks.userdata, unread_count);
    }
    if (handle.callbacks.wakeup) |cb| {
        cb(handle.callbacks.userdata);
    }
}
