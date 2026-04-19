//! github.zig — GitHub Notifications REST API client for libtowncrier.
//! Handles URL construction, JSON parsing, reason→NotifType mapping.
//! IMPORTANT: The notifications endpoint uses ?participating=true by default.
//! See PITFALLS.md Pitfall 14 for why bare /notifications floods badge counts.

const std = @import("std");
const types = @import("types.zig");
const http = @import("http.zig");

// ── Internal JSON parse types (never exported) ──────────────────────────────

/// Internal parse-only struct. Never stored in DB or returned to shell.
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

// ── Public API ───────────────────────────────────────────────────────────────

/// Result returned from fetchNotifications.
pub const FetchResult = struct {
    /// Slice of parsed notifications. Caller owns the slice and each item's string fields.
    notifications: []types.Notification,
    /// Heap-owned copy of the new Last-Modified value, or null.
    new_last_modified: ?[]const u8,
    /// True if server returned 304 Not Modified.
    not_modified: bool,
    /// Parsed X-Poll-Interval from response headers, or null.
    poll_interval_secs: ?u32,
};

/// Fetch GitHub notifications for the given account.
///
/// On 304: returns FetchResult with not_modified=true and empty notifications.
/// On 401: returns error.Unauthorized.
/// On 200: parses JSON and maps to types.Notification slice.
///
/// Caller owns all memory in the returned FetchResult.
pub fn fetchNotifications(
    client: *http.HttpClient,
    allocator: std.mem.Allocator,
    account: types.Account,
) !FetchResult {
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/notifications?participating=true",
        .{account.base_url},
    );
    defer allocator.free(url);

    // Build Authorization header — temp allocation, freed after HTTP call.
    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{account.token});
    defer allocator.free(bearer);

    // Build headers slice. If-Modified-Since is conditional.
    var headers_buf: [4]std.http.Header = undefined;
    var n_headers: usize = 3;
    headers_buf[0] = .{ .name = "Authorization", .value = bearer };
    headers_buf[1] = .{ .name = "Accept", .value = "application/vnd.github+json" };
    headers_buf[2] = .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" };
    if (account.last_modified) |lm| {
        headers_buf[3] = .{ .name = "If-Modified-Since", .value = lm };
        n_headers = 4;
    }
    const headers = headers_buf[0..n_headers];

    var resp = try client.get(url, headers);
    defer resp.deinit();

    switch (resp.status) {
        .not_modified => {
            return FetchResult{
                .notifications = &.{},
                .new_last_modified = null,
                .not_modified = true,
                .poll_interval_secs = null,
            };
        },
        .unauthorized => return error.Unauthorized,
        .ok => {}, // handled below
        else => return error.UnexpectedHttpStatus,
    }

    // --- 200 OK: parse JSON and map to Notification slice ---

    const parsed = try std.json.parseFromSlice(
        []NotificationJson,
        allocator,
        resp.body.items,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    // Capture last_modified before resp is deferred-deinitialized.
    const new_last_modified: ?[]const u8 = if (resp.last_modified) |lm|
        try allocator.dupe(u8, lm)
    else
        null;
    errdefer if (new_last_modified) |lm| allocator.free(lm);

    const poll_interval_secs = resp.poll_interval_secs;

    // Zig 0.16: std.ArrayList is now unmanaged — pass allocator to deinit/append/toOwnedSlice.
    var notifications = try std.ArrayList(types.Notification).initCapacity(
        allocator,
        parsed.value.len,
    );
    errdefer {
        for (notifications.items) |n| {
            allocator.free(n.api_id);
            allocator.free(n.repo);
            allocator.free(n.title);
            allocator.free(n.url);
        }
        notifications.deinit(allocator);
    }

    for (parsed.value) |item| {
        // Generate a stable u64 id unique per (account_id, api_id) pair.
        // Combining account_id ensures two accounts polling the same notification
        // (same api_id string) produce different u64 ids and don't collide on
        // the notifications PRIMARY KEY column in the DB.
        const api_id_num = std.fmt.parseInt(u64, item.id, 10) catch std.hash.Wyhash.hash(0, item.id);
        // Mix account_id into the high bits. account_id is u32; shift left 32 bits
        // and XOR with the numeric api_id to produce a unique composite key.
        const id = api_id_num ^ (@as(u64, account.id) << 32);

        const updated_at = parseIso8601(item.updated_at);

        const web_url = try apiUrlToWebUrl(allocator, item.subject.url);
        errdefer allocator.free(web_url);

        const api_id = try allocator.dupe(u8, item.id);
        errdefer allocator.free(api_id);

        const repo = try allocator.dupe(u8, item.repository.full_name);
        errdefer allocator.free(repo);

        const title = try allocator.dupe(u8, item.subject.title);
        errdefer allocator.free(title);

        try notifications.append(allocator, .{
            .id = id,
            .account_id = account.id,
            .api_id = api_id,
            .service = .github,
            .notif_type = reasonToNotifType(item.reason),
            .repo = repo,
            .title = title,
            .url = web_url,
            .updated_at = updated_at,
            .is_read = !item.unread,
        });
    }

    return FetchResult{
        .notifications = try notifications.toOwnedSlice(allocator),
        .new_last_modified = new_last_modified,
        .not_modified = false,
        .poll_interval_secs = poll_interval_secs,
    };
}

