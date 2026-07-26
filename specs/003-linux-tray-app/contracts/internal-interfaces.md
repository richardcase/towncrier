# Contracts: Linux Tray App

This phase exposes **no external/network API** — it is a desktop application. Its contracts are
(1) the core C ABI it *consumes*, and (2) the internal Zig interfaces that keep subsystems decoupled
(so libstray/libsecret are swappable and testable). Signatures are Zig-flavored sketches for the plan;
exact types are finalized during implementation.

## 1. Consumed core C ABI (reference — do not modify)

The shell drives the core through the locked contract in
[`../../001-core-scaffolding-abi-contract/contracts/towncrier.h`](../../001-core-scaffolding-abi-contract/contracts/towncrier.h).
Functions used by this shell:

| Function | Use in shell |
|----------|--------------|
| `towncrier_init(rt)` | register `on_update`/`wakeup`/`on_error` + `AppState` userdata |
| `towncrier_start` / `towncrier_tick` / `towncrier_free` | lifecycle; `tick` drains on the main thread after `wakeup` |
| `towncrier_add_account` / `towncrier_remove_account` | config screen add/remove (GitHub) |
| `towncrier_snapshot_get` / `_count` / `_get_item` / `_free` | build the grouped view-model each refresh |
| `towncrier_mark_read(core, id)` | on notification row activate |

**Callback rules (from the header):** callbacks fire on the poll thread; the shell MUST hop to the GTK
main thread (`g_idle_add`) before any UI or further ABI call; `userdata` (`AppState`) must outlive the
handle.

## 2. `Tray` interface (isolates libstray)

```zig
pub const Tray = struct {
    // libstray-backed by default; a hand-rolled D-Bus SNI backend may replace it.
    pub fn init(alloc, on_activate: *const fn(*AppState) void, ctx: *AppState) TrayError!Tray;
    pub fn setIconUnreadCount(self: *Tray, unread: u32) void; // 0 clears the badge (LINUX-02)
    pub fn deinit(self: *Tray) void;
};
pub const TrayError = error{ NoSniHost, DbusUnavailable, RegisterFailed };
```
- `NoSniHost` is returned when `org.kde.StatusNotifierWatcher` is absent → caller shows the guidance dialog (LINUX-06).
- The activate callback opens/toggles the GTK popover (main thread).

## 3. `Secrets` interface (isolates libsecret)

```zig
pub const Secrets = struct {
    pub fn probe() bool;                                  // org.freedesktop.secrets present?
    pub fn store(alloc, account_id: u32, token: []const u8) SecretsError!void;
    pub fn lookup(alloc, account_id: u32) SecretsError![]u8;   // caller frees
    pub fn delete(account_id: u32) SecretsError!void;
};
pub const SecretsError = error{ NoSecretService, StoreFailed, NotFound };
```
- Schema attribute keys: `{ service = "towncrier", account_id = <u32> }`.
- `NoSecretService` → clear error dialog; **never** fall back to plaintext (Constitution IV).

## 4. `dbus_probe` contract

```zig
pub fn nameHasOwner(bus: []const u8, name: []const u8) bool; // e.g. "org.kde.StatusNotifierWatcher"
```
- Session bus name-ownership check used by both the SNI probe (LINUX-06) and the Secret-Service probe.

## 5. `browser` contract

```zig
pub fn open(url: []const u8) BrowserError!void; // spawns `xdg-open <url>` detached
```
- Used on row activate (LINUX-04) before `towncrier_mark_read`.
