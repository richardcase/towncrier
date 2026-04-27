# Phase 2: Zig Core — Poll Engine + GitHub - Pattern Map

**Mapped:** 2026-04-17
**Files analyzed:** 8 new/modified files
**Analogs found:** 3 / 8 (5 have no in-codebase analog — patterns from RESEARCH.md)

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `src/types.zig` | model | — | `src/types.zig` (Phase 1 empty shell) | self — expand in place |
| `src/http.zig` | utility | request-response | `src/c_api.zig` (C ABI + std import conventions) | partial — import/struct style only |
| `src/github.zig` | service | request-response | `src/c_api.zig` (extern structs, error handling) | partial — Zig module conventions only |
| `src/poller.zig` | service | event-driven | `src/c_api.zig` (handle pointer pattern) | partial — handle/allocator conventions only |
| `src/store.zig` | service | CRUD | `src/c_api.zig` (allocator + error union conventions) | partial — module conventions only |
| `src/c_api.zig` | controller | request-response | `src/c_api.zig` (existing stubs) | exact — replace stub bodies |
| `build.zig` | config | — | `build.zig` (existing test-c step) | exact — extend with test-poll step |
| `tests/core/poll_test.zig` | test | event-driven | `tests/c_abi_test.c` (test structure, assert pattern) | role-match — different language |

---

## Pattern Assignments

### `src/types.zig` (model — expand in place)

**Analog:** `src/types.zig` (Phase 1, lines 1–7) — expand this file, do not replace root.

**Current file** (`src/types.zig` lines 1–7):
```zig
//! types.zig — Internal Towncrier data types.
//! Phase 1: placeholder. Phase 2 adds Notification, Account, Service, NotifType structs.

/// Internal handle struct. Phase 1: empty. Phase 2 adds poller, accounts, snapshot mutex.
pub const TowncrierHandle = struct {
    // Phase 2: add poll engine, accounts list, snapshot RwLock here
};
```

**Phase 2 expansion pattern** (from RESEARCH.md "TowncrierHandle: Phase 2 Structure"):
```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub const Service = enum(u8) { github = 0, gitlab = 1 };

pub const NotifType = enum(u8) {
    pr_review,
    pr_comment,
    issue_mention,
    issue_assigned,
    ci_failed,
    other,
};

pub const Account = struct {
    id: u32,
    service: Service,
    base_url: []const u8,  // heap-owned copy, freed with account
    token: []const u8,     // heap-owned copy, NEVER written to disk or DB
    poll_interval_secs: u32,
    last_modified: ?[]const u8 = null, // cached per-account; also in poll_state table
};

pub const Notification = struct {
    id: u64,
    account_id: u32,
    api_id: []const u8,    // GitHub thread ID string
    service: Service,
    notif_type: NotifType,
    repo: []const u8,      // "owner/name"
    title: []const u8,
    url: []const u8,       // web URL (not API URL — see github.zig apiUrlToWebUrl)
    updated_at: i64,       // Unix timestamp
    is_read: bool,
};

pub const Action = union(enum) {
    mark_read: struct { notif_id: u64, account_id: u32, api_id: []const u8 },
    mark_all_read: struct { account_id: u32 },
};

pub const AccountState = struct {
    account: Account,
    thread: ?std.Thread = null,
    ctx: ?*PollContext = null, // heap-allocated; freed on remove
};

// Forward declaration — PollContext defined in poller.zig; referenced here via pointer only.
pub const PollContext = opaque {};

pub const TowncrierHandle = struct {
    allocator: std.mem.Allocator = std.heap.c_allocator,
    callbacks: RuntimeCallbacks = undefined,
    accounts: std.ArrayList(AccountState) = undefined,
    // Action queue: main thread writes, poll threads drain
    action_mutex: std.Thread.Mutex = .{},
    action_queue: std.ArrayList(Action) = undefined,
    // notif_id → account_id map: updated on snapshot write; protected by snapshot_lock
    notif_account_map: std.AutoHashMap(u64, u32) = undefined,
    // Snapshot: poll thread writes, main thread reads
    snapshot_lock: std.Thread.RwLock = .{},
    snapshot: ?*TowncrierSnapshot = null,
    db: ?sqlite.Db = null,
};

pub const TowncrierSnapshot = struct {
    items: []NotificationC,     // slice of NotificationC (C-ABI-compatible)
    string_buf: std.ArrayList(u8), // all string data owned here; items point into it
    allocator: std.mem.Allocator,
};
```

