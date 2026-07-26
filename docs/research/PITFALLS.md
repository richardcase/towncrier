# Domain Pitfalls: Towncrier

**Domain:** Cross-platform tray app — Zig core + Swift macOS shell + Zig/GTK Linux shell + GitHub/GitLab API polling
**Researched:** 2026-04-16

---

## Critical Pitfalls

These mistakes cause rewrites, hard crashes, or security failures.

---

### Pitfall 1: Swift Cannot Pass Closures as C Callbacks — Use-After-Free at Runtime

**What goes wrong:** When the Zig core library calls back into Swift (e.g., "new notifications arrived," "poll error occurred"), the Swift side will try to pass a closure as a C function pointer. Swift's compiler forbids closures that capture context from being passed as C function pointers — the compiler rejects it at compile time. Developers work around this using the `void *` context-pointer pattern, but if the Swift object holding the context is deallocated before the callback fires (ARC collected it because no other strong references exist), the callback dereferences a dangling pointer and crashes.

**Why it happens:** Swift's ARC manages objects automatically. The raw `UnsafeMutableRawPointer` passed through the C ABI is invisible to ARC — it does not hold a retain. If the Swift object goes out of scope between registering the callback and the callback being invoked, ARC frees the object.

**Consequences:** Silent memory corruption or crashes in production. The callback fires on a Zig-managed thread, making the crash non-reproducible in debug builds where object lifetimes differ.

**Prevention:**
- Use `Unmanaged<T>.passRetained(self).toOpaque()` to convert the Swift delegate to a raw pointer. This manually increments the retain count.
- Pass that pointer as the `context` parameter to the Zig-side callback registration function.
- In the C callback (which Swift implements as a `@convention(c)` free function), reconstruct the Swift object with `Unmanaged<T>.fromOpaque(ctx).takeUnretainedValue()`.
- Explicitly call `.release()` via `Unmanaged<T>.fromOpaque(ctx).release()` when unregistering the callback or tearing down the library.
- Never use `takeRetainedValue()` unless you understand that it decrements the retain count on access.

**Detection:** If the app crashes in the Zig callback thread after the main window is dismissed or the app goes to background, this is the likely cause. Enable Swift's address sanitizer (`-sanitize=address`) early. The crash will be in a `objc_release` or free path called from inside Zig-dispatched callback code.

**Phase:** Address in Phase 1 when the first C ABI callback is designed. The pattern must be established before any async events cross the boundary.

---

### Pitfall 2: String Ownership Across the C ABI Is Undefined Without Explicit Convention

**What goes wrong:** Zig's native string type is a slice (`[]const u8`) — it has a pointer and a length, and is not null-terminated. C strings are null-terminated `char *`. Swift `String` is a fully managed value type. When strings cross the boundary (notification titles, repo names, error messages), the receiving side may:
- Read past the end of a non-null-terminated buffer.
- Free memory it does not own (or fail to free memory it does own).
- Hold a pointer to stack-allocated Zig memory that has already been popped.

**Why it happens:** Without a documented and enforced convention, each function at the boundary makes different assumptions. Stack-allocated strings in Zig become dangling pointers the moment the Zig function returns.

**Consequences:** Intermittent garbled text, heap corruption, use-after-free crashes that appear only under load.

**Prevention:**
- Choose one convention for the entire ABI and document it in `towncrier.h`:
  - **Recommended:** The Zig side heap-allocates strings it returns to the caller using a single named allocator. The caller (Swift or Zig shell) is responsible for calling a paired `towncrier_free_string(char *)` function. Never return stack pointers.
  - For strings passed *into* Zig (e.g., configuration values, tokens), use `[*:0]const u8` (null-terminated pointer) — Swift's `String.withCString` safely provides this.
- Export a single `towncrier_free_string` function from the Zig core. Never assume the Swift side can call `free()` directly — the allocator used in Zig must be the one that frees.
- Use Zig's `[*:0]const u8` type for all ABI-boundary string exports so the compiler enforces null termination.

**Detection:** Run the full integration under valgrind (Linux) or AddressSanitizer. Any string returned from the Zig side should be logged with its address and verified to be heap-allocated, not stack-allocated.

