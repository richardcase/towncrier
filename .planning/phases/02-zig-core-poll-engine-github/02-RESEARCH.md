# Phase 2: Zig Core — Poll Engine + GitHub - Research

**Researched:** 2026-04-17
**Domain:** Zig threading, std.http.Client, GitHub Notifications REST API, SQLite (zig-sqlite), mock HTTP server
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** One `std.Thread` per account. No shared coordinator. Per-account independence.
- **D-02:** `towncrier_remove_account` waits for the in-flight poll cycle to finish before joining the thread. Clean exit — no abandoned connections.
- **D-03:** Test harness is a headless Zig test binary (`tests/core/poll_test.zig`) with an embedded mock HTTP server. No live API calls.
- **D-04:** Mock server simulates real GitHub behavior: tracks `If-Modified-Since` per account, returns `304 Not Modified` when data is unchanged, includes `X-Poll-Interval` header. Stateful, not static.
- **D-05:** `towncrier_mark_read` (main thread) appends to a Mutex-protected `ArrayList` action queue on `TowncrierHandle`. Each account's poll thread drains the queue (filtered by `account_id`) at the start of each poll cycle.
- **D-06:** Use `vrischmann/zig-sqlite` as the SQLite wrapper. Verify 0.14 compatibility at plan time.

### Claude's Discretion

- Exact HTTP connection reuse strategy within `src/http.zig` (shared `std.http.Client` per account vs. new client per poll).
- Internal module layout beyond the files named in `ARCHITECTURE.md` (helper structs, error types).
- Mock server port selection and startup/shutdown sequencing in the test binary.
- Specific `zig-sqlite` version to pin (latest compatible with Zig 0.14).

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CORE-03 | Poll engine runs on background thread with configurable interval; respects `X-Poll-Interval` header | Per-account `std.Thread` + `Condition.timedWait` sleep loop; `X-Poll-Interval` parsed from response headers |
| CORE-04 | Per-account polling model — each account has independent state, token, base URL, last-seen timestamps, unread list | D-01 one-thread-per-account design; `Account` struct in `types.zig` |
| CORE-05 | Unified notification data model (common struct across GitHub and GitLab) | `Notification` struct with `NotifType` enum mapping GitHub `reason` field |
| CORE-06 | Notifications grouped by repository (client-side, in core) | Grouping done at snapshot-build time in `poller.zig`; sorted by `repo` field |
| CORE-07 | Read/unread state persisted locally via SQLite (WAL mode) | `vrischmann/zig-sqlite` confirmed `minimum_zig_version = "0.14.0"` |
| CORE-08 | Token storage via system keychain (macOS/Linux) — core never persists tokens | Tokens passed to `add_account`, held in memory only; no disk write in core |
| GH-01 | User can add GitHub account with PAT | `towncrier_add_account` stub wired to real `Account` struct with `token` field |
| GH-02 | App fetches all GitHub notification types | `reason` field maps to `NotifType` enum; all 15 reason values handled |
| GH-03 | Conditional polling with `If-Modified-Since`/`Last-Modified`; 304 does not consume rate limit | `poll_state` table persists `last_modified`; `extra_headers` on `std.http.Client` request |
| GH-04 | Marking a notification read issues `PATCH /notifications/threads/:id`; removed from next snapshot | D-05 action queue drains on poll thread; `PATCH` with `notif.api_id` |
| GH-05 | Multiple GitHub accounts, each polls independently | D-01 one-thread-per-account; `accounts: ArrayList(Account)` on `TowncrierHandle` |
</phase_requirements>

---

## Summary

Phase 2 converts all Phase 1 stubs into a working GitHub poll engine. The five new source files (`src/types.zig` expanded, `src/http.zig`, `src/github.zig`, `src/poller.zig`, `src/store.zig`) form a clean layered architecture: `store.zig` owns SQLite persistence, `github.zig` owns HTTP protocol details, `poller.zig` owns threading and scheduling, and `c_api.zig` wires them together through `TowncrierHandle`.

The key threading model is one `std.Thread` per account. Each poll thread sleeps using `std.Thread.Condition.timedWait` so it can be woken early on `towncrier_stop`. Cross-thread communication uses two primitives: a `std.Thread.RwLock` protecting the in-memory snapshot (read by main thread via `towncrier_snapshot_get`), and a `std.Thread.Mutex`-guarded `ArrayList` action queue for mark-read mutations.

The `vrischmann/zig-sqlite` library is confirmed compatible with Zig 0.14.0 — its `build.zig.zon` sets `minimum_zig_version = "0.14.0"` and the master branch was updated 2026-04-16. The mock HTTP server is a `std.http.Server` listening on a loopback port, stateful per-account to simulate `If-Modified-Since`/`304` correctly.