**Key constraints:**
- `token` in `Account` is NEVER written to `db`. Add a comptime assertion in `store.zig`.
- `RuntimeCallbacks` extern struct stays in `c_api.zig` (it is the C ABI surface). Import it here or keep it there — do not duplicate.

---

### `src/http.zig` (utility, request-response)

**Analog:** `src/c_api.zig` lines 1–10 (import conventions, std usage)

**Import pattern** (copy from `src/c_api.zig` lines 1–11):
```zig
const std = @import("std");
// No third-party imports in http.zig — stdlib only.
```

**Core pattern** (from RESEARCH.md Pattern 2 — lower-level Request API preferred for header access):
```zig
pub const HttpClient = struct {
    client: std.http.Client,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return .{ .client = .{ .allocator = allocator }, .allocator = allocator };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    pub const Response = struct {
        status: std.http.Status,
        body: std.ArrayList(u8),
        last_modified: ?[]const u8,   // heap-owned copy or null
        poll_interval_secs: ?u32,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Response) void {
            self.body.deinit();
            if (self.last_modified) |lm| self.allocator.free(lm);
        }
    };

    // Uses lower-level open/send/wait to access response headers.
    // RESEARCH.md Pitfall 2: fetch() may not expose headers in FetchResult.
    pub fn get(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !Response {
        const uri = try std.Uri.parse(url);
        var req = try self.client.open(.GET, uri, .{ .extra_headers = extra_headers });
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();

        var body = std.ArrayList(u8).init(self.allocator);
        try req.reader().readAllArrayList(&body, 10 * 1024 * 1024); // 10 MB cap

        const lm_raw = req.response.headers.getFirstValue("Last-Modified");
        const last_modified = if (lm_raw) |v| try self.allocator.dupe(u8, v) else null;

        const pi_raw = req.response.headers.getFirstValue("X-Poll-Interval");
        const poll_interval: ?u32 = if (pi_raw) |v| std.fmt.parseInt(u32, v, 10) catch null else null;

        return Response{
            .status = req.response.status,
            .body = body,
            .last_modified = last_modified,
            .poll_interval_secs = poll_interval,
            .allocator = self.allocator,
        };
    }

    pub fn patch(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !std.http.Status {
        const uri = try std.Uri.parse(url);
        var req = try self.client.open(.PATCH, uri, .{ .extra_headers = extra_headers });
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();
        return req.response.status;
    }
};
```

**Note:** One `HttpClient` is created per `AccountState` (not shared globally). See RESEARCH.md Pattern 2 and Anti-Pattern "One client shared globally".

**Error handling pattern** (Zig error union — same style as `src/c_api.zig` error returns):
```zig
// Callers use try / catch pattern:
const resp = self.http_client.get(url, &headers) catch |err| {
    std.log.err("http get failed: {}", .{err});
    return err;
};
defer resp.deinit();
```

---

### `src/github.zig` (service, request-response)

**Analog:** `src/c_api.zig` lines 14–41 (extern struct layout, Zig module conventions)

**Import pattern:**
```zig
const std = @import("std");
const types = @import("types.zig");
const http = @import("http.zig");
```

