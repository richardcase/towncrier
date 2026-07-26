# Project Research Summary

**Project:** Towncrier — cross-platform GitHub + GitLab notification tray app
**Domain:** Native system tray notification aggregator (macOS + Linux)
**Researched:** 2026-04-16
**Confidence:** HIGH (core stack and architecture), MEDIUM (Linux tray ecosystem)

---

## Executive Summary

Towncrier is a native tray application that unifies GitHub and GitLab notifications into a single inbox, targeting developers who dislike Electron-based alternatives (Gitify, Gitlight) and need first-class multi-account and self-hosted GitLab support. The proven architectural pattern — Ghostty's libcore + platform shells approach — maps directly onto this project: a Zig static library handles all API polling, state, and business logic, while a Swift/AppKit shell handles macOS tray UI and a Zig/GTK4 shell handles Linux. This is not speculation; Ghostty is a public, battle-tested reference implementation with documented build pipelines.

The recommended stack is non-negotiable on several points. For macOS: NSStatusItem (not SwiftUI MenuBarExtra, which lacks programmatic control), Keychain Services via `keychain-swift`, and the XCFramework packaging path from Zig to Swift. For Linux: `libstray` v0.4.0 for the tray icon (GTK4 removed GtkStatusIcon and `libayatana-appindicator` is GTK3-only — mixing both in one process is impossible), and `libsecret` for credential storage with a startup probe for the Secret Service daemon. The Zig core uses stdlib exclusively for HTTP and JSON (no third-party HTTP clients needed), with SQLite in WAL mode for persistent state.

The critical risks cluster around two areas: the Swift/Zig C ABI boundary (callback context use-after-free, string ownership ambiguity) and Linux tray ecosystem fragmentation (GNOME Wayland has no native tray; SNI requires the AppIndicator GNOME Shell extension or a non-GNOME compositor). Both must be designed correctly from the start — they cannot be fixed by retrofitting. The threading model (poll thread owned by core, main thread owned by shell, one-way wakeup signal) is also a design decision that becomes load-bearing once both shells are in play.

---

## Key Findings

### Recommended Stack

The Zig core library targets 0.14.0 stable (pinned — master breaks APIs between releases). It uses `std.http.Client` for API polling (TLS 1.3, connection pooling, custom headers — sufficient for 30–300s poll intervals) and `std.json` with typed struct parsing. State is persisted in SQLite via the amalgamation or `vrischmann/zig-sqlite`. The XCFramework pipeline for macOS (build arm64 + x86_64 static libs → `lipo` → `xcodebuild -create-xcframework`) is the correct integration path, documented step-by-step in Mitchell Hashimoto's public writing on Ghostty.

**Core technologies:**
- **Zig 0.14.0**: Core library language — stable, cross-compilation built in, C ABI exports via `export fn`
- **std.http.Client + std.json**: API polling and response parsing — no third-party deps needed
- **SQLite (WAL mode)**: Persistent notification state — concurrent reader/writer without manual locking
- **Swift 5.10 + NSStatusItem**: macOS shell — only viable path for AppKit tray integration
- **keychain-swift (SPM)**: macOS credential storage — maintained, ergonomic wrapper over Keychain Services
- **libstray v0.4.0**: Linux tray icon via StatusNotifierItem D-Bus — the only GTK4-compatible path
- **GTK4 (direct C calls preferred over zig-gobject)**: Linux settings window — zig-gobject v0.3.1 is experimental; direct C calls are lower-risk for a small UI surface
- **libsecret**: Linux credential storage — requires startup probe for Secret Service daemon availability

### Expected Features

