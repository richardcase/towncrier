# Technology Stack: Towncrier

**Project:** Towncrier — cross-platform GitHub/GitLab notification tray app
**Researched:** 2026-04-16
**Zig version baseline:** 0.14.0 (stable, released March 2025)

---

## Recommended Stack

### Core Library (Zig)

| Technology | Version | Purpose | Rationale |
|------------|---------|---------|-----------|
| Zig | 0.14.0 | Core language | Current stable. 0.14 introduced `addLibrary()` (replaces `addStaticLibrary`/`addSharedLibrary`), incremental compilation, and a faster x86 backend. Use 0.14, not master — master breaks APIs between releases. |
| std.http.Client | stdlib | GitHub/GitLab REST API polling | Built-in, supports HTTP/1.1 with connection pooling, TLS 1.3, compression, and custom headers. Sufficient for polling intervals of 30–300s. No third-party dependency needed. |
| std.json | stdlib | Parsing API responses | Type-safe `parseFromSlice` into Zig structs. Handles GitHub/GitLab JSON cleanly. No third-party JSON library needed for structured API responses. |
| build.zig | stdlib | Build system | Native Zig build. Produces static `.a` library with `b.addLibrary(.{ .linkage = .static })`. Supports multi-target: build for `aarch64-macos` and `x86_64-linux` from one machine. |

**What NOT to use in the core:**
- `zig-json` (berdon/berdon) — only adds JSON5/NaN support; irrelevant for well-formed API JSON.
- `http.zig` (karlseguin) — HTTP server library, not a client. Ignore.
- `requestz` / `ducdetronquito` — abandoned; last activity 2022–2023.
- Zig `master` / nightly — API breaks frequently. Pin to 0.14.0 in `build.zig.zon`.

---

### macOS Shell (Swift/Xcode)

| Technology | Version | Purpose | Rationale |
|------------|---------|---------|-----------|
| Swift | 5.10+ (Xcode 16) | macOS tray app language | Required for NSStatusItem/AppKit access. Same approach as Ghostty. |
| AppKit / NSStatusItem | macOS 11+ | Menu bar icon + menu | Use NSStatusItem directly, not SwiftUI MenuBarExtra. NSStatusItem has no minimum version constraint beyond macOS 11. MenuBarExtra requires macOS Ventura (13+) and lacks APIs to programmatically control the menu state, access the underlying NSWindow, or set the popup visibility — all of which are needed for a notification tray with a live list. |
| Security.framework | macOS 11+ | Keychain token storage | Native OS framework. Use `SecItemAdd` / `SecItemCopyMatching` / `SecItemUpdate` directly, or wrap with the `keychain-swift` SPM package (evgenyneu/keychain-swift, actively maintained, ~7.5k stars) for ergonomic Swift API. Do not store tokens in `UserDefaults` or plist files. |
| XCFramework | Xcode 12+ | Packages Zig static lib for Swift | The proven integration path (identical to Ghostty). Build flow: `zig build` → `.a` static lib → `libtool` bundle → `lipo` universal binary (arm64 + x86_64) → `xcodebuild -create-xcframework`. Requires a `module.modulemap` + C header. |

**Swift ↔ Zig C ABI integration pattern (from Ghostty):**

1. Zig exports functions with `export fn` using only C-compatible types in signatures.
2. Write a C header (e.g., `towncrier.h`) matching every exported symbol.
3. Create `module.modulemap` pointing at the header.
4. Bundle into `.xcframework` via `xcodebuild -create-xcframework`.
5. Add the XCFramework to the Xcode project. Swift imports it as `import TowncrierKit` — Xcode auto-bridges C types.

**What NOT to use on macOS:**
- SwiftUI `MenuBarExtra` — too restrictive for a notification list UI; missing programmatic control APIs.
- Swift Package Manager for the Zig lib — XCFramework is the correct packaging unit for a compiled C-ABI library.
- `KeychainAccess` (kishikawakatsumi) — archived/unmaintained since 2023. Use `keychain-swift` or Security.framework directly.

---

### Linux Shell (Zig + GTK)

