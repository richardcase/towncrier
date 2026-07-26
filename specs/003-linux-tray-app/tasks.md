---
description: "Task list for Linux Tray App"
---

# Tasks: Linux Tray App

**Input**: Design documents from `/specs/003-linux-tray-app/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/internal-interfaces.md, quickstart.md

**Tests**: No automated test tasks — this is a GTK/tray UI shell validated manually against the DE
matrix (KDE/Cinnamon/Sway) per `quickstart.md`. Each story ends with a validation checkpoint.

**Organization**: Tasks are grouped by user story. Phases 1–2 are shared prerequisites; Phases 3–5 are
the user stories in priority order; Phase 6 is polish.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on incomplete tasks)
- **[Story]**: US1 / US2 / US3 (setup, foundational, polish have no story label)
- All paths are relative to the repo root. New shell code lives in `src/linux/`.

---

## Phase 1: Setup (build wiring + module skeleton)

**Purpose**: Get a Linux executable target building and the shell module skeleton in place.

- [ ] T001 Add the `libstray` v0.4.0 dependency to `build.zig.zon` (`zig fetch --save https://github.com/charlesrocket/libstray/archive/v0.4.0.tar.gz`)
- [ ] T002 In `build.zig`, add a `towncrier-gtk` executable target and a `linux` build step **inside** the `target.result.os.tag == .linux` guard; link `libtowncrier`, `gtk-4`, `libsecret-1`, and the `libstray` module; keep the core library and macOS build free of these symbols
- [ ] T003 [P] Create the `src/linux/` module skeleton with empty stubs + module-header comments: `main.zig`, `app.zig`, `tray.zig`, `menu.zig`, `config_window.zig`, `secrets.zig`, `browser.zig`, `dbus_probe.zig`
- [ ] T004 Verify `zig build linux` compiles the empty skeleton (a minimal `main` that inits GTK and exits), confirming the toolchain + linkage before feature work

**Checkpoint**: `zig build linux` produces `zig-out/bin/towncrier-gtk`.

---

## Phase 2: Foundational (blocking prerequisites for all stories)

**⚠️ MUST complete before any user story — these wire the core↔shell boundary and the main loop.**

- [ ] T005 [P] Implement `nameHasOwner(bus, name)` D-Bus session-bus name-ownership check in `src/linux/dbus_probe.zig` (used by both the SNI and Secret-Service probes)
- [ ] T006 [P] Implement `open(url)` (spawn `xdg-open <url>` detached) in `src/linux/browser.zig`
- [ ] T007 Define `AppState` (core handle, view-model, unread total, GTK handles) and its alloc/free lifecycle in `src/linux/app.zig` per `data-model.md`
- [ ] T008 Implement the snapshot→view-model builder in `src/linux/app.zig`: `towncrier_snapshot_get` → `RepoGroup[]` grouped by repo (alphabetical) with rows sorted by `updated_at` desc, copying out strings; free the snapshot after
- [ ] T009 Implement `main.zig`: initialize GTK4, allocate `AppState`, call `towncrier_init` registering `on_update`/`wakeup`/`on_error` with `AppState` as userdata, `towncrier_start`, then run the GTK main loop; `towncrier_free` on shutdown
- [ ] T010 Implement poll-thread→main-thread marshalling in `src/linux/app.zig`: `wakeup`/`on_update` callbacks schedule work via `g_idle_add`; on the main thread call `towncrier_tick`, rebuild the view-model (T008), and refresh open UI — no GTK/ABI calls inside the raw callbacks

**Checkpoint**: the app starts, connects to the core, and receives snapshots on the main thread (no UI yet).

---

## Phase 3: User Story 1 — Live tray icon with unread badge (Priority: P1) 🎯 MVP

**Goal**: A StatusNotifierItem tray icon appears and its badge reflects live unread counts.

**Independent Test**: On KDE/Cinnamon/Sway the tray icon shows; badge tracks poll-engine unread data (SC-001).

- [ ] T011 [US1] Define the thin `Tray` interface (`init(on_activate, ctx)`, `setIconUnreadCount`, `deinit`, `TrayError`) in `src/linux/tray.zig` per `contracts/internal-interfaces.md`
- [ ] T012 [US1] Implement the libstray backend behind `Tray` in `src/linux/tray.zig`: register the SNI item, set icon, expose the activate callback
- [ ] T013 [US1] Wire `on_update`/refresh (T010) → `tray.setIconUnreadCount(unread_total)`; badge clears at 0 (LINUX-02)
- [ ] T014 [US1] Implement the SNI-host probe at startup in `main.zig` using `dbus_probe` (`org.kde.StatusNotifierWatcher`); on absence show a GTK dialog explaining no tray host is available (GNOME → link the AppIndicator extension) instead of failing silently (LINUX-06, SC-005)
- [ ] T015 [US1] Validate SC-001 + SC-005 per `quickstart.md` scenarios 1 and 5 on KDE/Cinnamon/Sway (and a no-SNI session)

