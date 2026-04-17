/*
 * tests/c_abi_test.c — Phase 1 C ABI integration test.
 *
 * Proves the C linkage path that the Swift/macOS shell will use.
 * Per CONTEXT.md D-04: this is a C source file compiled and linked against
 * libtowncrier.a by the `zig build test-c` step.
 *
 * All assertions use assert() from <assert.h>. A failure exits non-zero,
 * which causes `zig build test-c` to report the step as failed.
 */

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "towncrier.h"

/* Stub callbacks — satisfy towncrier_runtime_s function pointer types. */
static void on_update_cb(void *ud, uint32_t count) {
    (void)ud;
    (void)count;
    /* Phase 1: never called (no poll engine). */
}

static void wakeup_cb(void *ud) {
    (void)ud;
    /* Phase 1: never called (no poll engine). */
}

static void on_error_cb(void *ud, const char *msg) {
    (void)ud;
    fprintf(stderr, "c_abi_test: on_error called: %s\n", msg ? msg : "(null)");
    /* Phase 1: should not be called. */
}

int main(void) {
    /* 1. Initialize */
    towncrier_runtime_s rt = {
        .userdata  = NULL,
        .on_update = on_update_cb,
        .wakeup    = wakeup_cb,
        .on_error  = on_error_cb,
    };

    towncrier_t tc = towncrier_init(&rt);
    assert(tc != NULL && "towncrier_init must return non-NULL");

    /* 2. Start (no-op in Phase 1, but must not crash) */
    int start_result = towncrier_start(tc);
    assert(start_result == 0 && "towncrier_start must return 0");

    /* 3. Tick (no-op in Phase 1) */
    towncrier_tick(tc);

    /* 4. Add account (no-op stub, must return 0) */
    towncrier_account_s acct = {
        .id                 = 1,
        .service            = TOWNCRIER_SERVICE_GITHUB,
        .base_url           = NULL,
        .token              = "test_token_placeholder",
        .poll_interval_secs = 60,
    };
    int add_result = towncrier_add_account(tc, &acct);
    assert(add_result == 0 && "towncrier_add_account must return 0");

    /* 5. Snapshot — NULL in Phase 1 is correct and expected */
    towncrier_snapshot_t snap = towncrier_snapshot_get(tc);
    if (snap != NULL) {
        /* Non-NULL path: exercise iteration to verify no crash. */
        uint32_t count = towncrier_snapshot_count(snap);
        for (uint32_t i = 0; i < count; i++) {
            const towncrier_notification_s *notif = towncrier_snapshot_get_item(snap, i);
            (void)notif;
        }
        towncrier_snapshot_free(snap);
    }
    /* NULL snap is the expected Phase 1 result — no assert needed. */

    /* 6. Mark read — Phase 2: returns 1 when notif_id is not in the snapshot map.
     *    notif_id=0 is not in any snapshot here (no poll has run), so non-zero is
     *    the correct Phase 2 result.  We call it to verify it does not crash. */
    (void)towncrier_mark_read(tc, 0);

    /* 7. Remove account — account id=1 was added above; must return 0. */
    int remove_result = towncrier_remove_account(tc, 1);
    assert(remove_result == 0 && "towncrier_remove_account must return 0");

    /* 8. Stop (no-op in Phase 1) */
    towncrier_stop(tc);

    /* 9. Free */
    towncrier_free(tc);

    printf("c_abi_test: PASS\n");
    return 0;
}
