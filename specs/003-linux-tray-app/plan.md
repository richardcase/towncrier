# Implementation Plan: Linux Tray App

**Branch**: `003-linux-tray-app` | **Date**: 2026-07-26 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/003-linux-tray-app/spec.md`

## Summary

Build the Zig-native Linux shell: a `towncrier-gtk` executable that links the Phase 2 core
(`libtowncrier`), registers a StatusNotifierItem tray icon over D-Bus via **libstray** (wrapped behind
a thin internal `Tray` interface), and renders a **GTK4 popover** (called through the direct C API,
no bindings layer) listing unread notifications grouped by repository. Clicking a notification opens
it via `xdg-open` and marks it read; a GitHub-only config screen adds/removes accounts with PATs
stored in **libsecret**. Two startup probes guard the environment: an SNI-host probe (LINUX-06) and a
Secret Service probe. This is the first shell — it proves the ABI callback path end-to-end before the
macOS/Swift shell.

## Technical Context

**Language/Version**: Zig 0.14 target (0.16.0 in the local toolchain — mind the API adaptations noted in Phase 2)

**Primary Dependencies**: `libtowncrier` (core, linked directly); **libstray** v0.4.0 (SNI tray, via `build.zig.zon`); **GTK4** (`gtk-4`, via `@cImport`, direct C calls); **libsecret** (`libsecret-1`, via `@cImport`); D-Bus (name-lookup probes)

**Storage**: none new in the shell — notification/read state lives in the core's SQLite; tokens live in libsecret

**Testing**: `zig build` (compile the Linux exe); manual DE matrix (KDE, Cinnamon, Sway) per quickstart; a headless smoke path for the SNI/Secret-Service probes where feasible

**Target Platform**: Linux (x86_64) — KDE Plasma, Cinnamon, Sway natively; GNOME requires the AppIndicator shell extension (surfaced by the probe)

**Project Type**: Native desktop shell (Zig executable) consuming a C-ABI core library

**Constraints**: tray must not depend on GTK (SNI over D-Bus); GTK4 UI decoupled from the tray session; UI touched only on the main thread (marshal poll-thread callbacks via `g_idle_add`); tokens only in libsecret; no GitLab in this phase

**Scale/Scope**: single user, 2–5 accounts, tens–hundreds of notifications; ~5 new Zig source files + build wiring

## Constitution Check

*GATE: must pass before Phase 0 and again after Phase 1 design.*

- **I. Zig Core, C-ABI Boundary** — ✅ The shell links `libtowncrier` and drives it **only** through the C ABI functions (`towncrier_init`/`start`/`tick`/`add_account`/`snapshot_*`/`mark_read`), never core internals. No ABI changes.
- **II. Thin Shells** — ✅ The shell does UI + OS integration only (tray, popover, config form, libsecret, `xdg-open`). No API/polling/state logic — all delegated to the core.
- **III. Build-Time Platform Isolation** — ✅ All GTK4/libstray/libsecret linkage lives inside the `target.result.os.tag == .linux` guard in `build.zig`; the core stays dependency-free and the macOS build never sees these symbols.
- **IV. Tokens in Keychain** — ✅ PATs are written to/read from libsecret (Secret Service) only; passed across the ABI for the poll session; never written to disk/logs. A Secret-Service probe prevents silent plaintext fallbacks.
- **V. Poll, Don't Push** — ✅ The shell owns no polling; it receives `on_update`/`wakeup` from the core's poll thread and renders snapshots.

**Result:** PASS — no violations, Complexity Tracking not required.

*Post-design re-check (after Phase 1):* still PASS — the design adds no core-internal coupling and no new ABI surface; the internal `Tray` interface and view-model are shell-local.

## Project Structure

### Documentation (this feature)

```text
specs/003-linux-tray-app/
├── plan.md              # This file
├── research.md          # Phase 0 — decisions (libstray, GTK4-via-C, probes)
├── data-model.md        # Phase 1 — shell view-model + config entities
├── quickstart.md        # Phase 1 — build/run/validate on the DE matrix
├── contracts/           # Phase 1 — consumed C ABI + internal Tray/Secrets interfaces
└── tasks.md             # (generated later by /speckit-tasks)
```

### Source Code (repository root)

```text
src/linux/               # Linux shell (Zig executable "towncrier-gtk")
├── main.zig             # Entry: init core, register callbacks, run GTK main loop, probes
├── app.zig              # AppState: holds core handle, view-model, marshals wakeup → tick → refresh
├── tray.zig             # Thin `Tray` interface + libstray backend (SNI icon + unread badge)
├── menu.zig             # GTK4 popover: notification rows grouped by repo; row activate → open+mark-read
├── config_window.zig    # GTK4 config screen: add/remove GitHub account (PAT)
├── secrets.zig          # libsecret wrapper: store/lookup/delete PAT; Secret-Service probe
├── browser.zig          # xdg-open via std.process
└── dbus_probe.zig       # org.kde.StatusNotifierWatcher + org.freedesktop.secrets name lookups

build.zig                # + Linux exe target under the .linux guard; link gtk-4, libsecret, libstray
build.zig.zon            # + libstray v0.4.0 dependency
```

**Structure Decision**: A Zig executable that links the core static library and calls its C-ABI
functions. Tray (libstray/D-Bus SNI) and windowed UI (GTK4) are kept as separate subsystems that
never share a widget hierarchy — the tray session is D-Bus-only; GTK owns the popover/config windows.
The `Tray` interface isolates libstray so a hand-rolled SNI backend can replace it if needed.

## Design Decisions (from clarify + research)

| Area | Decision | Source |
|------|----------|--------|
| Tray backend | libstray v0.4.0 behind a thin `Tray` interface | Clarify Q1 |
| GTK4 access | Direct C API via `@cImport("gtk/gtk.h")` — no `zig-gobject` | Clarify Q2 |
| Config scope | GitHub-only; GitLab base-URL fields deferred to Phase 5 | Clarify Q3 |
| Thread marshalling | Poll-thread `wakeup`/`on_update` → `g_idle_add` → `towncrier_tick` + snapshot refresh on the GTK main thread | ARCHITECTURE.md (threading) |
| SNI-host absence | Probe `org.kde.StatusNotifierWatcher` at startup; if absent, show a GTK dialog (esp. GNOME → link the AppIndicator extension) | LINUX-06 + PITFALLS §3 |
| Secret Service absence | Probe `org.freedesktop.secrets`; if absent, clear error, never cache plaintext | PITFALLS §7 |
| Popover vs window | Notification list = GTK4 popover anchored to the tray activate; config = separate window | Deferred item, resolved here |

## Complexity Tracking

No constitution violations — table intentionally empty.

## Open risks carried into implementation

- **GNOME Wayland**: SNI is invisible without the user's AppIndicator extension — mitigated by the probe + guidance dialog, but GNOME is not in the "native" DE matrix (KDE/Cinnamon/Sway).
- **libstray v0.4.0** production readiness on the target DEs — the `Tray` interface exists precisely so a hand-rolled SNI backend is a contained fallback.
- Zig 0.16 vs 0.14 API drift (GTK `@cImport`, `std.process`) — same class of adaptation seen in Phase 2.