**Checkpoint**: tray icon + live badge work independently; SNI-absent path shows guidance.

---

## Phase 4: User Story 2 — Popover list grouped by repository (Priority: P1)

**Goal**: Clicking the tray opens a GTK4 popover listing unread notifications grouped by repo; clicking a row opens it and marks it read.

**Independent Test**: Popover lists grouped notifications; row click opens the URL and removes the row (SC-002, SC-003).

**Depends on**: US1 (the tray activate callback opens the popover).

- [ ] T016 [US2] Build the GTK4 popover in `src/linux/menu.zig` from the `RepoGroup[]` view-model (direct C API via `@cImport`): repo section headers + notification rows (title/type)
- [ ] T017 [US2] Wire the `Tray` activate callback (T011) to toggle/open the popover on the main thread
- [ ] T018 [US2] Implement row-activate in `src/linux/menu.zig`: call `browser.open(row.url)` then `towncrier_mark_read(core, row.id)`; the row disappears on the next refresh (LINUX-04)
- [ ] T019 [US2] Ensure the popover re-renders on refresh (T010) while open, without touching GTK off the main thread
- [ ] T020 [US2] Validate SC-002 + SC-003 per `quickstart.md` scenarios 2 and 3

**Checkpoint**: popover + open/mark-read work end-to-end on top of the tray.

---

## Phase 5: User Story 3 — Account config from the tray (Priority: P2)

**Goal**: A GitHub-only config screen adds/removes accounts; PATs are stored in libsecret; accounts begin polling immediately.

**Independent Test**: Add a GitHub PAT → account polls, PAT in libsecret; remove → account + secret gone (SC-004).

- [ ] T021 [P] [US3] Implement the `Secrets` libsecret wrapper in `src/linux/secrets.zig` (`store`/`lookup`/`delete` keyed by `{service="towncrier", account_id}`) + `probe()` for `org.freedesktop.secrets` via `dbus_probe`
- [ ] T022 [US3] Add the Secret-Service startup probe (T021 `probe`) in `main.zig`: on absence show a clear error dialog and refuse to store PATs in plaintext (Constitution IV)
- [ ] T023 [US3] Build the GTK4 config window in `src/linux/config_window.zig` (opened from the tray menu): list accounts + add-account form (GitHub PAT); GitHub-only — no GitLab fields (deferred to Phase 5)
- [ ] T024 [US3] Wire *add account*: validate PAT non-empty → `secrets.store` → `towncrier_add_account` (service=GITHUB, base_url=null); polling begins immediately (LINUX-05, SC-004)
- [ ] T025 [US3] Wire *remove account*: `towncrier_remove_account` → `secrets.delete`; account leaves the tray/list
- [ ] T026 [US3] Add a tray-menu entry that opens the config window
- [ ] T027 [US3] Validate SC-004 + the no-Secret-Service path per `quickstart.md` scenario 4 and extra checks

**Checkpoint**: full add/remove/config flow with keychain-only token storage.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] T028 [P] Thread-safety pass: confirm notifications arriving while the popover is open update it safely (all UI via `g_idle_add`), per `quickstart.md` extra checks
- [ ] T029 [P] Verify no token ever hits disk (`grep` config/share dirs for a token prefix; DB/log inspection) — Constitution IV
- [ ] T030 [P] Error/empty states: empty-notifications popover message; `on_error` surfaced as a dialog; badge-clear-at-zero confirmed
- [ ] T031 Full `quickstart.md` run-through on KDE, Cinnamon, and Sway; record results
- [ ] T032 [P] Update `CLAUDE.md` roadmap note when Phase 3 completes; add any new Linux-shell conventions to `docs/`

---

## Dependencies & Execution Order

- **Setup (Phase 1)** → **Foundational (Phase 2)** → user stories.
- **US1 (P1)** is the MVP — deliver first. **US2 (P1)** depends on US1 (tray activate opens the popover). **US3 (P2)** depends only on Foundational (independent of US1/US2, but shares the tray menu entry).
- Within a story: interface/model → backend → wiring → validation.

## Parallel Opportunities

- Setup: T003 [P] alongside T001/T002 wiring.
- Foundational: T005 [P] (dbus_probe) and T006 [P] (browser) are independent files.
- US3: T021 [P] (secrets) can start as soon as Foundational is done, in parallel with US1/US2 UI work.
- Polish: T028/T029/T030/T032 are independent [P].

## Implementation Strategy

- **MVP = Phase 1 + Phase 2 + Phase 3 (US1)**: a live tray icon with an accurate unread badge and the SNI-absent guidance path. Stop and validate on the DE matrix.
- **Incremental**: add US2 (popover + open/mark-read), then US3 (config + libsecret). Each is independently demoable.