**Phase:** Define the string convention in the ABI design phase (Phase 1) before implementing any function that returns a string. Enforce it via code review on every subsequent ABI addition.

---

### Pitfall 3: GTK4 Has No Built-In Tray Icon — GNOME Wayland Requires a Shell Extension the User Must Install

**What goes wrong:** GTK removed `GtkStatusIcon` in GTK4. On GNOME Wayland (the default on Fedora, Ubuntu 22.04+, and most modern distros), tray icons do not exist at the protocol level. The StatusNotifierItem (SNI/AppIndicator) protocol is the modern replacement, but on GNOME it only works if the user has the "AppIndicator and KStatusNotifierItem Support" GNOME Shell extension installed. Without it, the tray icon is simply invisible — no error, no warning, the app just has no tray presence.

**Why it happens:** GNOME's design philosophy explicitly rejects persistent tray icons. Wayland's protocol does not include a system tray spec. GNOME relies on extensions (which are opt-in and version-sensitive) to bridge the gap.

**Consequences:** The app's primary UI surface is invisible to the majority of GNOME Wayland users out of the box. On KDE Plasma, Cinnamon, XFCE, and Sway, SNI works without any extension.

**Prevention:**
- Use `libayatana-appindicator` (the maintained fork of `libappindicator`) which implements the SNI D-Bus protocol. This works natively on KDE, Cinnamon, and Sway without any user action.
- For GNOME specifically: detect at startup whether a StatusNotifierWatcher is available on D-Bus (`org.kde.StatusNotifierWatcher`). If absent, display an in-app notification or fallback window explaining that the GNOME AppIndicator extension is required, with a link to `https://extensions.gnome.org/extension/615/appindicator-support/`.
- Do not use `GtkStatusIcon` — it is GTK3-only and removed in GTK4.
- Do not use `GDK_BACKEND=x11` as a workaround in production — it disables Wayland and breaks HiDPI scaling.
- Do not link against the old `libappindicator-gtk3` — it is deprecated; use `libayatana-appindicator3-1`.

**Detection:** Test on a stock Fedora 40+ install (GNOME Wayland, no extensions) and a stock KDE Plasma install. If the tray icon is invisible on GNOME but visible on KDE, you have confirmed the problem.

**Phase:** Address in Phase 2 (Linux tray shell). Do not assume tray icon works until tested on a clean GNOME Wayland VM.

---

### Pitfall 4: GitHub OAuth Token Expiry Blocks the Poll Thread If Handled Synchronously

**What goes wrong:** GitHub App installation tokens expire after 1 hour. GitHub OAuth device flow tokens can also expire. If token refresh is performed synchronously on the poll thread — i.e., the poll loop detects a 401, blocks to refresh, then retries — the entire notification pipeline stalls for the refresh duration. If the refresh fails (network error, revoked token), the poll loop may retry aggressively or crash, potentially hammering the API or triggering rate limiting bans.

**Why it happens:** The simplest implementation is synchronous: poll, get 401, refresh, retry. This works until refresh takes more than a few seconds or fails entirely.

**Consequences:** UI freezes if poll is on the main thread; missed notifications; secondary rate-limit bans from rapid retry; token stored in keychain is stale and the app never recovers without a restart.

**Prevention:**
- Separate token lifecycle management from the poll loop. The poll loop should read tokens from an in-memory cache. A separate token-refresh coroutine/thread manages expiry proactively (refresh before expiry, not after 401).
- On 401, the poll loop should surface an "authentication error" state to the UI and stop polling for that account — it should not retry automatically.
- Use a mutex or channel to prevent multiple simultaneous refresh attempts for the same account (the "thundering herd" on token expiry).
- Store both `access_token` and `refresh_token` atomically in the keychain. Never write one without the other.
- For GitLab specifically: access tokens expire after 2 hours; refresh tokens must be cycled atomically — invalidating both old tokens and storing the new pair in a single keychain operation.
- For GitHub PATs: they do not expire unless set to, but fine-grained tokens have shorter lifetimes; check `X-OAuth-Scopes` header on first use.

**Detection:** Manually expire a token in the keychain, restart the app, and verify the UI surfaces an actionable error rather than silently stopping notifications. Simulate a network failure during refresh.

