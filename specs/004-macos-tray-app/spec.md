# Feature Specification: macOS Tray App

**Feature Branch**: `004-macos-tray-app`

**Created**: 2026-04-16 · **Migrated to Spec Kit**: 2026-07-26

**Status**: Not started (Depends on: 002)

**Requirements**: MAC-01, MAC-02, MAC-03, MAC-04, MAC-05, MAC-06

> `plan.md` and `tasks.md` will be generated via `/speckit-plan` and `/speckit-tasks` when this
> phase is started. This spec is the migrated roadmap detail. **UI phase.**

## User Scenarios & Testing *(mandatory)*

The macOS app renders live GitHub notifications in an NSMenu popover via NSStatusItem, stores tokens
in Keychain, opens notifications in the browser, and ships as a universal-binary XCFramework. It
comes after the Linux shell so the ABI callbacks are already proven before adding Swift bridging.

### User Story 1 - Tray-only app with live badge (Priority: P1)

**Independent Test**: The app launches with no Dock icon; the status-bar icon shows the live unread
count badge.

**Acceptance Scenarios**:

1. **Given** the app launches, **When** it starts, **Then** it runs as a tray-only process (no Dock icon) and the status-bar icon shows the live unread count. *(SC-001)*

### User Story 2 - Popover list grouped by repository (Priority: P1)

**Acceptance Scenarios**:

1. **Given** the status-bar icon, **When** the user clicks it, **Then** a popover lists unread notifications grouped by repository and updates as new ones arrive. *(SC-002)*
2. **Given** a notification, **When** the user clicks it, **Then** it opens in the default browser and is removed from the list. *(SC-003)*

### User Story 3 - Account config + Keychain (Priority: P2)

**Acceptance Scenarios**:

1. **Given** the tray menu, **When** the user adds a GitHub account via PAT, **Then** the PAT is stored in Keychain and never written to disk. *(SC-004)*

### User Story 4 - Universal-binary packaging (Priority: P1)

**Acceptance Scenarios**:

1. **Given** the Xcode project, **When** it links `libtowncrier.xcframework` (arm64 + x86_64), **Then** the app runs natively on Apple Silicon and Intel. *(SC-005)*

### Edge Cases

- Callbacks fire from the poll thread → marshal to the main thread (`DispatchQueue.main.async`) before UI access; keep `userdata` alive via `Unmanaged<T>.passRetained` (per header rules).
- Tokens live only in Keychain (Constitution IV).

## Requirements *(mandatory)*

### Functional Requirements

- **MAC-01**: Run as a macOS tray application (NSStatusItem/AppKit) — no Dock icon.
- **MAC-02**: Tray icon shows an unread-count badge; badge clears when all are read.
- **MAC-03**: Clicking the tray icon opens a popover/panel listing unread notifications grouped by repository.
- **MAC-04**: Clicking a notification opens it in the default browser and marks it read.
- **MAC-05**: Config screen (from the tray menu) — add/remove accounts, enter tokens, set GitLab base URLs.
- **MAC-06**: Package the Zig core as an XCFramework (universal binary: arm64 + x86_64) consumed by the Swift/Xcode project.

## Success Criteria *(mandatory)*

- **SC-001**: App launches tray-only (no Dock icon); status-bar icon shows the live unread badge.
- **SC-002**: Clicking the icon opens a popover listing unread notifications grouped by repository; the list updates on new arrivals.
- **SC-003**: Clicking a notification opens it in the browser and removes it from the list.
- **SC-004**: The config screen adds a GitHub account via PAT; the PAT is stored in Keychain and never written to disk.
- **SC-005**: The Xcode project links `libtowncrier.xcframework` (arm64 + x86_64); the app runs natively on both architectures.

## Assumptions & Open Flags

- **UI hint:** yes. NSStatusItem directly (not SwiftUI MenuBarExtra) per CLAUDE.md; Keychain via Security.framework or keychain-swift.
- Packaging path: `zig build` → `.a` → `libtool` → `lipo` universal → `xcodebuild -create-xcframework` (Ghostty pattern).
- Depends on the poll engine from Phase 002; consumes the locked ABI via the XCFramework.
