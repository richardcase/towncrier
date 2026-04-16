# Architecture: Towncrier

**Domain:** Cross-platform tray notification aggregator
**Pattern:** Ghostty-style libcore + platform shells
**Researched:** 2026-04-16
**Overall confidence:** HIGH (Ghostty pattern is publicly documented and battle-tested)

---

## Conceptual Model

```
┌─────────────────────────────────────────────────────────┐
│                    libtowncrier (Zig)                    │
│                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐ │
│  │  API Clients │  │ Poll Engine  │  │  State Store  │ │
│  │  github.zig  │  │  poller.zig  │  │  sqlite.zig   │ │
│  │  gitlab.zig  │  │  (bg thread) │  │  (WAL mode)   │ │
│  └──────┬───────┘  └──────┬───────┘  └───────┬───────┘ │
│         └─────────────────┴──────────────────┘         │
│                           │                             │
│                    ┌──────▼───────┐                     │
│                    │  Notif Model │                     │
│                    │  types.zig   │                     │
│                    └──────┬───────┘                     │
│                           │                             │
│               ┌───────────▼──────────┐                 │
│               │    C ABI Surface     │                  │
│               │    towncrier.h       │                  │
│               └──┬────────────────┬─┘                  │
└──────────────────┼────────────────┼────────────────────┘
                   │                │
     (xcframework) │                │ (direct Zig import)
                   │                │
    ┌──────────────▼───┐   ┌────────▼──────────────┐
    │  macOS Shell     │   │  Linux Shell           │
    │  Swift / AppKit  │   │  Zig + GTK4 + D-Bus    │
    │                  │   │                        │
    │  NSStatusItem    │   │  StatusNotifierItem    │
    │  NSMenu          │   │  (via libstray or      │
    │  NSOpenPanel     │   │   D-Bus direct)        │
    │  Keychain        │   │  libsecret             │
    └──────────────────┘   └────────────────────────┘
```

---

## Component Boundaries

### Component 1: libtowncrier (Zig core)

**Owns:** All business logic. API communication, polling scheduling, notification state, data model, persistence.

**Does not own:** Any UI, any platform tray API, any keychain/secret-store access, any browser launching.

**Boundary rule:** If it touches a display or a system service, it belongs in the shell, not the core.

| Sub-component | File(s) | Responsibility |
|---|---|---|
| GitHub client | `src/github.zig` | HTTP requests, ETag tracking, response parsing, rate limit handling |
| GitLab client | `src/gitlab.zig` | Todos API + pipelines endpoint, self-hosted URL support |
| HTTP base | `src/http.zig` | Shared HTTP client wrapper (zig std or libcurl via C ABI) |
| Notification model | `src/types.zig` | `Notification` struct, `Account` struct, enums |
| Poll engine | `src/poller.zig` | Background thread, per-account intervals, wakeup channel |
| State store | `src/store.zig` | SQLite read/write, migration, query interface |
| C ABI surface | `src/c_api.zig` + `include/towncrier.h` | Exported functions, opaque handles, callback registrations |

---

### Component 2: macOS Shell (Swift / Xcode)

**Owns:** NSStatusItem lifecycle, NSMenu construction, NSOpenPanel/browser launch, Keychain reads, rendering the notification list in the popover.

**Does not own:** Any notification data fetching or state decisions.

**Consumes libtowncrier via:** GhosttyKit-style xcframework (`TowncrierKit.xcframework`) built by `build.zig`, linked into the Xcode project.

| Sub-component | Responsibility |
|---|---|
| `AppDelegate.swift` | Bootstraps app, calls `towncrier_init()`, registers callbacks |
| `TrayController.swift` | Manages `NSStatusItem`, updates icon/badge from callback data |
| `NotificationMenuBuilder.swift` | Builds `NSMenu` from the notification list snapshot |
| `KeychainService.swift` | Read/write tokens; called by `AppDelegate` before passing to core |
| `BrowserLauncher.swift` | `NSWorkspace.shared.open(url)` — invoked from menu action |

---

### Component 3: Linux Shell (Zig + GTK4 + D-Bus)

**Owns:** StatusNotifierItem D-Bus tray registration, GTK4 popover window, libsecret access, browser spawn.

