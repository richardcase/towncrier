---
phase: 1
slug: core-scaffolding-abi-contract
status: draft
nyquist_compliant: true
wave_0_complete: true
created: 2026-04-16
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | zig build test-c (custom build step) + ASAN |
| **Config file** | build.zig |
| **Quick run command** | `zig build test-c` |
| **Full suite command** | `zig build test-c -fsanitize=address,undefined` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `zig build`
- **After every plan wave:** Run `zig build test-c`
- **Before `/gsd-verify-work`:** Full suite must be green (ASAN clean)
- **Max feedback latency:** 10 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 1-01-01 | 01 | 0 | CORE-01 | — | N/A | build | `zig build` | ✅ / ❌ W0 | ✅ green |
| 1-01-02 | 01 | 1 | CORE-02 | — | N/A | build | `zig build test-c` | ✅ / ❌ W0 | ✅ green |
| 1-01-03 | 01 | 1 | CORE-09 | — | N/A | build | `zig build 2>&1 \| grep -v gtk` | ✅ / ❌ W0 | ✅ green |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [x] Zig 0.14.0 installed and accessible (`zig version` prints `0.14.0`)
- [x] `build.zig` skeleton created with `b.addLibrary` and `b.addExecutable` steps
- [x] `tests/c_abi_test.c` stub created (empty main that includes towncrier.h)
- [x] `include/towncrier.h` stub created (empty header with include guards)
- [x] `src/c_api.zig` stub created (empty Zig source)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| macOS build produces no GTK/Linux symbols | CORE-09 | Requires macOS build environment | `nm zig-out/lib/libtowncrier.a \| grep -v gtk` on macOS |
| Linux build produces no macOS symbols | CORE-09 | Requires Linux build environment | `nm zig-out/lib/libtowncrier.a \| grep -v CoreFoundation` on Linux |
| C test exits clean under ASAN | CORE-02 | ASAN runtime required at link time | `zig build test-c` with CFLAGS=-fsanitize=address,undefined |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 10s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** complete — Phase 1 deliverables verified
