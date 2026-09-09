---
name: payjp-v2-woocommerce
description: "Use when developing WooCommerce payment gateway plugins using PAY.JP v2 API: credit card payments, PayPay payments, Payment Flow API, Checkout v2, payments.js integration, webhook handling, and WooCommerce gateway class implementation."
compatibility: "Targets WooCommerce 8.0+ (current stable 10.9), WordPress 6.4+, PHP 8.0+. Requires PAY.JP v2 API keys (v2 is generally available; account enablement may be required)."
last_updated: "2026-07-02"
docs_source: "https://docs.pay.jp/v2/guide"
---

# PAY.JP v2 WooCommerce Gateway Development

## When to use

Use this skill for:

- Creating or extending WooCommerce payment gateways using PAY.JP v2
- Implementing credit card payments (card tokenization via payments.js)
- Implementing PayPay code payments
- Integrating Payment Flow API or Checkout v2 (hosted redirect; API object: Checkout Session, `cs_` IDs, `checkout.session.completed` webhook)
- Handling PAY.JP webhooks in WordPress/WooCommerce
- Implementing 3D Secure authentication flow (runs automatically in v2)
- Managing customer payment methods (Setup Flow)
- Refunds, captures, and order status management

> Note: PAY.JP v2 has no 定期課金 (subscription) API yet — planned for 2026. For WooCommerce Subscriptions / automatic recurring billing, stay on PAY.JP API v1. PayPay and Apple Pay in v2 are one-time only (cannot bind to a customer), so they cannot back subscription products.

## Inputs required

- Plugin root path
- PAY.JP public key and secret key (test/live)
- Target payment methods: card, paypay, or both
- Integration type: embedded (Payment Widgets) or external (Checkout v2)
- WooCommerce HPOS compatibility requirement

## Key concepts

See:
- `references/api-overview.md` — PAY.JP v2 architecture, objects, status lifecycle
- `references/card-payment.md` — Card payment implementation (embedded & external)
- `references/paypay-payment.md` — PayPay implementation (embedded & external)
- `references/payments-js.md` — payments.js library reference
- `references/webhooks.md` — Webhook events and WordPress handling
- `references/woocommerce-gateway.md` — WooCommerce gateway class patterns

## Procedure

### 0) Identify integration type

Two approaches exist in PAY.JP v2:

| Type | Class | When to use |
|------|-------|-------------|
| **External link (Checkout v2)** | Checkout v2 (hosted redirect) | Fastest integration; PAY.JP hosts payment page |
| **Embedded (Payment Widgets)** | Payment Flow API + payments.js | Custom UI on merchant site |

WooCommerce plugins typically use **Payment Widgets** for better UX.

### 1) WooCommerce Gateway class scaffold

Extend `WC_Payment_Gateway` for each payment method:

```php
class WC_Gateway_Payjp_Card extends WC_Payment_Gateway {
    public function __construct() {
        $this->id                 = 'payjp_card';
        $this->has_fields         = true;          // Payment Widgets: true; Checkout: false
        $this->method_title       = 'PAY.JP クレジットカード';
        $this->method_description = 'PAY.JP v2 によるクレジットカード決済';
        $this->supports           = [ 'products', 'refunds' ];

        $this->init_form_fields();
        $this->init_settings();

        $this->title       = $this->get_option( 'title' );
        $this->public_key  = $this->get_option( 'public_key' );
        $this->secret_key  = $this->get_option( 'secret_key' );
        $this->capture     = 'yes' === $this->get_option( 'capture', 'yes' );

        add_action( 'woocommerce_update_options_payment_gateways_' . $this->id,
                    [ $this, 'process_settings_save' ] );
        add_action( 'wp_enqueue_scripts', [ $this, 'payment_scripts' ] );
    }
}
```

See `references/woocommerce-gateway.md` for full class patterns including HPOS support.

### 2) Payment Flow creation (server-side)

Create a Payment Flow before showing the checkout form:

```php
function payjp_create_payment_flow( int $amount, array $method_types = ['card'] ): array {
    $response = wp_remote_post( 'https://api.pay.jp/v2/payment_flows', [
        'headers' => [
            'Authorization' => 'Bearer ' . get_option( 'payjp_secret_key' ),
            'Content-Type'  => 'application/json',
        ],
        'body' => wp_json_encode( [
            'amount'               => $amount,
            'currency'             => 'jpy',
            'payment_method_types' => $method_types,
            'capture_method'       => 'automatic',
        ] ),
        'timeout' => 30,
    ] );

    if ( is_wp_error( $response ) ) {
        throw new RuntimeException( $response->get_error_message() );
    }

    $body = json_decode( wp_remote_retrieve_body( $response ), true );

    if ( isset( $body['error'] ) ) {
        throw new RuntimeException( $body['error']['message'] ?? 'PAY.JP error' );
    }

    return $body; // ['id' => 'pfw_xxx', 'client_secret' => '...', 'status' => 'requires_payment_method']
}
```

### 3) payments.js initialization (frontend)

```javascript
// Enqueue: https://js.pay.jp/payments.js
const payments = PayjpPayments( payjpData.publicKey );
const widgets  = payments.widgets({ clientSecret: payjpData.clientSecret });

const form = widgets.createForm( 'payment', {
    layout: 'accordion',
    paymentMethodOrder: [ 'card', 'paypay' ],
} );
form.mount( '#payjp-payment-form' );

document.getElementById( 'payjp-checkout-form' ).addEventListener( 'submit', async ( e ) => {
    e.preventDefault();
    const result = await widgets.confirmPayment({
        return_url: payjpData.returnUrl,
    });
    if ( result.error ) {
        // Display error to customer
        document.getElementById( 'payjp-error' ).textContent = result.error.message;
        return;
    }
    // Redirect handled automatically on success
} );
```

### 4) process_payment() implementation

```php
public function process_payment( $order_id ): array {
    $order  = wc_get_order( $order_id );
    $amount = (int) round( $order->get_total() );

    try {
        $flow = payjp_create_payment_flow( $amount, [ 'card' ] );

        // Store flow ID and client_secret on order meta for return URL verification
        $order->update_meta_data( '_payjp_payment_flow_id', $flow['id'] );
        $order->update_meta_data( '_payjp_client_secret', $flow['client_secret'] );
        $order->save();

        return [
            'result'   => 'success',
            'redirect' => false,
            // client_secret returned to JS via wp_localize_script in payment_fields()
        ];
    } catch ( \Exception $e ) {
        wc_add_notice( $e->getMessage(), 'error' );
        return [ 'result' => 'failure' ];
    }
}
```

### 5) Return URL handler (after payments.js redirect)

```php
add_action( 'template_redirect', 'payjp_handle_return_url' );
function payjp_handle_return_url(): void {
    if ( ! isset( $_GET['payment_flow_client_secret'] ) ) {
        return;
    }
    $client_secret = sanitize_text_field( wp_unslash( $_GET['payment_flow_client_secret'] ) );
    $flow_id       = sanitize_text_field( wp_unslash( $_GET['payment_flow_id'] ?? '' ) );

    // Verify via server-side API call (never trust query params alone)
    $flow = payjp_get_payment_flow( $flow_id );

    $order = payjp_find_order_by_flow_id( $flow_id );
    if ( ! $order ) return;

    if ( 'succeeded' === $flow['status'] ) {
        $order->payment_complete( $flow_id );
        wp_redirect( $order->get_checkout_order_received_url() );
        exit;
    }

    if ( 'requires_capture' === $flow['status'] ) {
        $order->update_status( 'on-hold', 'PAY.JP オーソリ完了。売上確定待ち。' );
        wp_redirect( $order->get_checkout_order_received_url() );
        exit;
    }
}
```

### 6) Webhook handling

Register webhook endpoint and verify token:

```php
add_action( 'rest_api_init', function() {
    register_rest_route( 'payjp/v1', '/webhook', [
        'methods'             => 'POST',
        'callback'            => 'payjp_webhook_handler',
        'permission_callback' => '__return_true',
    ] );
} );

function payjp_webhook_handler( WP_REST_Request $request ): WP_REST_Response {
    // Token is the account-specific "発信元トークン" (whook_xxx) shown in the dashboard
    $token = $request->get_header( 'x-payjp-webhook-token' );
    if ( ! $token || ! hash_equals( (string) get_option( 'payjp_webhook_secret' ), $token ) ) {
        return new WP_REST_Response( [ 'error' => 'Unauthorized' ], 401 );
    }

    $event = $request->get_json_params();
    $type  = $event['type'] ?? '';

    // NOTE: event 'data' IS the resource object itself (not data.object like Stripe)
    switch ( $type ) {
        case 'payment_flow.succeeded':
            payjp_handle_payment_succeeded( $event['data'] );
            break;
        case 'payment_flow.payment_failed':
            payjp_handle_payment_failed( $event['data'] );
            break;
        case 'refund.created':
            payjp_handle_refund_created( $event['data'] );
            break;
    }

    return new WP_REST_Response( [ 'received' => true ] );
}
```

### 7) Refund via process_refund()

```php
public function process_refund( $order_id, $amount = null, $reason = '' ): bool {
    $order   = wc_get_order( $order_id );
    $flow_id = $order->get_meta( '_payjp_payment_flow_id' );

    if ( ! $flow_id ) return false;

    $body = [ 'payment_flow' => $flow_id ];
    if ( null !== $amount ) {
        $body['amount'] = (int) round( $amount );
    }
    if ( $reason ) {
        // Map WooCommerce reason to PAY.JP reason enum
        $body['reason'] = 'requested_by_customer';
    }

    $response = wp_remote_post( 'https://api.pay.jp/v2/payment_refunds', [
        'headers' => [
            'Authorization' => 'Bearer ' . $this->secret_key,
            'Content-Type'  => 'application/json',
        ],
        'body'    => wp_json_encode( $body ),
        'timeout' => 30,
    ] );

    $result = json_decode( wp_remote_retrieve_body( $response ), true );
    return isset( $result['id'] );
}
```

### 8) Security checklist

- [ ] Secret key stored with `get_option()` / encrypted options — never hardcoded
- [ ] Webhook token validated via `hash_equals()` comparison (timing-safe)
- [ ] All user-facing PAY.JP error messages sanitized before display (`esc_html()`)
- [ ] `wp_verify_nonce()` on all admin AJAX endpoints
- [ ] Payment Flow ID verified server-side (never trust client-supplied flow ID alone)
- [ ] Use `wp_remote_post()` not `curl` directly (respects WP proxy settings)
- [ ] HPOS compatibility: use `$order->get_meta()` / `$order->update_meta_data()` not direct `update_post_meta()`
- [ ] PCI DSS: card data never touches your server; only PAY.JP tokens/flow IDs

## Error handling patterns

PAY.JP v2 errors follow RFC 9457 (`application/problem+json`):
```json
{"status": 400, "code": "invalid_status", "title": "...", "detail": "...", "type": "...", "errors": [...]}
```

- HTTP 4xx (400/401/402/404/422) → log and show user-friendly message, do NOT retry
- HTTP 500/503/504 → exponential backoff, max 3 retries (use `Idempotency-Key`)
- `result.error` from payments.js → display `result.error.message` in payment form

## Testing

- Test API keys: `pk_test_xxx` / `sk_test_xxx` (same API keys as v1)
- Test cards: `4242 4242 4242 4242` (Visa), `5555 5555 5555 4444` (Mastercard), `3530 1113 3330 0000` (JCB); error cards e.g. `4000 0000 0000 0002` → `card_declined`
- PayPay test accounts: phone 080-1111-5912 to 080-1111-5921 (10 accounts, password `Pay2test`, SMS code `1234`)
- PayPay test limit: ¥100 per transaction; must fully refund after each test
- 3DS test: test mode shows a dedicated auth screen where you choose the outcome (success/failure)
- Local webhook testing: `payjp-cli listen --forward-to http://localhost:8888/wp-json/payjp/v1/webhook`

## Docs refresh

Docs source: `https://docs.pay.jp/v2/guide`
Full LLM-ready content: `https://docs.pay.jp/v2/llms-full.txt`
Individual page MDX: append `.mdx` to any docs URL (e.g. `https://docs.pay.jp/v2/guide/payments/checkout.mdx`)
