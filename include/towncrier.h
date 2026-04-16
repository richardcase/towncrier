/*
 * towncrier.h — C ABI contract for libtowncrier
 *
 * Memory ownership rules (read before using any function):
 *
 *   HANDLES: towncrier_t and towncrier_snapshot_t are opaque heap-allocated
 *   objects. The caller MUST call the paired free function exactly once.
 *   Double-free is undefined behavior.
 *
 *   STRINGS (inbound — caller → core): All const char * parameters are
 *   null-terminated. The core reads them only during the function call;
 *   it does NOT retain pointers to caller-owned strings after the call returns.
 *   The caller retains ownership and may free them at any time after the call.
 *
 *   STRINGS (outbound — snapshot fields): All const char * fields inside
 *   towncrier_notification_s point into memory owned by the snapshot. They are
 *   valid until towncrier_snapshot_free() is called on the containing snapshot.
 *   The shell MUST NOT retain these pointers after freeing the snapshot.
 *
 *   CALLBACKS: on_update and wakeup are called from the poll thread. The shell
 *   MUST NOT touch UI directly inside these callbacks. On macOS, use
 *   DispatchQueue.main.async. On Linux, use g_idle_add. The userdata pointer
 *   must remain valid for the entire lifetime of the towncrier_t handle.
 *   On macOS, use Unmanaged<T>.passRetained to prevent ARC from freeing the
 *   context object while callbacks may fire.
 *
 *   THREAD SAFETY: towncrier_snapshot_get / towncrier_snapshot_free /
 *   towncrier_mark_read / towncrier_mark_all_read may be called from the main
 *   thread concurrently with poll thread activity. All other lifecycle functions
 *   (init, free, start, stop, add_account, remove_account) must be called from
 *   a single thread (the main thread). Never call towncrier_stop() from inside
 *   a callback — deadlock guaranteed.
 */

#ifndef TOWNCRIER_H
#define TOWNCRIER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Opaque handles ─────────────────────────────────────────────────────── */

/** Opaque handle returned by towncrier_init. Heap-allocated by libtowncrier.
 *  Must be freed with towncrier_free() exactly once. */
typedef void *towncrier_t;

/** Opaque snapshot handle returned by towncrier_snapshot_get.
 *  Represents a frozen, immutable copy of the current notification list.
 *  Must be freed with towncrier_snapshot_free() exactly once.
 *  All const char * fields within towncrier_notification_s items are valid
 *  only until towncrier_snapshot_free() is called. */
typedef void *towncrier_snapshot_t;

/* ── Runtime callbacks ──────────────────────────────────────────────────── */

/**
 * Runtime callbacks registered at towncrier_init time.
 * The struct is copied by value inside towncrier_init; the pointer passed
 * to init need not remain valid after init returns. The callback function
 * pointers and userdata are retained for the lifetime of the handle.
 */
typedef struct {
    /** Caller-supplied context pointer. Passed back as the first argument
     *  to every callback. The core never dereferences this pointer.
     *  Must remain valid until towncrier_free() is called. */
    void *userdata;

    /** Called from the poll thread when new notifications are available.
     *  unread_count reflects the current total unread count across all accounts.
     *  Shell MUST marshal to main thread before accessing UI. Fire-and-forget:
     *  do NOT call any towncrier_* function from inside this callback. */
    void (*on_update)(void *userdata, uint32_t unread_count);

    /** Called from the poll thread to request a wakeup on the main thread.
     *  Shell should call towncrier_tick() after marshaling to the main thread.
     *  Fire-and-forget: do NOT call any towncrier_* function from this callback. */
    void (*wakeup)(void *userdata);

    /** Called when an unrecoverable error occurs (e.g., allocation failure).
     *  message is a null-terminated string valid only during this call.
     *  The shell should display the message and consider the handle invalid. */
    void (*on_error)(void *userdata, const char *message);
} towncrier_runtime_s;

/* ── Service constants ──────────────────────────────────────────────────── */

/** Service identifier for towncrier_account_s.service */
#define TOWNCRIER_SERVICE_GITHUB 0
#define TOWNCRIER_SERVICE_GITLAB 1

/* ── Data structures ────────────────────────────────────────────────────── */

/**
 * Account descriptor. Shell fills this and passes it to towncrier_add_account.
 * The core reads all fields during the call. String pointers (base_url, token)
 * are NOT retained after the call — the core copies what it needs.
 * The caller retains ownership of all memory in this struct.
 */
