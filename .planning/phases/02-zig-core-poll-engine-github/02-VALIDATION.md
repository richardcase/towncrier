---
phase: 2
slug: zig-core-poll-engine-github
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-17
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | zig build (custom steps: test-c, test-poll) |
| **Config file** | build.zig — test-c and test-poll steps |
| **Quick run command** | `zig build test-c` |
| **Full suite command** | `zig build test-c && zig build test-poll` |
| **Estimated runtime** | ~10 seconds |

---

## Sampling Rate

- **After every task commit:** Run `zig build test-c`
- **After plan 05 completes:** Run `zig build test-poll`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 2-01-01 | 01 | 1 | CORE-04, CORE-05 | — | N/A | unit | `zig build` | ❌ W0 | ⬜ pending |
| 2-01-02 | 01 | 1 | CORE-07 | — | N/A | build | `zig build` | ❌ W0 | ⬜ pending |
| 2-01-03 | 01 | 1 | CORE-07, CORE-08 | T-02-01 | No token in SQL | unit | `zig build` | ❌ W0 | ⬜ pending |
| 2-02-01 | 02 | 2 | GH-01, GH-03 | T-02-07 | N/A | unit | `zig build` | ❌ W0 | ⬜ pending |
| 2-02-02 | 02 | 2 | GH-01, GH-02, GH-04 | T-02-06 | Token not in Notification | unit | `zig build` | ❌ W0 | ⬜ pending |
| 2-03-01 | 03 | 3 | CORE-03, CORE-04, CORE-06, CORE-08 | T-02-10, T-02-14 | Token not on disk | integration | `zig build` | ❌ W0 | ⬜ pending |
| 2-04-01 | 04 | 4 | CORE-03..08, GH-01, GH-04, GH-05 | T-02-15..19 | String copies, token isolation | integration | `zig build test-c` | ❌ W0 | ⬜ pending |
| 2-05-01 | 05 | 5 | CORE-03..08, GH-01..05 | T-02-20..22 | assertTokenNotOnDisk | integration | `zig build test-poll` | ❌ W0 | ⬜ pending |
| 2-05-02 | 05 | 5 | CORE-03..08, GH-01..05 | — | N/A | integration | `zig build test-poll` | ❌ W0 | ⬜ pending |
| 2-05-03 | 05 | 5 | CORE-08 | T-02-20 | No token on disk | checkpoint | human review | N/A | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/core/poll_test.zig` — integration test binary covering all 11 requirements (created in Plan 05 Task 2)
- [ ] `build.zig` — `test-poll` step added (created in Plan 05 Task 1)
- [ ] `build.zig` — `test-c` step already exists from Phase 1 (verify still passing after each plan)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Token storage never leaves process memory | CORE-08 | Requires binary inspection of SQLite DB file | Run `strings ~/.local/share/towncrier/state.db | grep -E 'test-token'` — must return empty |
| Read/unread state survives restart | CORE-07 | Requires stopping and restarting process | Covered automatically in poll_test.zig restart scenario (step 32–39) |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
