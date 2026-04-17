---
phase: 02-zig-core-poll-engine-github
plan: "02"
subsystem: http-github-client
tags: [zig, http, github-api, notifications, json-parsing]

# Dependency graph
requires:
  - phase: 02-zig-core-poll-engine-github
    plan: "01"
    provides: "src/types.zig with Account, Notification, NotifType, Service"
provides:
  - "src/http.zig: std.http.Client wrapper with GET/PATCH and Last-Modified/X-Poll-Interval header extraction"
  - "src/github.zig: GitHub notifications API client — fetch, parse, reason mapping, URL rewriting, mark-read"
affects:
  - 02-03 (poller.zig calls github.fetchNotifications and github.markRead)

# Tech tracking
tech-stack:
  added:
    - "std.http.Client (Zig 0.16): uses request()/sendBodiless()/receiveHead() pipeline"
    - "std.http.HeaderIterator: custom header iteration for Last-Modified and X-Poll-Interval"
    - "std.json.parseFromSlice: typed JSON parse into []NotificationJson with ignore_unknown_fields"
  patterns:
    - "HttpClient.get(): request + sendBodiless + receiveHead + HeaderIterator for non-standard headers"
    - "Bearer token: allocPrint temp buffer, freed after HTTP call (T-02-06 mitigation)"
    - "Response.appendRemaining(.limited(10MB)): body cap for T-02-08 DoS mitigation"
    - "fetchNotifications: 304 early-return skips JSON parse; 401 returns error.Unauthorized"
    - "apiUrlToWebUrl: replaceOwned /pulls/ → /pull/, falls back to dupe for unknown URLs"
    - "Zig 0.16 unmanaged ArrayList: deinit/append/toOwnedSlice all take explicit allocator"

key-files:
  created:
    - src/http.zig
    - src/github.zig
  modified:
    - src/root.zig
    - build.zig

key-decisions:
  - "Zig 0.16 std.http.Client requires io: std.Io; used std.Io.Threaded.global_single_threaded.io() for synchronous single-threaded HTTP"
  - "Zig 0.16 std.ArrayList is now unmanaged (no embedded allocator); all deinit/append/toOwnedSlice calls updated to pass allocator explicitly"
  - "std.http.Client.request()+sendBodiless()+receiveHead() replaces open()+send()+finish()+wait() from Zig 0.14"
  - "Custom header iteration via std.http.HeaderIterator.init(response.head.bytes) required since Last-Modified and X-Poll-Interval are not parsed by Head.parse()"
  - "test{} block added to root.zig to pull sub-module tests into build.zig test-unit step"
  - "build.zig test-unit step added to run all 7 Zig unit tests via root module"

requirements-completed: [GH-01, GH-02, GH-03, GH-04]

# Metrics
duration: 45min
completed: 2026-04-17
---

# Phase 02 Plan 02: HTTP Client + GitHub API Client Summary

**std.http.Client wrapper and GitHub notifications API client with full reason mapping, URL rewriting, and 304/401 fast-paths, adapted for Zig 0.16 API changes**

## Performance

- **Duration:** ~45 min
- **Completed:** 2026-04-17
- **Tasks:** 2
- **Files created:** 2 (src/http.zig, src/github.zig)
- **Files modified:** 2 (src/root.zig, build.zig)
- **Tests:** 7 unit tests pass (1 http + 3 github + 1 types + 2 store)

## Accomplishments

- Created `src/http.zig` — `HttpClient` wraps `std.http.Client` for GET and PATCH. Uses the lower-level `request()/sendBodiless()/receiveHead()` pipeline (not `fetch()`) so custom response headers are accessible. Iterates raw header bytes via `std.http.HeaderIterator` to extract `Last-Modified` (heap-duped) and `X-Poll-Interval` (parsed to u32). Body read via `appendRemaining` with a 10 MB cap.
- Created `src/github.zig` — `fetchNotifications` builds URL with `?participating=true`, sends `Authorization: Bearer`, `Accept`, `X-GitHub-Api-Version`, and optional `If-Modified-Since` headers. Returns `FetchResult` with `not_modified=true` on 304 (no JSON parse), `error.Unauthorized` on 401, and parsed `[]types.Notification` on 200. `reasonToNotifType` handles all 15 GitHub reason values. `apiUrlToWebUrl` rewrites `api.github.com/repos/.../pulls/N` → `github.com/.../pull/N`. `markRead` issues PATCH to `/notifications/threads/{api_id}`.
- Updated `src/root.zig` with `pub const http` and `pub const github` re-exports plus a `test{}` block for sub-module test discovery.
- Added `test-unit` step to `build.zig` (runs all Zig unit tests via `root.zig`).

## Task Commits

1. **Task 1: src/http.zig** — `e844da0` (feat)
2. **Task 2: src/github.zig + root.zig + build.zig** — `6aca6f8` (feat)

## Acceptance Criteria Verification

