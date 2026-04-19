//! store.zig — SQLite persistence layer for libtowncrier.
//! All database operations go through this module. Tokens are NEVER written here.

const std = @import("std");
const sqlite = @import("sqlite");
const types = @import("types.zig");

/// Poll state for a single account, persisted across restarts.
pub const PollState = struct {
    last_modified: ?[]const u8,
    last_poll_at: i64,
};

// ── Schema ─────────────────────────────────────────────────────────────────

const schema_v1 =
    \\CREATE TABLE IF NOT EXISTS notifications (
    \\    id            INTEGER PRIMARY KEY,
    \\    account_id    INTEGER NOT NULL,
    \\    api_id        TEXT    NOT NULL,
    \\    service       INTEGER NOT NULL,
    \\    notif_type    INTEGER NOT NULL,
    \\    repo          TEXT    NOT NULL,
    \\    title         TEXT    NOT NULL,
    \\    url           TEXT    NOT NULL,
    \\    updated_at    INTEGER NOT NULL,
    \\    is_read       INTEGER NOT NULL DEFAULT 0,
    \\    UNIQUE(account_id, api_id)
    \\);
    \\CREATE TABLE IF NOT EXISTS poll_state (
    \\    account_id     INTEGER PRIMARY KEY,
    \\    last_modified  TEXT,
    \\    last_poll_at   INTEGER
    \\);
    \\CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
;

// ── Lifecycle ──────────────────────────────────────────────────────────────

/// Open the SQLite database at `db_path`, set WAL mode, and apply migrations.
/// Uses Serialized threading mode because multiple poll threads share this connection.
/// SQLITE_OPEN_NOMUTEX (MultiThread) would allow concurrent access to the same
/// connection, corrupting the lookaside allocator. Serialized mode adds a mutex
/// per connection, which is safe for the single-connection shared model here.
pub fn open(db_path: []const u8) !sqlite.Db {
    var db = try sqlite.Db.init(.{
        .mode = sqlite.DbMode{ .File = db_path },
        .open_flags = .{ .write = true, .create = true },
        .threading_mode = .Serialized,
    });
    try db.exec("PRAGMA journal_mode=WAL", .{}, .{});
    try db.exec("PRAGMA synchronous=NORMAL", .{}, .{});
    try migrate(&db);
    return db;
}

/// Apply schema migrations. Idempotent — safe to call on an already-migrated DB.
pub fn migrate(db: *sqlite.Db) !void {
    // Detect whether schema_version table exists and what version it contains.
    var version: i64 = 0;
    const SchemaRow = struct { version: i64 };
    const row = db.oneAlloc(
        SchemaRow,
        std.heap.c_allocator,
        "SELECT version FROM schema_version LIMIT 1",
        .{},
        .{},
    ) catch null; // "no such table" on first run — treat as version 0

    if (row) |r| {
        version = r.version;
    }

    if (version < 1) {
        try db.execMulti(schema_v1);
        try db.exec("INSERT INTO schema_version VALUES (?1)", .{}, .{@as(i64, 1)});
    }
}

// ── Notification CRUD ──────────────────────────────────────────────────────

/// Insert or update a notification. Preserves is_read=1 if already marked read.
/// SECURITY: No token fields are present in this SQL statement (T-02-01).
pub fn upsertNotification(db: *sqlite.Db, notif: types.Notification) !void {
    try db.exec(
        \\INSERT INTO notifications
        \\  (id, account_id, api_id, service, notif_type, repo, title, url, updated_at, is_read)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        \\ON CONFLICT(account_id, api_id) DO UPDATE SET
        \\  title=excluded.title, url=excluded.url, updated_at=excluded.updated_at,
        \\  is_read=CASE WHEN is_read=1 THEN 1 ELSE excluded.is_read END
    ,
        .{},
        .{
            notif.id,
            notif.account_id,
            notif.api_id,
            @as(i64, @intFromEnum(notif.service)),
            @as(i64, @intFromEnum(notif.notif_type)),
            notif.repo,
            notif.title,
            notif.url,
            notif.updated_at,
            @as(i64, if (notif.is_read) 1 else 0),
        },
    );
}