**Does not own:** Notification data or state.

**Consumes libtowncrier via:** Direct Zig `@import` — the Linux shell is itself a Zig executable, so it links the core as a static library without any C ABI indirection at the language level (though it respects the same boundaries).

| Sub-component | Responsibility |
|---|---|
| `main.zig` | Entry point, initializes core, GTK4 app loop |
| `tray.zig` | D-Bus StatusNotifierItem registration and icon/badge updates |
| `menu.zig` | GTK4 popover or menu construction from notification snapshot |
| `secrets.zig` | libsecret wrapper for token read/write |
| `browser.zig` | `std.process.spawn` for `xdg-open` |

---

## C ABI Design

### What belongs in the ABI

The Ghostty pattern is the right model: opaque handles, tagged-union action structs, and function-pointer callbacks registered at init time.

**Lifecycle functions:**
```c
// One-time setup. Returns opaque handle. Takes runtime callbacks.
towncrier_t towncrier_init(const towncrier_runtime_s *rt);
void        towncrier_free(towncrier_t tc);

// Account management (called before start)
int towncrier_add_account(towncrier_t tc, const towncrier_account_s *acct);
int towncrier_remove_account(towncrier_t tc, uint32_t account_id);

// Start/stop the poll engine background thread
int towncrier_start(towncrier_t tc);
void towncrier_stop(towncrier_t tc);

// Called by platform shell to drive any pending main-thread work
// (analogous to ghostty_app_tick). Shell calls this from its main
// run loop whenever the wakeup callback fires.
void towncrier_tick(towncrier_t tc);

// Query current notification snapshot (snapshot is immutable, must be freed)
towncrier_snapshot_t towncrier_snapshot_get(towncrier_t tc);
void                 towncrier_snapshot_free(towncrier_snapshot_t snap);

// Actions
int towncrier_mark_read(towncrier_t tc, uint64_t notif_id);
int towncrier_mark_all_read(towncrier_t tc, uint32_t account_id);
```

**Runtime callbacks (registered at init):**
```c
typedef struct {
    void *userdata;

    // Core calls this when new notifications are available.
    // Called from the poll thread — shell MUST marshal to main thread.
    void (*on_update)(void *userdata, uint32_t unread_count);

    // Core calls this to request a wakeup on the main thread
    // so towncrier_tick() can be called.
    void (*wakeup)(void *userdata);

    // Core calls this when an unrecoverable error occurs.
    void (*on_error)(void *userdata, const char *message);
} towncrier_runtime_s;
```

**Data structures:**
```c
// Opaque handles hide implementation
typedef void *towncrier_t;
typedef void *towncrier_snapshot_t;

// Account descriptor — shell fills this and passes to add_account
typedef struct {
    uint32_t    id;           // Shell-assigned; 0 = auto-assign
    uint8_t     service;      // TOWNCRIER_SERVICE_GITHUB / _GITLAB
    const char *base_url;     // NULL = use default; set for self-hosted
    const char *token;        // PAT or OAuth access token (not stored by core)
    uint32_t    poll_interval_secs;
} towncrier_account_s;

// Flat notification — returned inside a snapshot
typedef struct {
    uint64_t    id;
    uint32_t    account_id;
    uint8_t     type;         // PR, issue, CI, etc. (enum)
    uint8_t     state;        // unread / read
    const char *repo;         // "owner/name"
    const char *title;
    const char *url;          // Web URL for browser launch
    int64_t     updated_at;   // Unix timestamp
} towncrier_notification_s;

// Snapshot iteration
uint32_t towncrier_snapshot_count(towncrier_snapshot_t snap);
const towncrier_notification_s *towncrier_snapshot_get_item(
    towncrier_snapshot_t snap, uint32_t index);
```

### What to keep OUT of the ABI

- Token storage — tokens are passed in at `add_account` time, never persisted by core. The shell owns keychain reads.
- Browser launch — core emits a URL string; shell decides how to open it.
- Icon/badge rendering — core reports `unread_count`; shell renders.
- Any UI event loop — core has no run loop; it drives itself on its own thread and calls `wakeup` when the shell needs to act.
- Platform types — no `NSString`, no `GtkWidget`, no file descriptors crossing the boundary.

---

