# PayPay Payment Implementation

Source: https://docs.pay.jp/v2/guide/payments/methods/paypay
Last updated: 2026-07-02

## Characteristics

- **One-time payments only** — cannot be bound to a customer or reused
- Minimum amount: ¥50
- Maximum: determined by the individual PayPay user's account limit
- Requires a separate PAY.JP application/review even if card payments are already approved
- `capture_method: 'manual'` (auth = "出荷売上") requires prior PAY.JP approval (per merchant / product category); auth hold: 30 days (no extension)

## Fees

- Physical goods / services: 3.5%
- Digital content: 9.0%

## Refunds

- Window: 365 days from payment confirmation (until 23:59:59)
- **Async**: refund creation returns `status: 'pending'`; final result arrives via `refund.created` webhook — do not treat the initial response as completed

## Testing

- Test limit: **¥100 per transaction**
- Must perform full refund after each test transaction
- Avoid consecutive same-amount transactions (wait 5+ minutes)
- Test accounts: phone numbers 080-1111-5912 through 080-1111-5921 (10 accounts, password `Pay2test`, SMS code `1234`)
- PayPay app can be switched to Sandbox mode for app-based testing

## Implementation: Embedded (Payment Widgets)

### Flow

1. Server: Create Payment Flow with `payment_method_types: ['paypay']`
2. Frontend: Initialize payments.js, mount form
3. Frontend: `widgets.confirmPayment({ return_url })` — user redirected to PayPay app/web
4. PAY.JP: Redirects back to `return_url` with `payment_flow_id` and `payment_flow_client_secret`
5. Server or Frontend: Verify result via API or `retrievePaymentFlow()`

### Server-side (PHP)

```php
function payjp_create_paypay_payment_flow( int $amount ): array {
    $response = wp_remote_post( 'https://api.pay.jp/v2/payment_flows', [
        'headers' => [
            'Authorization' => 'Bearer ' . get_option( 'payjp_secret_key' ),
            'Content-Type'  => 'application/json',
        ],
        'body' => wp_json_encode( [
            'amount'               => $amount,
            'currency'             => 'jpy',
            'payment_method_types' => [ 'paypay' ],
            'capture_method'       => 'automatic',
        ] ),
        'timeout' => 30,
    ] );

    if ( is_wp_error( $response ) ) {
        throw new RuntimeException( $response->get_error_message() );
    }

    $data = json_decode( wp_remote_retrieve_body( $response ), true );
    if ( isset( $data['error'] ) ) {
        throw new RuntimeException( esc_html( $data['detail'] ?? 'PAY.JP error' ) );
    }

    return $data;
    // Returns: [ 'id' => 'pfw_xxx', 'client_secret' => '...', 'status' => 'requires_payment_method' ]
}
```

### Frontend (JavaScript)

```javascript
( async () => {
    const payments = PayjpPayments( payjpData.publicKey );
    const widgets  = payments.widgets({ clientSecret: payjpData.clientSecret });

    // PayPay form (accordion layout)
    const form = widgets.createForm( 'payment', {
        layout: 'accordion',
        paymentMethodOrder: [ 'paypay' ],
    } );
    form.mount( '#payjp-payment-form' );

    document.getElementById( 'pay-button' ).addEventListener( 'click', async () => {
        const result = await widgets.confirmPayment({
            return_url: payjpData.returnUrl,
        });
        if ( result.error ) {
            document.getElementById( 'payjp-error' ).textContent = result.error.message;
            return;
        }
        // On success: PayPay app/web opens; user completes payment there
        // After PayPay completion: auto-redirect to return_url
    } );
} )();
```

### Return URL handler (PHP)

