# Feature Specification: Linux Tray App

**Feature Branch**: `003-linux-tray-app`

**Created**: 2026-04-16 · **Migrated to Spec Kit**: 2026-07-26

**Status**: Not started (Depends on: 002)

**Requirements**: LINUX-01, LINUX-02, LINUX-03, LINUX-04, LINUX-05, LINUX-06

> `plan.md` and `tasks.md` will be generated via `/speckit-plan` and `/speckit-tasks` when this
> phase is started. This spec is the migrated roadmap detail. **UI phase.**

## Clarifications

### Session 2026-07-26

- Q: Tray implementation — `libstray` v0.4.0 or hand-rolled D-Bus SNI? → A: Depend on `libstray` v0.4.0, wrapped behind a thin internal `Tray` interface so a swap stays possible.
- Q: GTK4 UI — `zig-gobject` bindings or direct C calls via `@cImport`? → A: Direct GTK4 C API via `@cImport` (no bindings layer; lower risk for a small UI surface).
- Q: Config screen — include GitLab fields now, or GitHub-only? → A: GitHub-only in Phase 3; Phase 5 extends the config screen with GitLab base-URL fields when the GitLab client exists.

## User Scenarios & Testing *(mandatory)*

The Linux executable renders live GitHub notifications in a GTK4 popover via a D-Bus StatusNotifierItem
(SNI) tray icon, stores tokens in libsecret, and opens notifications in the browser. The Zig-native
shell is built before the macOS shell because it iterates faster and proves the ABI callbacks
end-to-end before Swift bridging complexity.

### User Story 1 - Live tray icon with unread badge (Priority: P1)

**Independent Test**: The tray icon appears on KDE, Cinnamon, and Sway; the unread-count badge
reflects live data from the poll engine.

**Acceptance Scenarios**:

1. **Given** a running app on KDE/Cinnamon/Sway, **When** the poll engine reports unread items, **Then** the tray icon shows a badge reflecting live counts. *(SC-001)*

### User Story 2 - Popover list grouped by repository (Priority: P1)

**Acceptance Scenarios**:

1. **Given** the tray icon, **When** the user clicks it, **Then** a GTK4 popover opens listing all unread notifications grouped by repository. *(SC-002)*
2. **Given** a notification in the list, **When** the user clicks it, **Then** the correct URL opens via `xdg-open` and the item is removed from the list. *(SC-003)*

### User Story 3 - Account config from the tray (Priority: P2)

**Acceptance Scenarios**:

1. **Given** the tray menu, **When** the user opens the config screen and enters a PAT, **Then** the account is added and immediately begins polling. *(SC-004)*

### Edge Cases

- No `org.kde.StatusNotifierWatcher` on D-Bus → show a clear user-facing message at startup instead of silently failing. *(SC-005)*
- Tokens are stored via libsecret (Secret Service), never plaintext (Constitution IV).

## Requirements *(mandatory)*

### Functional Requirements

- **LINUX-01**: Run as a Linux tray app using the StatusNotifierItem D-Bus protocol (via libstray); works on KDE, Cinnamon, Sway, and GNOME with the AppIndicator extension.
- **LINUX-02**: Tray icon shows an unread-count badge; badge clears when all are read.
- **LINUX-03**: Clicking the tray icon opens a GTK4 popover/window listing unread notifications grouped by repository.
- **LINUX-04**: Clicking a notification opens it in the default browser (`xdg-open`) and marks it read.
- **LINUX-05**: Config screen (from the tray menu) — add/remove **GitHub** accounts and enter their PATs. (GitLab base-URL fields are deferred to Phase 5, when the GitLab client exists; per GL-04 the config screen is extended then.)
- **LINUX-06**: At startup, detect if no SNI host (`org.kde.StatusNotifierWatcher`) is present on D-Bus and show a user-facing explanation.

## Success Criteria *(mandatory)*

- **SC-001**: Tray icon appears on KDE, Cinnamon, and Sway; badge reflects live poll-engine data.
- **SC-002**: Clicking the tray icon opens a GTK4 popover listing unread notifications grouped by repository.
- **SC-003**: Clicking a notification opens the correct URL (`xdg-open`) and removes it from the list.
- **SC-004**: The config screen adds/removes a GitHub account via PAT; the account immediately begins polling.
- **SC-005**: With no `org.kde.StatusNotifierWatcher` on D-Bus, the app shows a clear message at startup instead of failing silently.

## Assumptions & Open Flags

- **Tray implementation (resolved 2026-07-26):** depend on `libstray` v0.4.0 via `build.zig.zon`, wrapped behind a thin internal `Tray` interface so the shell can swap to a hand-rolled D-Bus SNI implementation if a production blocker appears. GTK4 dropped `GtkStatusIcon` and `libayatana-appindicator` is GTK3-only, so SNI-over-D-Bus is required either way; `libstray` provides it without a GTK/GLib/Qt dependency.
- **UI hint:** yes. Tray via libstray (SNI over D-Bus, no GTK); windowed UI via GTK4 called through direct C API (`@cImport("gtk/gtk.h")`, no `zig-gobject` bindings layer) — kept decoupled per CLAUDE.md.
- Consumes the core `libtowncrier.a` directly (Zig-native shell); depends on the poll engine from Phase 002.