- [x] `src/http.zig` contains `pub const HttpClient = struct {`
- [x] `src/http.zig` contains `pub const Response = struct {`
- [x] `src/http.zig` contains `pub fn get(` and `pub fn patch(`
- [x] `src/http.zig` contains `Last-Modified`
- [x] `src/http.zig` contains `X-Poll-Interval`
- [x] `src/http.zig` does NOT contain `.fetch(` — uses lower-level API
- [x] `src/github.zig` contains `pub fn fetchNotifications(`
- [x] `src/github.zig` contains `pub fn markRead(`
- [x] `src/github.zig` contains `apiUrlToWebUrl(`
- [x] `src/github.zig` contains `participating=true`
- [x] `src/github.zig` contains all 15 reason strings (including `security_advisory_credit`)
- [x] `src/github.zig` contains `"If-Modified-Since"`
- [x] `src/root.zig` contains `@import("http.zig")` and `@import("github.zig")`
- [x] `zig build` exits 0
- [x] `zig build test-c` exits 0 (C ABI test still passes)
- [x] `zig build test-unit` exits 0 (7/7 unit tests pass)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Zig 0.16 std.http.Client API completely different from 0.14**
- **Found during:** Task 1 (implementing http.zig)
- **Issue:** Plan was written for Zig 0.14 where `std.http.Client` used `open()/send()/finish()/wait()` and `req.response.headers.getFirstValue()`. In Zig 0.16, the API changed to `request()/sendBodiless()/receiveHead(redirect_buf)`. Response headers are not stored in a `Headers` struct but in raw `response.head.bytes`, requiring manual iteration via `std.http.HeaderIterator`.
- **Fix:** Rewrote `HttpClient.get()` to use `request()/sendBodiless()/receiveHead()`. Used `std.http.HeaderIterator.init(response.head.bytes)` to find `Last-Modified` and `X-Poll-Interval` with case-insensitive comparison. Also: `std.http.Client` now requires `io: std.Io` field — provided via `std.Io.Threaded.global_single_threaded.io()` for synchronous HTTP.
- **Files modified:** src/http.zig
- **Verification:** `zig build` and unit tests pass
- **Committed in:** e844da0 (Task 1)

**2. [Rule 1 - Bug] Zig 0.16 std.ArrayList is now unmanaged**
- **Found during:** Task 1 (unit test compilation)
- **Issue:** `std.ArrayList(u8).init(allocator)` produced compile error: `struct 'array_list.Aligned(u8,null)' has no member named 'init'`. In Zig 0.16, `std.ArrayList` was changed to the unmanaged variant — no embedded allocator. Initialization is `.empty`, and `deinit`/`append`/`toOwnedSlice` all take an explicit allocator argument. The old managed list is now `std.array_list.Managed(T)` (deprecated).
- **Fix:** Changed all ArrayList usages to unmanaged API: `var body: std.ArrayList(u8) = .empty`, `body.deinit(allocator)`, `body.appendSlice(allocator, data)`, `notifications.append(allocator, item)`, `notifications.toOwnedSlice(allocator)`.
- **Files modified:** src/http.zig, src/github.zig
- **Verification:** All 7 unit tests pass
- **Committed in:** e844da0 (Task 1), 6aca6f8 (Task 2)

**3. [Rule 2 - Missing Critical] Added test{} block to root.zig for sub-module test discovery**
- **Found during:** Task 2 (verifying test coverage)
- **Issue:** `zig build test-unit` only found 1 test instead of 7. Zig's test runner only discovers tests in the root module unless `test {}` blocks or `std.testing.refAllDecls` explicitly reference sub-modules.
- **Fix:** Added `test { _ = @import("http.zig"); _ = @import("github.zig"); ... }` block to `root.zig`. Also added `test-unit` step to `build.zig`.
- **Files modified:** src/root.zig, build.zig
- **Verification:** `zig build test-unit --summary all` now reports 7/7 tests passed
- **Committed in:** 6aca6f8 (Task 2)

---

**Total deviations:** 3 auto-fixed (2 Zig 0.16 API changes, 1 missing test infrastructure)
**Impact on plan:** All deviations were Zig 0.16 API adaptations. Functional behavior is identical to the plan spec. No architectural changes.

## Threat Surface Scan

No new network endpoints beyond the documented GitHub API surface. No new auth paths. The Bearer token allocation pattern (allocPrint → use in headers → free after call) satisfies T-02-06 (token never stored in Notification or returned from fetchNotifications).

| Flag | File | Description |
|------|------|-------------|
| T-02-05 mitigated | src/github.zig | `parseFromSlice` with `.ignore_unknown_fields = true` — rejects malformed JSON |
| T-02-06 mitigated | src/github.zig | Bearer token freed after HTTP call; never in Notification fields |
| T-02-08 mitigated | src/http.zig | `appendRemaining(.limited(10MB))` — oversized response returns error |

## Known Stubs

None. Both modules are fully wired — `fetchNotifications` and `markRead` make real HTTP calls with real headers. No placeholder data.

## Self-Check: PASSED
