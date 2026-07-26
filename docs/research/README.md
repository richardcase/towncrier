# Project Research (reference)

Project-level research carried over verbatim during the migration from GSD to
[GitHub Spec Kit](https://github.com/github/spec-kit). These documents are **reference**,
not governance — the Towncrier constitution (`.specify/memory/constitution.md`) governs, and
the versioned technology stack lives in `CLAUDE.md`.

Unlike Spec Kit's per-feature `specs/NNN-*/research.md`, this material is cross-cutting and
applies across phases, so it lives here rather than inside any single spec.

| Document | What it covers |
|----------|----------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Conceptual model, C ABI design, threading model, build.zig structure, repo layout |
| [PITFALLS.md](PITFALLS.md) | Domain pitfalls (Zig ABI/FFI, build system, keychain, tray/SNI) with root causes |
| [FEATURES.md](FEATURES.md) | GitHub/GitLab API coverage map and competitor/feature landscape |
| [SUMMARY.md](SUMMARY.md) | Executive research summary tying the above together |

> The original GSD `research/STACK.md` was intentionally dropped in the migration — its content
> is already reflected in `CLAUDE.md`'s Technology Stack section. Original GSD artifacts remain in
> version-control history.

*Researched 2026-04-16 · migrated to Spec Kit 2026-07-26.*
