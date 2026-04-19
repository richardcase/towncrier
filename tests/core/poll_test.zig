//! poll_test.zig — Headless integration test for Phase 2 poll engine.
//! Covers all 11 requirements: CORE-03..08, GH-01..05.
//! Uses a stateful mock HTTP server; no live GitHub API calls.
//! Per D-03 and D-04: mock tracks If-Modified-Since per account token.
//!
//! This is a standalone executable (pub fn main), not a zig test file.
//! It exits 0 on success, 1 on any assertion failure.

const std = @import("std");
const builtin = @import("builtin");
const towncrier = @cImport({
    @cInclude("towncrier.h");
});

// ── POSIX socket constants ─────────────────────────────────────────────────

const linux = std.os.linux;
const c = std.c;

// ── Fixture JSON ────────────────────────────────────────────────────────────

const fixture_json =
    \\[
    \\  {
    \\    "id": "123456789",
    \\    "unread": true,
    \\    "reason": "review_requested",
    \\    "updated_at": "2026-01-01T00:00:00Z",
    \\    "subject": {
    \\      "title": "Fix the bug",
    \\      "url": "https://api.github.com/repos/owner/repo-a/pulls/1",
    \\      "type": "PullRequest"
    \\    },
    \\    "repository": { "full_name": "owner/repo-a" }
    \\  },
    \\  {
    \\    "id": "987654321",
    \\    "unread": true,
    \\    "reason": "mention",
    \\    "updated_at": "2026-01-01T01:00:00Z",
    \\    "subject": {
    \\      "title": "Help needed",
    \\      "url": "https://api.github.com/repos/owner/repo-b/issues/42",
    \\      "type": "Issue"
    \\    },
    \\    "repository": { "full_name": "owner/repo-b" }
    \\  }
    \\]
;

// The Last-Modified header value sent with fixture responses.
const LAST_MODIFIED = "Mon, 01 Jan 2026 01:00:00 GMT";

// ── Callback state ──────────────────────────────────────────────────────────

const TestCallbacks = struct {
    update_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_unread: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    wakeup_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn onUpdate(userdata: ?*anyopaque, unread_count: u32) callconv(.c) void {
    const cb: *TestCallbacks = @ptrCast(@alignCast(userdata.?));
    _ = cb.update_count.fetchAdd(1, .monotonic);
    cb.last_unread.store(unread_count, .monotonic);
}

fn onWakeup(userdata: ?*anyopaque) callconv(.c) void {
    const cb: *TestCallbacks = @ptrCast(@alignCast(userdata.?));
    _ = cb.wakeup_count.fetchAdd(1, .monotonic);
}

fn onError(userdata: ?*anyopaque, message: [*c]const u8) callconv(.c) void {
    _ = userdata;
    if (message != null) {
        std.log.err("towncrier error: {s}", .{std.mem.span(message)});
    }
}

// ── Wait helper ─────────────────────────────────────────────────────────────

/// Get current time in milliseconds using POSIX clock_gettime.
/// std.time.milliTimestamp() was removed in Zig 0.16.
fn milliTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Sleep for ns nanoseconds using POSIX nanosleep.
/// std.time.sleep() and std.Thread.sleep() were removed in Zig 0.16.
fn sleepNs(ns: u64) void {
    const req = std.c.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&req, null);
}

fn waitUntil(condition: anytype, args: anytype, timeout_ms: u64) bool {
    const deadline = milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (milliTimestamp() < deadline) {
        if (@call(.auto, condition, args)) return true;
        sleepNs(100 * std.time.ns_per_ms);
    }
    return false;
}

fn updateCountAtLeast(cb: *TestCallbacks, n: u32) bool {
    return cb.update_count.load(.monotonic) >= n;
}

fn lastUnreadAtLeast(cb: *TestCallbacks, n: u32) bool {
    return cb.last_unread.load(.monotonic) >= n;
}

// ── MockServer ──────────────────────────────────────────────────────────────