| Technology | Version | Purpose | Rationale |
|------------|---------|---------|-----------|
| GTK4 | 4.x | UI framework for Linux shell | GTK4 is the current generation. GTK3 enters maintenance-only mode. |
| libstray | 0.4.0 (March 2026) | System tray icon + menu | **Critical finding.** GTK4 dropped `GtkStatusIcon`. `libayatana-appindicator` only supports GTK3 (mixing GTK3 and GTK4 in one process is impossible). `libstray` (charlesrocket/libstray) is a C+Zig library implementing StatusNotifierItem over raw D-Bus — no GTK, no GLib, no Qt dependency. Actively maintained with v0.4.0 shipped March 2026. Ships with `build.zig` and `build.zig.zon` so it integrates directly into the Zig build system. Tested on KDE, GNOME, Hyprland, eww. |
| zig-gobject | v0.3.1 (Nov 2025) | GTK4 Zig bindings | For the popup/settings window in the Linux shell. Ian Johnson's `zig-gobject` generates bindings via GObject introspection. v0.3.1 is the latest stable. **Experimental** — expect API churn, requires `xsltproc` as system dep. Alternative: call GTK4 C API directly from Zig (no bindings layer); this is simpler for a small UI surface. |
| libsecret | 0.21.x | Keychain: Linux Secret Service | Standard GNOME library for the org.freedesktop.secrets D-Bus API (backed by gnome-keyring or KWallet in secret-service mode). It is a C library — call via Zig's C interop (`@cImport`). No Zig-specific binding needed. |

**GTK4 tray approach decision — use libstray directly:**

The ecosystem situation is messy. The clean path is:
- Tray icon + tray menu → `libstray` (C+Zig, D-Bus, no GTK involved)
- Settings/config window → GTK4 (either direct C calls from Zig or `zig-gobject`)
- Keep them decoupled: libstray handles the SNI D-Bus session; GTK4 handles windowed UI

This mirrors what several projects discovered independently: org.kde.StatusNotifierItem does not require GTK, making it usable alongside GTK4 without the version-mixing problem.

**What NOT to use on Linux:**
- `libayatana-appindicator` — GTK3 only; incompatible with GTK4 in the same process. Multiple open issues (2021+) with no GTK4 support. Do not use.
- `GtkStatusIcon` — removed in GTK4. Do not use.
- `capy` — cross-platform UI abstraction; adds abstraction cost and reduces control over tray behavior; unnecessary for a targeted Linux+macOS app that already has platform-specific shells.
- `zig-gtk4` (paveloom-z) — appears abandoned; last significant activity 2022–2023. Prefer `zig-gobject` or direct C calls.

---

### Build System

| Aspect | Recommendation | Notes |
|--------|---------------|-------|
| Core lib build | `build.zig` with `b.addLibrary(.{ .linkage = .static })` | Produces `libtowncrier.a` consumed by both shells |
| macOS packaging | `build.zig` step calls `lipo` + `xcodebuild -create-xcframework` | Automate via `b.addSystemCommand` in build.zig or a Makefile wrapper |
| Linux executable | `build.zig` with `b.addExecutable` linking GTK4 and libstray | Use `exe.linkSystemLibrary("gtk-4")` and link libstray as a dependency |
| Dependency management | `build.zig.zon` with `zig fetch --save` for libstray | Zig 0.14 package manager handles this cleanly |
| Zig version pinning | `.minimum_zig_version = "0.14.0"` in `build.zig.zon` | Prevents accidental master-branch breakage |

---

## Confidence Levels

| Area | Confidence | Basis |
|------|------------|-------|
| Zig C ABI / Swift XCFramework | HIGH | Ghostty is public, proven, Mitchell Hashimoto's blog post is a direct blueprint |
| std.http for API polling | HIGH | Official stdlib docs + Zig 0.14 release notes confirm HTTP/1.1 + TLS 1.3 + custom headers |
| std.json for API parsing | HIGH | Official stdlib; `parseFromSlice` into typed structs is well-documented |
| GTK4 + libstray tray approach | MEDIUM-HIGH | libstray v0.4.0 confirmed working on KDE/GNOME/Hyprland; SNI approach verified by multiple projects. Risk: some minimal desktop environments lack an SNI host. |
| zig-gobject for GTK4 UI | MEDIUM | v0.3.1 released Nov 2025, actively maintained, but self-described as experimental. Direct C calls to GTK4 are a lower-risk alternative for a small UI surface. |
| Security.framework (macOS) | HIGH | Apple first-party; NSStatusItem + Keychain Services are stable, long-standing APIs |
| libsecret (Linux) | MEDIUM | Well-established C library; no Zig-specific bindings needed (use @cImport). Risk: not all Linux desktops run a Secret Service daemon (headless servers, some minimal DEs). |
| build.zig multi-target | HIGH | Cross-compilation is a core Zig feature; `addLibrary` static output confirmed in 0.14 release notes |

