# Contract: C ABI

`towncrier.h` here is a reference copy of the **live, shipped** header at
[`include/towncrier.h`](../../../include/towncrier.h) as of Phase 1 completion (2026-04-16).

The live header at the repository root is the source of truth that the build installs and that
shells link against. This copy documents the ABI surface that Phase 1 locked: 13 functions, the
`towncrier_runtime_s` / `towncrier_account_s` / `towncrier_notification_s` structs, and the inline
memory-ownership rules. Per Constitution Principle I, changes to this surface after Phase 1 are ABI
breaks.
