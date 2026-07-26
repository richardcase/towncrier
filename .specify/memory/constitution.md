# Towncrier Constitution

Towncrier is a cross-platform tray application that aggregates GitHub and GitLab
notifications in one place. It runs as a system tray app on macOS (Swift/Xcode) and
Linux (Zig/GTK), with a shared Zig core library handling all API communication,
notification state, and business logic — the same libcore + platform-shell architecture
used by Ghostty.

**Core value:** Developers can see all their GitHub and GitLab notifications at a glance,
grouped by repository, and act on them (open in browser + mark read) without leaving their
current context.

These principles are non-negotiable. Every spec, plan, and task MUST comply; `/speckit-analyze`
checks artifacts against them, and any deviation MUST be justified in the plan's Complexity
Tracking section or the deviation is rejected.

## Core Principles

### I. Zig Core, C-ABI Boundary (NON-NEGOTIABLE)

All API logic, data models, polling, and notification state live in a single Zig core library
(`libtowncrier.a`) that exposes a stable C ABI. Platform shells consume the core **only** through
that C ABI — never by reaching into Zig internals. The C header (`include/towncrier.h`) is the
contract; changes to it after it is locked are ABI breaks and MUST be treated as such. This is the
critical design surface and the reason the project can share one brain across two platforms.

### II. Platform Shells Are Thin

Platform code handles UI rendering and OS integration (tray, keychain, browser launch) and nothing
else. No business logic, no API calls, no state management in a shell. The macOS shell is
**Swift/Xcode** (NSStatusItem/AppKit — native tray access). The Linux shell is **Zig + GTK4** with
`libstray` for the tray (consistent core language, no extra runtime deps). A shell must remain
replaceable without touching core logic.

### III. Build-Time Platform Isolation

Platform-specific dependencies (GTK, libstray, libsecret on Linux; Security.framework/AppKit on
macOS) are gated in `build.zig` by target detection (`target.result.os.tag == .linux`), never by
`@import("builtin")` OS checks scattered through library source. The macOS build MUST NOT reference
GTK/Linux symbols and vice versa. The core library itself has zero platform-specific dependencies.

### IV. Tokens Live Only in the System Keychain (NON-NEGOTIABLE)

Access tokens (PAT or OAuth) are stored in the OS keychain — macOS Security.framework, Linux Secret
Service via libsecret — and **never** written to disk in plaintext, config files, logs, or the
SQLite state DB. The core does not persist tokens; the shell reads them from the keychain and passes
them across the ABI for the duration of a poll session only. Any spec that persists a token anywhere
else violates this constitution.

### V. Poll, Don't Push; Be a Good API Citizen

Notification delivery is by polling with conditional requests — GitHub `If-Modified-Since` /
`Last-Modified` and `X-Poll-Interval`, GitLab Todos `updated_after`. No webhooks, no server-side
component (this is what keeps distribution server-free). Polling MUST respect rate limits: a 304
response must not reprocess data or consume quota, and dynamic poll-interval headers are honored.

## Scope Boundaries

The following are explicitly **out of scope**. A spec proposing any of these MUST be rejected unless
this constitution is first amended:

- **Windows support** — two-platform (macOS + Linux) scope is already complex; no Windows shell/keychain.
- **Webhook-based push delivery** — eliminates the server-free advantage; polling is sufficient.
- **Desktop OS notification popups (system banners)** — invasive UX + per-OS permission management; the tray badge is the signal.
- **In-app thread replies / comments** — opening in the browser covers all interaction beyond mark-read; this is not a Git client.
- **Repository browsing or search** — notifications only.
- **Email/Slack notification forwarding** — users already have those channels.
- **GitLab `/notification_settings` API** — that is account preferences, not notification events; the Todos API is correct.
- **Full notification filtering DSL** — a basic type filter (a v2 item) covers the common case.

Post-v1 ideas are tracked in `specs/000-backlog.md`, not here.

## Technology & Governance

**Technology reference.** The authoritative, versioned technology stack (Zig 0.14 baseline, stdlib
`std.http`/`std.json`, GTK4 + libstray + libsecret, keychain-swift/Security.framework, XCFramework
packaging, and the rationale/confidence for each) lives in `CLAUDE.md` and `docs/research/`. Those
documents are reference; this constitution governs. Where they conflict on a *principle*, the
constitution wins; where they differ on a *version or library detail*, the reference documents win.

**Governance.** This constitution supersedes ad-hoc practices. The Spec Kit workflow is the path for
all planned work: `/speckit-constitution` → `/speckit-specify` → (`/speckit-clarify`) → `/speckit-plan`
→ `/speckit-tasks` → (`/speckit-analyze`) → `/speckit-implement`. Amendments require updating this
file with a version bump and a note in the amendment history. Complexity or deviation from a principle
MUST be justified in the affected plan's Complexity Tracking table.

**Version**: 1.0.0 | **Ratified**: 2026-07-26 | **Last Amended**: 2026-07-26

<!--
Amendment history:
- 1.0.0 (2026-07-26): Initial ratification. Migrated from GSD planning artifacts
  (.planning/PROJECT.md, REQUIREMENTS.md, and CLAUDE.md constraints) into the Spec Kit
  constitution format. Principles derived from the project's locked architectural constraints;
  scope boundaries from the v1 Out-of-Scope table.
-->