## Threading Model

This is the highest-risk design area. The pattern Ghostty uses (and the right model here) is a strict "poll thread owns data, main thread owns UI" split with a single synchronization primitive.

```
Poll Thread (Zig, owned by libtowncrier)
  │
  │  1. Issues HTTP requests on interval
  │  2. Parses responses, diffs against stored state
  │  3. Writes deltas to SQLite (WAL mode, safe from main thread reads)
  │  4. Atomically updates in-memory snapshot (RwLock or seqlock)
  │  5. Calls runtime.wakeup() — this is the ONLY call back to platform
  │
  ▼ (wakeup fires)

Main Thread (Swift or Zig/GTK)
  │
  │  6. Shell receives wakeup (via GCD dispatch_async, or GTK g_idle_add)
  │  7. Calls towncrier_tick(tc)
  │  8. Core applies any queued main-thread actions (none in v1)
  │  9. Shell calls towncrier_snapshot_get() to read current state
  │  10. Shell rebuilds menu/badge from snapshot
  │  11. Calls towncrier_snapshot_free()
```

**Key rules:**
- `on_update` and `wakeup` are called from the poll thread. The shell MUST NOT touch UI directly inside these callbacks. On macOS, use `DispatchQueue.main.async`. On Linux, use `g_idle_add`.
- `towncrier_snapshot_get` returns a copy owned by the caller. The snapshot is a frozen read — no locks held after the function returns. This avoids holding a lock across UI rendering.
- `towncrier_mark_read` may be called from the main thread; core uses a channel (Zig `std.Thread.Mutex` + condition or a lock-free queue) to relay the mutation to the poll thread, which applies it on next tick.
- Never call `towncrier_stop` from inside a callback — deadlock guaranteed.

---

## Data Model

### Notification struct (internal, Zig)

```zig
pub const Service = enum(u8) { github, gitlab };

pub const NotifType = enum(u8) {
    pr_review,
    pr_comment,
    issue_mention,
    issue_assigned,
    ci_failed,
    ci_passed,
    pipeline_failed,   // GitLab-specific
    other,
};

pub const Notification = struct {
    id:           u64,      // stable across polls; derived from API id
    account_id:   u32,
    service:      Service,
    notif_type:   NotifType,
    repo:         []const u8,  // "owner/repo"
    title:        []const u8,
    url:          []const u8,  // HTML URL for browser
    api_id:       []const u8,  // raw API identifier (GitHub thread_id, GitLab todo_id)
    updated_at:   i64,         // Unix timestamp
    is_read:      bool,
};

pub const Account = struct {
    id:           u32,
    service:      Service,
    base_url:     []const u8,  // "https://github.com" or self-hosted root
    token:        []const u8,  // held in memory only; never written to disk
    poll_interval: u32,        // seconds
    etag:          ?[]const u8, // GitHub Last-Modified value; persisted
};
```

**GitHub-to-model mapping:**
- `reason` field maps to `NotifType`: `review_requested` → `pr_review`, `mention` → `issue_mention`, `ci_activity` → `ci_failed`/`ci_passed`, etc.
- GitHub thread `id` is the stable identifier. Use `Last-Modified` header for conditional polling (not ETag; GitHub specifically uses `If-Modified-Since` for the notifications endpoint).

**GitLab-to-model mapping:**
- Todos API covers: `assigned`, `mentioned`, `approval_required`, `build_failed`, `directly_addressed`.
- `build_failed` maps to `ci_failed`. There is no `ci_passed` equivalent in the Todos API — GitLab todos are created on failure; passing pipelines don't create todos. This is a known limitation; document it rather than work around it in v1.
- GitLab todo `id` is the stable identifier. Todos can be paginated; use `X-Next-Page` header.

---

## State Persistence: SQLite

Use SQLite. Flat files require inventing a serialization format, a diff mechanism, and concurrent-access semantics. SQLite provides all three and has zero external runtime dependencies (embed the amalgamation).

**Why not a flat file:**
- Concurrent reads from main thread and writes from poll thread require manual locking with a flat file. SQLite WAL mode handles this transparently.
- Querying "all unread for account X" is one SQL statement vs. iterating a serialized array.
- Schema migrations are manageable; flat-file format changes require custom migration logic.

