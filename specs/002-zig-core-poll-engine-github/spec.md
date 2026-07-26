# Feature Specification: Zig Core — Poll Engine + GitHub

**Feature Branch**: `002-zig-core-poll-engine-github`

**Created**: 2026-04-16 · **Migrated to Spec Kit**: 2026-07-26

**Status**: ✅ Complete (2026-04-27) — 5/5 roadmap success criteria verified; human UAT signed off (shipped tag `phase-02-complete`)

**Requirements**: CORE-03, CORE-04, CORE-05, CORE-06, CORE-07, CORE-08, GH-01, GH-02, GH-03, GH-04, GH-05

> Full port from GSD (this phase was completed under GSD after the migration branch was cut). The
> completed record lives in [`plan.md`](plan.md), [`research.md`](research.md), and
> [`tasks.md`](tasks.md); the shipped code is in `src/{types,http,github,poller,store,sqlite,c_api}.zig`,
> `vendor/sqlite/`, and `tests/core/poll_test.zig`.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Multi-account GitHub polling delivers grouped notifications (Priority: P1)

A user adds one or more GitHub accounts (each with a PAT); each polls independently on a background
thread, and the `on_update` callback fires with notifications grouped by repository.

**Why this priority**: This is the core engine — the first end-to-end proof that the C-ABI foundation
delivers real notification data to a shell. Everything visible to users depends on it.

**Independent Test**: A headless test harness adds two GitHub accounts; each polls independently and
`on_update` fires with notifications grouped by repository.

**Acceptance Scenarios**:

1. **Given** two configured GitHub accounts, **When** the poll engine runs, **Then** each polls independently and `on_update` fires with notifications grouped by repository. *(SC-001)*
2. **Given** an active poll loop, **When** GitHub returns `304 Not Modified`, **Then** no notifications are reprocessed and no rate-limit quota is consumed. *(SC-002)*
3. **Given** an unread notification, **When** the user marks it read, **Then** `PATCH /notifications/threads/:id` is issued and the next snapshot omits it. *(SC-003)*
4. **Given** persisted SQLite state, **When** the process restarts, **Then** read/unread state survives. *(SC-004)*
5. **Given** any account, **When** it is added, **Then** its token is delegated to the shell/keychain and never written to disk in plaintext. *(SC-005)*

### Edge Cases

- Token invalid/expired → surface an auth-error state; do not retry in a loop (verified more fully in Phase 6).
- `X-Poll-Interval` header larger than the configured interval → honor the server value.
- Concurrent poll-thread writes and main-thread reads of SQLite → WAL mode.

## Requirements *(mandatory)*

### Functional Requirements

- **CORE-03**: Poll engine runs on a background thread with a configurable interval; respects GitHub's `X-Poll-Interval` header dynamically.
- **CORE-04**: Per-account polling model — each account has independent state, token, base URL, last-seen timestamps, and unread list.
- **CORE-05**: Unified notification data model (a common struct across GitHub and GitLab).
- **CORE-06**: Notifications grouped by repository (client-side, in core).
- **CORE-07**: Read/unread state persisted locally via SQLite (WAL mode for concurrent read/write).
- **CORE-08**: Token storage via the system keychain, delegated to the shell over the ABI (macOS Security.framework; Linux libsecret). Core never persists tokens.
- **GH-01**: Add a GitHub account with a Personal Access Token.
- **GH-02**: Fetch all GitHub notification types (review_requested, assign, mention, team_mention, comment, ci_activity, state_change, approval_requested, …).
- **GH-03**: Poll GitHub using `If-Modified-Since` / `Last-Modified` conditional requests (304 doesn't consume rate limit).
- **GH-04**: Mark a GitHub notification as read (`PATCH /notifications/threads/:id`); it is removed from the list.
- **GH-05**: Add multiple GitHub accounts (personal + work); each polls independently.

### Key Entities

- **Account** — id, service, base_url, token (transient), poll interval, last-seen timestamps, unread list.
- **Notification** — unified model (id, account_id, type, state, repo, title, url, updated_at).
- **Snapshot** — immutable deep copy delivered to shells via the ABI.
- **State DB** — SQLite (WAL) persisting read/unread across restarts; never stores tokens.

## Success Criteria *(mandatory)*

All five verified via `zig build test-poll` (11 requirement checks, `ALL TESTS PASSED`) plus unit tests.

- **SC-001**: Headless harness adds two GitHub accounts; each polls independently; `on_update` fires with notifications grouped by repository. ✅
- **SC-002**: A 304 response neither reprocesses notifications nor consumes rate-limit quota. ✅ (mock tracks `Last-Modified`/`If-Modified-Since` per account; `not_modified` skips upsert)
- **SC-003**: Marking read issues `PATCH /notifications/threads/:id`; the notification is gone from the next snapshot. ✅
- **SC-004**: Read/unread state survives a process restart (stop/restart the harness with a pre-populated DB). ✅ (SQLite `is_read=1` persists across stop/reinit/restart)
- **SC-005**: Token storage delegates to the shell via the ABI callback; no token is written to disk in plaintext. ✅ (DB binary-searched for token strings — none found; no token field in any SQL)

## Assumptions & Open Flags (resolved)

- **`std.Thread` sufficiency (open flag from Phase 1)** — resolved: one `std.Thread` per account with an interruptible timed wait is sufficient at the 2–5 account scale.
- **Notable deviation:** `vrischmann/zig-sqlite` (the planned binding) was incompatible with Zig 0.16, so a custom `src/sqlite.zig` wrapper over the vendored SQLite 3.49.2 amalgamation (`vendor/sqlite/`) was used instead — identical API surface, no external `build.zig.zon` dependency.
- **Zig version:** plans were written for 0.14 but execution ran on 0.16.0; ~7 API adaptations were applied (unmanaged `ArrayList`, `std.Io` Mutex/RwLock, `std.http.Client` pipeline change, `std.time` removals). UAT surfaced a process-hang after `ALL TESTS PASSED` (background event-loop threads have no shutdown API); fixed with `std.process.exit(0)`.
- **CORE-08 scope:** Phase 2 satisfies "no token written to disk in plaintext." Full keychain storage (macOS Security.framework, Linux libsecret) is delivered by Phases 004 / 003.
- **UI hint:** no UI (headless engine + test harness).
- Built on the locked ABI from `specs/001-*/contracts/towncrier.h` — signatures unchanged (stubs replaced with real implementations).
