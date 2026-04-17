# Roadmap: Towncrier

## Overview

Towncrier is built in six phases that follow a strict dependency graph: scaffolding and the C ABI contract must exist before any feature code is written; the Zig core (GitHub + SQLite) is proven next; the Linux shell (Zig-native, faster iteration) validates the ABI end-to-end before the more complex macOS shell is added; GitLab integration is layered on top of a proven poll engine; and a final integration phase delivers end-to-end verification across both platforms. Each phase produces a testable, self-contained capability — nothing is left half-built between phases.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Core Scaffolding + ABI Contract** - Build system, static library, and C ABI header proven on both platforms
- [ ] **Phase 2: Zig Core — Poll Engine + GitHub** - Background polling, SQLite state, GitHub API client, and snapshot delivery
- [ ] **Phase 3: Linux Tray App** - D-Bus tray, GTK4 notification list, libsecret, and xdg-open on Linux
- [ ] **Phase 4: macOS Tray App** - NSStatusItem tray, XCFramework integration, Keychain, and browser launch on macOS
- [ ] **Phase 5: GitLab Integration** - Todos API client, self-hosted base URL, mark-as-done, multi-account GitLab
- [ ] **Phase 6: Integration + End-to-End Verification** - Both platforms work with both services; config screen; SNI probe UX

## Phase Details

### Phase 1: Core Scaffolding + ABI Contract
**Goal**: The Zig core builds as a static library on both macOS and Linux, the C ABI header documents ownership rules, and a minimal test binary exercises the lifecycle functions
**Depends on**: Nothing (first phase)
**Requirements**: CORE-01, CORE-02, CORE-09
**Success Criteria** (what must be TRUE):
  1. `zig build` on macOS produces `libtowncrier.a` without any GTK or Linux-specific symbol references
  2. `zig build` on Linux produces `libtowncrier.a` without any macOS-specific symbol references
  3. A minimal C test binary links against `libtowncrier.a`, calls `towncrier_init` / `towncrier_tick` / `towncrier_free`, and exits cleanly under Valgrind / ASAN with no leaks
  4. `towncrier.h` documents string ownership rules (who allocates, who frees, null-termination guarantee) and callback context lifecycle
**Plans**: 2 plans (01-01-PLAN.md, 01-02-PLAN.md)
Plans:
- [x] 01-01-PLAN.md — Build system scaffold, ABI header, and Zig stub implementations
- [x] 01-02-PLAN.md — ASAN validation, symbol verification, and human sign-off

### Phase 2: Zig Core — Poll Engine + GitHub
**Goal**: The background poll engine runs per-account threads that fetch GitHub notifications, persist state in SQLite, and deliver snapshots to the shell via ABI callbacks
**Depends on**: Phase 1
**Requirements**: CORE-03, CORE-04, CORE-05, CORE-06, CORE-07, CORE-08, GH-01, GH-02, GH-03, GH-04, GH-05
**Success Criteria** (what must be TRUE):
  1. A headless test harness can add two GitHub accounts; each polls independently and the `on_update` callback fires with notifications grouped by repository
  2. Polling uses `If-Modified-Since` / `Last-Modified` headers; a 304 response does not re-process notifications and does not consume rate-limit quota
  3. Marking a notification as read issues `PATCH /notifications/threads/:id`; subsequent snapshot no longer includes that notification
  4. Read/unread state survives process restart (verified by stopping and restarting the test harness with pre-populated SQLite DB)
  5. Token storage delegates to the platform shell via the ABI callback; no token is written to disk in plaintext
**Plans**: 5 plans
Plans:
- [x] 02-01-PLAN.md — Data model (types.zig), SQLite store, zig-sqlite dependency
- [x] 02-02-PLAN.md — HTTP wrapper (http.zig), GitHub API client (github.zig)
- [x] 02-03-PLAN.md — Poll engine thread loop (poller.zig)
- [x] 02-04-PLAN.md — C ABI wiring — replace all stubs with real implementations
- [ ] 02-05-PLAN.md — Test harness: mock server + integration assertions for all 11 requirements
**UI hint**: no

