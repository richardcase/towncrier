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
| **Framework** | zig build test (built-in Zig test runner) |
| **Config file** | build.zig — test step wired via `b.addTest` |
| **Quick run command** | `zig build test` |
| **Full suite command** | `zig build test` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `zig build test`
- **After every plan wave:** Run `zig build test`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 10 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 2-01-01 | 01 | 1 | CORE-03 | — | N/A | unit | `zig build test` | ❌ W0 | ⬜ pending |
| 2-01-02 | 01 | 1 | CORE-04 | — | N/A | unit | `zig build test` | ❌ W0 | ⬜ pending |
| 2-01-03 | 01 | 1 | CORE-05 | — | No plaintext token on disk | unit | `zig build test` | ❌ W0 | ⬜ pending |
| 2-02-01 | 02 | 1 | GH-01 | — | N/A | unit | `zig build test` | ❌ W0 | ⬜ pending |
| 2-02-02 | 02 | 1 | GH-02 | — | N/A | unit | `zig build test` | ❌ W0 | ⬜ pending |
| 2-02-03 | 02 | 1 | GH-03 | — | N/A | unit | `zig build test` | ❌ W0 | ⬜ pending |
| 2-02-04 | 02 | 1 | GH-04 | — | N/A | unit | `zig build test` | ❌ W0 | ⬜ pending |
| 2-02-05 | 02 | 1 | GH-05 | — | N/A | unit | `zig build test` | ❌ W0 | ⬜ pending |
| 2-03-01 | 03 | 2 | CORE-06 | — | N/A | integration | `zig build test` | ❌ W0 | ⬜ pending |
| 2-03-02 | 03 | 2 | CORE-07 | — | N/A | integration | `zig build test` | ❌ W0 | ⬜ pending |
| 2-03-03 | 03 | 2 | CORE-08 | — | No token written to disk | integration | `zig build test` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `src/core/test_poll_engine.zig` — stubs for CORE-03, CORE-04, CORE-05
- [ ] `src/core/test_github.zig` — stubs for GH-01 through GH-05
- [ ] `src/core/test_integration.zig` — headless harness stubs for CORE-06, CORE-07, CORE-08
- [ ] build.zig test step wired: `b.addTest(.{ .root_source_file = ... })`

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Token storage delegates to ABI callback; shell keychain used | CORE-05 | Requires platform shell integration not available in headless tests | Run test harness, verify no `.token` or plaintext file in CWD; inspect ABI callback invocation log |
| Read/unread state survives restart | CORE-08 | Requires stopping and restarting process | Run test harness, mark notification read, kill process, restart with same DB, verify notification absent from snapshot |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 10s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