**Core pattern — JSON parsing** (from RESEARCH.md "GitHub API: Parse Notification JSON"):
```zig
// Internal parse-only struct — never stored in DB or returned to shell.
const NotificationJson = struct {
    id: []const u8,
    unread: bool,
    reason: []const u8,
    updated_at: []const u8,
    subject: struct {
        title: []const u8,
        url: []const u8,
        type: []const u8,
    },
    repository: struct {
        full_name: []const u8,
    },
};

pub fn parseNotifications(
    allocator: std.mem.Allocator,
    body: []const u8,
) ![]types.Notification {
    const parsed = try std.json.parseFromSlice(
        []NotificationJson,
        allocator,
        body,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    // Map to types.Notification ...
}
```

**Core pattern — reason mapping** (from RESEARCH.md "GitHub API: Reason → NotifType Mapping"):
```zig
fn reasonToNotifType(reason: []const u8) types.NotifType {
    if (std.mem.eql(u8, reason, "review_requested")) return .pr_review;
    if (std.mem.eql(u8, reason, "comment"))          return .pr_comment;
    if (std.mem.eql(u8, reason, "mention"))          return .issue_mention;
    if (std.mem.eql(u8, reason, "team_mention"))     return .issue_mention;
    if (std.mem.eql(u8, reason, "assign"))           return .issue_assigned;
    if (std.mem.eql(u8, reason, "ci_activity"))      return .ci_failed;
    // author, manual, subscribed, state_change, invitation,
    // security_alert, approval_requested, member_feature_requested,
    // security_advisory_credit → .other
    return .other;
}
```

**Core pattern — API URL to web URL** (from RESEARCH.md Pitfall 3):
```zig
// RESEARCH.md Pitfall 3: subject.url is an API URL, not a web URL.
// "https://api.github.com/repos/owner/repo/pulls/123"
//  → "https://github.com/owner/repo/pull/123"
pub fn apiUrlToWebUrl(allocator: std.mem.Allocator, api_url: []const u8) ![]u8 {
    // Replace prefix
    const api_prefix = "https://api.github.com/repos/";
    const web_prefix = "https://github.com/";
    if (!std.mem.startsWith(u8, api_url, api_prefix)) {
        return allocator.dupe(u8, api_url); // fallback: return as-is
    }
    const rest = api_url[api_prefix.len..];
    // /pulls/ → /pull/
    const rest_fixed = try std.mem.replaceOwned(u8, allocator, rest, "/pulls/", "/pull/");
    defer allocator.free(rest_fixed);
    return std.mem.concat(allocator, u8, &.{ web_prefix, rest_fixed });
}
```

**Headers pattern** (from RESEARCH.md Pattern 2 and GitHub API docs):
```zig
pub fn buildAuthHeaders(
    allocator: std.mem.Allocator,
    token: []const u8,
    last_modified: ?[]const u8,
) ![]std.http.Header {
    var headers = std.ArrayList(std.http.Header).init(allocator);
    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    try headers.append(.{ .name = "Authorization", .value = bearer });
    try headers.append(.{ .name = "Accept", .value = "application/vnd.github+json" });
    try headers.append(.{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" });
    if (last_modified) |lm| {
        try headers.append(.{ .name = "If-Modified-Since", .value = lm });
    }
    return headers.toOwnedSlice();
}
```

**Anti-pattern note:** Default URL is `https://api.github.com/notifications?participating=true` — NOT bare `/notifications`. See RESEARCH.md Anti-Patterns (Pitfall 14 in PITFALLS.md).

---

### `src/poller.zig` (service, event-driven)

**Analog:** `src/c_api.zig` lines 44–68 (handle pointer dereference pattern, lifecycle pattern)

**Handle pointer dereference pattern** (copy from `src/c_api.zig` lines 54–58):
```zig
// Pattern used throughout c_api.zig for safe handle cast:
const handle: *types.TowncrierHandle = @ptrCast(@alignCast(ptr));
```

**Import pattern:**
```zig
const std = @import("std");
const types = @import("types.zig");
const github = @import("github.zig");
const store = @import("store.zig");
const http = @import("http.zig");
```

