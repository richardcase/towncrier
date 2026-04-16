# Towncrier

## What This Is

Towncrier is a cross-platform tray application that aggregates GitHub and GitLab notifications in one place. It runs as a system tray app on macOS (Swift/Xcode) and Linux (GTK/Zig), with a shared Zig core library handling all API communication, notification state, and business logic — following the same libcore + platform-shell architecture used by Ghostty.

## Core Value

Developers can see all their GitHub and GitLab notifications at a glance, grouped by repository, and act on them (open in browser + mark read) without leaving their current context.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Core Zig library with GitHub notifications API client
- [ ] Core Zig library with GitLab notifications API client (gitlab.com + self-hosted)
- [ ] Polling engine in core lib (configurable interval)
- [ ] Notification types: PR/MR reviews, comments/mentions, CI/pipeline status, assigned issues
- [ ] Read/unread state persisted locally across restarts
- [ ] Multiple accounts per service (each with independent URL + token)
- [ ] OAuth and PAT authentication for both services
- [ ] Tokens stored in system keychain (macOS Keychain / Linux Secret Service)
- [ ] macOS tray app (Swift/Xcode) consuming core lib via C ABI
- [ ] Linux tray app (Zig + GTK) consuming core lib directly
- [ ] Notifications displayed grouped by repository
- [ ] Click notification → open in browser + mark as read
- [ ] Tray icon shows unread count badge
- [ ] Config screen accessible from tray menu (manage accounts: URLs, tokens, OAuth)

### Out of Scope

- Windows support — not requested; two-platform scope is already complex
- Webhook-based push delivery — polling is sufficient for v1; webhooks add server-side infrastructure
- Custom notification filtering rules — keep v1 simple, users can manage via source platform
- Desktop OS notifications (system popups) — tray list is the primary UI; OS popups deferred to v2
- GitLab CI log streaming / artifact downloads — out of notification scope

## Context

The architecture closely mirrors Ghostty: a core library (written in Zig) exposes a stable C ABI that platform shells consume. The macOS shell is Swift/Xcode and the Linux shell is Zig + GTK. This means:

- All API logic, data models, polling, and state management live in the Zig core
- Platform code only handles UI rendering and system integration (tray, keychain, browser launch)
- The C ABI boundary is the critical design surface

GitHub notifications API is well-documented with proper unread/read state and ETag-based polling. GitLab notifications are more fragmented — the "to-do" API covers mentions and assignments, but CI events need separate webhook or pipeline polling.

Reference: https://github.com/ghostty-org/ghostty — examine how libghostty exposes its C API and how the Swift app layer consumes it.

## Constraints

- **Tech stack**: Core library must be Zig — user's explicit architectural decision
- **Tech stack**: macOS shell must be Swift/Xcode — native macOS tray API access
- **Tech stack**: Linux shell must be Zig + GTK — consistent with core language, avoids additional runtime deps
- **Compatibility**: Must run on macOS and Linux — no Windows requirement
- **Security**: Tokens must be stored in system keychain, never in plaintext config files
- **Architecture**: Platform shells consume core via C ABI — loose coupling, same pattern as Ghostty

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Zig core library | Single language for all business logic, C ABI interop, no GC, small binary | — Pending |
| Swift for macOS tray | Native NSStatusItem/AppKit access; same approach Ghostty uses | — Pending |
| Zig + GTK for Linux tray | Reuse core language, GTK has good tray/indicator support on Linux | — Pending |
| System keychain for token storage | Security best practice; avoids plaintext token files | — Pending |
| OAuth + PAT support | OAuth where possible (better UX), PAT as fallback (enterprise/self-hosted) | — Pending |
| Polling over webhooks | Simpler infrastructure for v1; no server-side component needed | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-04-16 after initialization*
