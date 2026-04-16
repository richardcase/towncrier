# Requirements: Towncrier

**Defined:** 2026-04-16
**Core Value:** Developers can see all their GitHub and GitLab notifications at a glance, grouped by repository, and act on them (open in browser + mark read) without leaving their current context.

## v1 Requirements

### Core Library

- [x] **CORE-01**: Zig core library builds as a static library with a stable C ABI header
- [x] **CORE-02**: C ABI exposes lifecycle functions (init, tick, free) and a snapshot pattern for safe cross-thread data access
- [ ] **CORE-03**: Poll engine runs on a background thread with configurable interval; respects GitHub's `X-Poll-Interval` header dynamically
- [ ] **CORE-04**: Per-account polling model — each account has independent state, token, base URL, last-seen timestamps, and unread list
- [ ] **CORE-05**: Unified notification data model (common struct across GitHub and GitLab notifications)
- [ ] **CORE-06**: Notifications grouped by repository (client-side, in core)
- [ ] **CORE-07**: Read/unread state persisted locally via SQLite (WAL mode for concurrent read/write)
- [ ] **CORE-08**: Token storage via system keychain (macOS Security.framework via Swift shell; Linux Secret Service via libsecret)
- [x] **CORE-09**: build.zig supports multi-platform compilation; GTK/Linux-specific dependencies are OS-gated (macOS build never references GTK)

### GitHub Integration