```php
add_action( 'template_redirect', 'payjp_paypay_return_handler' );
function payjp_paypay_return_handler(): void {
    if ( ! isset( $_GET['payment_flow_id'] ) ) {
        return;
    }

    $flow_id = sanitize_text_field( wp_unslash( $_GET['payment_flow_id'] ) );

    // Always verify via server-side API call
    $response = wp_remote_get(
        'https://api.pay.jp/v2/payment_flows/' . rawurlencode( $flow_id ),
        [
            'headers' => [ 'Authorization' => 'Bearer ' . get_option( 'payjp_secret_key' ) ],
            'timeout' => 30,
        ]
    );
    $flow = json_decode( wp_remote_retrieve_body( $response ), true );

    $order = payjp_find_order_by_flow_id( $flow_id );
    if ( ! $order ) {
        return;
    }

    switch ( $flow['status'] ) {
        case 'succeeded':
            $order->payment_complete( $flow_id );
            $order->add_order_note( 'PAY.JP PayPay 決済完了 (ID: ' . esc_html( $flow_id ) . ')' );
            wp_safe_redirect( $order->get_checkout_order_received_url() );
            exit;

        case 'requires_capture':
            $order->update_status( 'on-hold', 'PAY.JP PayPay オーソリ完了。売上確定待ち。' );
            wp_safe_redirect( $order->get_checkout_order_received_url() );
            exit;

        default:
            // Payment not completed — stay on checkout
            wc_add_notice( 'PayPay 決済が完了しませんでした。再度お試しください。', 'error' );
            wp_safe_redirect( wc_get_checkout_url() );
            exit;
    }
}
```

## Implementation: External Link (Checkout v2)

### Flow

1. Server: Create Checkout Session with `payment_method_types: ['paypay']`
2. Server: Redirect user to `session.url` (HTTP 303)
3. User: Completes PayPay payment on PAY.JP hosted page
4. PAY.JP: Redirects to `success_url` or `cancel_url`
5. Server: Receive `checkout.session.completed` Webhook for authoritative confirmation

### Server-side (PHP)

```php
function payjp_create_paypay_checkout_session( string $order_id ): string {
    $order  = wc_get_order( (int) $order_id );
    $amount = (int) round( $order->get_total() );

    $response = wp_remote_post( 'https://api.pay.jp/v2/checkout/sessions', [
        'headers' => [
            'Authorization' => 'Bearer ' . get_option( 'payjp_secret_key' ),
            'Content-Type'  => 'application/json',
        ],
        'body' => wp_json_encode( [
            'mode'                 => 'payment',
            'payment_method_types' => [ 'paypay' ],
            'line_items'           => [ // required in payment mode; price_data = inline price
                [
                    'price_data' => [
                        'currency'     => 'jpy',
                        'unit_amount'  => $amount,
                        'product_data' => [ 'name' => 'Order #' . $order_id ],
                    ],
                    'quantity'   => 1,
                ],
            ],
            'success_url'          => home_url( '/payjp/success?order_id=' . $order_id ),
            'cancel_url'           => wc_get_checkout_url(),
            'metadata'             => [
                'order_id'  => $order_id,
                'site_url'  => get_site_url(),
            ],
        ] ),
        'timeout' => 30,
    ] );

    $data = json_decode( wp_remote_retrieve_body( $response ), true );
    return $data['url'];
}

// In WC_Payment_Gateway::process_payment():
$url = payjp_create_paypay_checkout_session( $order_id );
return [ 'result' => 'success', 'redirect' => $url ];
```

## Combined card + PayPay form

Show both payment methods in a single form:

```javascript
const form = widgets.createForm( 'payment', {
    layout: 'accordion',
    paymentMethodOrder: [ 'card', 'paypay' ],
} );
```

Server-side Payment Flow must include both:
```php
'payment_method_types' => [ 'card', 'paypay' ],
```

## Webhook (PayPay-specific)

Same events as card:
- `payment_flow.succeeded` — PayPay payment completed
- `payment_flow.payment_failed` — PayPay payment failed/rejected by user

PayPay user cancellation: `payment_flow` status becomes `canceled` (not `failed`).
