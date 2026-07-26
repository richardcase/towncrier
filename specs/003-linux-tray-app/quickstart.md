# Quickstart: Linux Tray App

Build, run, and validate the Zig-native Linux shell end-to-end. This is a **validation guide** —
implementation lives in `tasks.md` + the source.

## Prerequisites

- Linux with Zig 0.14+ (0.16 in the current toolchain; see `.mise.toml`).
- System libraries: **GTK4** (`gtk4`/`libgtk-4-dev`), **libsecret** (`libsecret-1-dev`), D-Bus.
- A **Secret Service daemon** running (gnome-keyring or KDE `ksecretd`, or keepassxc with Secret Service enabled).
- A **StatusNotifierItem host**: native on KDE Plasma, Cinnamon, Sway; on GNOME install the AppIndicator support extension.
- A GitHub **Personal Access Token** with `notifications` scope for live validation.

## Build & run

```bash
zig build linux            # builds the towncrier-gtk executable (Linux target only)
./zig-out/bin/towncrier-gtk
```

`build.zig` gates the GTK4/libsecret/libstray linkage behind `target.result.os.tag == .linux`; the
core `libtowncrier.a` and the macOS build never reference these symbols.

## Validation scenarios (map to Success Criteria)

Run on the native DE matrix — **KDE, Cinnamon, Sway** — unless noted.

1. **SC-001 — Tray icon + live badge.** Launch with a configured account. A tray icon appears; once the poll engine reports unread items, the badge shows the count. Mark items read elsewhere → badge decrements. *(LINUX-01/02)*
2. **SC-002 — Popover grouped by repo.** Click the tray icon → a GTK4 popover lists unread notifications grouped by repository (groups alphabetical). *(LINUX-03)*
3. **SC-003 — Open + mark read.** Click a notification row → the correct URL opens in the default browser (`xdg-open`) and the row disappears from the list on the next refresh. *(LINUX-04)*
4. **SC-004 — Config add/remove.** Open the config screen from the tray menu, enter a GitHub PAT → the account is added, the PAT lands in libsecret (verify: `secret-tool search service towncrier`), and polling begins immediately; remove it → account gone and the libsecret entry deleted. *(LINUX-05)*
5. **SC-005 — No SNI host.** On a session with no `org.kde.StatusNotifierWatcher` (e.g. stock GNOME Wayland without the extension), launch → a clear dialog explains no tray host is available (with the extension link on GNOME), instead of a silent no-op. *(LINUX-06)*

## Extra checks (from research decisions)

- **Secret Service absent.** On a minimal WM with no Secret Service daemon, launch → clear error; the app refuses to store the PAT in plaintext (Constitution IV). Verify no token appears on disk: `grep -r "<token-prefix>" ~/.config ~/.local/share 2>/dev/null` returns nothing.
- **Thread safety.** New notifications arriving while the popover is open update the list without a crash (callbacks marshalled via `g_idle_add`, not touching GTK from the poll thread).

## Expected outcome

`zig build linux` compiles clean; scenarios 1–5 pass on KDE/Cinnamon/Sway; the SNI-absent and
Secret-Service-absent paths surface user-facing guidance rather than failing silently. Tokens are only
ever in libsecret. No changes to `include/towncrier.h`.