### Phase 3: Linux Tray App
**Goal**: The Linux executable renders live GitHub notifications in a GTK4 popover via a D-Bus SNI tray icon, stores tokens in libsecret, and opens notifications in the browser
**Depends on**: Phase 2
**Requirements**: LINUX-01, LINUX-02, LINUX-03, LINUX-04, LINUX-05, LINUX-06
**Success Criteria** (what must be TRUE):
  1. The tray icon appears on KDE, Cinnamon, and Sway; the unread count badge reflects live data from the poll engine
  2. Clicking the tray icon opens a GTK4 popover listing all unread notifications grouped by repository
  3. Clicking a notification opens the correct URL in the default browser (`xdg-open`) and removes the notification from the list
  4. The config screen (accessible from the tray menu) lets the user add or remove a GitHub account by entering a PAT; the account immediately begins polling
  5. On a desktop without `org.kde.StatusNotifierWatcher` on D-Bus, the app shows a clear user-facing message at startup instead of silently failing
**Plans**: TBD
**UI hint**: yes

### Phase 4: macOS Tray App
**Goal**: The macOS app renders live GitHub notifications in an NSMenu popover via NSStatusItem, stores tokens in Keychain, and opens notifications in the browser — distributed as a universal binary XCFramework
**Depends on**: Phase 2
**Requirements**: MAC-01, MAC-02, MAC-03, MAC-04, MAC-05, MAC-06
**Success Criteria** (what must be TRUE):
  1. The app launches as a tray-only process (no Dock icon); the status bar icon shows the live unread count badge
  2. Clicking the status bar icon opens a popover listing unread notifications grouped by repository; the list updates when new notifications arrive
  3. Clicking a notification opens it in the default browser and removes it from the list
  4. The config screen (accessible from the tray menu) allows adding a GitHub account via PAT; the PAT is stored in Keychain and never written to disk
  5. The Xcode project links `libtowncrier.xcframework` containing universal binaries for arm64 and x86_64; the app runs natively on both Apple Silicon and Intel Macs
**Plans**: TBD
**UI hint**: yes

### Phase 5: GitLab Integration
**Goal**: The poll engine gains a GitLab Todos API client; users can add GitLab accounts (gitlab.com and self-hosted) on both platforms; notifications from GitHub and GitLab appear together in the tray
**Depends on**: Phase 4
**Requirements**: GL-01, GL-02, GL-03, GL-04, GL-05
**Success Criteria** (what must be TRUE):
  1. A headless test harness can add a GitLab account with a configurable base URL; the Todos API is polled using `updated_after` for delta fetching
  2. All GitLab todo types (assigned, mentioned, directly_addressed, approval_required, build_failed, unmergeable, merge_train_removed) appear as notifications
  3. Marking a GitLab todo as done issues `POST /todos/:id/mark_as_done`; the notification is removed from the next snapshot
  4. On both Linux and macOS, the config screen accepts a GitLab account with a custom base URL; a self-hosted instance can be added alongside gitlab.com accounts
  5. Multiple GitLab accounts poll independently; notifications from all accounts appear in the tray merged with GitHub notifications
**Plans**: TBD

### Phase 6: Integration + End-to-End Verification
**Goal**: Both platforms work correctly with both services simultaneously; edge cases (SNI probe, token expiry signaling, rate-limit handling) are verified; the product is releasable
**Depends on**: Phase 5
**Requirements**: (no new requirements — cross-cutting verification of all prior phases)
**Success Criteria** (what must be TRUE):
  1. On Linux with both a GitHub and a GitLab account configured, all notifications appear grouped by repository in the tray with correct unread counts
  2. On macOS with both a GitHub and a GitLab account configured, all notifications appear in the popover; marking items read on either service persists across app restarts
  3. When a token is invalid or expired, the poll engine surfaces an auth-error state to the UI and stops polling for that account — it does not retry in a loop
  4. Adding, removing, and re-adding accounts on both platforms leaves no orphaned state in SQLite or the system keychain
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Core Scaffolding + ABI Contract | 2/2 | Complete   | 2026-04-16 |
| 2. Zig Core — Poll Engine + GitHub | 0/5 | Not started | - |
| 3. Linux Tray App | 0/TBD | Not started | - |
| 4. macOS Tray App | 0/TBD | Not started | - |
| 5. GitLab Integration | 0/TBD | Not started | - |
| 6. Integration + End-to-End Verification | 0/TBD | Not started | - |