/// Mark a single notification as read by its primary key id.
pub fn markRead(db: *sqlite.Db, notif_id: u64) !void {
    try db.exec(
        "UPDATE notifications SET is_read=1 WHERE id=?1",
        .{},
        .{notif_id},
    );
}

/// Mark all notifications for an account as read.
pub fn markAllRead(db: *sqlite.Db, account_id: u32) !void {
    try db.exec(
        "UPDATE notifications SET is_read=1 WHERE account_id=?1",
        .{},
        .{account_id},
    );
}

/// Query unread notifications. If account_id is non-null, filter to that account.
/// Returns a heap-allocated slice; caller owns and must free each string field.
pub fn queryUnread(
    db: *sqlite.Db,
    allocator: std.mem.Allocator,
    account_id: ?u32,
) ![]types.Notification {
    const NotifRow = struct {
        id: i64,
        account_id: i64,
        api_id: []const u8,
        service: i64,
        notif_type: i64,
        repo: []const u8,
        title: []const u8,
        url: []const u8,
        updated_at: i64,
        is_read: i64,
    };

    const rows = if (account_id) |aid|
        try db.allAlloc(
            NotifRow,
            allocator,
            "SELECT id, account_id, api_id, service, notif_type, repo, title, url, updated_at, is_read FROM notifications WHERE is_read=0 AND account_id=?1 ORDER BY repo, updated_at DESC",
            .{},
            .{@as(i64, @intCast(aid))},
        )
    else
        try db.allAlloc(
            NotifRow,
            allocator,
            "SELECT id, account_id, api_id, service, notif_type, repo, title, url, updated_at, is_read FROM notifications WHERE is_read=0 ORDER BY repo, updated_at DESC",
            .{},
            .{},
        );
    defer allocator.free(rows);

    var result = try allocator.alloc(types.Notification, rows.len);
    for (rows, 0..) |row, i| {
        result[i] = .{
            .id = @intCast(row.id),
            .account_id = @intCast(row.account_id),
            .api_id = row.api_id,
            .service = @enumFromInt(@as(u8, @intCast(row.service))),
            .notif_type = @enumFromInt(@as(u8, @intCast(row.notif_type))),
            .repo = row.repo,
            .title = row.title,
            .url = row.url,
            .updated_at = row.updated_at,
            .is_read = row.is_read != 0,
        };
    }

    return result;
}

// ── Poll state ─────────────────────────────────────────────────────────────

/// Save (upsert) poll state for an account.
pub fn savePollState(
    db: *sqlite.Db,
    account_id: u32,
    last_modified: ?[]const u8,
    last_poll_at: i64,
) !void {
    try db.exec(
        "INSERT OR REPLACE INTO poll_state (account_id, last_modified, last_poll_at) VALUES (?1, ?2, ?3)",
        .{},
        .{ account_id, last_modified, last_poll_at },
    );
}

/// Load poll state for an account. Returns null if no state has been saved yet.
pub fn loadPollState(
    db: *sqlite.Db,
    allocator: std.mem.Allocator,
    account_id: u32,
) !?PollState {
    const PollRow = struct {
        last_modified: ?[]const u8,
        last_poll_at: i64,
    };

    const row = try db.oneAlloc(
        PollRow,
        allocator,
        "SELECT last_modified, last_poll_at FROM poll_state WHERE account_id=?1",
        .{},
        .{@as(i64, @intCast(account_id))},
    );

    if (row) |r| {
        return PollState{
            .last_modified = r.last_modified,
            .last_poll_at = r.last_poll_at,
        };
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "store: migrate creates tables" {
    const allocator = std.testing.allocator;
    var db = try sqlite.Db.init(.{
        .mode = sqlite.DbMode{ .Memory = {} },
        .open_flags = .{ .write = true, .create = true },
        .threading_mode = .MultiThread,
    });
    defer db.deinit();
    try migrate(&db);
    // Verify tables exist by running a benign query on each
    try db.exec("SELECT COUNT(*) FROM notifications", .{}, .{});
    try db.exec("SELECT COUNT(*) FROM poll_state", .{}, .{});
    try db.exec("SELECT COUNT(*) FROM schema_version", .{}, .{});
    _ = allocator;
}