**Core pattern — poll thread with interruptible sleep** (from RESEARCH.md Pattern 1):
```zig
pub const PollContext = struct {
    account_state: *types.AccountState,
    handle: *types.TowncrierHandle,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_cond: std.Thread.Condition = .{},
    stop_mutex: std.Thread.Mutex = .{},
    // One HTTP client per account — no cross-thread sharing.
    http_client: http.HttpClient,
};

pub fn pollThread(ctx: *PollContext) void {
    while (!ctx.stop_flag.load(.acquire)) {
        // 1. Drain action queue filtered by account_id
        drainActionQueue(ctx) catch |err| {
            std.log.err("action queue drain failed: {}", .{err});
        };
        // 2. Fetch notifications (304 → skip upsert)
        poll(ctx) catch |err| {
            std.log.err("poll failed: {}", .{err});
            // On 401: signal on_error and set stop_flag
        };
        // 3. Rebuild snapshot, fire callbacks
        buildSnapshot(ctx) catch |err| {
            std.log.err("snapshot build failed: {}", .{err});
        };

        // Interruptible sleep — wakes early on towncrier_stop
        ctx.stop_mutex.lock();
        defer ctx.stop_mutex.unlock();
        // timedWait returns error.Timeout on normal expiry — ignore it
        ctx.stop_cond.timedWait(
            &ctx.stop_mutex,
            @as(u64, ctx.account_state.account.poll_interval_secs) * std.time.ns_per_s,
        ) catch {};
    }
}

pub fn stopPollThread(ctx: *PollContext) void {
    ctx.stop_flag.store(true, .release);
    ctx.stop_mutex.lock();
    ctx.stop_cond.signal();
    ctx.stop_mutex.unlock();
    if (ctx.account_state.thread) |t| t.join();
}
```

**Snapshot build pattern** (from RESEARCH.md data flow diagram — lock only during final swap):
```zig
fn buildSnapshot(ctx: *PollContext) !void {
    // Parse + allocate OUTSIDE the lock
    const new_snap = try buildSnapshotData(ctx);

    // Lock only during pointer swap — microseconds, not milliseconds
    ctx.handle.snapshot_lock.lock();
    defer ctx.handle.snapshot_lock.unlock();

    // Free old snapshot if present
    if (ctx.handle.snapshot) |old| {
        old.string_buf.deinit();
        ctx.handle.allocator.free(old.items);
        ctx.handle.allocator.destroy(old);
    }
    ctx.handle.snapshot = new_snap;

    // Also update notif_account_map under same lock
    // ... update map entries ...
}
```

**Callback invocation pattern** (from `include/towncrier.h` lines 73–85 — fire-and-forget, no snapshot data in payload):
```zig
// NEVER pass snapshot data through callbacks — shell calls towncrier_snapshot_get after marshaling.
if (ctx.handle.callbacks.on_update) |cb| {
    cb(ctx.handle.callbacks.userdata, unread_count);
}
if (ctx.handle.callbacks.wakeup) |cb| {
    cb(ctx.handle.callbacks.userdata);
}
```

---

### `src/store.zig` (service, CRUD)

**Analog:** `src/c_api.zig` lines 48–51 (allocator pattern, error union return)

**Import pattern:**
```zig
const std = @import("std");
const sqlite = @import("sqlite");
const types = @import("types.zig");
```

**Core pattern — DB init + pragmas + migration** (from RESEARCH.md Pattern 3):
```zig
pub fn open(db_path: []const u8) !sqlite.Db {
    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = db_path },
        .open_flags = .{ .write = true, .create = true },
        .threading_mode = .MultiThread,
    });
    try db.exec("PRAGMA journal_mode=WAL", .{}, .{});
    try db.exec("PRAGMA synchronous=NORMAL", .{}, .{});
    try migrate(&db);
    return db;
}
```