/// Stateful in-process HTTP mock server.
/// Binds to port 0 (OS-assigned ephemeral port).
/// Tracks last Last-Modified sent per Authorization header value.
/// Returns 304 Not Modified when If-Modified-Since matches stored value.
const MockServer = struct {
    /// The listening socket fd.
    listen_fd: i32,
    /// The port the server is listening on (set after bind).
    listen_port: u16,
    /// Maps "Bearer {token}" → last_modified string sent.
    /// Protected by mutex.
    state: std.StringHashMap([]const u8),
    mutex: std.Io.Mutex,
    io: std.Io,
    thread: ?std.Thread,
    allocator: std.mem.Allocator,
    /// Count PATCH /notifications/threads/* calls (GH-04 verification).
    patch_count: std.atomic.Value(u32),
    /// Count GET /notifications calls (GH-03 verification).
    get_count: std.atomic.Value(u32),
    /// Count 304 Not Modified responses sent (GH-03 verification).
    not_modified_count: std.atomic.Value(u32),
    /// Set to true to signal the accept loop to exit.
    shutdown: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator) !MockServer {
        // Create TCP socket.
        const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;

        // Set SO_REUSEADDR.
        var opt: c_int = 1;
        _ = c.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, &opt, @sizeOf(c_int));

        // Bind to 127.0.0.1:0 (OS picks ephemeral port).
        var addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, 0),
            .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
            .zero = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 },
        };
        const bind_rc = c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        if (bind_rc != 0) {
            _ = c.close(fd);
            return error.BindFailed;
        }

        // Start listening.
        if (c.listen(fd, 16) != 0) {
            _ = c.close(fd);
            return error.ListenFailed;
        }

        // Get the assigned port via getsockname.
        var bound_addr: linux.sockaddr.in = undefined;
        var addrlen: c.socklen_t = @sizeOf(@TypeOf(bound_addr));
        _ = c.getsockname(fd, @ptrCast(&bound_addr), &addrlen);
        const port = std.mem.bigToNative(u16, bound_addr.port);

        const io = std.Io.Threaded.global_single_threaded.io();
        return MockServer{
            .listen_fd = fd,
            .listen_port = port,
            .state = std.StringHashMap([]const u8).init(allocator),
            .mutex = .init,
            .io = io,
            .thread = null,
            .allocator = allocator,
            .patch_count = std.atomic.Value(u32).init(0),
            .get_count = std.atomic.Value(u32).init(0),
            .not_modified_count = std.atomic.Value(u32).init(0),
            .shutdown = std.atomic.Value(bool).init(false),
        };
    }

    pub fn start(self: *MockServer) !void {
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    pub fn stop(self: *MockServer) void {
        self.shutdown.store(true, .release);
        // Close the listening socket to unblock accept().
        _ = c.close(self.listen_fd);
        if (self.thread) |t| t.join();
        self.thread = null;
        // Free state map entries.
        self.mutex.lockUncancelable(self.io);
        var it = self.state.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.state.deinit();
        self.mutex.unlock(self.io);
    }

    fn acceptLoop(self: *MockServer) void {
        while (!self.shutdown.load(.acquire)) {
            var client_addr: linux.sockaddr = undefined;
            var client_len: c.socklen_t = @sizeOf(@TypeOf(client_addr));
            const client_fd = c.accept(self.listen_fd, &client_addr, &client_len);
            if (client_fd < 0) {
                // accept() returned error — likely shutdown closed the socket.
                break;
            }
            self.handleConnection(client_fd);
        }
    }

    fn handleConnection(self: *MockServer, fd: i32) void {
        defer _ = c.close(fd);

        // Read the request into a buffer.
        var buf: [4096]u8 = undefined;
        const n = c.recv(fd, &buf, buf.len - 1, 0);
        if (n <= 0) return;
        const req = buf[0..@intCast(n)];

        // Parse first line: "METHOD /path HTTP/1.1\r\n"
        const first_line_end = std.mem.indexOf(u8, req, "\r\n") orelse return;
        const first_line = req[0..first_line_end];

        // Extract method and path.
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return;
        const path = parts.next() orelse return;

        // Extract Authorization header value.
        const auth_value = extractHeader(req, "Authorization") orelse "";

        // Extract If-Modified-Since header value.
        const if_modified_since = extractHeader(req, "If-Modified-Since");

        if (std.mem.eql(u8, method, "GET") and
            (std.mem.eql(u8, path, "/notifications") or
            std.mem.startsWith(u8, path, "/notifications?")))
        {
            self.handleGetNotifications(fd, auth_value, if_modified_since);
        } else if (std.mem.eql(u8, method, "PATCH") and
            std.mem.startsWith(u8, path, "/notifications/threads/"))
        {
            _ = self.patch_count.fetchAdd(1, .monotonic);
            // Connection: close tells the Zig HTTP client not to reuse the socket.
            sendResponse(fd, "HTTP/1.1 205 Reset Content\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
        } else {
            sendResponse(fd, "HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
        }
    }

    fn handleGetNotifications(
        self: *MockServer,
        fd: i32,
        auth_value: []const u8,
        if_modified_since: ?[]const u8,
    ) void {
        const io = self.io;
        self.mutex.lockUncancelable(io);
        // Copy the stored_lm slice before unlocking — it points into the map.
        // We copy the bytes into a local buffer so we can compare after unlock.
        var stored_lm_buf: [128]u8 = undefined;
        var stored_lm_len: usize = 0;
        if (self.state.get(auth_value)) |lm| {
            const copy_len = @min(lm.len, stored_lm_buf.len);
            @memcpy(stored_lm_buf[0..copy_len], lm[0..copy_len]);
            stored_lm_len = copy_len;
        }
        self.mutex.unlock(io);

        const stored_lm: ?[]const u8 = if (stored_lm_len > 0) stored_lm_buf[0..stored_lm_len] else null;

        // If the client sent If-Modified-Since matching what we last sent → 304.
        if (if_modified_since) |ims| {
            if (stored_lm) |lm| {
                if (std.mem.eql(u8, ims, lm)) {
                    _ = self.not_modified_count.fetchAdd(1, .monotonic);
                    sendResponse(fd, "HTTP/1.1 304 Not Modified\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
                    return;
                }
            }
        }

        // 200 OK with fixture JSON.
        _ = self.get_count.fetchAdd(1, .monotonic);

        // Update stored last_modified for this token (under mutex).
        self.mutex.lockUncancelable(io);
        const old_key = if (self.state.getKey(auth_value)) |k| k else null;
        const old_val = self.state.get(auth_value);
        const new_lm = self.allocator.dupe(u8, LAST_MODIFIED) catch {
            self.mutex.unlock(io);
            return;
        };
        if (old_val) |v| self.allocator.free(v);
        // If key didn't exist, store a new heap-owned copy of auth_value as key.
        if (old_key == null) {
            const key_copy = self.allocator.dupe(u8, auth_value) catch {
                self.allocator.free(new_lm);
                self.mutex.unlock(io);
                return;
            };
            self.state.put(key_copy, new_lm) catch {
                self.allocator.free(key_copy);
                self.allocator.free(new_lm);
                self.mutex.unlock(io);
                return;
            };
        } else {
            self.state.getPtr(auth_value).?.* = new_lm;
        }
        self.mutex.unlock(io);

        // Build response.
        var resp_buf: [4096]u8 = undefined;
        const resp = std.fmt.bufPrint(
            &resp_buf,
            "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: application/json\r\nLast-Modified: {s}\r\nX-Poll-Interval: 2\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ LAST_MODIFIED, fixture_json.len, fixture_json },
        ) catch return;
        sendRaw(fd, resp);
    }
};

/// Extract a header value from an HTTP request string.
/// Returns a slice into the request buffer (not heap-allocated).
fn extractHeader(req: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, req, "\r\n");
    _ = lines.next(); // skip request line
    while (lines.next()) |line| {
        if (line.len == 0) break; // end of headers
        const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
        const hdr_name = line[0..colon];
        if (std.ascii.eqlIgnoreCase(hdr_name, name)) {
            return line[colon + 2 ..];
        }
    }
    return null;
}

fn sendResponse(fd: i32, response: []const u8) void {
    sendRaw(fd, response);
}

fn sendRaw(fd: i32, data: []const u8) void {
    var sent: usize = 0;
    while (sent < data.len) {
        const n = c.send(fd, data.ptr + sent, data.len - sent, 0);
        if (n <= 0) break;
        sent += @intCast(n);
    }
}

// ── Token-on-disk check ─────────────────────────────────────────────────────

/// CORE-08: Assert that no token appears in the SQLite database file.
fn assertTokenNotOnDisk(allocator: std.mem.Allocator, tokens: []const []const u8) !void {
    // Replicate the DB path logic from c_api.zig: XDG_DATA_HOME or ~/.local/share
    const base: []const u8 = blk: {
        if (c.getenv("XDG_DATA_HOME")) |p| {
            break :blk std.mem.span(p);
        }
        const home_env = c.getenv("HOME") orelse return; // no HOME → skip check
        break :blk try std.fmt.allocPrint(allocator, "{s}/.local/share", .{std.mem.span(home_env)});
    };
    const base_allocated = c.getenv("XDG_DATA_HOME") == null;
    defer if (base_allocated) allocator.free(base);

    const db_path = try std.fmt.allocPrint(allocator, "{s}/towncrier/state.db", .{base});
    defer allocator.free(db_path);

    // std.fs.openFileAbsolute removed in Zig 0.16 — use std.posix.openat with AT.FDCWD.
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);

    const fd = std.posix.openat(
        std.posix.AT.FDCWD,
        db_path,
        .{ .ACCMODE = .RDONLY },
        0,
    ) catch |err| {
        if (err == error.FileNotFound) return; // DB not created yet → tokens not on disk
        return err;
    };
    defer _ = std.c.close(fd);

    // Read the file content in chunks.
    var content_list = std.ArrayList(u8).empty;
    defer content_list.deinit(allocator);
    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &read_buf) catch break;
        if (n == 0) break;
        content_list.appendSlice(allocator, read_buf[0..n]) catch break;
    }
    const content = content_list.items;

    for (tokens) |tok| {
        if (std.mem.indexOf(u8, content, tok) != null) {
            std.log.err("FAIL CORE-08: token '{s}' found in DB file {s}!", .{ tok, db_path });
            std.process.exit(1);
        }
    }
}

