# Feature Specification: GitLab Integration

**Feature Branch**: `005-gitlab-integration`

**Created**: 2026-04-16 · **Migrated to Spec Kit**: 2026-07-26

**Status**: Not started (Depends on: 004)

**Requirements**: GL-01, GL-02, GL-03, GL-04, GL-05

> `plan.md` and `tasks.md` will be generated via `/speckit-plan` and `/speckit-tasks` when this
> phase is started. This spec is the migrated roadmap detail.

## User Scenarios & Testing *(mandatory)*

The poll engine gains a GitLab Todos API client; users add GitLab accounts (gitlab.com and
self-hosted) on both platforms; GitHub and GitLab notifications appear together in the tray. GitLab
comes after GitHub because the simpler GitHub API proves the poll-engine pattern first.

### User Story 1 - Poll GitLab Todos with a configurable base URL (Priority: P1)

**Independent Test**: A headless harness adds a GitLab account with a configurable base URL; the
Todos API is polled using `updated_after` for delta fetching.

**Acceptance Scenarios**:

1. **Given** a GitLab account with a base URL, **When** the engine polls, **Then** the Todos API is queried using `updated_after` for delta fetching. *(SC-001)*
2. **Given** GitLab todos, **When** they are fetched, **Then** all todo types appear as notifications. *(SC-002)*
3. **Given** a todo, **When** the user marks it done, **Then** `POST /todos/:id/mark_as_done` is issued and it is removed from the next snapshot. *(SC-003)*

### User Story 2 - Self-hosted + multi-account (Priority: P1)

**Acceptance Scenarios**:

1. **Given** the config screen on Linux and macOS, **When** the user adds a GitLab account with a custom base URL, **Then** a self-hosted instance can run alongside gitlab.com accounts. *(SC-004)*
2. **Given** multiple GitLab accounts, **When** they poll, **Then** each polls independently and all notifications merge with GitHub in the tray. *(SC-005)*

### Edge Cases

- `build_failed` and other pipeline-related todo types — confirm Todos API coverage is sufficient (see open flag) rather than needing full Pipelines API polling (that is a v2 item, CI-01).
- Self-hosted base URLs must be honored exactly (no assumption of gitlab.com).

## Requirements *(mandatory)*

### Functional Requirements

- **GL-01**: Add a GitLab account with a PAT and a configurable base URL (gitlab.com and self-hosted).
- **GL-02**: Fetch all GitLab todo types (assigned, mentioned, directly_addressed, approval_required, build_failed, unmergeable, merge_train_removed).
- **GL-03**: Poll the GitLab Todos API with `updated_after` for efficient delta fetching.
- **GL-04**: Mark a GitLab todo as done (`POST /todos/:id/mark_as_done`); it is removed from the list.
- **GL-05**: Add multiple GitLab accounts (each with independent URL + token); each polls independently.

## Success Criteria *(mandatory)*

- **SC-001**: Headless harness adds a GitLab account with a configurable base URL; Todos API polled via `updated_after`.
- **SC-002**: All GitLab todo types appear as notifications.
- **SC-003**: Marking a todo done issues `POST /todos/:id/mark_as_done`; it is removed from the next snapshot.
- **SC-004**: On both Linux and macOS, the config screen accepts a GitLab account with a custom base URL alongside gitlab.com.
- **SC-005**: Multiple GitLab accounts poll independently; all notifications merge with GitHub in the tray.

## Assumptions & Open Flags

- **Open product decision (carried from Phase 1 sign-off):** confirm whether `build_failed` Todos API coverage is sufficient, or full Pipelines API polling is needed, before starting this phase. Resolve during `/speckit-plan`/`/speckit-clarify`.
- Reuses the unified notification model and per-account polling built in Phase 002.
- The `/notification_settings` API is explicitly out of scope (constitution) — the Todos API is the correct endpoint.