**Schema migration pattern** (from RESEARCH.md "SQLite Schema Migration"):
```zig
pub fn migrate(db: *sqlite.Db) !void {
    // schema_version table may not exist yet — handle that case
    var version: i64 = 0;
    // ... read version, apply schema_v1 if needed ...
}

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
```

**Upsert pattern** (from RESEARCH.md Pattern 3 — preserve is_read=1):
```zig
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
        .{ notif.id, notif.account_id, notif.api_id, @intFromEnum(notif.service),
           @intFromEnum(notif.notif_type), notif.repo, notif.title, notif.url,
           notif.updated_at, @intFromBool(notif.is_read) },
    );
}
```

**Security assertion pattern** (RESEARCH.md Security domain — token never written to DB):
```zig
// Comptime guard: ensure Account.token is not a field being persisted
// Runtime assertion in tests: grep DB file for "ghp_" / "github_pat_" prefixes
```

**Anti-pattern — don't cache last_modified from DB on every poll** (RESEARCH.md Anti-Patterns):
Cache `last_modified` in `Account.last_modified` (in-memory). Use DB only for persistence across restarts (read once on `open`/`add_account`, write on each successful 200 response).

---

### `src/c_api.zig` (controller, request-response — replace stub bodies)

**Analog:** `src/c_api.zig` (existing file, lines 1–123) — this IS the file. Replace stub bodies only. No signature changes.

**Existing patterns to preserve:**

Import and extern struct pattern (lines 1–41 — keep exactly):
```zig
const std = @import("std");
const types = @import("types.zig");
// Add in Phase 2:
const poller = @import("poller.zig");
const store = @import("store.zig");
```

Handle initialization pattern (lines 45–52 — extend, keep allocator):
```zig
export fn towncrier_init(rt: ?*const RuntimeCallbacks) callconv(.c) ?*anyopaque {
    if (rt == null) return null;
    const handle = std.heap.c_allocator.create(types.TowncrierHandle) catch return null;
    handle.* = .{
        .callbacks = rt.?.*,  // copy by value — rt pointer need not outlive this call
        .accounts = std.ArrayList(types.AccountState).init(std.heap.c_allocator),
        .action_queue = std.ArrayList(types.Action).init(std.heap.c_allocator),
        .notif_account_map = std.AutoHashMap(u64, u32).init(std.heap.c_allocator),
    };
    // Open SQLite DB
    const db_path = getDbPath(std.heap.c_allocator) catch return null;
    defer std.heap.c_allocator.free(db_path);
    handle.db = store.open(db_path) catch return null;
    return handle;
}
```

Handle free pattern (lines 54–59 — extend to stop threads first):
```zig
export fn towncrier_free(tc: ?*anyopaque) callconv(.c) void {
    if (tc) |ptr| {
        const handle: *types.TowncrierHandle = @ptrCast(@alignCast(ptr));
        // Must stop poll threads before destroying handle (RESEARCH.md Pitfall 6)
        towncrier_stop(ptr);
        // ... deinit accounts, action_queue, snapshot, db ...
        std.heap.c_allocator.destroy(handle);
    }
}
```

Null guard pattern — every export fn uses this (lines 45–68):
```zig
// Pattern: every export fn that takes tc checks for null before casting
const handle: *types.TowncrierHandle = @ptrCast(@alignCast(tc orelse return 0));
```

---

### `build.zig` (config — extend with test-poll step)

**Analog:** `build.zig` lines 33–47 (existing test-c step — exact pattern to copy)

**Pattern to copy** (lines 33–47 of `build.zig`):
```zig
// Existing test-c step — copy this pattern for test-poll:
const c_test_mod = b.createModule(.{
    .target = target,
    .optimize = optimize,
});
c_test_mod.addCSourceFile(.{ .file = b.path("tests/c_abi_test.c"), .flags = &.{"-std=c11"} });
c_test_mod.addIncludePath(b.path("include"));
c_test_mod.linkLibrary(lib);

const c_test = b.addExecutable(.{
    .name = "c_abi_test",
    .root_module = c_test_mod,
});

const run_c_test = b.addRunArtifact(c_test);
const test_c_step = b.step("test-c", "Run C ABI integration test");
test_c_step.dependOn(&run_c_test.step);
```