**Must have (table stakes):**
- GitHub notifications: review requests, assignments, @mentions, CI activity (user-triggered)
- GitLab todos: MR assignments, @mentions, approval requests, build failures on authored MRs
- Group notifications by repository (client-side)
- Tray icon with unread count badge
- Click to open in browser + mark as read
- Multiple accounts per service (personal + work)
- System keychain token storage (macOS Keychain / Linux Secret Service)
- PAT authentication for both services
- Persistent read/unread state across restarts
- Configurable poll interval (must respect GitHub's `X-Poll-Interval` header floor)

**Should have (competitive differentiators):**
- OAuth device flow (GitHub + GitLab 17.2+) — better onboarding than copy-pasting PATs
- Notification type filtering (show only review requests / assignments)
- Repo-level muting
- Self-hosted GitLab first-class support (per-account base URL)
- Per-service unread counts in tray (GitHub vs GitLab split)

**Defer to v2+:**
- GitLab CI pipeline status beyond the Todo API (high complexity; separate project polling loop required)
- Desktop OS notification popups (invasive, adds permission management)
- Full notification filtering DSL
- In-app thread replies
- Windows support

### Architecture Approach

The architecture follows the Ghostty pattern exactly: one `libtowncrier.a` Zig static library owns all API communication, polling scheduling, notification state, and persistence. Two platform shells consume it — the macOS Swift shell via XCFramework, and the Linux Zig shell via direct Zig import. The C ABI surface (`towncrier.h`) is the contract: opaque handles, callback registration at init, snapshot-based data delivery (frozen copies, no locks held during UI rendering), and a one-way wakeup signal from the poll thread to the main thread. Tokens never touch disk — they are passed in at `add_account` time from the shell's keychain read and held in memory only.

**Major components:**
1. **libtowncrier (Zig core)** — GitHub/GitLab API clients, poll engine (background thread, per-account scheduling), SQLite state store, C ABI surface; zero platform dependencies
2. **macOS shell (Swift/AppKit)** — NSStatusItem, NSMenu, Keychain reads, XCFramework integration; calls `towncrier_tick()` from main queue on wakeup
3. **Linux shell (Zig + GTK4 + libstray)** — D-Bus SNI tray via libstray, GTK4 popover/settings, libsecret; same ABI contract, direct Zig import (no XCFramework)

**Threading model (must be established before shells are written):**
- Poll thread: issues HTTP, diffs state, writes SQLite, updates in-memory snapshot, calls `wakeup()`
- Main thread: receives wakeup, calls `towncrier_tick()`, reads snapshot, rebuilds UI, frees snapshot
- Callbacks (`on_update`, `wakeup`) are fire-and-forget signals — no UI touches inside them

### Critical Pitfalls

1. **Swift callback context use-after-free** — ARC deallocates the Swift delegate before the Zig poll thread fires the callback. Fix: `Unmanaged<T>.passRetained(self).toOpaque()` when registering; `takeUnretainedValue()` inside the `@convention(c)` callback; explicit `.release()` on teardown. Must be in the ABI design before any async event crosses the boundary.

2. **String ownership across the C ABI is undefined without explicit convention** — Zig slices are not null-terminated; without a documented rule, heap corruption follows. Fix: document in `towncrier.h` that all strings returned to callers are heap-allocated by Zig and freed via `towncrier_free_string()`; use `[*:0]const u8` at ABI boundaries; never return stack pointers.

3. **GTK4 tray is invisible on stock GNOME Wayland** — SNI requires the AppIndicator GNOME Shell extension on GNOME; on KDE, Sway, XFCE it works natively. Fix: use `libstray`; detect `org.kde.StatusNotifierWatcher` on D-Bus at startup; surface a clear message with the extension link if absent.

4. **Token expiry handled synchronously blocks the poll thread** — synchronous 401 refresh stalls the pipeline; aggressive retry triggers secondary rate limit bans. Fix: separate token lifecycle (proactive refresh) from the poll loop; on 401, surface auth-error state to UI and stop polling — do not retry automatically.

5. **GitHub secondary rate limits are invisible until banned** — concurrent requests per account multiply across multi-account setups; secondary limits produce intermittent 403s that look like auth failures. Fix: serial requests per account; respect `Retry-After`; queue mark-as-read PATCHes as background ops; log `X-RateLimit-Remaining` from day one.

---

## Implications for Roadmap

Based on the dependency graph in ARCHITECTURE.md and the phase-specific pitfall warnings in PITFALLS.md:

### Phase 1: Core Scaffolding + ABI Contract

**Rationale:** Everything depends on this. C ABI contract, string ownership convention, and platform-gated build system must be established before any feature code is written — retrofitting is expensive.

**Delivers:** Compiling `build.zig` that produces `libtowncrier.a` on both macOS and Linux; `towncrier.h` with documented ownership rules; minimal test binary calling the ABI; no GTK/platform leakage in the core build.

**Avoids:** Pitfalls 1 (callback use-after-free), 2 (string ownership), 8 (Linux deps on macOS build), 13 (Zig version drift)

---

### Phase 2: Zig Core — GitHub Polling + SQLite State

**Rationale:** GitHub's API is simpler and better documented than GitLab's. Building GitHub end-to-end first proves the polling architecture before adding GitLab complexity.

**Delivers:** `github.zig` with `Last-Modified` conditional requests, poll engine with per-account background threads, SQLite schema in WAL mode, in-memory snapshot with RwLock, `on_update`/`wakeup` callbacks firing correctly.

**Avoids:** Pitfalls 5 (ETag invalidated by token rotation — use Last-Modified as primary), 9 (secondary rate limits — serial requests, Retry-After), 14 (misleading unread count — default `?participating=true`), 4 (token expiry — separate lifecycle from poll loop)

**Research flag:** Verify `std.Thread` is sufficient for per-account workers in Zig 0.14 (async/await story in flux).

---

### Phase 3: Linux Shell (Tray + GTK4)

**Rationale:** Linux shell is Zig-native — no XCFramework build pipeline, faster iteration. Proves ABI callbacks work end-to-end before tackling the more complex macOS build toolchain.

**Delivers:** Linux executable with D-Bus tray via `libstray`, GTK4 popover displaying notifications from core snapshot, `libsecret` credential storage with D-Bus probe, `xdg-open` browser launch.

**Avoids:** Pitfalls 3 (GNOME tray invisibility), 7 (Secret Service daemon absent), 12 (D-Bus absent in CI — mock interfaces from the start)

**Research flag:** Evaluate vendoring `libstray` vs. hand-rolling D-Bus StatusNotifierItem before starting this phase.

---

### Phase 4: macOS Shell (Swift + XCFramework)

**Rationale:** Highest integration complexity (Zig → lipo → XCFramework → Xcode → Swift). Building after Linux shell means the ABI is proven and stable before adding Swift bridging complexity.

**Delivers:** macOS app with NSStatusItem tray, NSMenu notification list, Keychain token storage via `keychain-swift`, browser launch via NSWorkspace, universal binary (arm64 + x86_64).

**Avoids:** Pitfalls 1 (callback context — `Unmanaged.passRetained`), 10 (Hardened Runtime and notarization — universal binary via lipo, Hardened Runtime enabled in Xcode target)

---

### Phase 5: GitLab Integration

**Rationale:** Same poll engine and SQLite schema as GitHub — additive, not architectural. Best done after both shells are working so GitLab can be tested end-to-end on both platforms immediately.

**Delivers:** `gitlab.zig` with Todos API polling, self-hosted base URL support, `build_failed` CI notifications, per-account pagination handling.

**Avoids:** Pitfall 6 (wrong endpoint — Todos API, not `/notification_settings`), Pitfall 11 (self-hosted version skew — check API version at account setup)

**Research flag:** Validate with users whether `build_failed`-only CI coverage is acceptable or whether a separate Pipelines API polling loop is needed.

---

### Phase 6: Auth Polish + Differentiators

**Rationale:** PAT auth covers all functional needs for a working product. OAuth device flow, notification filtering, and repo muting are UX improvements easier to add onto a working foundation.

**Delivers:** OAuth device flow for GitHub and GitLab 17.2+ (PAT fallback for older self-hosted), notification type filtering (persisted per account), repo muting.

**Avoids:** Pitfall 4 (async token refresh state machine — design before adding OAuth refresh tokens)

---

### Phase Ordering Rationale

- Core before shells: the C ABI is the foundation; both shells must build against a stable contract
- Linux before macOS: Zig-native shell iterates faster; proves ABI before adding Swift bridging complexity
- GitHub before GitLab: simpler API, better docs, same engine — get the pattern right before duplicating it
- PAT before OAuth: OAuth adds state management complexity (refresh tokens, expiry); PAT validates the full notification pipeline first
- Scaffolding pitfalls first: pitfalls that cause rewrites (ABI design, string ownership, build platform gating) all hit Phase 1 — front-loading them is non-negotiable

### Research Flags

Phases needing deeper research during planning:
- **Phase 2 (Poll engine):** Zig 0.14 `std.Thread` vs async for per-account workers — async story is in flux
- **Phase 3 (Linux shell):** `libstray` production readiness — community project, v0.4.0 March 2026, evaluate vendoring vs. hand-rolling SNI
- **Phase 5 (GitLab):** CI coverage scope — `build_failed` only vs. full pipeline polling — user validation needed

Phases with standard patterns (research-phase likely not needed):
- **Phase 1 (Scaffolding):** Well-documented Zig build patterns; Ghostty is a direct reference
- **Phase 4 (macOS shell):** XCFramework pipeline documented step-by-step; NSStatusItem is stable AppKit
- **Phase 6 (OAuth):** GitHub and GitLab 17.2+ device flow documented in official API docs

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Zig stdlib HTTP/JSON confirmed in 0.14 release notes; XCFramework pattern is Ghostty's exact approach; NSStatusItem is stable AppKit |
| Features | HIGH | GitHub and GitLab API docs verified directly; competitor analysis is secondary but consistent |
| Architecture | HIGH | Ghostty is public and battle-tested; component boundaries and threading model are well-documented |
| Pitfalls | HIGH | Swift callback/ARC issue documented in Swift Forums with confirmed workaround; GTK4 tray situation confirmed in multiple community threads; rate limit behaviour from official GitHub docs |

**Overall confidence:** HIGH

### Gaps to Address

- **libstray production readiness:** v0.4.0 is recent (March 2026); fallback is hand-rolling D-Bus StatusNotifierItem using `std.os.linux`. Decide before Phase 3.
- **Zig async story:** `std.Thread` is the safe choice for per-account poll workers in 0.14. If a third-party async runtime is needed for I/O multiplexing, decide before Phase 2.
- **GitLab CI scope:** Whether `build_failed` (Todos API) is sufficient or users need full pipeline status is a product decision — validate before Phase 5.
- **GNOME Wayland tray fallback UX:** On stock GNOME without the AppIndicator extension, the app has no tray presence. A fallback UI should be designed before the Linux shell ships.
- **Self-hosted GitLab TLS:** Zig's stdlib supports TLS 1.3 only. If self-hosted GitLab on older configurations uses TLS 1.2, a fallback is needed. Validate early if self-hosted is a priority target.

---

## Sources

### Primary (HIGH confidence)
- Mitchell Hashimoto — "Integrating Zig and SwiftUI": https://mitchellh.com/writing/zig-and-swiftui
- Ghostty source (reference implementation): https://github.com/ghostty-org/ghostty
- Zig 0.14.0 release notes: https://ziglang.org/download/0.14.0/release-notes.html
- GitHub Notifications API: https://docs.github.com/en/rest/activity/notifications
- GitHub rate limits: https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api
- GitLab Todos API: https://docs.gitlab.com/api/todos/
- GitLab Pipelines API: https://docs.gitlab.com/api/pipelines/
- GitLab OAuth2 API: https://docs.gitlab.com/api/oauth2/
- Apple NSStatusItem docs: https://developer.apple.com/documentation/appkit/nsstatusitem
- Apple Notarizing macOS Software: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

### Secondary (MEDIUM confidence)
- libstray v0.4.0: https://github.com/charlesrocket/libstray
- zig-gobject v0.3.1: https://github.com/ianprime0509/zig-gobject
- keychain-swift SPM: https://github.com/evgenyneu/keychain-swift
- vrischmann/zig-sqlite: https://github.com/vrischmann/zig-sqlite
- GNOME Discourse on GTK4 tray: https://discourse.gnome.org/t/what-to-use-instead-of-statusicon-in-gtk4-to-display-the-icon-in-the-system-tray/7175
- Swift Forums — C function pointer context capture: https://forums.swift.org/t/a-c-function-pointer-cannot-be-formed-from-a-local-function-that-captures-context/67311
- Gitify (GitHub-only competitor): https://gitify.io
- Gitlight (GitHub+GitLab Electron competitor): https://github.com/colinlienard/gitlight

---

*Research completed: 2026-04-16*
*Ready for roadmap: yes*