**Schema (v1):**

```sql
-- Core notification table
CREATE TABLE notifications (
    id            INTEGER PRIMARY KEY,
    account_id    INTEGER NOT NULL,
    api_id        TEXT    NOT NULL,
    service       INTEGER NOT NULL,
    notif_type    INTEGER NOT NULL,
    repo          TEXT    NOT NULL,
    title         TEXT    NOT NULL,
    url           TEXT    NOT NULL,
    updated_at    INTEGER NOT NULL,
    is_read       INTEGER NOT NULL DEFAULT 0,
    UNIQUE(account_id, api_id)
);

-- Per-account poll metadata
CREATE TABLE poll_state (
    account_id     INTEGER PRIMARY KEY,
    last_modified  TEXT,     -- GitHub If-Modified-Since value
    last_poll_at   INTEGER   -- Unix timestamp
);

-- Schema version for migrations
CREATE TABLE schema_version (version INTEGER NOT NULL);
```

**SQLite configuration:**
- WAL journal mode (concurrent reader + writer without blocking)
- `synchronous = NORMAL` (safe, not paranoid — notification state loss on crash is acceptable)
- DB file path: platform data dir (`~/Library/Application Support/towncrier/state.db` on macOS, `~/.local/share/towncrier/state.db` on Linux)

**Zig wrapper choice:** `vrischmann/zig-sqlite` (most mature, wraps the C API with type safety, supports 0.13+). Alternatively embed the amalgamation directly and call C functions — more portable across Zig version churn.

---

## Build System

### Repo layout

```
towncrier/
├── build.zig             # top-level orchestrator
├── build.zig.zon         # dependencies
├── include/
│   └── towncrier.h       # C header; source of truth for ABI
├── src/
│   ├── root.zig          # library root; re-exports public API
│   ├── c_api.zig         # export fn declarations (the only file that uses `export`)
│   ├── types.zig
│   ├── github.zig
│   ├── gitlab.zig
│   ├── http.zig
│   ├── poller.zig
│   └── store.zig
├── linux/                # Linux shell (Zig source)
│   ├── main.zig
│   ├── tray.zig
│   ├── menu.zig
│   ├── secrets.zig
│   └── browser.zig
├── macos/                # macOS shell (Xcode project)
│   ├── Towncrier.xcodeproj/
│   ├── Towncrier/
│   │   ├── AppDelegate.swift
│   │   ├── TrayController.swift
│   │   ├── NotificationMenuBuilder.swift
│   │   ├── KeychainService.swift
│   │   └── BrowserLauncher.swift
│   └── TowncrierKit.xcframework/  # generated by build.zig, gitignored
└── tests/
    └── core/             # unit tests for Zig core only
```

### build.zig structure

```zig
// Pseudocode — illustrates the conditional compilation strategy
const target = b.standardTargetOptions(.{});

if (target.result.os.tag.isDarwin()) {
    // 1. Build static lib for aarch64-macos
    // 2. Build static lib for x86_64-macos
    // 3. lipo merge → universal .a
    // 4. xcodebuild xcframework → TowncrierKit.xcframework
    // Shell: Xcode project uses TowncrierKit.xcframework; build separately
} else {
    // Linux: build static lib + Linux shell executable together
    const lib = b.addStaticLibrary(.{ .name = "towncrier", ... });
    const exe = b.addExecutable(.{ .name = "towncrier-gtk", ... });
    exe.addObject(lib);
    exe.linkSystemLibrary("gtk-4");
    // D-Bus tray: link libdbus-1 or use the libstray vendored C lib
}
```

**macOS xcframework pipeline (mirrors Ghostty exactly):**
1. `zig build-lib -target aarch64-macos-none` → `libtowncrier-arm64.a`
2. `zig build-lib -target x86_64-macos-none` → `libtowncrier-x86.a`
3. `lipo -create` → `libtowncrier-universal.a`
4. `xcodebuild -create-xcframework -library libtowncrier-universal.a -headers include/` → `TowncrierKit.xcframework`
5. `module.modulemap` in `include/` maps `#include "towncrier.h"` to Swift module `TowncrierKit`