typedef struct {
    /** Shell-assigned unique account ID. Must be non-zero and unique across
     *  all accounts registered with this towncrier_t handle. */
    uint32_t    id;

    /** Service type: TOWNCRIER_SERVICE_GITHUB or TOWNCRIER_SERVICE_GITLAB. */
    uint8_t     service;

    /** Base URL for the service. NULL = use the default public API endpoint.
     *  Non-NULL for self-hosted GitLab (e.g., "https://gitlab.mycompany.com").
     *  Null-terminated. Read during add_account; not retained. */
    const char *base_url;

    /** Personal Access Token or OAuth access token. NOT stored by the core —
     *  held in memory only for the duration of the poll session.
     *  The shell must read the token from the system keychain before calling
     *  towncrier_add_account and must not free it while the account is active.
     *  Null-terminated. */
    const char *token;

    /** Poll interval in seconds. Minimum effective value is 60 seconds.
     *  GitHub's X-Poll-Interval header may override this at runtime. */
    uint32_t    poll_interval_secs;
} towncrier_account_s;

/**
 * Flat notification struct. Returned from towncrier_snapshot_get_item.
 * All const char * fields point into memory owned by the snapshot.
 * They are valid until towncrier_snapshot_free() is called.
 * The shell MUST NOT retain these pointers after freeing the snapshot.
 * The shell MUST NOT free any of these fields — they are owned by the core.
 */
typedef struct {
    /** Stable notification ID. Derived from the service API ID.
     *  Consistent across poll cycles for the same notification event. */
    uint64_t    id;

    /** ID of the account that produced this notification.
     *  Matches the id field of towncrier_account_s used in add_account. */
    uint32_t    account_id;

    /** Notification type (PR review, CI failure, mention, etc.).
     *  Exact enum values to be defined in Phase 2. */
    uint8_t     type;

    /** Notification state (0 = unread, 1 = read). */
    uint8_t     state;

    /** Repository in "owner/name" format. Null-terminated.
     *  Valid until towncrier_snapshot_free(). */
    const char *repo;

    /** Human-readable notification title. Null-terminated.
     *  Valid until towncrier_snapshot_free(). */
    const char *title;

    /** Web URL for opening the notification in a browser. Null-terminated.
     *  Valid until towncrier_snapshot_free(). */
    const char *url;

    /** Last-modified Unix timestamp (seconds since epoch). */
    int64_t     updated_at;
} towncrier_notification_s;

/* ── Lifecycle functions ─────────────────────────────────────────────────── */

/**
 * Initialize the towncrier core. Returns an opaque handle.
 *
 * The handle is heap-allocated by libtowncrier using the system allocator (malloc).
 * The caller MUST call towncrier_free() exactly once when done.
 * Returns NULL on allocation failure.
 *
 * @param rt  Runtime callbacks. The struct is copied; the pointer need not
 *            remain valid after this call returns. Callbacks within are
 *            retained for the lifetime of the handle. NULL is not permitted.
 */
towncrier_t towncrier_init(const towncrier_runtime_s *rt);

/**
 * Free the towncrier handle and all associated resources.
 *
 * This function stops the poll engine if running (equivalent to calling
 * towncrier_stop before towncrier_free). Safe to call with a NULL handle
 * (no-op). Must be called exactly once per handle returned by towncrier_init.
 * After this call, the handle is invalid and must not be used.
 *
 * @param tc  Handle returned by towncrier_init. May be NULL (no-op).
 */
void towncrier_free(towncrier_t tc);

/**
 * Start the background poll engine.
 *
 * Spawns the background poll thread. towncrier_add_account should be called
 * before start so accounts are polled immediately on the first tick.
 * Calling start on an already-started handle is a no-op.
 *
 * @param tc  Valid handle. Must not be NULL.
 * @return    0 on success, non-zero on failure (e.g., thread spawn failure).
 */
int towncrier_start(towncrier_t tc);

/**
 * Stop the background poll engine.
 *
 * Signals the poll thread to exit and waits for it to terminate. Safe to call
 * on a handle that was never started (no-op). Must NOT be called from inside
 * an on_update or wakeup callback — deadlock guaranteed.
 *
 * @param tc  Valid handle. Must not be NULL.
 */
void towncrier_stop(towncrier_t tc);

/**
 * Process pending main-thread work.
 *
 * Called by the shell from the main thread after receiving the wakeup callback.
 * In Phase 1 this is a no-op. In Phase 2+ it drains the action queue
 * (mark-read mutations, snapshot updates).
 *
 * @param tc  Valid handle. Must not be NULL.
 */
void towncrier_tick(towncrier_t tc);

/* ── Account management ─────────────────────────────────────────────────── */

