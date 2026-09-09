# Card Payment Implementation

Source: https://docs.pay.jp/v2/guide/payments/methods/card
Last updated: 2026-07-02

## Supported brands

Visa, Mastercard, American Express, JCB, Diners Club, Discover

## Amount limits

- Minimum: ¥50
- Maximum: ¥9,999,999

## Key features

- Customer binding and reuse (card stored on PAY.JP, referenced by payment_method_id)
- 3D Secure authentication (mandatory at card registration or first use in v2)
- Authorization/capture separation (`capture_method: 'manual'`)
- Billing info update (name, address only — card number cannot be changed)

## Fees

- Physical goods / services: 3.0%
- Digital content: 3.6%

## Implementation: Embedded (Payment Widgets)

### Flow

1. Server: Create Payment Flow → return `client_secret` to frontend
2. Frontend: Initialize payments.js with public key
3. Frontend: Mount payment form widget to DOM
4. Frontend: `widgets.confirmPayment({ return_url })` on form submit
5. Frontend: Redirected to `return_url?payment_flow_id=pfw_xxx&payment_flow_client_secret=pfws_xxx`
6. Server or Frontend: Verify via `retrievePaymentFlow(client_secret)` or API call

### Server-side (PHP)

```php
// Step 1: Create Payment Flow
function payjp_create_card_payment_flow( int $amount, string $customer_id = '' ): array {
    $body = [
        'amount'               => $amount,
        'currency'             => 'jpy',
        'payment_method_types' => [ 'card' ],
        'capture_method'       => 'automatic',
    ];
    if ( $customer_id ) {
        $body['customer_id'] = $customer_id;
    }

    $response = wp_remote_post( 'https://api.pay.jp/v2/payment_flows', [
        'headers' => [
            'Authorization' => 'Bearer ' . get_option( 'payjp_secret_key' ),
            'Content-Type'  => 'application/json',
        ],
        'body'    => wp_json_encode( $body ),
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
}

// Step 6: Verify payment result
function payjp_get_payment_flow( string $flow_id ): array {
    $response = wp_remote_get(
        'https://api.pay.jp/v2/payment_flows/' . rawurlencode( $flow_id ),
        [
            'headers' => [ 'Authorization' => 'Bearer ' . get_option( 'payjp_secret_key' ) ],
            'timeout' => 30,
        ]
    );
    return json_decode( wp_remote_retrieve_body( $response ), true );
}
```

### Frontend (JavaScript)

```html
<div id="payjp-payment-form"></div>
<button id="pay-button">支払う</button>
<div id="payjp-error" role="alert"></div>
```

```javascript
( async () => {
    const payments = PayjpPayments( payjpData.publicKey );
    const widgets  = payments.widgets({ clientSecret: payjpData.clientSecret });

    const form = widgets.createForm( 'payment', {
        layout: 'accordion',
        paymentMethodOrder: [ 'card' ],
    } );
    form.mount( '#payjp-payment-form' );

    document.getElementById( 'pay-button' ).addEventListener( 'click', async () => {
        const result = await widgets.confirmPayment({
            return_url: payjpData.returnUrl,
        });
        if ( result.error ) {
            document.getElementById( 'payjp-error' ).textContent = result.error.message;
        }
        // On success: auto-redirect to return_url with payment_flow_id & client_secret params
    } );
} )();
```

## Implementation: External Link (Checkout v2)

### Flow

1. Server: Create Checkout Session → redirect user to `session.url` (HTTP 303)
2. User: Completes payment on PAY.JP hosted page
3. PAY.JP: Redirects to `success_url` or `cancel_url`
4. Server: Receive Webhook `checkout.session.completed` for authoritative result

### Server-side (PHP)

```php
function payjp_create_checkout_session( int $amount, string $order_id ): string {
    // line_items is required in payment mode. Use inline price_data for dynamic
    // cart totals (no pre-registered Product/Price needed; session-scoped, not reusable).
    $response = wp_remote_post( 'https://api.pay.jp/v2/checkout/sessions', [
        'headers' => [
            'Authorization' => 'Bearer ' . get_option( 'payjp_secret_key' ),
            'Content-Type'  => 'application/json',
        ],
        'body' => wp_json_encode( [
            'mode'                 => 'payment',
            'payment_method_types' => [ 'card' ],
            'line_items'           => [
                [
                    'price_data' => [
                        'currency'     => 'jpy',
                        'unit_amount'  => $amount,
                        'product_data' => [ 'name' => 'Order #' . $order_id ],
                    ],
                    'quantity'   => 1,
                ],
            ],
            'success_url'          => home_url( '/payjp/success?order=' . $order_id ),
            'cancel_url'           => wc_get_checkout_url(),
            'metadata'             => [ 'order_id' => $order_id ],
        ] ),
        'timeout' => 30,
    ] );

    $data = json_decode( wp_remote_retrieve_body( $response ), true );
    return $data['url']; // Redirect user here with HTTP 303
}
```

## 3D Secure

3DS is automatically triggered at card registration or first card use. To force 3DS on every payment:

```php
$body['payment_method_options'] = [
    'card' => [
        'request_three_d_secure' => 'any',
    ],
];
```

To skip 3DS on Setup Flow (card registration) — authentication will be required on first payment instead:

```php
// Setup Flow body
$body['usage'] = 'on_session';
```

## Authorization (manual capture)

```php
// Create with manual capture
$body['capture_method'] = 'manual';

// Later: capture the authorization
// Partial capture: pass [ 'amount_to_capture' => 3000 ] (only once; remainder auto-canceled)
$response = wp_remote_post(
    'https://api.pay.jp/v2/payment_flows/' . $flow_id . '/capture',
    [
        'headers' => [
            'Authorization' => 'Bearer ' . get_option( 'payjp_secret_key' ),
            'Content-Type'  => 'application/json',
        ],
        'body'    => wp_json_encode( [] ),
        'timeout' => 30,
    ]
);
// Response: status=succeeded, amount_received=captured amount
```

Authorization hold: 7 days; extendable to 30 days (not extendable for overseas-issued cards).

## Customer payment method reuse

```php
// Create Payment Flow with existing customer + confirm immediately
$body = [
    'amount'      => $amount,
    'currency'    => 'jpy',
    'customer_id' => $customer_id,
    'confirm'     => true,  // Uses customer's default_payment_method_id
];
// Result status may be 'succeeded', 'requires_action', or error
```

## Refunds

- Allowed within 180 days of payment creation
- Partial refunds supported (multiple; total cannot exceed `amount_received`)
- Card refunds usually complete immediately (`status: succeeded`)

```php
POST https://api.pay.jp/v2/payment_refunds
{
    "payment_flow": "pfw_xxx",
    "amount": 500,           // optional; omit for full refund
    "reason": "requested_by_customer" // or "fraudulent" | "duplicate"
}
// Response: refund object (id: pyr_xxx)
```
