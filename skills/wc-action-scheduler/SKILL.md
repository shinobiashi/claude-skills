---
name: wc-action-scheduler
description: >
  Use when a WooCommerce extension needs deferred, recurring, or batch background work with
  Action Scheduler: as_schedule_single_action / as_schedule_recurring_action /
  as_enqueue_async_action, groups, unique actions, priorities, chunked batch processing that
  reschedules itself, cancelling on deactivation/uninstall, the WC()->queue() wrapper, running and
  inspecting actions via WP-CLI or the admin UI, and testing scheduled actions in PHPUnit with
  WC_Helper_Queue::run_all_pending(). Trigger on "Action Scheduler", "as_schedule", "background
  job", "queue", "batch", "delayed grant", "expiry cron", or any request to use WP-Cron inside a
  WooCommerce plugin (Action Scheduler is the correct replacement).
compatibility: >
  Action Scheduler 4.1.0 as bundled with WooCommerce 11.1 (verified 2026-09-09). The $unique and
  $priority parameters require AS 3.6+; as_has_scheduled_action() requires 3.3+; as_supports()
  is 4.x. Requires WooCommerce (or the standalone Action Scheduler plugin) to be active.
---

# wc-action-scheduler

Action Scheduler (AS) is WooCommerce's persistent job queue: actions are rows in
`wp_actionscheduler_actions`, run by a queue runner triggered from WP-Cron, admin page loads,
async loopback requests, or WP-CLI. Use it instead of raw `wp_schedule_event()` for anything
in a WooCommerce extension.

## When to use

- Delayed work tied to an entity (confirm points after N days, send a reminder, retry a webhook).
- Daily / hourly maintenance (expire lots, send notices, purge logs).
- Large batches that must not run inside a request (recalculate 100k rows).
- Anything the plugin previously did with `wp_schedule_event`, `wp_schedule_single_event`, or
  `spawn_cron`.

## API cheat sheet (signatures verified against AS trunk)

```php
as_enqueue_async_action( $hook, $args = [], $group = '', $unique = false, $priority = 10 );
as_schedule_single_action( $timestamp, $hook, $args = [], $group = '', $unique = false, $priority = 10 );
as_schedule_recurring_action( $timestamp, $interval_in_seconds, $hook, $args = [], $group = '', $unique = false, $priority = 10 );
as_schedule_cron_action( $timestamp, $schedule, $hook, $args = [], $group = '', $unique = false, $priority = 10 );
as_unschedule_action( $hook, $args = [], $group = '' );          // cancels the next matching pending action
as_unschedule_all_actions( $hook, $args = [], $group = '' );     // cancels all matching; hook may be ''
as_next_scheduled_action( $hook, $args = null, $group = '' );    // int timestamp | true (async/running) | false
as_has_scheduled_action( $hook, $args = null, $group = '' );     // bool (3.3+)
as_get_scheduled_actions( $args = [], $return_format = OBJECT ); // query by hook/args/group/status/date
as_get_datetime_object( $date_string = null, $timezone = 'UTC' );
as_supports( string $feature ): bool;                            // 4.x feature detection
```

- `$timestamp` is a Unix timestamp in **UTC**. Build local times with
  `as_get_datetime_object( '03:00', wp_timezone_string() )->getTimestamp()` or `wp_date()`.
- `$args` is stored as JSON and matched **by exact JSON string** when you cancel or query, so
  always pass the same keys in the same order. Keep args small (IDs, not objects). Args longer
  than 191 characters are looked up via the `extended_args` column; avoid relying on that.
- `$unique = true` skips scheduling when a pending or running action with the same hook and
  group already exists (args are not compared). Use it for recurring registrations.
- `$priority` 0–255, lower runs first; default 10.
- Every `as_*` scheduling function returns the action ID (`int`), or `0` when `$unique`
  prevented scheduling. `pre_as_*` filters allow short-circuiting.

