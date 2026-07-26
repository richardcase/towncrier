# Research: Linux Tray App (Phase 0)

**Date:** 2026-07-26 · **Feature:** `003-linux-tray-app`

All Technical-Context unknowns are resolved (no `NEEDS CLARIFICATION` remain). The major forks were
settled in `/speckit-clarify` (2026-07-26); the probe/threading decisions come from
[`docs/research/ARCHITECTURE.md`](../../docs/research/ARCHITECTURE.md) and
[`docs/research/PITFALLS.md`](../../docs/research/PITFALLS.md).

## Decision 1 — Tray via libstray v0.4.0 behind a `Tray` interface

- **Decision:** Depend on `libstray` v0.4.0 for the StatusNotifierItem D-Bus tray; wrap it behind a thin internal `Tray` interface (create/destroy, `setIconUnreadCount`, `onActivate` callback).
- **Rationale:** GTK4 removed `GtkStatusIcon`, so SNI-over-D-Bus is mandatory. libstray implements SNI in C+Zig with **no** GTK/GLib/Qt dependency, ships `build.zig`/`build.zig.zon`, and is tested on KDE/GNOME/Hyprland/eww (March 2026). The interface keeps a hand-rolled backend as a contained fallback.
- **Alternatives considered:** hand-rolled D-Bus SNI (max control, large error-prone surface — rejected as default); `libayatana-appindicator` (GTK3-only, deprecated, incompatible with GTK4 in-process — rejected).

## Decision 2 — GTK4 via direct C API (`@cImport`), not zig-gobject

- **Decision:** Call GTK4 through `@cImport("gtk/gtk.h")` directly for the popover and config window.
- **Rationale:** The UI surface is small (a grouped list + a simple form). `zig-gobject` v0.3.1 is self-described experimental with API churn and adds `xsltproc` as a build dep. Direct C calls are lower-risk and mirror the SQLite/libsecret C-interop already used in the core.
- **Alternatives considered:** `zig-gobject` bindings (nicer ergonomics, higher risk/build cost — rejected for this surface).

## Decision 3 — GitHub-only config in Phase 3

- **Decision:** The config screen adds/removes GitHub accounts (PAT) only. GitLab base-URL fields are deferred to Phase 5 (GL-04 extends the screen when the GitLab client exists).
- **Rationale:** The Phase 2 poll engine speaks only GitHub; GitLab config now would be dead UI.
- **Alternatives considered:** full GitHub+GitLab UI with inert GitLab fields (rejected — ships non-functional controls).

## Decision 4 — Thread marshalling: poll thread → GTK main thread

- **Decision:** Register `on_update`/`wakeup` at `towncrier_init`. Both fire on the core's poll thread; each schedules work onto the GTK main loop via `g_idle_add`, which then calls `towncrier_tick`, pulls a fresh snapshot (`towncrier_snapshot_get`), rebuilds the popover model, and updates the tray badge.
- **Rationale:** The header mandates no UI access inside callbacks; `g_idle_add` is the GTK-safe hop to the main thread (mirrors the macOS `DispatchQueue.main.async` path). Fire-and-forget — no ABI calls from inside the callbacks themselves.
- **Alternatives considered:** touching GTK widgets directly in the callback (unsafe — rejected); a self-pipe/`GSource` fd (more plumbing than needed — deferred).

## Decision 5 — SNI-host probe at startup (LINUX-06)

- **Decision:** Before registering the tray, do a D-Bus name lookup for `org.kde.StatusNotifierWatcher`. If absent, show a GTK dialog explaining no system tray host is available; on GNOME specifically, link the AppIndicator support extension.
- **Rationale:** On GNOME Wayland (Fedora/Ubuntu default) SNI is invisible without the user's extension — silent failure otherwise. KDE/Cinnamon/Sway work natively.
- **Alternatives considered:** assume a tray host exists (rejected — silent invisibility); poll for the watcher indefinitely (rejected — bad UX).

## Decision 6 — Secret Service probe before libsecret use

- **Decision:** Probe `org.freedesktop.secrets` on D-Bus before storing/reading PATs. If absent, show a clear error ("install gnome-keyring or keepassxc with Secret Service enabled") and refuse to cache tokens in plaintext.
- **Rationale:** Minimal WMs/headless sessions run no Secret Service daemon; libsecret calls then error silently or block. Constitution IV forbids any plaintext fallback.
- **Alternatives considered:** treat libsecret failure as fatal-crash (rejected — poor UX); silent in-memory-only fallback without telling the user (rejected — hides a security-relevant state).

## Consumed core ABI (reference)

The shell links `libtowncrier` and uses only these exported functions: `towncrier_init`,
`towncrier_start`, `towncrier_tick`, `towncrier_add_account`, `towncrier_remove_account`,
`towncrier_snapshot_get`/`_count`/`_get_item`/`_free`, `towncrier_mark_read`, and `towncrier_free`.
Full signatures/ownership are the locked contract in
[`specs/001-*/contracts/towncrier.h`](../001-core-scaffolding-abi-contract/contracts/towncrier.h).