**Primary recommendation:** Follow the ARCHITECTURE.md data flow exactly. Build in layer order: `types.zig` → `store.zig` → `http.zig` → `github.zig` → `poller.zig` → `c_api.zig` wiring → test harness.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Notification data model | Core (`types.zig`) | — | Shared across GitHub/GitLab clients; no platform dependency |
| SQLite persistence | Core (`store.zig`) | — | Business logic, no UI; WAL mode handles concurrent read (main) + write (poll thread) |
| GitHub HTTP polling | Core (`github.zig`) | Core (`http.zig`) | All API communication owned by core; platform shells have no HTTP |
| Poll scheduling / threading | Core (`poller.zig`) | — | Background work owned by core; shells only receive `wakeup` callback |
| Mark-read mutations | Core (action queue in `TowncrierHandle`) | Core (`github.zig` issues PATCH) | Mutation queued on main thread, applied by poll thread |
| Token storage | Platform shell (keychain) | Core (memory-only) | Core holds token in memory; never writes to disk; shell reads keychain |
| Snapshot delivery | Core (`towncrier_snapshot_get`) | — | Deep copy returned; no lock held after return; shell reads safely from main thread |
| Test harness mock server | Test binary (`tests/core/poll_test.zig`) | — | Hermetic CI; no live API calls; stateful per-account 304 simulation |

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Zig | 0.14.0 | Core language | Locked project decision; stable API |
| std.Thread | stdlib | Per-account poll threads | Sufficient for 2–5 accounts; no async runtime needed |
| std.Thread.Mutex | stdlib | Action queue protection | Standard synchronization primitive |
| std.Thread.RwLock | stdlib | Snapshot read/write protection | Multiple readers (snapshot_get) safe; single writer (poll thread) |
| std.Thread.Condition | stdlib | Interruptible poll sleep | `timedWait` enables early wakeup on `towncrier_stop` |
| std.http.Client | stdlib | GitHub REST API requests | HTTP/1.1, TLS 1.3, connection pooling, thread-safe pool; custom headers via `extra_headers` |
| std.json | stdlib | Parse GitHub API JSON responses | `parseFromSlice` into typed Zig structs |
| vrischmann/zig-sqlite | master (confirmed `minimum_zig_version = "0.14.0"`) | SQLite wrapper | Type-safe comptime query binding; actively maintained; 0.14 confirmed |
| std.http.Server | stdlib (test only) | Mock HTTP server in test binary | Available since 0.12; sufficient for loopback test use |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| std.ArrayList | stdlib | Action queue, accounts list | Dynamic collections on `TowncrierHandle` |
| std.StringHashMap | stdlib | Per-account `last_modified` cache | Optional in-memory cache if not reading from DB each poll |
| std.heap.c_allocator | stdlib | Primary allocator for handle and children | Established in Phase 1; consistent with C-ABI caller model |
| std.mem.Allocator | stdlib | Passed through for per-request allocations | Arena allocator for HTTP response parsing |
| std.heap.ArenaAllocator | stdlib | Scoped allocation for JSON parse per poll cycle | Reset after parse; avoids per-notification alloc/free |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| vrischmann/zig-sqlite | Direct SQLite C amalgamation via `@cImport` | Direct is more portable across Zig version churn but requires manual SQL binding |
| vrischmann/zig-sqlite | karlseguin/zqlite.zig | zqlite requires Zig 0.16+; not compatible with pinned 0.14 |
| std.http.Client | libcurl via C interop | libcurl handles TLS 1.2 (for self-hosted GitLab); adds a system dependency; not needed for Phase 2 (GitHub only) |
| std.Thread.Condition.timedWait | std.time.sleep | sleep cannot be interrupted on stop; Condition wakeup is cleaner shutdown |

**Installation:**
```bash
# Add zig-sqlite to build.zig.zon:
zig fetch --save git+https://github.com/vrischmann/zig-sqlite
```

**Version verification:** [VERIFIED: github.com/vrischmann/zig-sqlite branches] Master branch updated 2026-04-16. `build.zig.zon` sets `minimum_zig_version = "0.14.0"`. No dedicated 0.14 branch exists — master supports 0.14. The zig-0.15.2 branch and fix-for-zig-master branch also exist; pin to the git hash of master at fetch time to avoid surprises.

---

## Architecture Patterns

### System Architecture Diagram