`WC()->queue()` (`WC_Queue_Interface`) wraps the same store with `add()`, `schedule_single()`,
`schedule_recurring()`, `schedule_cron()`, `cancel()`, `cancel_all()`, `get_next()`, `search()`.
It has no `$unique` / `$priority` parameters; call `as_*` directly when you need them.

## Procedure

### 1) Register handlers and recurring actions

```php
final class Scheduler {
    public const GROUP = 'myplugin';

    public function register(): void {
        add_action( 'myplugin_confirm_lot',   [ $this, 'confirm_lot' ], 10, 1 );
        add_action( 'myplugin_run_expiry',    [ $this, 'run_expiry' ], 10, 1 );
        add_action( 'init', [ $this, 'ensure_recurring' ] );
    }

    public function ensure_recurring(): void {
        if ( ! function_exists( 'as_schedule_recurring_action' ) ) {
            return; // WooCommerce not loaded (e.g. WP-CLI without WC, uninstall).
        }
        if ( ! as_has_scheduled_action( 'myplugin_run_expiry', null, self::GROUP ) ) {
            $first = as_get_datetime_object( 'tomorrow 03:00', wp_timezone_string() )->getTimestamp();
            as_schedule_recurring_action( $first, DAY_IN_SECONDS, 'myplugin_run_expiry', [ 0 ], self::GROUP, true );
        }
    }
}
```

- Handler callbacks receive the **args array unpacked as positional parameters** (an action
  scheduled with `[ 'lot_id' => 5 ]` calls `confirm_lot( 5 )`). Declare `accepted_args`
  accordingly.
- Register handlers on every request (plugin bootstrap), not only when scheduling; the runner
  needs them in a separate request.
- Use one group per plugin (`myplugin`). It makes cancellation and WP-CLI filtering trivial.

### 2) Schedule work

```php
// Single delayed action, idempotent per entity.
$when = strtotime( '+7 days', time() );
if ( ! as_has_scheduled_action( 'myplugin_confirm_lot', [ 'lot_id' => $lot_id ], Scheduler::GROUP ) ) {
    as_schedule_single_action( $when, 'myplugin_confirm_lot', [ 'lot_id' => $lot_id ], Scheduler::GROUP );
}

// Fire-and-forget after the current request.
as_enqueue_async_action( 'myplugin_send_mail', [ 'user_id' => $user_id ], Scheduler::GROUP );
```

Note that `as_has_scheduled_action()` with `$args` compares the JSON encoding of the args.

### 3) Write idempotent handlers

The same action can run twice (timeout + retry, duplicate schedule, manual re-run from the
admin UI). Handlers must therefore:

- Re-check state before acting (`if ( $lot->status !== 'pending' ) return;`).
- Rely on database-level idempotency where money or points move (unique keys, row locks).
- Throw an exception on failure. AS marks the action **failed** and logs the message
  (visible under WooCommerce > Status > Scheduled Actions). Returning silently hides errors.
- Never assume the current user, session, or cart: actions run in a bare WP request.

### 4) Chunk large batches

```php
public function run_expiry( int $offset = 0 ): void {
    $chunk = 500;
    $users = $this->repo->find_expiring( time(), $chunk, $offset );
    foreach ( $users as $user_id ) {
        try {
            $this->service->expire_user( $user_id );
        } catch ( \Throwable $e ) {
            wc_get_logger()->error( $e->getMessage(), [ 'source' => 'myplugin' ] );
        }
    }
    if ( count( $users ) === $chunk ) {
        as_enqueue_async_action( 'myplugin_run_expiry', [ $offset + $chunk ], Scheduler::GROUP );
    }
}
```

- Default runner budget: 30 s per batch (`action_scheduler_queue_runner_time_limit`), 25 actions
  per batch (`action_scheduler_queue_runner_batch_size`), 1 concurrent batch
  (`action_scheduler_queue_runner_concurrent_batches`). Size chunks so one action finishes in a
  few seconds; do not raise the time limit as a fix.