**Phase:** Address in Phase 3 (OAuth integration). The token refresh state machine should be designed before the polling engine, not retrofitted.

---

## Moderate Pitfalls

---

### Pitfall 5: GitHub ETag Cache Is Invalidated by Token Rotation

**What goes wrong:** GitHub's conditional request system uses ETags stored per-endpoint. When an OAuth installation token expires and a new one is generated, the previously cached ETags become invalid — GitHub returns fresh 200 responses instead of 304s, consuming rate limit quota on every poll cycle immediately after token rotation.

**Why it happens:** The GitHub documentation explicitly states: "If the token expires and you generate a new one, the ETags cached are no longer valid."

**Consequences:** After every hourly token rotation, the poll loop may exhaust a significant portion of the 5,000 request/hour limit with full-payload responses instead of lightweight 304s.

**Prevention:**
- Use the `Last-Modified` / `If-Modified-Since` header pair as the primary caching mechanism for the notifications endpoint, falling back to ETags. `Last-Modified` survives token rotation.
- Store ETags and Last-Modified timestamps per account, per endpoint.
- After a token refresh, add a brief backoff before the next poll to absorb the ETag cache miss gracefully.
- Always check `X-RateLimit-Remaining` before each poll. If below a threshold (e.g., 100), back off to a longer polling interval regardless of configured poll interval.

**Detection:** Log `X-RateLimit-Remaining` on each response. A sharp drop after a known token rotation event confirms this problem.

**Phase:** Address in Phase 2 (polling engine). Implement Last-Modified support alongside ETag from the start.

---

### Pitfall 6: GitLab "Notifications" API Is Not What You Think — Todo API Is the Real Source

**What goes wrong:** The GitLab API has a `GET /notification_settings` endpoint. This sounds like it returns your notifications. It does not — it returns your notification *preference settings* (whether you want email, what events trigger notifications). Actual actionable items live in the **Todos API** (`GET /todos`). This confusion is extremely common and wastes development time.

**Why it happens:** Misleading naming. The Notifications API is a preferences API, not an event feed.

**Consequences:** Building the GitLab integration against the wrong endpoint, discovering it returns a single preferences object rather than a list of notification events, and having to redesign.

**Prevention:**
- Use `GET /todos` as the primary notification feed for GitLab. It returns: assigned issues/MRs, mentions, approval requests, failed builds (`build_failed`), and direct addressing.
- CI pipeline status beyond `build_failed` (e.g., pipeline success, stage failures, specific job logs) requires `GET /projects/:id/pipelines` polled separately — the Todo API does not cover granular pipeline events.
- GitLab pagination uses offset-based (`?page=N&per_page=100`) and keyset cursor pagination. For large accounts, offset pagination omits `X-Total` and `X-Total-Pages` headers when results exceed 10,000 — use the `Link` header's `rel="next"` to drive pagination rather than relying on total counts.
- GitLab's rate limit headers are `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset` — different capitalization from GitHub's `X-RateLimit-*` headers.

**Detection:** In development, manually call `GET /notification_settings` and `GET /todos` against a real GitLab account and compare responses. The preferences endpoint will be obvious immediately.

**Phase:** Address in Phase 2 (GitLab API client). Add an explicit comment in the code and ADR noting why `notification_settings` is not used.

---

### Pitfall 7: Linux Secret Service Daemon May Not Be Running

**What goes wrong:** `libsecret` communicates with a Secret Service daemon over D-Bus. On a GNOME desktop, `gnome-keyring-daemon` typically provides this service. On KDE Plasma 6, `ksecretd` does. On minimal desktops (XFCE, i3, Sway, headless), no daemon is running at all — `libsecret` calls return errors silently or block indefinitely.

**Why it happens:** The Secret Service daemon is not a mandatory Linux service. It is started by GNOME/KDE session managers. Users on minimal window managers or custom setups often have no daemon.

**Consequences:** Token storage silently fails. The app stores nothing, prompts for tokens every launch, or crashes depending on how errors are handled.

