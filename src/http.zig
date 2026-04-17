//! http.zig — std.http.Client wrapper for libtowncrier.
//! One HttpClient instance is created per account; never shared across threads.
//! Uses the lower-level request/sendBodiless/receiveHead API (not fetch()) to access response headers.
//!
//! Zig 0.16 API notes:
//! - std.http.Client requires io: std.Io; we use global_single_threaded.io().
//! - std.ArrayList is now unmanaged (no embedded allocator); pass allocator to deinit/append.

const std = @import("std");

/// HTTP response wrapper. Caller owns memory; call deinit() when done.
pub const Response = struct {
    status: std.http.Status,
    /// Body bytes. Caller must call deinit() to free.
    body: std.ArrayList(u8),
    /// Heap-owned copy of Last-Modified header value, or null.
    last_modified: ?[]const u8,
    /// Parsed X-Poll-Interval header value, or null.
    poll_interval_secs: ?u32,
    /// Allocator used for all owned memory in this response.
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.body.deinit(self.allocator);
        if (self.last_modified) |lm| self.allocator.free(lm);
    }
};

/// HTTP client wrapper. One per account; do not share across threads.
pub const HttpClient = struct {
    client: std.http.Client,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        const io = std.Io.Threaded.global_single_threaded.io();
        return .{
            .client = .{ .allocator = allocator, .io = io },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    /// Issues a GET request and returns a Response with body and extracted headers.
    /// Caller must call Response.deinit().
    pub fn get(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !Response {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.GET, uri, .{
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        try req.sendBodiless();

        // Buffer for redirect URI rewriting (8 KB as recommended by RFC 9110).
        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        // Extract Last-Modified and X-Poll-Interval from raw header bytes.
        var last_modified: ?[]const u8 = null;
        var poll_interval_secs: ?u32 = null;
        var header_it = std.http.HeaderIterator.init(response.head.bytes);
        while (header_it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "last-modified")) {
                last_modified = try self.allocator.dupe(u8, header.value);
            } else if (std.ascii.eqlIgnoreCase(header.name, "x-poll-interval")) {
                poll_interval_secs = std.fmt.parseInt(u32, header.value, 10) catch null;
            }
        }
        errdefer if (last_modified) |lm| self.allocator.free(lm);

        // Read response body (10 MB cap — T-02-08 DoS mitigation).
        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(self.allocator);

        // transfer_buffer is required by response.reader() in Zig 0.16.
        var transfer_buf: [8192]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        reader.appendRemaining(self.allocator, &body, .limited(10 * 1024 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => return error.ResponseTooLarge,
            else => return err,
        };

        return Response{
            .status = response.head.status,
            .body = body,
            .last_modified = last_modified,
            .poll_interval_secs = poll_interval_secs,
            .allocator = self.allocator,
        };
    }

    /// Issues a PATCH request and returns the response status code.
    pub fn patch(
        self: *HttpClient,
        url: []const u8,
        extra_headers: []const std.http.Header,
    ) !std.http.Status {
        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.PATCH, uri, .{
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [8192]u8 = undefined;
        const response = try req.receiveHead(&redirect_buf);
        return response.head.status;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "http: Response.deinit frees all memory" {
    const allocator = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(allocator, "test body");
    const lm = try allocator.dupe(u8, "Thu, 01 Jan 2026 00:00:00 GMT");
    var resp = Response{
        .status = .ok,
        .body = body,
        .last_modified = lm,
        .poll_interval_secs = 60,
        .allocator = allocator,
    };
    resp.deinit();
    // No leak = test passes with std.testing.allocator
}