/// Mark a notification thread as read via PATCH.
pub fn markRead(
    client: *http.HttpClient,
    allocator: std.mem.Allocator,
    account: types.Account,
    api_id: []const u8,
) !void {
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/notifications/threads/{s}",
        .{ account.base_url, api_id },
    );
    defer allocator.free(url);

    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{account.token});
    defer allocator.free(bearer);

    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = bearer },
        .{ .name = "Accept", .value = "application/vnd.github+json" },
        .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
    };

    const status = try client.patch(url, &headers);
    // 205 Reset Content = success for GitHub mark-read; 200 also accepted.
    if (status != .reset_content and status != .ok) {
        return error.MarkReadFailed;
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Maps GitHub notification reason strings to NotifType.
/// Handles all 15 documented reason values.
fn reasonToNotifType(reason: []const u8) types.NotifType {
    if (std.mem.eql(u8, reason, "review_requested"))          return .pr_review;
    if (std.mem.eql(u8, reason, "comment"))                   return .pr_comment;
    if (std.mem.eql(u8, reason, "mention"))                   return .issue_mention;
    if (std.mem.eql(u8, reason, "team_mention"))              return .issue_mention;
    if (std.mem.eql(u8, reason, "assign"))                    return .issue_assigned;
    if (std.mem.eql(u8, reason, "ci_activity"))               return .ci_failed;
    // author, manual, subscribed, state_change, invitation,
    // security_alert, approval_requested, member_feature_requested,
    // security_advisory_credit → .other
    return .other;
}

/// Converts a GitHub API URL to a web URL.
///
/// Example:
///   "https://api.github.com/repos/owner/repo/pulls/123"
///   → "https://github.com/owner/repo/pull/123"
///
/// Unknown patterns are returned as-is (fallback, never constructed from user data).
pub fn apiUrlToWebUrl(allocator: std.mem.Allocator, api_url: []const u8) ![]u8 {
    const api_prefix = "https://api.github.com/repos/";
    const web_prefix = "https://github.com/";
    if (!std.mem.startsWith(u8, api_url, api_prefix)) {
        return allocator.dupe(u8, api_url);
    }
    const rest = api_url[api_prefix.len..];
    // /pulls/ → /pull/ (plural → singular)
    const rest_fixed = try std.mem.replaceOwned(u8, allocator, rest, "/pulls/", "/pull/");
    defer allocator.free(rest_fixed);
    return std.mem.concat(allocator, u8, &.{ web_prefix, rest_fixed });
}

/// Parse an ISO 8601 timestamp string (e.g. "2026-04-01T12:00:00Z") to a Unix timestamp.
/// Returns 0 on parse failure.
fn parseIso8601(s: []const u8) i64 {
    // Minimal parser: expects "YYYY-MM-DDTHH:MM:SSZ"
    if (s.len < 19) return 0;
    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return 0;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return 0;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return 0;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return 0;
    const min = std.fmt.parseInt(u8, s[14..16], 10) catch return 0;
    const sec = std.fmt.parseInt(u8, s[17..19], 10) catch return 0;
    // Days since epoch using a simple formula (Gregorian calendar).
    const y: i64 = if (month <= 2) year - 1 else year;
    const m: i64 = if (month <= 2) month + 9 else month - 3;
    const d: i64 = day;
    // Zig 0.16: signed integer division requires @divTrunc/@divFloor/@divExact.
    const jdn: i64 = @divTrunc(146097 * (y + 4800), 400) + @divTrunc(153 * m + 2, 5) + d - 32045;
    const unix_day: i64 = jdn - 2440588; // JDN for 1970-01-01
    return unix_day * 86400 + @as(i64, hour) * 3600 + @as(i64, min) * 60 + @as(i64, sec);
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "github: reasonToNotifType covers all known reasons" {
    const reasons = [_][]const u8{
        "review_requested", "comment", "mention", "team_mention", "assign",
        "ci_activity", "author", "manual", "subscribed", "state_change",
        "invitation", "security_alert", "approval_requested",
        "member_feature_requested", "security_advisory_credit",
    };
    for (reasons) |r| {
        _ = reasonToNotifType(r); // must not panic
    }
}

test "github: apiUrlToWebUrl converts PR URL" {
    const allocator = std.testing.allocator;
    const result = try apiUrlToWebUrl(
        allocator,
        "https://api.github.com/repos/owner/repo/pulls/123",
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("https://github.com/owner/repo/pull/123", result);
}

test "github: apiUrlToWebUrl returns non-api URLs unchanged" {
    const allocator = std.testing.allocator;
    const input = "https://github.com/owner/repo/issues/42";
    const result = try apiUrlToWebUrl(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}