**Prevention:**
- At startup on Linux, probe for the Secret Service daemon by attempting a D-Bus name lookup for `org.freedesktop.secrets` before using libsecret. If absent, present the user with a clear error: "No Secret Service daemon found. Install gnome-keyring or keepassxc and enable its Secret Service feature."
- Do not treat a libsecret failure as fatal — fall back to prompting for re-entry of credentials and do not cache them in plaintext. Never silently swallow the error.
- Document in installation notes that `gnome-keyring` or `kwallet` (with Secret Service bridge enabled) is required on Linux. KeePassXC also implements the Secret Service protocol and is a valid alternative.
- Do not attempt to store tokens in a fallback plaintext file — this violates the project's security constraint and silently reduces security without user awareness.

**Detection:** Test in a Docker container or minimal VM running only a window manager (i3, openbox) with no GNOME/KDE session manager. Verify the app surfaces a clear user-facing error rather than crashing or silently failing.

**Phase:** Address in Phase 2 (Linux token storage). Probe-and-surface pattern must be in place before the Linux tray shell ships.

---

### Pitfall 8: Zig Build Breaking the macOS Dev Machine When GTK Is a Linux-Only Dependency

**What goes wrong:** The Linux tray shell links against GTK (`libgtk-4`, `libayatana-appindicator3`). These libraries do not exist on macOS. If the `build.zig` unconditionally calls `addSystemLibrary("gtk4")` or `addSystemLibrary("ayatana-appindicator3-0.1")`, the macOS build fails with a linker error. This is a daily developer-experience tax that slows iteration on the macOS shell.

**Why it happens:** Zig's build system is code — it is easy to forget to gate platform-specific dependencies behind a `target.os.tag` check.

**Consequences:** macOS developers cannot build the project at all without commenting out Linux-specific lines. CI for macOS fails. Continuous friction discourages developers from keeping the build working across platforms.

**Prevention:**
- In `build.zig`, gate all GTK and AppIndicator dependencies behind `if (target.result.os.tag == .linux)`. The Ghostty project uses this pattern extensively and is a direct reference for this project's architecture.
- The Zig core library (`libcore`) should have zero platform-specific system library dependencies — it must build on both platforms identically.
- Keep a CI job that builds the core library on macOS even if the macOS tray shell is built by Xcode — this catches regressions where Linux-only code leaks into the core.
- Use `zig build --help` and test the build on both platforms on every PR.

**Detection:** Running `zig build` on macOS should succeed and produce the core static library. If it fails with a "library not found" error for any GTK or Linux-specific package, the guard is missing.

**Phase:** Address in Phase 1 (project scaffolding). The build.zig structure must be platform-aware before any GTK code is added.

---

### Pitfall 9: GitHub API Secondary Rate Limits Are Invisible Until Banned

**What goes wrong:** GitHub has two rate limiting tiers. The primary limit (5,000 requests/hour for authenticated users) is well-documented and returns clear `X-RateLimit-*` headers. Secondary rate limits are less visible: no more than 100 concurrent requests, no more than 900 points/minute per endpoint, and triggering secondary limits can result in a temporary ban rather than just a 429 response. A polling app that opens multiple concurrent requests per account (e.g., parallel fetches for different notification types) can trigger secondary limits silently.

**Why it happens:** The notifications endpoint may spawn multiple follow-up requests (fetching thread details, marking as read). If these are issued concurrently per account and the app has multiple accounts, the concurrency multiplies quickly.

**Consequences:** Intermittent 429s or 403s that look like auth failures; eventual integration banning from GitHub; rate limit exhaustion that prevents notifications from arriving for the rest of the hour.

**Prevention:**
- Issue all requests for a given account *serially*, not concurrently. One request at a time per account.
- Respect `Retry-After` headers on 429 responses. On repeated failures, apply exponential backoff with jitter.
- For marking notifications as read (PATCH requests), queue these as a background operation after displaying results — do not block the poll cycle on them. PATCH/POST/PUT requests cost 5 rate limit points vs 1 for GET.
- Log `X-RateLimit-Remaining` on every response during development. Set an alert threshold (e.g., warn at < 500 remaining).

**Detection:** Add metrics for `X-RateLimit-Remaining` per account per poll cycle. A value that drops faster than expected (more than ~1 per poll when using ETags) indicates concurrent or redundant requests.