/**
 * Register an account with the poll engine.
 *
 * The core copies all string fields in acct. The caller retains ownership of
 * the acct struct and its string fields after this call returns.
 * Accounts should be added before towncrier_start for immediate polling.
 *
 * @param tc    Valid handle. Must not be NULL.
 * @param acct  Account descriptor. Must not be NULL. All string fields must
 *              be null-terminated. token must not be NULL or empty.
 * @return      0 on success, non-zero on failure (e.g., duplicate account ID).
 */
int towncrier_add_account(towncrier_t tc, const towncrier_account_s *acct);

/**
 * Remove a previously registered account.
 *
 * Stops polling for the account and removes its state from memory.
 * Notifications from this account will not appear in subsequent snapshots.
 * SQLite state is retained (Phase 2+) to avoid re-notifying on re-add.
 *
 * @param tc          Valid handle. Must not be NULL.
 * @param account_id  ID matching a previously added towncrier_account_s.
 * @return            0 on success, non-zero if account_id not found.
 */
int towncrier_remove_account(towncrier_t tc, uint32_t account_id);

/* ── Snapshot API (thread-safe read) ────────────────────────────────────── */

/**
 * Get a snapshot of the current notification list.
 *
 * Returns a deep copy of the current notification list owned by the snapshot.
 * The snapshot is immutable and thread-safe to read after this call returns.
 * No locks are held after this function returns.
 *
 * All const char * fields in towncrier_notification_s items are valid until
 * towncrier_snapshot_free() is called on this snapshot. The shell MUST NOT
 * retain these pointers beyond the snapshot lifetime.
 *
 * In Phase 1, this function returns NULL (stub — no notifications yet).
 *
 * @param tc  Valid handle. Must not be NULL.
 * @return    Snapshot handle, or NULL if no notifications available (Phase 1 stub).
 *            If non-NULL, the caller MUST call towncrier_snapshot_free() exactly once.
 */
towncrier_snapshot_t towncrier_snapshot_get(towncrier_t tc);

/**
 * Free a snapshot returned by towncrier_snapshot_get.
 *
 * Releases all memory associated with the snapshot, including all string data
 * referenced by towncrier_notification_s fields. After this call, all pointers
 * obtained from snapshot_get_item are invalid. Must be called exactly once per
 * non-NULL snapshot. NULL is safe (no-op).
 *
 * @param snap  Snapshot handle returned by towncrier_snapshot_get. May be NULL.
 */
void towncrier_snapshot_free(towncrier_snapshot_t snap);

/**
 * Get the number of notifications in a snapshot.
 *
 * @param snap  Valid snapshot handle (must not be NULL).
 * @return      Number of notifications in the snapshot.
 */
uint32_t towncrier_snapshot_count(towncrier_snapshot_t snap);

/**
 * Get a notification by index from a snapshot.
 *
 * The returned pointer is valid until towncrier_snapshot_free() is called.
 * Indices are zero-based. Returns NULL if index >= snapshot count.
 * The shell MUST NOT free the returned pointer.
 *
 * @param snap   Valid snapshot handle (must not be NULL).
 * @param index  Zero-based index. Must be < towncrier_snapshot_count(snap).
 * @return       Pointer to the notification, or NULL if index is out of bounds.
 */
const towncrier_notification_s *towncrier_snapshot_get_item(
    towncrier_snapshot_t snap, uint32_t index);

/* ── Action functions ───────────────────────────────────────────────────── */

/**
 * Mark a specific notification as read.
 *
 * Enqueues a mark-read mutation for the given notification ID. The mutation
 * is applied on the next poll cycle. For GitHub, issues PATCH /notifications/threads/:id.
 * For GitLab, issues POST /todos/:id/mark_as_done.
 * The notification will be absent from the next snapshot after the mutation is applied.
 *
 * @param tc        Valid handle. Must not be NULL.
 * @param notif_id  ID from towncrier_notification_s.id.
 * @return          0 if enqueued successfully, non-zero if notif_id not found.
 */
int towncrier_mark_read(towncrier_t tc, uint64_t notif_id);

/**
 * Mark all notifications for an account as read.
 *
 * Enqueues mark-read mutations for all unread notifications belonging to the
 * given account. For GitHub, this issues a single PUT /notifications (mark all read).
 * For GitLab, iterates todos and calls mark_as_done for each.
 *
 * @param tc          Valid handle. Must not be NULL.
 * @param account_id  Account ID from towncrier_account_s.id.
 * @return            0 if enqueued successfully, non-zero if account_id not found.
 */
int towncrier_mark_all_read(towncrier_t tc, uint32_t account_id);

#ifdef __cplusplus
}
#endif

#endif /* TOWNCRIER_H */