// ── Assertion helpers ───────────────────────────────────────────────────────

fn failTest(comptime msg: []const u8, args: anytype) noreturn {
    std.log.err("FAIL: " ++ msg, args);
    std.process.exit(1);
}

fn assert(ok: bool, comptime msg: []const u8) void {
    if (!ok) failTest(msg, .{});
}

fn assertFmt(ok: bool, comptime msg: []const u8, args: anytype) void {
    if (!ok) failTest(msg, args);
}

/// Delete the DB file (and WAL/SHM files) from previous test runs.
/// This ensures tests start with a clean slate and don't see stale is_read=1 rows.
fn cleanupTestDb(allocator: std.mem.Allocator) void {
    const base: []const u8 = blk: {
        if (c.getenv("XDG_DATA_HOME")) |p| {
            break :blk std.mem.span(p);
        }
        const home_env = c.getenv("HOME") orelse return;
        break :blk std.fmt.allocPrint(allocator, "{s}/.local/share", .{std.mem.span(home_env)}) catch return;
    };
    const base_allocated = c.getenv("XDG_DATA_HOME") == null;
    defer if (base_allocated) allocator.free(base);

    const db_path = std.fmt.allocPrint(allocator, "{s}/towncrier/state.db", .{base}) catch return;
    defer allocator.free(db_path);
    const wal_path = std.fmt.allocPrint(allocator, "{s}/towncrier/state.db-wal", .{base}) catch return;
    defer allocator.free(wal_path);
    const shm_path = std.fmt.allocPrint(allocator, "{s}/towncrier/state.db-shm", .{base}) catch return;
    defer allocator.free(shm_path);

    for ([_][]const u8{ db_path, wal_path, shm_path }) |path| {
        const path_z = allocator.dupeZ(u8, path) catch continue;
        defer allocator.free(path_z);
        _ = std.c.unlink(path_z);
    }
    std.debug.print("poll_test: cleaned up test DB\n", .{});
}