**Phase:** Address in Phase 2 (polling engine design). Concurrency budget must be defined before the poller is written, not after rate-limiting complaints appear.

---

### Pitfall 10: macOS Hardened Runtime Blocks Zig Static Library by Default

**What goes wrong:** macOS Gatekeeper and the Hardened Runtime are required for notarization. The Hardened Runtime imposes memory protection rules — specifically, it defaults to disabling writable+executable memory (`com.apple.security.cs.allow-jit` must be explicitly granted if needed). A Zig-compiled static library linked into the Swift app inherits the app's Hardened Runtime policy. If the Zig library uses any JIT-style code generation, memory tricks, or runtime code patching, it will crash under the Hardened Runtime with an SIGKILL.

For Towncrier specifically (an API poller with no JIT), this is unlikely to be a problem. However, notarization also requires that the `.xcarchive` includes the Zig static library in a form that passes Apple's automated scan. A static library with undefined symbols, or one built without the correct architecture slices for universal binary (x86_64 + arm64), will fail notarization.

**Why it happens:** Developers test on their development machine (Apple Silicon) and forget to produce a universal binary. The x86_64 slice is needed for Intel Macs and for Rosetta compatibility.

**Consequences:** Notarization rejection; the distributed app cannot be opened on Intel Macs.

**Prevention:**
- Build the Zig core library for both `aarch64-macos` and `x86_64-macos` targets in CI.
- Merge into a universal binary with `lipo -create`.
- Bundle as an XCFramework as Mitchell Hashimoto describes — this is the correct mechanism for distributing multi-arch static libraries to Xcode.
- Enable Hardened Runtime in the Xcode project target. Verify the linked Zig library does not require any Hardened Runtime exception entitlements.
- For notarization: the app must be signed with a Developer ID Application certificate, not just an ad-hoc or development certificate.

**Detection:** Run `lipo -info libcore.a` after build to confirm both architecture slices are present. Run `codesign -vvv --deep` on the final `.app` to check signing. Submit to notarization in CI and fail the build on rejection.

**Phase:** Address in Phase 4 (macOS packaging and distribution). Set up the universal binary build pipeline before the first TestFlight or public distribution.

---

## Minor Pitfalls

---

### Pitfall 11: GitLab Self-Hosted Instances Have Inconsistent API Versions

**What goes wrong:** GitLab self-hosted instances may be months or years behind gitlab.com in API version. Features present on gitlab.com (e.g., specific Todo action types, pipeline events) may be absent on a customer's self-hosted instance. The API version is discoverable via `GET /api/v4/version`, but self-hosted admins may not have upgraded.

**Prevention:** Target the lowest-common-denominator API features (Todo list, basic pagination). Document the minimum GitLab version supported (recommend 15.0+). Gracefully degrade when newer endpoints return 404.

**Phase:** Address during GitLab API client implementation. Add a version check at account setup time.

---

### Pitfall 12: D-Bus Availability on Linux Is Not Guaranteed in All Test Environments

**What goes wrong:** Both libsecret (Secret Service) and StatusNotifierItem (tray icon) rely on D-Bus. Docker containers and some CI environments do not have a D-Bus session bus running. Tests that call libsecret or attempt to register a tray icon will hang or crash in CI.

**Prevention:** Abstract the keychain and tray icon behind interfaces in the Zig core and Linux shell. In CI, run tests with mock implementations that bypass D-Bus. Use `dbus-run-session` to provide a session bus in integration test environments when needed.

**Phase:** Address in Phase 2 when setting up Linux CI. Use mock implementations from the start.

---

### Pitfall 13: Zig's Build System Is Unstable Across Minor Versions

**What goes wrong:** Zig's build system API (`build.zig`) has changed significantly between 0.11, 0.12, 0.13, and 0.14. Functions like `addSystemLibrary`, `addModule`, and step dependencies were renamed or restructured. If the team is not pinned to a specific Zig version, `build.zig` may silently fail or produce different behavior on different developer machines.

**Prevention:** Pin the exact Zig version in `build.zig.zon` and document it in the README. Use `zigup` or the Zig version manager to enforce the pinned version. Do not upgrade Zig mid-milestone without a dedicated migration task.