- Isolate per-item failures with try/catch so one bad row does not fail the whole chunk.
- For deterministic pagination while rows change, prefer keyset (`WHERE id > $last_id`) over
  OFFSET.

### 5) Clean up on deactivation and uninstall

```php
register_deactivation_hook( __FILE__, function () {
    if ( function_exists( 'as_unschedule_all_actions' ) ) {
        as_unschedule_all_actions( '', [], Scheduler::GROUP );
    }
} );
```

- Cancel by **group** so nothing is missed. Recurring actions are re-created by
  `ensure_recurring()` on the next `init` after reactivation.
- In `uninstall.php` WooCommerce is usually not loaded; guard with `function_exists()` and
  accept that leftover rows expire (`action_scheduler_retention_period`, default 30 days).

### 6) Run and inspect

- Admin: WooCommerce > Status > Scheduled Actions (or Tools > Scheduled Actions). Filter by
  group, run or cancel individual actions, read failure logs.
- WP-CLI (run `wp action-scheduler --help` for the exact subcommands of the bundled version):
  ```bash
  wp action-scheduler run --group=myplugin --batch-size=100
  wp action-scheduler run --hooks=myplugin_run_expiry --force
  wp action-scheduler action list --group=myplugin --status=pending
  wp action-scheduler clean
  ```
- Production hosts should disable WP-Cron (`DISABLE_WP_CRON`) and call
  `wp action-scheduler run` from a real cron every minute. Without a working cron or loopback
  requests, actions stay `pending` and WooCommerce shows a "past-due actions" notice.

### 7) Test in PHPUnit (WooCommerce test framework)

```php
// tests/Integration/...
as_schedule_single_action( time() - 1, 'myplugin_confirm_lot', [ 'lot_id' => $lot_id ], Scheduler::GROUP );
$this->assertTrue( as_has_scheduled_action( 'myplugin_confirm_lot', [ 'lot_id' => $lot_id ], Scheduler::GROUP ) );

WC_Helper_Queue::run_all_pending( Scheduler::GROUP ); // runs every pending action in the group now
$this->assertSame( 'available', $this->lots->find( $lot_id )['status'] );
```

- `WC_Helper_Queue::get_all_pending( $group )` and `cancel_all_pending()` are also available.
- Actions scheduled in the future are still executed by `run_all_pending()`; if you need to test
  "not yet due" logic, assert on `as_next_scheduled_action()` instead of running.
- Reset the queue between tests (`WC_Helper_Queue::cancel_all_pending()` in `tearDown`) to keep
  tests independent.

## Verification checklist

- [ ] No `wp_schedule_event` / `wp_schedule_single_event` / `spawn_cron` in the plugin.
- [ ] Every `as_*` call is guarded by `function_exists()` where WooCommerce may be absent.
- [ ] Handlers are registered on every request and are idempotent.
- [ ] Recurring actions use `$unique = true` or an `as_has_scheduled_action()` check.
- [ ] One group per plugin; deactivation cancels by group.
- [ ] Batches are chunked and reschedule themselves; per-item errors are logged, not fatal.
- [ ] Integration tests exercise the handler via `WC_Helper_Queue::run_all_pending()`.

## Failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Actions stay `pending` forever | WP-Cron disabled and no system cron / loopback blocked | `wp action-scheduler run` from cron; check Site Health loopback |
| Duplicate recurring actions after reactivation | Scheduled on activation without uniqueness check | `$unique = true` + `as_has_scheduled_action()` on `init` |
| `as_unschedule_action()` cancels nothing | Args differ in key order or type from the scheduled ones | Normalize args (same keys, ints not strings) or cancel by hook + group with `[]` args |
| Action marked failed after ~30 s | Handler exceeded the runner time limit | Smaller chunks, reschedule the remainder |
| Handler runs with wrong parameters | `accepted_args` not set on `add_action` | Pass the number of args explicitly |
| Fatal in `uninstall.php` | `as_*` called while WooCommerce is not loaded | Guard with `function_exists()` |