---

## Key Risks

1. **libstray SNI host availability:** On GNOME, SNI tray support requires either the AppIndicator GNOME Shell extension or a compatible compositor. Sway/KDE/XFCE work natively. Pure GNOME Shell without the extension will not show the tray icon. This is a known limitation of the SNI approach and should be documented.

2. **zig-gobject API instability:** If using zig-gobject for the settings window, pin to v0.3.1. For a small number of GTK widgets (a preferences window with a list of accounts), calling GTK4's C API directly via `@cImport` is a viable lower-risk alternative that avoids the binding layer entirely.

3. **std.http TLS 1.3 only:** Zig's stdlib TLS implementation supports only TLS 1.3. GitHub.com and gitlab.com both support TLS 1.3. Self-hosted GitLab instances on older configurations might be TLS 1.2 only. If self-hosted GitLab is a priority target, test this early and consider `curl` via subprocess or `libssl` via C interop as a fallback.

4. **macOS universal binary orchestration:** Building the XCFramework requires running `lipo` and `xcodebuild` as part of the build pipeline. This step only works on macOS. Linux-only CI machines cannot produce the macOS XCFramework — macOS CI runners are required for macOS release artifacts.

---

## Installation Sketch

```bash
# Zig toolchain
# Install Zig 0.14.0 from https://ziglang.org/download/

# Linux: system dependencies
apt install libgtk-4-dev libsecret-1-dev libdbus-1-dev

# macOS: no system deps (Security.framework and AppKit are OS-provided)
# Xcode 16+ required for Swift 5.10 and XCFramework tooling

# Zig package dependencies (in build.zig.zon)
# zig fetch --save https://github.com/charlesrocket/libstray/archive/v0.4.0.tar.gz
# zig fetch --save https://github.com/ianprime0509/zig-gobject/archive/v0.3.1.tar.gz
```

---

## Sources

- Mitchell Hashimoto — Integrating Zig and SwiftUI: https://mitchellh.com/writing/zig-and-swiftui
- Ghostty build.zig (reference implementation): https://github.com/ghostty-org/ghostty/blob/main/build.zig
- Zig 0.14.0 Release Notes: https://ziglang.org/download/0.14.0/release-notes.html
- Zig build system docs: https://ziglang.org/learn/build-system/
- libstray (StatusNotifierItem C+Zig, v0.4.0): https://github.com/charlesrocket/libstray
- zig-gobject (GTK4 Zig bindings, v0.3.1): https://github.com/ianprime0509/zig-gobject
- libayatana-appindicator GTK4 issue (GTK3 only, no GTK4 path): https://github.com/AyatanaIndicators/libayatana-appindicator
- Transmission GTK4 SNI migration discussion: https://github.com/transmission/transmission/issues/7364
- Ziggit thread on D-Bus system tray in Zig: https://ziggit.dev/t/system-tray-icons-via-d-bus/12750
- zig-gobject Ziggit announcement: https://ziggit.dev/t/zig-gobject-gobject-gtk-etc-bindings-for-zig/3306
- GNOME Discourse on GTK4 tray replacement: https://discourse.gnome.org/t/what-to-use-instead-of-statusicon-in-gtk4-to-display-the-icon-in-the-system-tray/7175
- keychain-swift (Swift SPM Keychain wrapper): https://github.com/evgenyneu/keychain-swift
- NSStatusItem Apple Developer Docs: https://developer.apple.com/documentation/appkit/nsstatusitem
- Zig C ABI overview: https://zig.guide/working-with-c/abi/
- std.json documentation: https://zig.guide/standard-library/json/