**Phase:** Address in Phase 1 (project scaffolding). Pin the version before any code is written.

---

### Pitfall 14: GitHub Notifications Endpoint Polls All Repos — Unread Count Can Be Misleading

**What goes wrong:** `GET /notifications` returns all unread notifications across all repositories the user has access to, including repositories in organizations they barely participate in. This can surface hundreds of "unread" notifications the user never intended to see, making the badge count overwhelming and reducing trust in the app.

**Prevention:** Expose per-repository and per-organization filtering in the account configuration. Default to filtering to repositories the user has explicitly participated in (use `?participating=true` query parameter as the default, not the raw unread feed). Document this default visibly.

**Phase:** Address in Phase 2 (GitHub API client design). The `?participating=true` default should be in the initial implementation, not added later after user complaints.

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|---|---|---|
| C ABI design (Phase 1) | Callback context use-after-free (Pitfall 1) | Define retain/release ownership contract before writing any callback |
| C ABI design (Phase 1) | String ownership undefined (Pitfall 2) | Document allocator + free convention in `towncrier.h` from day one |
| Project scaffolding (Phase 1) | Zig version drift (Pitfall 13) | Pin Zig version in `build.zig.zon` on first commit |
| Project scaffolding (Phase 1) | Linux deps on macOS build (Pitfall 8) | Gate GTK deps behind `target.os.tag == .linux` immediately |
| GitHub API client (Phase 2) | ETag invalidated by token rotation (Pitfall 5) | Use `Last-Modified` as primary cache header |
| GitHub API client (Phase 2) | Secondary rate limit ban (Pitfall 9) | Serial requests per account, respect Retry-After |
| GitHub API client (Phase 2) | Misleading unread count (Pitfall 14) | Default to `?participating=true` |
| GitLab API client (Phase 2) | Wrong notifications endpoint (Pitfall 6) | Use Todos API, not Notification Settings API |
| GitLab API client (Phase 2) | Self-hosted version skew (Pitfall 11) | Check API version at account setup |
| Polling engine (Phase 2) | Token expiry blocking poll thread (Pitfall 4) | Separate token lifecycle management from poll loop |
| Linux tray shell (Phase 2) | GTK4 tray invisible on GNOME Wayland (Pitfall 3) | Use libayatana-appindicator, detect SNI watcher at startup |
| Linux token storage (Phase 2) | Secret Service daemon absent (Pitfall 7) | Probe D-Bus before calling libsecret |
| Linux CI setup (Phase 2) | D-Bus not available in CI (Pitfall 12) | Mock keychain and tray in test environments |
| OAuth integration (Phase 3) | Synchronous token refresh blocks UI (Pitfall 4) | Async token refresh with error state surfaced to UI |
| macOS packaging (Phase 4) | Zig library fails notarization (Pitfall 10) | Universal binary (lipo), XCFramework, Hardened Runtime |

---

## Sources

- Mitchell Hashimoto, "Integrating Zig and SwiftUI": https://mitchellh.com/writing/zig-and-swiftui
- Swift Forums — C function pointer context capture: https://forums.swift.org/t/a-c-function-pointer-cannot-be-formed-from-a-local-function-that-captures-context/67311
- GitHub REST API best practices: https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api
- GitHub rate limits: https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api
- GitLab Todos API: https://docs.gitlab.com/api/todos/
- GitLab Notification Settings API: https://docs.gitlab.com/api/notification_settings/
- GitLab REST API pagination: https://docs.gitlab.com/api/rest/
- GNOME Discourse — GTK4 tray icons: https://discourse.gnome.org/t/what-to-use-instead-of-statusicon-in-gtk4-to-display-the-icon-in-the-system-tray/7175
- GNOME Shell AppIndicator extension: https://extensions.gnome.org/extension/615/appindicator-support/
- Northflank — GitLab expiring OAuth tokens: https://northflank.com/blog/supporting-expiring-oauth-access-tokens-for-gitlab
- GNOME libsecret: https://wiki.gnome.org/Projects/Libsecret
- Apple — Configuring macOS App Sandbox: https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox
- Apple — Notarizing macOS software: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Zig strings and C interop: https://mtlynch.io/notes/zig-strings-call-c-code/
