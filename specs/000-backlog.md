# Backlog: Post-v1 Requirements

Ideas deferred beyond v1. These are **not** scheduled and have no spec yet. When one is picked up,
promote it to its own `specs/NNN-*/` feature via `/speckit-specify`. Governance boundaries (what is
permanently out of scope) live in the constitution, not here.

Carried over from the GSD `REQUIREMENTS.md` v2 section during the Spec Kit migration.

## v2 — Authentication

- **AUTH-01**: Authenticate with GitHub via OAuth device flow (no PAT copy-paste required).
- **AUTH-02**: Authenticate with GitLab via OAuth device flow (GitLab 17.2+); fall back to PAT for older self-hosted instances.
- **AUTH-03**: Handle OAuth token expiry and refresh transparently; prompt re-auth only when refresh fails.

## v2 — Notification Control

- **NOTIF-01**: Filter notifications by type (e.g. show only review requests + assignments; hide CI noise).
- **NOTIF-02**: Mute a repository (suppress all notifications from it without leaving the app).
- **NOTIF-03**: Tray icon shows split unread counts per service (GitHub count / GitLab count).

## v2 — GitLab CI

- **CI-01**: Poll GitLab pipeline status for watched projects beyond the Todos API (covers pipelines on MRs you reviewed but didn't author).
- **CI-02**: Select which GitLab projects to watch for pipeline status.

---

**Note on filtering:** a *basic* type filter (NOTIF-01) is in scope for v2; a full notification
filtering DSL is permanently out of scope per the constitution.
