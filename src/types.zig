//! types.zig — Internal Towncrier data types.
//! Phase 2: Notification, Account, Service, NotifType, TowncrierHandle, TowncrierSnapshot.

const std = @import("std");
const sqlite = @import("sqlite");
const c_api = @import("c_api.zig");

/// GitHub vs GitLab service discriminant.
pub const Service = enum(u8) { github = 0, gitlab = 1 };

/// Notification type, derived from the service-specific "reason" field.
pub const NotifType = enum(u8) {
    pr_review = 0,
    pr_comment = 1,
    issue_mention = 2,
    issue_assigned = 3,
    ci_failed = 4,
    ci_passed = 5,
    pipeline_failed = 6,
    other = 7,
};

/// Represents a single configured account (one service + URL + token).
pub const Account = struct {
    id: u32,
    service: Service,
    /// Heap-owned copy; freed with the account.
    base_url: []const u8,
    /// Heap-owned copy; NEVER written to disk or DB.
    token: []const u8,
    poll_interval_secs: u32,
    /// Cached Last-Modified header value; also stored in poll_state table.
    last_modified: ?[]const u8 = null,
};

/// Internal notification record. Never serialised to disk except via store.zig (no token field).
pub const Notification = struct {
    id: u64,
    account_id: u32,
    /// Service-native thread/notification ID string (e.g. GitHub thread ID).
    api_id: []const u8,
    service: Service,
    notif_type: NotifType,
    /// "owner/name" format.
    repo: []const u8,
    title: []const u8,
    /// Web URL (not API URL). See github.zig apiUrlToWebUrl.
    url: []const u8,
    /// Unix timestamp (seconds).
    updated_at: i64,
    is_read: bool,
};

/// Actions enqueued by the shell and drained by the poll thread.
pub const Action = union(enum) {
    mark_read: struct { notif_id: u64, account_id: u32, api_id: []const u8 },
    mark_all_read: struct { account_id: u32 },
};

/// Forward declaration — PollContext is defined in poller.zig; referenced here by pointer only.
pub const PollContext = opaque {};

/// Combines an Account with its live runtime state.
pub const AccountState = struct {
    account: Account,
    thread: ?std.Thread = null,
    /// Heap-allocated; freed on account removal.
    ctx: ?*PollContext = null,
};

/// Snapshot of notification data passed to the shell via the C ABI.
pub const TowncrierSnapshot = struct {
    /// Slice of C-ABI-compatible notification structs.
    items: []c_api.NotificationC,
    /// All string data owned here; items point into it.
    string_buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,
};

/// Central state for the library instance.
/// Note: Zig 0.16 moved Mutex/RwLock to std.Io (async I/O framework).
/// std.Io.Mutex and std.Io.RwLock are used here for field storage;
/// locking calls in poller.zig will pass the appropriate Io context.
pub const TowncrierHandle = struct {
    allocator: std.mem.Allocator = std.heap.c_allocator,
    callbacks: c_api.RuntimeCallbacks = undefined,
    accounts: std.ArrayList(AccountState) = undefined,
    /// Action queue: shell writes, poll threads drain.
    action_mutex: std.Io.Mutex = .init,
    action_queue: std.ArrayList(Action) = undefined,
    /// notif_id → account_id map; updated on snapshot write; protected by snapshot_lock.
    notif_account_map: std.AutoHashMap(u64, u32) = undefined,
    /// Snapshot: poll thread writes, shell reads.
    snapshot_lock: std.Io.RwLock = .init,
    snapshot: ?*TowncrierSnapshot = null,
    db: ?sqlite.Db = null,
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "types: basic size assertions" {
    try std.testing.expect(@sizeOf(Service) == 1);
    try std.testing.expect(@sizeOf(NotifType) == 1);
}
