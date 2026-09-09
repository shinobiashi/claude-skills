# Webhook Handling

Source: https://docs.pay.jp/v2/guide/developers/event-webhook
Last updated: 2026-07-02

## Overview

PAY.JP v2 sends webhooks for payment state changes. In WooCommerce, webhooks are the authoritative confirmation source — do not rely solely on redirect URLs.

## Authentication

Every webhook request includes the account-specific token ID (shown as「発信元トークン」when registering the endpoint in the PAY.JP dashboard):
```
X-Payjp-Webhook-Token: whook_xxxxxxxxxxxxx
```

Always validate with timing-safe comparison:
```php
if ( ! hash_equals( get_option( 'payjp_webhook_secret' ), $token ) ) {
    return new WP_REST_Response( [ 'error' => 'Unauthorized' ], 401 );
}
```

## Retry Policy

- 3 retries at 3-minute intervals on non-2xx response, timeout (10 s), or connection error
- Respond within **10 seconds** with 2xx; process asynchronously if needed
- Local testing: `payjp-cli listen --forward-to <local URL>` (test mode events only)

## Event Payload Structure

`data` contains the resource object **directly** — there is no `data.object` wrapper (unlike Stripe):

```json
{
  "id": "evt_xxx",
  "object": "event",
  "livemode": true,
  "type": "payment_flow.succeeded",
  "pending_webhooks": 1,
  "data": { "id": "pfw_xxx", "object": "payment_flow", "status": "succeeded", ... }
}
```

## Key Events

| Event | When |
|-------|------|
| `payment_flow.succeeded` | Payment fully completed |
| `payment_flow.payment_failed` | Payment rejected/failed |
| `payment_flow.requires_action` | Customer action needed (3DS etc.) |
| `payment_flow.canceled` | Payment Flow canceled |
| `refund.created` / `refund.updated` / `refund.failed` | Refund lifecycle (PayPay refunds start as `pending`) |
| `checkout.session.completed` / `checkout.session.expired` | Checkout v2 session completed / expired |
| `setup_flow.succeeded` / `setup_flow.setup_failed` | Payment method registration result |

## WordPress REST API Endpoint

```php
add_action( 'rest_api_init', function () {
    register_rest_route( 'payjp/v1', '/webhook', [
        'methods'             => WP_REST_Server::CREATABLE,
        'callback'            => 'payjp_webhook_handler',
        'permission_callback' => '__return_true', // auth handled inside handler
    ] );
} );
```

Webhook URL: `https://yoursite.com/wp-json/payjp/v1/webhook`

## Handler Implementation

```php
function payjp_webhook_handler( WP_REST_Request $request ): WP_REST_Response {
    // 1. Authenticate
    $token = $request->get_header( 'x-payjp-webhook-token' );
    if ( ! $token || ! hash_equals( (string) get_option( 'payjp_webhook_secret' ), $token ) ) {
        return new WP_REST_Response( [ 'error' => 'Unauthorized' ], 401 );
    }

    // 2. Parse event — 'data' IS the resource object itself
    $event = $request->get_json_params();
    if ( ! isset( $event['type'], $event['data'] ) ) {
        return new WP_REST_Response( [ 'error' => 'Invalid payload' ], 400 );
    }

    $object = $event['data'];

    // 3. Route to handler
    switch ( $event['type'] ) {
        case 'payment_flow.succeeded':
            payjp_on_payment_succeeded( $object );
            break;

        case 'payment_flow.payment_failed':
            payjp_on_payment_failed( $object );
            break;

        case 'refund.created':
            payjp_on_refund_created( $object );
            break;

        case 'checkout.session.completed':
            payjp_on_checkout_completed( $object );
            break;
    }

    // 4. Return 200 immediately
    return new WP_REST_Response( [ 'received' => true ] );
}
```

## Event Handlers

```php
function payjp_on_payment_succeeded( array $payment_flow ): void {
    $flow_id = sanitize_text_field( $payment_flow['id'] );
    $order   = payjp_find_order_by_flow_id( $flow_id );

    if ( ! $order || $order->is_paid() ) {
        return; // Idempotent: already processed
    }

    $order->payment_complete( $flow_id );
    $order->add_order_note(
        sprintf( 'PAY.JP 決済完了 (Payment Flow ID: %s)', esc_html( $flow_id ) )
    );
}

function payjp_on_payment_failed( array $payment_flow ): void {
    $flow_id = sanitize_text_field( $payment_flow['id'] );
    $order   = payjp_find_order_by_flow_id( $flow_id );

    if ( ! $order ) return;

    $order->update_status(
        'failed',
        sprintf( 'PAY.JP 決済失敗 (Payment Flow ID: %s)', esc_html( $flow_id ) )
    );
}

function payjp_on_refund_created( array $refund ): void {
    // PayPay refunds are async: status may be 'pending' at first — only act on 'succeeded'
    if ( 'succeeded' !== ( $refund['status'] ?? '' ) ) {
        return;
    }

    $flow_id  = sanitize_text_field( $refund['payment_flow'] );
    $order    = payjp_find_order_by_flow_id( $flow_id );

    if ( ! $order ) return;

    // WooCommerce refund record creation — PAY.JP amounts are already in yen (integer)
    wc_create_refund( [
        'order_id' => $order->get_id(),
        'amount'   => (int) $refund['amount'],
        'reason'   => sanitize_text_field( $refund['reason'] ?? '' ),
    ] );
}

function payjp_on_checkout_completed( array $session ): void {
    $order_id = sanitize_text_field( $session['metadata']['order_id'] ?? '' );
    if ( ! $order_id ) return;

    $order = wc_get_order( (int) $order_id );
    if ( ! $order || $order->is_paid() ) return;

    $order->payment_complete( $session['id'] );
}
```

## Finding order by Payment Flow ID

```php
function payjp_find_order_by_flow_id( string $flow_id ): ?WC_Order {
    // HPOS-compatible query
    $orders = wc_get_orders( [
        'meta_key'   => '_payjp_payment_flow_id',
        'meta_value' => $flow_id,
        'limit'      => 1,
    ] );

    return ! empty( $orders ) ? $orders[0] : null;
}
```

## Idempotency

Always check if order is already processed before applying changes:
```php
if ( $order->is_paid() ) return; // Already handled
if ( 'on-hold' === $order->get_status() && $order->is_paid() ) return;
```

## Security: Never trust redirect params alone

Always verify payment via server-side API call or Webhook, even when the user lands on the success URL:

```php
// BAD: trusting query param
if ( $_GET['payment_flow_id'] ) { $order->payment_complete(); }

// GOOD: verify via API
$flow = payjp_api_get( '/v2/payment_flows/' . $flow_id );
if ( 'succeeded' === $flow['status'] ) { $order->payment_complete( $flow_id ); }
```