- [ ] **GH-01**: User can add a GitHub account with a Personal Access Token
- [ ] **GH-02**: App fetches all GitHub notification types (review_requested, assign, mention, team_mention, comment, ci_activity, state_change, approval_requested, and others)
- [ ] **GH-03**: App polls GitHub using `If-Modified-Since` / `Last-Modified` conditional requests (304 responses don't consume rate limit)
- [ ] **GH-04**: User can mark a GitHub notification as read (PATCH /notifications/threads/:id); notification is removed from the list
- [ ] **GH-05**: User can add multiple GitHub accounts (personal + work); each polls independently

### GitLab Integration

- [ ] **GL-01**: User can add a GitLab account with a Personal Access Token and a configurable base URL (supports gitlab.com and self-hosted instances)
- [ ] **GL-02**: App fetches all GitLab todo types (assigned, mentioned, directly_addressed, approval_required, build_failed, unmergeable, merge_train_removed)
- [ ] **GL-03**: App polls GitLab Todos API with `updated_after` timestamp for efficient delta fetching
- [ ] **GL-04**: User can mark a GitLab todo as done (POST /todos/:id/mark_as_done); notification is removed from the list
- [ ] **GL-05**: User can add multiple GitLab accounts (each with independent URL + token); each polls independently

### macOS App

- [ ] **MAC-01**: App runs as a macOS tray application (NSStatusItem/AppKit) — no Dock icon
- [ ] **MAC-02**: Tray icon shows unread notification count badge; badge clears when all notifications are read
- [ ] **MAC-03**: Clicking the tray icon opens a popover/panel listing all unread notifications grouped by repository
- [ ] **MAC-04**: Clicking a notification opens it in the default browser and marks it as read
- [ ] **MAC-05**: Config screen accessible from the tray menu — user can add/remove accounts, enter tokens, set GitLab base URLs
- [ ] **MAC-06**: Zig core library is packaged as an XCFramework (universal binary: arm64 + x86_64) consumed by the Swift/Xcode project

### Linux App

- [ ] **LINUX-01**: App runs as a Linux tray application using the StatusNotifierItem D-Bus protocol (via libstray); works on KDE, Cinnamon, Sway, and GNOME with AppIndicator extension
- [ ] **LINUX-02**: Tray icon shows unread notification count badge; badge clears when all notifications are read
- [ ] **LINUX-03**: Clicking the tray icon opens a GTK4 popover/window listing all unread notifications grouped by repository
- [ ] **LINUX-04**: Clicking a notification opens it in the default browser (`xdg-open`) and marks it as read
- [ ] **LINUX-05**: Config screen accessible from the tray menu — user can add/remove accounts, enter tokens, set GitLab base URLs
- [ ] **LINUX-06**: App detects at startup if no SNI host (`org.kde.StatusNotifierWatcher`) is present on D-Bus and shows a user-facing explanation

## v2 Requirements

### Authentication

- **AUTH-01**: User can authenticate with GitHub via OAuth device flow (no copy-paste of PAT required)
- **AUTH-02**: User can authenticate with GitLab via OAuth device flow (GitLab 17.2+); falls back to PAT for older self-hosted instances
- **AUTH-03**: App handles OAuth token expiry and refresh transparently; prompts re-auth only when refresh fails

### Notification Control

- **NOTIF-01**: User can filter notifications by type (e.g. show only review requests + assignments; hide CI noise)
- **NOTIF-02**: User can mute a repository (suppress all notifications from it without leaving the app)
- **NOTIF-03**: Tray icon shows split unread counts per service (GitHub count / GitLab count)

### GitLab CI

- **CI-01**: App polls GitLab pipeline status for watched projects beyond the Todos API (covers pipelines on MRs you reviewed but didn't author)
- **CI-02**: User can select which GitLab projects to watch for pipeline status

## Out of Scope

| Feature | Reason |
|---------|--------|
| Windows support | Not requested; adds a third shell + third keychain integration; target audience is macOS/Linux |
| Webhook-based push delivery | Eliminates server-free distribution advantage; polling with conditional requests is efficient enough |
| Desktop OS notification popups (system banners) | Invasive UX; per-OS permission management; tray badge is sufficient signal for v1 |
| In-app thread replies / comments | Turns the app into a GitHub/GitLab client; open in browser for all interactions beyond mark-read |
| Repository browsing or search | This is not a Git client; notifications only |
| Email/Slack notification forwarding | Scope creep; users already have those channels |
| GitLab `/notification_settings` API | This is account preference settings, NOT notification events; Todos API is the correct endpoint |
| Full notification filtering DSL | High complexity; basic type filter (v2) covers 90% of use cases |
| Auto-refresh token rotation daemon | Daemon adds complexity; prompt re-auth on token expiry is sufficient |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| CORE-01 | Phase 1 | Complete |
| CORE-02 | Phase 1 | Complete |
| CORE-09 | Phase 1 | Complete |
| CORE-03 | Phase 2 | Pending |
| CORE-04 | Phase 2 | Pending |
| CORE-05 | Phase 2 | Pending |
| CORE-06 | Phase 2 | Pending |
| CORE-07 | Phase 2 | Pending |
| CORE-08 | Phase 2 | Pending |
| GH-01 | Phase 2 | Pending |
| GH-02 | Phase 2 | Pending |
| GH-03 | Phase 2 | Pending |
| GH-04 | Phase 2 | Pending |
| GH-05 | Phase 2 | Pending |
| LINUX-01 | Phase 3 | Pending |
| LINUX-02 | Phase 3 | Pending |
| LINUX-03 | Phase 3 | Pending |
| LINUX-04 | Phase 3 | Pending |
| LINUX-05 | Phase 3 | Pending |
| LINUX-06 | Phase 3 | Pending |
| MAC-01 | Phase 4 | Pending |
| MAC-02 | Phase 4 | Pending |
| MAC-03 | Phase 4 | Pending |
| MAC-04 | Phase 4 | Pending |
| MAC-05 | Phase 4 | Pending |
| MAC-06 | Phase 4 | Pending |
| GL-01 | Phase 5 | Pending |
| GL-02 | Phase 5 | Pending |
| GL-03 | Phase 5 | Pending |
| GL-04 | Phase 5 | Pending |
| GL-05 | Phase 5 | Pending |

**Coverage:**
- v1 requirements: 31 total
- Mapped to phases: 31 (Phases 1-5; Phase 6 is cross-cutting verification)
- Unmapped: 0 ✓

---
*Requirements defined: 2026-04-16*
*Last updated: 2026-04-16 after roadmap creation*
