# Data Model: Linux Tray App (Phase 1)

The shell owns **no persistent data** — notification/read state lives in the core's SQLite and tokens
live in libsecret. This model describes the shell-local **view-model** (derived each refresh from a
core snapshot) and the small config/tray state the shell holds in memory.

## Consumed from the core (read-only, via the C ABI)

**`towncrier_notification_s`** (owned by the snapshot; valid until `towncrier_snapshot_free`):
`id: u64`, `account_id: u32`, `type: u8`, `state: u8`, `repo: cstr "owner/name"`, `title: cstr`,
`url: cstr`, `updated_at: i64`. The shell copies out any string it needs to retain past the snapshot's
lifetime.

## Shell-local entities

### AppState
The root object passed as `userdata` to `towncrier_init`.
- `core: towncrier_t` — the core handle
- `tray: Tray` — the tray backend (see contracts)
- `view: []RepoGroup` — current grouped view-model (rebuilt each refresh)
- `unread_total: u32` — last value from `on_update`; drives the tray badge
- `popover: ?*GtkWidget`, `config_window: ?*GtkWidget` — GTK handles (main thread only)
- **Lifetime:** allocated before `towncrier_init`, freed after `towncrier_free`. Must outlive all callbacks.

### RepoGroup (view-model)
- `repo: []const u8` — "owner/name" (owned copy)
- `rows: []NotificationRow`
- **Rule:** groups sorted alphabetically by `repo` (matches core SC/CORE-06); rows within a group by `updated_at` desc.

### NotificationRow (view-model)
- `id: u64` (from the core; used for `towncrier_mark_read`)
- `title: []const u8`, `url: []const u8` — owned copies (snapshot strings must not be retained)
- `type: u8` — for the row icon/label
- **Transition:** on row activate → `browser.open(url)` then `towncrier_mark_read(core, id)`; the row disappears on the next refresh (core omits read items).

### AccountConfig (config screen, GitHub-only in Phase 3)
- `id: u32` — shell-assigned, unique, non-zero
- `token: []const u8` — the PAT; **never** persisted by the shell except into libsecret
- `poll_interval_secs: u32` — default 60
- **Validation:** token non-empty; `id` unique across added accounts. Maps to `towncrier_account_s` (service = GITHUB, `base_url = null`).
- **Lifecycle:** *add* → store PAT in libsecret, `towncrier_add_account`; *remove* → `towncrier_remove_account`, delete the libsecret entry.

### TrayState
- `unread: u32` — badge count; `0` clears the badge (LINUX-02)
- `present: bool` — whether an SNI host was found at startup (LINUX-06)

### EnvironmentProbe (startup, transient)
- `sni_host_present: bool` — `org.kde.StatusNotifierWatcher` on D-Bus
- `secret_service_present: bool` — `org.freedesktop.secrets` on D-Bus
- **Rule:** each absence triggers a user-facing dialog; Secret-Service absence blocks token storage (no plaintext fallback).

## Refresh cycle (state transitions)

```
poll thread: on_update(count) / wakeup()
        └─ g_idle_add ──▶ main thread:
               towncrier_tick(core)
               snap = towncrier_snapshot_get(core)
               view = group_and_sort(snap)      # rebuild RepoGroup[]
               menu.render(popover, view)        # if open
               tray.setIconUnreadCount(unread)   # badge
               towncrier_snapshot_free(snap)
```
