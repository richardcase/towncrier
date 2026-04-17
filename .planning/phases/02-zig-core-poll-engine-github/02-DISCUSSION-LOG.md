# Phase 2: Zig Core — Poll Engine + GitHub - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-17
**Phase:** 02-zig-core-poll-engine-github
**Areas discussed:** Poll threading model, Test harness, Mark-read mutation queue, SQLite binding

---

## Poll Threading Model

| Option | Description | Selected |
|--------|-------------|----------|
| One thread per account | Each account gets its own `std.Thread`. Simple isolation, natural per-account independence, ~8MB stack per thread acceptable at 2–5 accounts. | ✓ |
| Single coordinator thread | One thread loops all accounts with per-account interval tracking. Lower resources but more complex scheduling, sequential polling. | |

**User's choice:** One thread per account

---

## Thread Exit on remove_account

| Option | Description | Selected |
|--------|-------------|----------|
| Finish current cycle, then exit | Poll thread checks stop flag after HTTP request completes. Clean exit. | ✓ |
| Exit immediately | Atomic stop flag; may abort mid-request. Simpler signaling but requires HTTP cleanup. | |

**User's choice:** Finish current cycle, then exit

---

## Test Harness

| Option | Description | Selected |
|--------|-------------|----------|
| Live API with real token | Reads PAT from keychain or env var. Proves full stack. Not runnable in CI without secrets. | |
| Mock HTTP server in Zig | Embedded minimal HTTP listener with canned responses. Hermetic, runs in CI. | ✓ |
| Env-gated | Real token if set, skip otherwise. Tests may be silently skipped in CI. | |

**User's choice:** Mock HTTP server in Zig

---

## Mock Server Fidelity

| Option | Description | Selected |
|--------|-------------|----------|
| Simulate real GitHub behavior | Tracks If-Modified-Since, returns 304 on unchanged data, sends X-Poll-Interval. Verifies GH-03. | ✓ |
| Static canned responses only | Always returns 200 with fixed JSON. Simpler but can't verify 304 handling. | |

**User's choice:** Simulate real GitHub behavior (304 + X-Poll-Interval)

---

## Mark-Read Mutation Queue

| Option | Description | Selected |
|--------|-------------|----------|
| Mutex + ArrayList queue | Lock, append action, unlock. Poll thread drains on each cycle. Simple, proven. | ✓ |
| Lock-free ring buffer | Atomic head/tail, no Mutex. Faster under contention. Overkill for rare user action at this scale. | |

**User's choice:** Mutex + ArrayList queue

---

## SQLite Binding

| Option | Description | Selected |
|--------|-------------|----------|
| zig-sqlite (vrischmann) | Type-safe Zig wrapper, comptime query binding, maintained for 0.13+. Adds build.zig.zon dependency. | ✓ |
| Embed C amalgamation | Vendor sqlite3.c, call C API via @cImport. Zero dependencies, portable across Zig version churn. | |
| zig-sqlite with fallback plan | Start with zig-sqlite; switch to amalgamation if 0.14 breaks. | |

**User's choice:** zig-sqlite wrapper (vrischmann/zig-sqlite)

---

## Claude's Discretion

- HTTP connection reuse strategy within `src/http.zig`
- Internal module layout beyond ARCHITECTURE.md named files
- Mock server port selection and lifecycle in test binary
- Specific `zig-sqlite` version to pin

## Deferred Ideas

None