**New test-poll step pattern** (adapts above for a Zig test binary):
```zig
// Add zig-sqlite dependency (fetch hash captured in build.zig.zon)
const sqlite_dep = b.dependency("sqlite", .{ .target = target, .optimize = optimize });

// Add sqlite to lib_mod (core library needs it)
lib_mod.addImport("sqlite", sqlite_dep.module("sqlite"));

// Poll test binary
const poll_test_mod = b.createModule(.{
    .root_source_file = b.path("tests/core/poll_test.zig"),
    .target = target,
    .optimize = optimize,
});
poll_test_mod.addImport("sqlite", sqlite_dep.module("sqlite"));
poll_test_mod.link_libc = true;

const poll_test = b.addExecutable(.{
    .name = "poll_test",
    .root_module = poll_test_mod,
});
poll_test.linkLibrary(lib);

const run_poll_test = b.addRunArtifact(poll_test);
const test_poll_step = b.step("test-poll", "Run poll engine integration test");
test_poll_step.dependOn(&run_poll_test.step);
```

**build.zig.zon change pattern** (from RESEARCH.md Pitfall 1 — pin by hash, not branch):
```zig
// After `zig fetch --save git+https://github.com/vrischmann/zig-sqlite#<sha>`
// build.zig.zon .dependencies gets:
.sqlite = .{
    .url = "git+https://github.com/vrischmann/zig-sqlite#<pinned-sha>",
    .hash = "<content-hash>",
},
```

---

### `tests/core/poll_test.zig` (test, event-driven)

**Analog:** `tests/c_abi_test.c` lines 1–94 — same test lifecycle pattern, different language

**Test lifecycle pattern** (from `tests/c_abi_test.c` lines 35–93 — map to Zig):
```zig
// c_abi_test.c structure translated to Zig test binary:
// 1. Initialize handle with callbacks
// 2. Add accounts
// 3. Start poll engine
// 4. Wait for mock server to receive requests / callbacks to fire
// 5. Assert snapshot state
// 6. Mark read / assert next snapshot
// 7. Stop engine
// 8. Free handle
pub fn main() !void {
    const allocator = std.heap.c_allocator; // matches library allocator
    // ... test setup ...
}
```

**Mock server pattern** (from RESEARCH.md Pattern 4):
```zig
// Zig 0.14 std.http.Server — bind to port 0 for OS-assigned ephemeral port
const MockServer = struct {
    server: std.net.Server,
    // Per-token state for stateful 304 simulation (D-04)
    state: std.StringHashMap([]const u8), // token → last_modified_sent
    mutex: std.Thread.Mutex = .{},
    thread: std.Thread = undefined,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !MockServer {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        const server = try addr.listen(.{ .reuse_address = true });
        return MockServer{
            .server = server,
            .state = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn port(self: *MockServer) u16 {
        return self.server.listen_address.getPort();
        // RESEARCH.md Assumption A2: verify getPort() exists in 0.14
    }
};
// Mock response logic:
// GET /notifications + If-Modified-Since matching stored → 304 + no body
// GET /notifications + different/absent If-Modified-Since → 200 + fixture JSON
//   + Last-Modified: <timestamp> + X-Poll-Interval: 60
// PATCH /notifications/threads/:id → 205 Reset Content
```

**Assertion pattern** (from `tests/c_abi_test.c` lines 45–91 — C assert → Zig std.testing):
```zig
// c_abi_test.c uses: assert(condition && "message")
// poll_test.zig uses: try std.testing.expect(condition)
//   or: try std.testing.expectEqual(expected, actual)
```

**Note:** Do NOT use Zig 0.16 APIs from `main.zig` (`std.Io`, `std.process.Init`). Use standard 0.14 entry point:
```zig
pub fn main() !void {
    // std.heap.c_allocator or std.testing.allocator as appropriate
}
```

---

## Shared Patterns

### Handle Null Guard
**Source:** `src/c_api.zig` lines 45–58 (all export functions)
**Apply to:** All export functions in `src/c_api.zig` (Phase 2 replacement bodies)
```zig
// Every export fn uses this pattern before accessing handle fields:
if (tc == null) return 0; // or return null / return void as appropriate
const handle: *types.TowncrierHandle = @ptrCast(@alignCast(tc.?));
```

### Allocator Convention
**Source:** `src/c_api.zig` line 49 — `std.heap.c_allocator`
**Apply to:** `src/c_api.zig` (top-level handle allocation), `src/types.zig` (TowncrierHandle.allocator default), all ArrayList inits on handle
```zig
// All handle-lifetime allocations use std.heap.c_allocator.
// Per-request / per-poll-cycle allocations use std.heap.ArenaAllocator
// (reset after each cycle — avoids fragmentation).
const handle = std.heap.c_allocator.create(types.TowncrierHandle) catch return null;
```

### Error Union Return
**Source:** `src/c_api.zig` lines 61–79 (export fn returning c_int)
**Apply to:** All internal functions in `src/http.zig`, `src/github.zig`, `src/poller.zig`, `src/store.zig`
```zig
// Export fns return c_int (0 = success, non-zero = failure) for the C ABI.
// Internal Zig functions use error unions: fn foo() !void
// The c_api.zig boundary converts: catch return 1 (or appropriate error code)
export fn towncrier_add_account(...) callconv(.c) c_int {
    internalAddAccount(handle, acct) catch return 1;
    return 0;
}
```

### Callback Invocation (fire-and-forget)
**Source:** `include/towncrier.h` lines 73–85 (ownership docs)
**Apply to:** `src/poller.zig` — all callback invocations
```zig
// Callbacks are fire-and-forget. No towncrier_* functions called inside.
// Check for null before calling (optional function pointers in extern struct).
if (handle.callbacks.on_update) |cb| {
    cb(handle.callbacks.userdata, unread_count);
}
```

### Module Header Comment
**Source:** `src/c_api.zig` lines 1–9, `src/types.zig` lines 1–2, `src/root.zig` lines 1–6
**Apply to:** All new source files (`src/http.zig`, `src/github.zig`, `src/poller.zig`, `src/store.zig`)
```zig
//! http.zig — std.http.Client wrapper for libtowncrier.
//! One HttpClient instance is created per account; never shared across threads.
```

---

## No Analog Found

Files with no close in-codebase match (planner references RESEARCH.md patterns instead):

| File | Role | Data Flow | Reason |
|---|---|---|---|
| `src/http.zig` | utility | request-response | No HTTP code exists yet; first HTTP wrapper |
| `src/github.zig` | service | request-response | No API client code exists yet |
| `src/poller.zig` | service | event-driven | No threading code exists yet |
| `src/store.zig` | service | CRUD | No SQLite code exists yet; first DB layer |
| `tests/core/poll_test.zig` | test | event-driven | Only existing test is C (`c_abi_test.c`); no Zig test binary yet |

For all five files, RESEARCH.md Code Examples and Architecture Patterns sections are the authoritative pattern source.

---

## Metadata

**Analog search scope:** `/home/richard/code/towncrier/src/`, `/home/richard/code/towncrier/tests/`, `/home/richard/code/towncrier/build.zig`
**Files scanned:** 6 Zig source files + 1 C test file + 2 build files + 1 C header
**Key finding:** Project is early-stage (Phase 1 only). All 5 new source files have no in-codebase structural analog. Pattern extraction relies on RESEARCH.md for implementation patterns and Phase 1 files for project-wide conventions (allocator choice, module header style, extern struct layout, error return codes, null guards).
**Pattern extraction date:** 2026-04-17