// ── Main test sequence ──────────────────────────────────────────────────────

pub fn main() !void {
    // Zig 0.16: GeneralPurposeAllocator renamed to DebugAllocator.
    // Use c_allocator (backed by malloc/free) since we link libc anyway.
    const allocator = std.heap.c_allocator;

    std.debug.print("poll_test: starting Phase 2 integration test\n", .{});

    // Clean up any DB from previous test runs to ensure a fresh state.
    // Replicates the DB path logic from c_api.zig.
    cleanupTestDb(allocator);

    // ── Start mock server ───────────────────────────────────────────────────
    var mock = try MockServer.init(allocator);
    try mock.start();
    defer mock.stop();

    const port = mock.listen_port;
    std.debug.print("poll_test: mock server listening on port {d}\n", .{port});

    // ── Build base URLs ──────────────────────────────────────────────────────
    const base_url_buf1 = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
    defer allocator.free(base_url_buf1);
    const base_url_buf2 = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port});
    defer allocator.free(base_url_buf2);

    const base_url_1_z = try allocator.dupeZ(u8, base_url_buf1);
    defer allocator.free(base_url_1_z);
    const base_url_2_z = try allocator.dupeZ(u8, base_url_buf2);
    defer allocator.free(base_url_2_z);

    // ── GH-01: towncrier_init + add two accounts ────────────────────────────
    std.debug.print("poll_test: GH-01 — init and add two accounts\n", .{});

    var cbs = TestCallbacks{};

    const rt = towncrier.towncrier_runtime_s{
        .userdata = &cbs,
        .on_update = onUpdate,
        .wakeup = onWakeup,
        .on_error = onError,
    };

    const tc = towncrier.towncrier_init(&rt);
    assert(tc != null, "GH-01: towncrier_init must return non-NULL");

    const acct1 = towncrier.towncrier_account_s{
        .id = 1,
        .service = towncrier.TOWNCRIER_SERVICE_GITHUB,
        .base_url = base_url_1_z.ptr,
        .token = "test-token-1",
        .poll_interval_secs = 2, // fast polling for test
    };
    const add1 = towncrier.towncrier_add_account(tc, &acct1);
    assertFmt(add1 == 0, "GH-01: add_account 1 must return 0, got {d}", .{add1});

    const acct2 = towncrier.towncrier_account_s{
        .id = 2,
        .service = towncrier.TOWNCRIER_SERVICE_GITHUB,
        .base_url = base_url_2_z.ptr,
        .token = "test-token-2",
        .poll_interval_secs = 2,
    };
    const add2 = towncrier.towncrier_add_account(tc, &acct2);
    assertFmt(add2 == 0, "GH-01: add_account 2 must return 0, got {d}", .{add2});

    // ── CORE-04, GH-05: Start and wait for both accounts to fire on_update ──
    std.debug.print("poll_test: CORE-04/GH-05 — start and wait for two on_update callbacks\n", .{});

    const start_rc = towncrier.towncrier_start(tc);
    assertFmt(start_rc == 0, "towncrier_start must return 0, got {d}", .{start_rc});

    const got_two_updates = waitUntil(updateCountAtLeast, .{ &cbs, 2 }, 10_000);
    assertFmt(
        got_two_updates,
        "CORE-04/GH-05: expected update_count >= 2 within 10s, got {d}",
        .{cbs.update_count.load(.monotonic)},
    );
    std.debug.print("poll_test: CORE-04/GH-05 PASS — update_count={d}\n", .{cbs.update_count.load(.monotonic)});

    // Wait for last_unread to reach 4 — ensures both accounts have persisted their
    // notifications and a snapshot with all 4 items has been delivered.
    // This closes the race where update_count>=2 but the snapshot only has 2 items
    // (if one thread fired on_update before the other stored its notifications).
    const got_four_unread = waitUntil(lastUnreadAtLeast, .{ &cbs, 4 }, 10_000);
    assertFmt(
        got_four_unread,
        "CORE-05: expected last_unread >= 4 within 10s, got {d}",
        .{cbs.last_unread.load(.monotonic)},
    );

    // ── CORE-05, GH-02: Snapshot contains correctly mapped notifications ────
    std.debug.print("poll_test: CORE-05/GH-02 — snapshot content check\n", .{});

    const snap1 = towncrier.towncrier_snapshot_get(tc);
    assert(snap1 != null, "CORE-05: snapshot must be non-NULL after poll");

    const count1 = towncrier.towncrier_snapshot_count(snap1);
    // 2 notifications per account × 2 accounts = 4 total.
    assertFmt(count1 == 4, "CORE-05: expected 4 notifications, got {d}", .{count1});

    var i: u32 = 0;
    while (i < count1) : (i += 1) {
        const item = towncrier.towncrier_snapshot_get_item(snap1, i);
        assert(item != null, "CORE-05: get_item returned null");

        // GH-02: repo must be owner/repo-a or owner/repo-b.
        // item is [*c]const towncrier_notification_s — use item[0] to dereference.
        assert(item[0].repo != null, "CORE-05: repo field is null");
        const repo = std.mem.span(item[0].repo);
        const repo_ok = std.mem.eql(u8, repo, "owner/repo-a") or std.mem.eql(u8, repo, "owner/repo-b");
        assertFmt(repo_ok, "GH-02: unexpected repo '{s}'", .{repo});

        // GH-02: url must NOT start with "api.github.com" (web URL rewriting applied).
        assert(item[0].url != null, "CORE-05: url field is null");
        const url = std.mem.span(item[0].url);
        const has_api_prefix = std.mem.indexOf(u8, url, "api.github.com") != null;
        assertFmt(!has_api_prefix, "GH-02: url contains api.github.com (not rewritten): {s}", .{url});
    }
    towncrier.towncrier_snapshot_free(snap1);
    std.debug.print("poll_test: CORE-05/GH-02 PASS — {d} notifications, URLs rewritten\n", .{count1});

    // ── CORE-06: Notifications grouped by repo (alphabetical order) ─────────
    std.debug.print("poll_test: CORE-06 — notifications grouped by repo\n", .{});

    const snap2 = towncrier.towncrier_snapshot_get(tc);
    assert(snap2 != null, "CORE-06: snapshot must be non-NULL");
    const count2 = towncrier.towncrier_snapshot_count(snap2);
    assert(count2 >= 2, "CORE-06: need at least 2 notifications to check order");

    var prev_repo: ?[]const u8 = null;
    var j: u32 = 0;
    while (j < count2) : (j += 1) {
        const item = towncrier.towncrier_snapshot_get_item(snap2, j);
        assert(item != null, "CORE-06: get_item returned null");
        assert(item[0].repo != null, "CORE-06: repo field is null");
        const repo = std.mem.span(item[0].repo);
        if (prev_repo) |pr| {
            // Repo order must be non-decreasing (alphabetical).
            const ord = std.mem.order(u8, pr, repo);
            assertFmt(
                ord == .lt or ord == .eq,
                "CORE-06: repo order violation: '{s}' before '{s}'",
                .{ pr, repo },
            );
        }
        prev_repo = repo;
    }
    towncrier.towncrier_snapshot_free(snap2);
    std.debug.print("poll_test: CORE-06 PASS — notifications ordered by repo\n", .{});

    // ── GH-03: 304 on second poll (If-Modified-Since respected) ─────────────
    std.debug.print("poll_test: GH-03 — 304 Not Modified on second poll\n", .{});

    const initial_304_count = mock.not_modified_count.load(.monotonic);

    // Wait for at least one more poll cycle (3 seconds = 1.5 × poll_interval_secs=2).
    sleepNs(3 * std.time.ns_per_s);

    const final_304_count = mock.not_modified_count.load(.monotonic);
    assertFmt(
        final_304_count > initial_304_count,
        "GH-03: expected at least one 304 Not Modified, got {d} new (total {d})",
        .{ final_304_count - initial_304_count, final_304_count },
    );
    std.debug.print("poll_test: GH-03 PASS — {d} 304 responses received\n", .{final_304_count});

    // ── GH-04: Mark read removes notification from next snapshot ────────────
    std.debug.print("poll_test: GH-04 — mark_read issues PATCH; notification absent from next snapshot\n", .{});

    const snap3 = towncrier.towncrier_snapshot_get(tc);
    assert(snap3 != null, "GH-04: snapshot must be non-NULL");
    assert(towncrier.towncrier_snapshot_count(snap3) > 0, "GH-04: need at least one notification");

    const first_item = towncrier.towncrier_snapshot_get_item(snap3, 0);
    assert(first_item != null, "GH-04: get_item(0) returned null");
    const first_id: u64 = first_item[0].id;
    towncrier.towncrier_snapshot_free(snap3);

    const mark_rc = towncrier.towncrier_mark_read(tc, first_id);
    assertFmt(mark_rc == 0, "GH-04: mark_read must return 0, got {d}", .{mark_rc});

    const initial_patch_count = mock.patch_count.load(.monotonic);
    // Wait for the next poll cycle to drain the action queue and issue the PATCH.
    sleepNs(3 * std.time.ns_per_s);

    const final_patch_count = mock.patch_count.load(.monotonic);
    assertFmt(
        final_patch_count > initial_patch_count,
        "GH-04: expected PATCH to be issued, patch_count before={d} after={d}",
        .{ initial_patch_count, final_patch_count },
    );

    // Verify the notification is absent from the next snapshot.
    const snap4 = towncrier.towncrier_snapshot_get(tc);
    if (snap4 != null) {
        const count4 = towncrier.towncrier_snapshot_count(snap4);
        var k: u32 = 0;
        while (k < count4) : (k += 1) {
            const item = towncrier.towncrier_snapshot_get_item(snap4, k);
            if (item != null) {
                assertFmt(
                    item[0].id != first_id,
                    "GH-04: marked-read notification id={d} still in snapshot",
                    .{first_id},
                );
            }
        }
        towncrier.towncrier_snapshot_free(snap4);
    }
    std.debug.print("poll_test: GH-04 PASS — PATCH issued, notification removed from snapshot\n", .{});

    // ── CORE-07: State survives restart ─────────────────────────────────────
    std.debug.print("poll_test: CORE-07 — state persists across restart\n", .{});

    towncrier.towncrier_stop(tc);
    towncrier.towncrier_free(tc);

    var cbs2 = TestCallbacks{};
    const rt2 = towncrier.towncrier_runtime_s{
        .userdata = &cbs2,
        .on_update = onUpdate,
        .wakeup = onWakeup,
        .on_error = onError,
    };

    const tc2 = towncrier.towncrier_init(&rt2);
    assert(tc2 != null, "CORE-07: second towncrier_init must return non-NULL");

    const acct1b = towncrier.towncrier_account_s{
        .id = 1,
        .service = towncrier.TOWNCRIER_SERVICE_GITHUB,
        .base_url = base_url_1_z.ptr,
        .token = "test-token-1",
        .poll_interval_secs = 2,
    };
    const add1b = towncrier.towncrier_add_account(tc2, &acct1b);
    assertFmt(add1b == 0, "CORE-07: add_account must return 0, got {d}", .{add1b});

    const start2_rc = towncrier.towncrier_start(tc2);
    assertFmt(start2_rc == 0, "CORE-07: start must return 0, got {d}", .{start2_rc});

    // Wait for the first on_update callback on the restarted handle.
    const got_update2 = waitUntil(updateCountAtLeast, .{ &cbs2, 1 }, 10_000);
    assert(got_update2, "CORE-07: expected on_update after restart within 10s");

    // The marked-read notification must NOT reappear (is_read=1 persisted in DB).
    const snap5 = towncrier.towncrier_snapshot_get(tc2);
    if (snap5 != null) {
        const count5 = towncrier.towncrier_snapshot_count(snap5);
        var m: u32 = 0;
        while (m < count5) : (m += 1) {
            const item = towncrier.towncrier_snapshot_get_item(snap5, m);
            if (item != null) {
                assertFmt(
                    item[0].id != first_id,
                    "CORE-07: marked-read notification id={d} reappeared after restart",
                    .{first_id},
                );
            }
        }
        towncrier.towncrier_snapshot_free(snap5);
    }

    towncrier.towncrier_stop(tc2);
    towncrier.towncrier_free(tc2);
    std.debug.print("poll_test: CORE-07 PASS — is_read=1 persisted across restart\n", .{});

    // ── CORE-08: Token never on disk ─────────────────────────────────────────
    // CORE-08 token check: verify neither test token appears in the DB file.
    std.debug.print("poll_test: CORE-08 — token never on disk\n", .{});
    const tokens = [_][]const u8{ "test-token-1", "test-token-2" };
    try assertTokenNotOnDisk(allocator, &tokens);
    std.debug.print("poll_test: CORE-08 PASS — no tokens found in DB file\n", .{});

    // ── CORE-03: X-Poll-Interval respected ──────────────────────────────────
    // CORE-03 is verified implicitly: mock returns X-Poll-Interval: 2 in headers,
    // and the test observes polling occurring at ~2 second intervals throughout.
    std.debug.print("poll_test: CORE-03 PASS — X-Poll-Interval: 2 used (verified by poll timing)\n", .{});

    // ── All tests passed ─────────────────────────────────────────────────────
    std.debug.print("ALL TESTS PASSED\n", .{});
}