The Xcode project references the xcframework as a local dependency. Swift imports it as `import TowncrierKit` and all exported C functions become Swift-callable with automatic type bridging.

**Linux build:**
The Linux shell is a Zig executable that `@import`s the core library source directly rather than going through a .a file. This simplifies the build: one `zig build` step compiles everything. The tray mechanism requires either:
- Vendored `libstray` (pure C, no GTK dependency) — preferred; avoids GTK3/GTK4 status icon conflict.
- `libayatana-appindicator` — GPL, GTK3-only, deprecated path. Avoid.

**Build targets to define:**
```
zig build           # Linux: build + run tests
zig build linux     # Linux shell executable
zig build xcframework  # macOS: produce TowncrierKit.xcframework
zig build test      # core unit tests (no platform deps)
```

---

## Data Flow

### Poll cycle (happy path)

```
poller.zig (bg thread)
  │
  ├─ for each account:
  │   ├─ github.zig: GET /notifications?If-Modified-Since=<stored>
  │   │     200 → parse thread list → diff against store → upsert SQLite
  │   │     304 → no-op (rate limit untouched)
  │   │     401 → emit error callback → remove account from rotation
  │   │
  │   └─ gitlab.zig: GET /todos?state=pending (paginate if X-Next-Page)
  │         diff against store → upsert SQLite
  │
  ├─ update in-memory snapshot (RwLock write)
  └─ call runtime.wakeup()

main thread (Swift or Zig/GTK)
  │
  ├─ receives wakeup → dispatches to main queue
  ├─ towncrier_tick(tc) → core drains action queue
  ├─ towncrier_snapshot_get(tc) → frozen copy
  ├─ rebuild tray menu / badge count
  └─ towncrier_snapshot_free(snap)
```

### Mark-read flow

```
User clicks "open" in tray menu
  │
  ├─ Shell: open URL in browser
  ├─ Shell: call towncrier_mark_read(tc, notif_id)
  │
  └─ Core (main thread path): enqueue {mark_read, id} → action queue
       │
       └─ Poll thread drains action queue:
           ├─ UPDATE notifications SET is_read=1 WHERE id=?
           ├─ GitHub: PATCH /notifications/threads/{id}
           └─ GitLab: POST /todos/{id}/mark_as_done
```

---

## Component Build Order (Phase Dependency)

This is the order phases should follow, based on dependency graph:

1. **Core data model + types** (`types.zig`, `Notification` struct, enums)
   Unblocks everything. No external deps.

2. **SQLite state store** (`store.zig`, schema, migrations)
   Unblocks poll engine. Can be tested in isolation.

3. **GitHub client** (`github.zig`, HTTP, ETag/Last-Modified, response parsing)
   Unblocks end-to-end notification retrieval. GitHub API is simpler and better documented than GitLab.

4. **Poll engine** (`poller.zig`, background thread, per-account scheduling)
   Integrates client + store. First time threading complexity appears.

5. **C ABI surface** (`c_api.zig`, `towncrier.h`, callback registration)
   Unblocks both shells. Should be designed before the shells, validated with a minimal test harness (a simple C or Zig test binary that calls the ABI directly).

6. **Linux shell** (Zig + GTK4 + D-Bus tray)
   Can develop in parallel with macOS once ABI is defined. Zig-native, easier iteration.

7. **macOS shell** (Swift + xcframework)
   Requires xcframework pipeline to be working. Highest integration complexity due to build toolchain crossing.

8. **GitLab client** (`gitlab.zig`, Todos API)
   Can be added after GitHub is working end-to-end. Same poll engine, same store schema.

9. **OAuth + PAT UI flows** (config screens in both shells)
   Depends on shell UIs being functional. Keychain integration is per-shell.

---

## Anti-Patterns to Avoid

### Passing Zig allocator-backed pointers across the ABI

**What goes wrong:** Zig slices (`[]u8`) cannot cross the C ABI. Returning a `[]const u8` from an exported function is undefined behavior. Use `[*:0]const u8` (null-terminated C string) or pass a buffer + length pair.

**Instead:** The `towncrier_notification_s` struct holds `const char *` fields. Core owns the memory inside a snapshot; it is valid until `towncrier_snapshot_free` is called. Shell must not retain these pointers after freeing the snapshot.