```
towncrier_add_account()          towncrier_mark_read()
      │                                 │
      ▼                                 ▼
TowncrierHandle ──────────── action_queue (Mutex+ArrayList)
      │                                 │
      │ spawn thread per account        │ drain at poll start
      ▼                                 │
PollThread (per account) ◄─────────────┘
      │
      ├─ check stop_flag (atomic bool)
      │
      ├─ drain action queue (filter by account_id)
      │   └─ UPDATE notifications SET is_read=1  ──► store.zig (SQLite)
      │   └─ PATCH /notifications/threads/:id    ──► github.zig → http.zig
      │
      ├─ GET /notifications
      │   If-Modified-Since: <poll_state.last_modified>  ──► http.zig → GitHub API
      │       │
      │       ├─ 304 Not Modified → no-op, sleep
      │       ├─ 200 OK → parse JSON → upsert notifications
      │       │   └─ store.zig: INSERT OR REPLACE INTO notifications
      │       │   └─ store.zig: UPDATE poll_state SET last_modified
      │       └─ 401 Unauthorized → on_error callback → stop polling
      │
      ├─ build snapshot (read unread from store)
      │   └─ snapshot_rwlock.lockWrite()
      │   └─ deep copy notifications → TowncrierSnapshot
      │   └─ snapshot_rwlock.unlockWrite()
      │
      ├─ callbacks.on_update(userdata, unread_count)  ──► platform shell
      ├─ callbacks.wakeup(userdata)                   ──► platform shell
      │
      └─ Condition.timedWait(poll_interval or X-Poll-Interval)

towncrier_snapshot_get()          towncrier_tick()
      │                                 │
      │ snapshot_rwlock.lockRead()      │ drain queued main-thread work
      │ deep copy → caller owns         │ (Phase 2: already done by poll thread)
      │ snapshot_rwlock.unlockRead()    │
      ▼                                 ▼
TowncrierSnapshot (caller-owned)   (no-op or future work)
```

### Recommended Project Structure
```
src/
├── root.zig          # library root (unchanged from Phase 1)
├── c_api.zig         # C ABI surface — stubs wired to real implementations
├── types.zig         # Notification, Account, Service, NotifType, TowncrierHandle
├── http.zig          # std.http.Client wrapper: GET/PATCH, header handling
├── github.zig        # GitHub-specific: URL construction, JSON parsing, reason mapping
├── poller.zig        # Poll thread loop, stop/start, per-account scheduling
└── store.zig         # SQLite open/migrate/upsert/query via zig-sqlite
tests/
└── core/
    └── poll_test.zig # Headless test binary: mock server + two-account scenario
```

### Pattern 1: Per-Account Poll Thread with Interruptible Sleep

**What:** Each account runs in its own `std.Thread`. The thread sleeps between polls using `std.Thread.Condition.timedWait` so it can be woken immediately when `towncrier_stop` is called.

**When to use:** Any per-account background work that must be independently interruptible.

**Example:**
```zig
// Source: Zig stdlib Condition docs + ARCHITECTURE.md threading model
const PollContext = struct {
    account: Account,
    handle: *TowncrierHandle,
    stop_flag: std.atomic.Value(bool),
    stop_cond: std.Thread.Condition,
    stop_mutex: std.Thread.Mutex,
};

fn pollThread(ctx: *PollContext) void {
    while (!ctx.stop_flag.load(.acquire)) {
        // Drain action queue, execute HTTP poll, update snapshot...

        // Interruptible sleep: wakes early if stop is signaled
        ctx.stop_mutex.lock();
        defer ctx.stop_mutex.unlock();
        ctx.stop_cond.timedWait(&ctx.stop_mutex, poll_interval_ns) catch {}; // Timeout is normal
    }
}

// To stop:
fn stopAccount(ctx: *PollContext) void {
    ctx.stop_flag.store(true, .release);
    ctx.stop_mutex.lock();
    ctx.stop_cond.signal();
    ctx.stop_mutex.unlock();
    ctx.thread.join();
}
```
[CITED: github.com/ziglang/zig/blob/0.14.0/lib/std/Thread/Condition.zig]

### Pattern 2: std.http.Client — Shared Per-Account, Custom Headers

**What:** A single `std.http.Client` is created per account and reused across poll cycles. The connection pool is thread-safe. Individual requests are single-threaded (only the poll thread uses this client).

**When to use:** This approach (one client per account, not one global client) avoids lock contention on the connection pool across account threads and isolates connection state per account.

**Example:**
```zig
// Source: github.com/ziglang/zig/blob/0.14.0/lib/std/http/Client.zig
var client = std.http.Client{ .allocator = allocator };
defer client.deinit();

var body = std.ArrayList(u8).init(allocator);
defer body.deinit();

const result = try client.fetch(.{
    .location = .{ .url = "https://api.github.com/notifications" },
    .method = .GET,
    .extra_headers = &.{
        .{ .name = "Authorization", .value = token_header },
        .{ .name = "Accept", .value = "application/vnd.github+json" },
        .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
        .{ .name = "If-Modified-Since", .value = last_modified orelse "" },
    },
    .response_storage = .{ .dynamic = &body },
});

if (result.status == .not_modified) {
    // 304 — no work to do
    return;
}
// Parse body.items as JSON...
```
[CITED: github.com/ziglang/zig/blob/0.14.0/lib/std/http/Client.zig extra_headers field]

