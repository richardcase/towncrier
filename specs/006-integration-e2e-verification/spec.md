# Feature Specification: Integration + End-to-End Verification

**Feature Branch**: `006-integration-e2e-verification`

**Created**: 2026-04-16 · **Migrated to Spec Kit**: 2026-07-26

**Status**: Not started (Depends on: 005)

**Requirements**: None new — cross-cutting verification of all prior phases (CORE/GH/GL/MAC/LINUX).

> `plan.md` and `tasks.md` will be generated via `/speckit-plan` and `/speckit-tasks` when this
> phase is started. This spec is the migrated roadmap detail. This phase adds **no new
> requirements**; it verifies that everything built in Phases 001–005 works together and hardens the
> edge cases, so the product is releasable.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Both services on Linux, grouped and counted (Priority: P1)

**Acceptance Scenarios**:

1. **Given** a Linux install with a GitHub and a GitLab account, **When** the app runs, **Then** all notifications appear grouped by repository with correct unread counts. *(SC-001)*

### User Story 2 - Both services on macOS, persistent across restart (Priority: P1)

**Acceptance Scenarios**:

1. **Given** a macOS install with a GitHub and a GitLab account, **When** the user marks items read on either service, **Then** all notifications appear in the popover and read state persists across app restarts. *(SC-002)*

### User Story 3 - Auth-error handling without retry loops (Priority: P1)

**Acceptance Scenarios**:

1. **Given** an invalid or expired token, **When** the engine polls, **Then** it surfaces an auth-error state to the UI and stops polling that account — it does not retry in a loop. *(SC-003)*

### User Story 4 - Clean account lifecycle (Priority: P2)

**Acceptance Scenarios**:

1. **Given** adding, removing, and re-adding accounts on both platforms, **When** the operations complete, **Then** no orphaned state remains in SQLite or the system keychain. *(SC-004)*

### Edge Cases

- SNI probe UX on Linux (from LINUX-06) exercised end-to-end.
- Rate-limit handling under real load across both services.
- Token expiry signaling surfaced consistently on both shells.

## Requirements *(mandatory)*

No new functional requirements. This phase verifies the full v1 requirement set (all 31 IDs across
CORE-/GH-/GL-/MAC-/LINUX-) works together, and delivers the config screen polish and SNI probe UX
called out in the roadmap.

## Success Criteria *(mandatory)*

- **SC-001**: On Linux with a GitHub + GitLab account, all notifications appear grouped by repository with correct unread counts.
- **SC-002**: On macOS with a GitHub + GitLab account, all notifications appear in the popover; marking read on either service persists across restarts.
- **SC-003**: An invalid/expired token surfaces an auth-error state and stops polling that account — no retry loop.
- **SC-004**: Adding, removing, and re-adding accounts on both platforms leaves no orphaned state in SQLite or the keychain.

## Assumptions & Open Flags

- Pure verification/hardening phase — depends on all of 001–005 being complete.
- No new ABI surface; any gap found here that requires an ABI change is a red flag against Constitution Principle I and must be escalated, not silently patched.