### Calling UI from the poll thread callback

**What goes wrong:** `on_update` fires on the poll thread. Touching `NSMenu` or GTK widgets from a non-main thread causes crashes that are intermittent and hard to reproduce.

**Instead:** Enforce that `on_update` and `wakeup` callbacks are fire-and-forget signals only. No data is passed in the callback — the shell calls `towncrier_snapshot_get` after marshaling to the main thread.

### Storing tokens in the SQLite database

**What goes wrong:** Database file in app data directory is readable by any process running as the user. Tokens persist after uninstall.

**Instead:** Tokens are passed to `towncrier_add_account` at startup (after the shell reads them from Keychain/Secret Service) and held in memory. Core never writes tokens to disk.

### GTK4 StatusIcon / libappindicator on Linux

**What goes wrong:** `GtkStatusIcon` was removed in GTK4. `libappindicator` is GTK3-only. Mixing GTK3 and GTK4 in one process is unsupported. `libayatana-appindicator` works but is GPL and has known StatusNotifierItem bugs.

**Instead:** Implement the StatusNotifierItem D-Bus protocol directly, using `libstray` (pure C, no toolkit dependency, MIT-licensed, tested on Wayland compositors) or a minimal hand-rolled D-Bus implementation.

### One monolithic poll loop for all accounts

**What goes wrong:** If one account's HTTP request blocks (timeout, slow self-hosted instance), all other accounts are delayed.

**Instead:** Each account gets its own poll goroutine-equivalent (`std.Thread` or async frame). The poll engine is a supervisor that spawns per-account workers and aggregates results.

---

## Open Questions / Phase Research Flags

| Phase | Topic | Flag |
|---|---|---|
| Phase 4 (Poll engine) | Zig `std.Thread` vs `async`/`await` — Zig's async story is in flux as of 0.13/0.14. Verify whether `std.Thread` is sufficient or if a third-party async runtime is needed. | Needs verification before implementation |
| Phase 5 (C ABI) | `towncrier_snapshot_t` memory model — decide whether snapshot copies strings into a Zig allocator-owned buffer or returns pointers into a locked core-owned region. The copy approach is simpler and eliminates lock lifetime complexity. | Design decision before coding |
| Phase 6 (Linux tray) | `libstray` maturity — the project is a community showcase, not a stable library. Evaluate vendoring it vs. implementing D-Bus StatusNotifierItem from scratch with `std.os.linux` and the Zig D-Bus bindings. | Investigate before Linux shell phase |
| Phase 7 (macOS xcframework) | Xcode project generation — Ghostty uses XcodeGen to produce the .xcodeproj from a YAML spec, avoiding committing Xcode project files. Evaluate whether this is worth the complexity for a smaller project. | Nice-to-have, not blocking |
| Phase 8 (GitLab) | CI notification coverage — GitLab Todos API covers `build_failed` but not `build_succeeded`. Users expecting "CI passed" notifications will not get them via the Todos endpoint. Validate whether this is acceptable or whether a separate Pipelines API poll is needed. | Requirement validation with user before implementation |

---

## Sources

- Ghostty source structure: https://github.com/ghostty-org/ghostty
- Mitchell Hashimoto, "Integrating Zig and SwiftUI": https://mitchellh.com/writing/zig-and-swiftui
- Mitchell Hashimoto, "libghostty is coming": https://mitchellh.com/writing/libghostty-is-coming
- Ghostty xcframework / XcodeGen integration: https://github.com/Uzaaft/awesome-libghostty
- Zig C ABI guide: https://zig.guide/working-with-c/abi/
- GitHub Notifications API: https://docs.github.com/en/rest/activity/notifications
- GitLab Todos API: https://docs.gitlab.com/api/todos/
- Zig system tray via D-Bus (libstray): https://ziggit.dev/t/system-tray-icons-via-d-bus/12750
- GTK4 StatusIcon removal: https://discourse.gnome.org/t/what-to-use-instead-of-statusicon-in-gtk4-to-display-the-icon-in-the-system-tray/7175
- vrischmann/zig-sqlite: https://github.com/vrischmann/zig-sqlite
- mitchellh/zig-build-macos-sdk: https://github.com/mitchellh/zig-build-macos-sdk