**Caveat on response headers:** `std.http.Client.fetch` returns a `FetchResult` with `status` and access to response headers via iterator. To get `Last-Modified` and `X-Poll-Interval`, iterate `result.headers` after the fetch. [ASSUMED — need to verify iterator API in 0.14; if `fetch()` result doesn't expose header iterator, use the lower-level `open`/`send`/`wait` API instead]

### Pattern 3: zig-sqlite — Schema Migration and Upsert

**What:** Open the DB, apply the v1 schema if `schema_version` is absent, then use comptime-typed queries.

**Example:**
```zig
// Source: vrischmann/zig-sqlite README
const sqlite = @import("sqlite");

var db = try sqlite.Db.init(.{
    .mode = sqlite.Db.Mode{ .File = db_path },
    .open_flags = .{ .write = true, .create = true },
    .threading_mode = .MultiThread,
});
defer db.deinit();

// Apply pragmas
try db.exec("PRAGMA journal_mode=WAL", .{}, .{});
try db.exec("PRAGMA synchronous=NORMAL", .{}, .{});

// Upsert notification
try db.exec(
    \\INSERT INTO notifications
    \\  (id, account_id, api_id, service, notif_type, repo, title, url, updated_at, is_read)
    \\VALUES
    \\  (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
    \\ON CONFLICT(account_id, api_id) DO UPDATE SET
    \\  title=excluded.title, url=excluded.url, updated_at=excluded.updated_at,
    \\  is_read=CASE WHEN is_read=1 THEN 1 ELSE excluded.is_read END
    ,
    .{},
    .{ notif.id, notif.account_id, notif.api_id, @intFromEnum(notif.service), ... },
);
```
[CITED: github.com/vrischmann/zig-sqlite README and source]

**Note on `ON CONFLICT` keep-read logic:** The upsert must never overwrite `is_read=1` with `is_read=0` from a new API response. Once the user marks something read locally, it stays read until the next poll confirms it's gone from the API response.

### Pattern 4: Mock HTTP Server for Test Harness (D-03, D-04)

**What:** A `std.http.Server` listening on a loopback port. A goroutine-equivalent thread accepts connections. State tracks `last_modified` per account-token to implement stateful 304 responses.

**When to use:** Phase 2 test binary only. Never in production library code.

**Example:**
```zig
// Source: cookbook.ziglang.cc/05-03-http-server-std + Zig 0.14 std.http.Server
const MockServer = struct {
    // Map: account_token -> last_modified_sent
    state: std.StringHashMap([]const u8),
    mutex: std.Thread.Mutex,
    // ... accept loop in separate thread
};

// On GET /notifications:
// If request has If-Modified-Since matching stored last_modified → respond 304
// Else → respond 200 with fixture JSON + Last-Modified + X-Poll-Interval: 60
// On PATCH /notifications/threads/:id → respond 205 Reset Content
```

**Port selection:** Bind to port 0 (OS assigns ephemeral port); read back with `server.listen_address.getPort()`. Pass the port to accounts via `base_url = "http://127.0.0.1:{port}"`. [ASSUMED — verify `std.net.Address.getPort()` exists in 0.14]

### Anti-Patterns to Avoid

- **One `std.http.Client` shared globally across all account threads:** The connection pool is thread-safe for acquiring/releasing connections, but sharing a single client across multiple poll threads that may issue requests simultaneously can lead to unexpected connection reuse. Use one client per account thread instead.
- **Reading `last_modified` from SQLite on every poll:** Causes a read for each poll cycle. Cache the value in the `Account` struct's `etag`/`last_modified` field (as defined in ARCHITECTURE.md). SQLite stores it for persistence across restarts; memory holds it for fast access.
- **Calling `callbacks.on_update` with snapshot data in the payload:** The ABI design (ARCHITECTURE.md) makes `on_update` a fire-and-forget count signal. Never pass snapshot pointers through callbacks — the shell calls `towncrier_snapshot_get` after marshaling to main thread.
- **Holding the snapshot RwLock during JSON parse or SQL queries:** Parse first, acquire lock only during the final swap. Lock duration should be microseconds, not milliseconds.
- **Forgetting `?participating=true` on the GitHub notifications endpoint:** Raw `/notifications` returns all unread across all org repos, causing overwhelming badge counts. Default to `?participating=true` (see Pitfall 14 in PITFALLS.md).

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| SQLite C binding | Custom `@cImport` + manual binding layer | `vrischmann/zig-sqlite` | Handles column type mapping, error unions, compile-time query validation; SQLite C API has ~100 functions and many error code nuances |
| Conditional HTTP polling | Manual ETag string management | `If-Modified-Since`/`Last-Modified` pattern from `std.http.Client.extra_headers` | GitHub explicitly uses `Last-Modified` for notifications (not ETag); misimplementing this wastes rate limit quota |
| JSON → Zig struct mapping | Manual field iteration | `std.json.parseFromSlice` into typed structs | Type-safe, handles null fields, cleans up with `defer parsed.deinit()` |
| Thread stop protocol | `pthread_cancel` or `std.time.sleep` | `std.Thread.Condition.timedWait` with atomic stop flag | `sleep` cannot be interrupted; `Condition` allows immediate wakeup on stop signal |
| In-memory snapshot copy | Shared pointer + manual refcount | Deep copy into caller-owned allocation | Eliminates lock lifetime complexity; snapshot is a value, not a view |

**Key insight:** The threading and HTTP conditional-polling patterns have many edge cases (spurious Condition wakeups, `Last-Modified` format parsing, `X-Poll-Interval` honor). Use stdlib primitives exactly as documented and test with the mock server before touching a real API.

---

## Common Pitfalls

### Pitfall 1: zig-sqlite Master vs. Pinned Hash

**What goes wrong:** `zig fetch --save git+https://github.com/vrischmann/zig-sqlite` without a commit ref fetches the latest master, which changes. A future CI run may fetch a different commit and break the build.

**Why it happens:** Zig's package manager pins by content hash, not by branch name. Fetching a branch URL without a `#<commit>` suffix pins to the current tip, but future `zig fetch` runs will pull updated master if the `.zig-cache` is cleared.

**How to avoid:** After `zig fetch --save git+...`, capture the resulting hash in `build.zig.zon` and commit it. Treat upgrades as explicit. Alternatively, use a specific tag or commit hash: `git+https://github.com/vrischmann/zig-sqlite#<sha>`.

**Warning signs:** `build.zig.zon` has a git URL without a pinned hash.

### Pitfall 2: `std.http.Client.fetch` Does Not Return Response Headers Directly

**What goes wrong:** Using `.fetch()` for a simple 200/304 check is straightforward, but extracting `Last-Modified` and `X-Poll-Interval` response headers may require iterating the `response.headers` field, which is not always exposed in the `FetchResult` type depending on the 0.14 version.

**Why it happens:** `fetch()` is a high-level convenience; the lower-level `open`/`send`/`wait` API gives full access to response headers.

**How to avoid:** Verify in the actual `std.http.Client` 0.14 source whether `FetchResult` exposes headers. If not, use the lower-level `Request` API:
```zig
var req = try client.open(.GET, uri, .{ .extra_headers = &headers });
defer req.deinit();
try req.send();
try req.finish();
try req.wait();
// req.response.headers is now available
const last_modified = req.response.headers.getFirstValue("Last-Modified");
const poll_interval = req.response.headers.getFirstValue("X-Poll-Interval");
```
[ASSUMED — exact API shape needs verification against 0.14.0 source]

**Warning signs:** Compilation error on `result.headers` after using `.fetch()`.

### Pitfall 3: GitHub subject.url Is an API URL, Not a Web URL

**What goes wrong:** The `subject.url` field in a notification thread looks like `https://api.github.com/repos/owner/repo/pulls/123`. This is not a browseable URL — it is the REST API endpoint for the subject. The shell needs a web URL like `https://github.com/owner/repo/pull/123`.

**Why it happens:** The GitHub Notifications API does not return `html_url` for the subject directly. Derivation requires URL rewriting.

**How to avoid:** In `github.zig`, implement `apiUrlToWebUrl`:
- Replace `https://api.github.com/repos/` prefix with `https://github.com/`
- Replace `/pulls/` with `/pull/` (singular)
- Replace `/issues/` and `/commits/` — these already match web paths
- For commit notifications: `https://github.com/{owner}/{repo}/commit/{sha}`
[CITED: github.com docs.github.com/rest/activity/notifications — subject.url field]

**Warning signs:** The notification URL stored in SQLite starts with `api.github.com`.

### Pitfall 4: Snapshot Memory Model — String Lifetime

**What goes wrong:** `TowncrierSnapshot` contains `towncrier_notification_s` items with `const char *` fields. These must be valid until `towncrier_snapshot_free`. If the strings point into a SQLite result set or a Zig `ArrayList` that gets freed or resized, the shell reads dangling pointers.

**Why it happens:** It is tempting to return pointers into the current in-memory state rather than deep-copying.

**How to avoid:** `towncrier_snapshot_get` allocates a flat `TowncrierSnapshot` struct that owns all string data in a single `ArrayList(u8)` string buffer. All `const char *` fields in `NotificationC` point into this buffer. `towncrier_snapshot_free` frees the buffer and the array.

**Warning signs:** Valgrind reports use-after-free on snapshot item fields after `towncrier_snapshot_free`.

### Pitfall 5: Action Queue Filter Requires account_id to Be in the Notification Record

**What goes wrong:** D-05 says each poll thread drains the queue filtering by `account_id`. But `towncrier_mark_read` only receives `notif_id` (not `account_id`). The core must look up `account_id` from `notif_id` to route the action.

**Why it happens:** The ABI only exposes `notif_id` to the caller. Account routing is an internal concern.

**How to avoid:** When the action is enqueued in `towncrier_mark_read`, look up the notification in the current snapshot to find its `account_id`. If not found, return error. The action queue entry stores both `notif_id` and `account_id`. [ASSUMED — verify this lookup is safe given snapshot RwLock ownership; alternative: store a `id → account_id` map separately in `TowncrierHandle`]

### Pitfall 6: `towncrier_free` Must Stop Poll Threads Before Freeing Handle

**What goes wrong:** `towncrier_free` calls `std.heap.c_allocator.destroy(handle)`, freeing `TowncrierHandle`. If poll threads are still running and hold a pointer to `handle`, they dereference freed memory.

**Why it happens:** Phase 1 `towncrier_free` is a simple `destroy`. Phase 2 expands `TowncrierHandle` significantly; free must now also call the stop protocol.

**How to avoid:** `towncrier_free` must call `towncrier_stop` internally before destroying the handle. The C header already documents this: "This function stops the poll engine if running." Implement this in Phase 2.

---

## Code Examples

### GitHub API: Parse Notification JSON

```zig
// Source: std.json documentation + GitHub Notifications API response schema
const NotificationJson = struct {
    id: []const u8,          // Thread ID as string
    unread: bool,
    reason: []const u8,      // "review_requested", "mention", etc.
    updated_at: []const u8,  // ISO 8601 timestamp
    subject: struct {
        title: []const u8,
        url: []const u8,     // API URL — must be converted to web URL
        type: []const u8,    // "PullRequest", "Issue", "Commit"
    },
    repository: struct {
        full_name: []const u8,   // "owner/repo"
    },
};

const parsed = try std.json.parseFromSlice(
    []NotificationJson,
    allocator,
    body,
    .{ .ignore_unknown_fields = true },
);
defer parsed.deinit();
```
[CITED: docs.github.com/en/rest/activity/notifications response schema]

### GitHub API: Reason → NotifType Mapping

```zig
// All 15 reason values from GitHub API docs
fn reasonToNotifType(reason: []const u8) NotifType {
    if (std.mem.eql(u8, reason, "review_requested")) return .pr_review;
    if (std.mem.eql(u8, reason, "comment"))          return .pr_comment;
    if (std.mem.eql(u8, reason, "mention"))          return .issue_mention;
    if (std.mem.eql(u8, reason, "team_mention"))     return .issue_mention;
    if (std.mem.eql(u8, reason, "assign"))           return .issue_assigned;
    if (std.mem.eql(u8, reason, "ci_activity"))      return .ci_failed; // approximation
    if (std.mem.eql(u8, reason, "author"))           return .other;
    if (std.mem.eql(u8, reason, "manual"))           return .other;
    if (std.mem.eql(u8, reason, "subscribed"))       return .other;
    if (std.mem.eql(u8, reason, "state_change"))     return .other;
    if (std.mem.eql(u8, reason, "invitation"))       return .other;
    if (std.mem.eql(u8, reason, "security_alert"))   return .other;
    // approval_requested, member_feature_requested, security_advisory_credit
    return .other;
}
```
[CITED: docs.github.com/en/rest/activity/notifications — reason field values]

### TowncrierHandle: Phase 2 Structure

```zig
// src/types.zig — Phase 2 expansion
pub const TowncrierHandle = struct {
    allocator: std.mem.Allocator = std.heap.c_allocator,
    callbacks: RuntimeCallbacks,
    accounts: std.ArrayList(AccountState),
    // Action queue: main thread writes, poll threads drain
    action_mutex: std.Thread.Mutex = .{},
    action_queue: std.ArrayList(Action),
    // Snapshot: poll thread writes, main thread reads
    snapshot_lock: std.Thread.RwLock = .{},
    snapshot: ?*TowncrierSnapshot = null,
    // DB handle: single connection shared carefully (WAL mode allows concurrent reads)
    db: ?sqlite.Db = null,
};

pub const AccountState = struct {
    account: Account,
    thread: ?std.Thread = null,
    ctx: ?*PollContext = null, // heap-allocated, freed on remove
};

pub const Action = union(enum) {
    mark_read: struct { notif_id: u64, account_id: u32, api_id: []const u8 },
    mark_all_read: struct { account_id: u32 },
};
```
[ASSUMED — exact struct layout is Claude's discretion per CONTEXT.md]

### SQLite Schema Migration

```zig
// src/store.zig — schema v1 migration
pub fn migrate(db: *sqlite.Db) !void {
    var version: i64 = 0;
    const row = db.oneAlloc(
        struct { version: i64 },
        allocator,
        "SELECT version FROM schema_version LIMIT 1",
        .{}, .{},
    ) catch null;
    if (row) |r| { version = r.version; }

    if (version < 1) {
        try db.exec(schema_v1, .{}, .{});
        try db.exec("INSERT INTO schema_version VALUES (1)", .{}, .{});
    }
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
[CITED: ARCHITECTURE.md § State Persistence: SQLite]

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `addStaticLibrary`/`addSharedLibrary` in build.zig | `b.addLibrary(.{ .linkage = .static })` | Zig 0.14.0 | Already used in Phase 1 build.zig |
| Zig `callconv(.C)` | `callconv(.c)` (lowercase) | Zig 0.16 (master) | Phase 1 already uses lowercase form |
| `std.net.StreamServer` (pre-0.12) | `std.net.Address.listen()` + `std.http.Server` | Zig 0.12.0 | Mock server must use new API |
| `std.ArrayList(T).init(allocator)` | `std.ArrayList(T).init(allocator)` | Unchanged in 0.14 | No change needed |

**Deprecated/outdated:**
- `main.zig` uses `std.Io` and `std.process.Init` — these are Zig 0.16 master APIs, not 0.14. The test binary (`poll_test.zig`) must use the 0.14 pattern (`pub fn main() !void` with standard allocators). Do not modify `main.zig`; it is the scaffold executable entry point, not the library.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `std.http.Client.fetch()` result exposes response headers; if not, lower-level `Request` API is needed | Architecture Patterns: Pattern 2 | Affects how `Last-Modified` and `X-Poll-Interval` headers are read; fallback (lower-level API) is well-understood |
| A2 | `std.net.Address.getPort()` is available in 0.14 for reading the OS-assigned port on bind-to-0 | Architecture Patterns: Pattern 4 | If absent, bind to a hardcoded loopback port (e.g., 14800) in tests instead |
| A3 | `Action` queue lookup of `account_id` from `notif_id` can use the current in-memory snapshot | Common Pitfalls: Pitfall 5 | If snapshot is stale or missing (first poll), mark_read silently fails; may need a separate `notif_id → account_id` map |
| A4 | `TowncrierHandle` struct layout (exact fields, naming) | Code Examples | Claude's discretion per CONTEXT.md; layout will be finalized during implementation |
| A5 | `zig-sqlite` `oneAlloc` and `exec` API shape matches documented usage above | Code Examples | If API changed in latest master, consult zig-sqlite source; the pattern is stable but exact method names may differ |

---

## Open Questions

1. **`std.http.Client.fetch()` vs. lower-level Request API for header access**
   - What we know: `extra_headers` on requests is confirmed. `FetchResult.status` is confirmed.
   - What's unclear: Whether `FetchResult` exposes response headers for `Last-Modified` and `X-Poll-Interval` in Zig 0.14.
   - Recommendation: During Wave 1 implementation, verify against `lib/std/http/Client.zig` source. If headers aren't in `FetchResult`, use the `open`/`send`/`wait` pattern instead. Both paths are well-supported.

2. **Action queue routing: snapshot lookup vs. separate map**
   - What we know: `towncrier_mark_read(tc, notif_id)` has no `account_id`. D-05 says poll thread filters by `account_id`.
   - What's unclear: Best place to resolve `notif_id → account_id` on the main thread.
   - Recommendation: Maintain a small `std.AutoHashMap(u64, u32)` (notif_id → account_id) on `TowncrierHandle`, updated whenever the snapshot is written. Protected by the snapshot RwLock. This is faster than scanning the snapshot and avoids the stale-snapshot edge case.

3. **SQLite WAL mode and single-connection sharing between poll threads**
   - What we know: WAL mode allows concurrent readers and one writer. Each poll thread writes (upserts); main thread reads (snapshot_get reads from DB).
   - What's unclear: Whether zig-sqlite's `Db` instance is safe to use from multiple threads when opened with `.threading_mode = .MultiThread`.
   - Recommendation: Verify zig-sqlite threading mode option. If uncertain, use a per-thread DB connection. SQLite WAL supports multiple concurrent writers (serialized by SQLite's internal lock). Alternatively, give the store a Mutex and serialize all SQL operations.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Zig | Core build | ✓ | 0.14.0 (pinned in build.zig.zon) | — |
| libsqlite3 (system) | zig-sqlite | Not needed | — | zig-sqlite bundles amalgamation (sqlite 3.49.2) |
| git | zig fetch for zig-sqlite | ✓ (assumed) | — | Download tarball manually |
| internet (CI) | zig fetch | ✓ | — | Vendor zig-sqlite in repo if CI is air-gapped |

**Missing dependencies with no fallback:** None — zig-sqlite bundles the SQLite amalgamation; no system library needed.

**Missing dependencies with fallback:** None relevant to Phase 2.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Zig built-in test runner + headless executable (`b.addExecutable`) |
| Config file | None — `b.step("test-poll", ...)` in `build.zig` |
| Quick run command | `zig build test-poll` |
| Full suite command | `zig build test-c && zig build test-poll` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CORE-03 | Poll interval respects `X-Poll-Interval` header value | integration | `zig build test-poll` | ❌ Wave 0 |
| CORE-04 | Two accounts poll independently; each fires `on_update` | integration | `zig build test-poll` | ❌ Wave 0 |
| CORE-05 | Notification struct populated from GitHub JSON | unit | `zig build test-poll` | ❌ Wave 0 |
| CORE-06 | Snapshot items sorted/grouped by repo | unit | `zig build test-poll` | ❌ Wave 0 |
| CORE-07 | Read/unread state survives restart (stop → start with existing DB) | integration | `zig build test-poll` | ❌ Wave 0 |
| CORE-08 | Token not written to disk (no token in DB or any file) | integration | `zig build test-poll` + grep check | ❌ Wave 0 |
| GH-01 | Adding a GitHub account → thread spawns, poll executes | integration | `zig build test-poll` | ❌ Wave 0 |
| GH-02 | All reason values map to a NotifType without panic | unit | `zig build test-poll` | ❌ Wave 0 |
| GH-03 | Second poll with same `Last-Modified` → 304 from mock → no SQL upsert | integration | `zig build test-poll` | ❌ Wave 0 |
| GH-04 | `mark_read` → PATCH issued to mock → notification absent from next snapshot | integration | `zig build test-poll` | ❌ Wave 0 |
| GH-05 | Two accounts share no state; removing one does not affect the other | integration | `zig build test-poll` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `zig build test-c` (existing Phase 1 test; fast, no mock needed)
- **Per wave merge:** `zig build test-c && zig build test-poll`
- **Phase gate:** Full suite green before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `tests/core/poll_test.zig` — covers all 11 requirements above
- [ ] `build.zig` — add `test-poll` step as `b.addExecutable` + `b.step`
- [ ] Fixture JSON file or inline string: sample GitHub notifications API response

*(Note: `tests/c_abi_test.c` continues to compile unchanged; Phase 2 real implementations must not break Phase 1 ABI assertions.)*

---

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No (PAT is stored in shell keychain; core receives it already resolved) | — |
| V3 Session Management | No (no session; PAT is stateless) | — |
| V4 Access Control | No (single-user local app) | — |
| V5 Input Validation | Yes — GitHub JSON response | `std.json.parseFromSlice` with `ignore_unknown_fields = true`; never use `eval` or dynamic dispatch |
| V6 Cryptography | No (TLS provided by `std.http.Client`; no custom crypto) | `std.http.Client` TLS 1.3 only |

### Known Threat Patterns for Phase 2 Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Token in SQLite DB | Information Disclosure | Never insert `account.token` into any DB table; assertion in store.zig tests |
| Token in log output | Information Disclosure | No logging of Authorization header values; log only status codes and rates |
| Malformed GitHub JSON (truncated, injected keys) | Tampering | `std.json` typed parse rejects unknown shapes; `ignore_unknown_fields` prevents panics on unexpected keys |
| Path traversal in DB file path | Tampering | DB path is constructed from `std.fs.getAppDataDir`; never from user-supplied strings in Phase 2 |
| Rate limit abuse (secondary limits) | Denial of Service | Serial requests per account; respect `Retry-After`; log `X-RateLimit-Remaining` |

---

## Sources

### Primary (HIGH confidence)
- [VERIFIED: github.com/vrischmann/zig-sqlite branches] — confirmed `minimum_zig_version = "0.14.0"` in build.zig.zon; master updated 2026-04-16
- [VERIFIED: github.com/ziglang/zig/blob/0.14.0/lib/std/http/Client.zig] — `extra_headers` field confirmed; `ConnectionPool.mutex` confirms thread-safe connection pool
- [VERIFIED: github.com/ziglang/zig/blob/0.14.0/lib/std/Thread/Condition.zig] — `timedWait` signature confirmed: `pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void`
- [CITED: docs.github.com/en/rest/activity/notifications] — 15 reason values; `subject.url` is API URL (not web URL); `If-Modified-Since`/`304` behavior; `X-Poll-Interval` semantics; `PATCH /notifications/threads/{thread_id}`
- [CITED: ARCHITECTURE.md] — threading model, data flow, SQLite schema, C ABI design — project source of truth

### Secondary (MEDIUM confidence)
- [VERIFIED: github.com/vrischmann/zig-sqlite/blob/master/build.zig] — `b.dependency("sqlite", ...)` pattern confirmed; module name is "sqlite"
- [CITED: PITFALLS.md] — Pitfalls 5, 9, 14 apply to Phase 2 directly (ETag/Last-Modified, secondary rate limits, `?participating=true` default)

### Tertiary (LOW confidence)
- [ASSUMED] `std.http.Client.fetch()` FetchResult header access — needs verification against 0.14.0 source during Wave 1

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — zig-sqlite 0.14 confirmed, std.http confirmed, std.Thread confirmed
- Architecture: HIGH — directly from ARCHITECTURE.md + Phase 1 codebase inspection
- Pitfalls: HIGH — most from PITFALLS.md (pre-researched) plus Phase 2-specific additions
- GitHub API: HIGH — from official GitHub docs; response schema confirmed

**Research date:** 2026-04-17
**Valid until:** 2026-05-17 (zig-sqlite master changes; re-verify hash before pinning)
