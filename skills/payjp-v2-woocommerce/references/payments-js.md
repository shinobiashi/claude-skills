# payments.js Reference

Source: https://docs.pay.jp/v2/guide/developers/paymentsjs-reference
Last updated: 2026-07-02

## Installation

### Script tag (recommended for WordPress)

```html
<script src="https://js.pay.jp/payments.js"></script>
```

Enqueue in WordPress:
```php
wp_enqueue_script(
    'payjp-payments-js',
    'https://js.pay.jp/payments.js',
    [],
    null,
    true
);
```

### NPM

```bash
npm install @payjp/payments-js
```

```javascript
import { loadPayments } from '@payjp/payments-js';
const payments = await loadPayments( 'YOUR_PUBLIC_KEY' );
```

For React: `react-payments-js` wrapper library.

## Initialization

```javascript
const payments = PayjpPayments( publicKey, options );
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `locale` | `"ja"` \| `"en"` | `"ja"` | UI language |

## Creating Widgets

```javascript
const widgets = payments.widgets({ clientSecret: clientSecret });
```

`clientSecret` (required): obtained from server-side Payment Flow or Setup Flow creation. Cannot be changed after creation.
`locale` (optional): overrides the PayjpPayments-level setting.

## Creating Forms

### Payment form

```javascript
const form = widgets.createForm( 'payment', options );
```

**Options:**

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `layout` | `"accordion"` \| `"tab"` \| `object` | `"accordion"` | Form layout |
| `paymentMethodOrder` | `["card", "paypay", "apple_pay"]` | auto | Display order |
| `fields.billingDetails.name` | `"auto"` \| `"never"` | `"auto"` | Name field |
| `fields.billingDetails.email` | `"auto"` \| `"never"` | `"auto"` | Email field |
| `fields.billingDetails.phone` | `"auto"` \| `"never"` | `"auto"` | Phone field |
| `defaultValues.billingDetails` | object | — | Pre-fill billing info (name/email/phone/address) |

`fields.billingDetails` also accepts a plain string (`"auto"` / `"never"`) applied to all fields.
If hidden with `"never"`, pass the values via `confirmPayment`'s `payment_method_data.billing_details` instead.

Accordion layout with `defaultCollapsed` (default: `true` for accordion, `false` for tab):
```javascript
const form = widgets.createForm( 'payment', {
    layout: { type: 'accordion', defaultCollapsed: false },
} );
```

### Address form

```javascript
const addressForm = widgets.createForm( 'address', options );
```

**Required option:**
- `mode`: `"shipping"` or `"billing"` (cannot be changed after creation)

| Option | Values | Description |
|--------|--------|-------------|
| `fields.phone` | `"always"` \| `"auto"` (default) \| `"never"` | Phone field visibility |
| `defaultValues` | object | Pre-fill `name` / `phone` / `address` |

## Form Methods

| Method | Description |
|--------|-------------|
| `form.mount( selector )` | Mount form to DOM element (selector or HTMLElement) |
| `form.unmount()` | Remove from DOM (remountable) |
| `form.update( options )` | Update form options post-mount (`layout` / `mode` cannot change) |
| `form.collapse()` | Collapse accordion sections |
| `form.on( event, handler )` | Attach event listener |
| `form.off( event, handler )` | Remove event listener |

## Widget Methods

| Method | Description |
|--------|-------------|
| `widgets.createForm( type, options )` | Create a form instance (`"payment"` or `"address"`) |
| `widgets.getForm( type, options )` | Retrieve existing form (address requires `{ mode }`) |
| `widgets.confirmPayment( params )` | Execute payment confirmation |
| `widgets.confirmSetup( params )` | Execute setup flow confirmation |
| `widgets.fetchUpdates()` | Fetch server-side updates |
| `widgets.update( options )` | Update widget config (`clientSecret` cannot change) |
| `widgets.on( 'updateEnd', handler )` | Fires when `update` / `fetchUpdates` completes |

## Confirming Payment

```javascript
const result = await widgets.confirmPayment({
    return_url: 'https://example.com/return',
    payment_method_data: {          // optional: override billing details
        billing_details: {
            name: 'Taro Yamada',
            email: 'taro@example.com',
            phone: '+81-90-0000-0000',
            address: {
                line1: '1-1-1 Shibuya',
                line2: 'Apartment 101',
                city: 'Shibuya-ku',
                state: 'Tokyo',
                zip: '150-0001',
                country: 'JP',
            },
        },
    },
});

if ( result.error ) {
    // Show error to user — do NOT redirect
    errorElement.textContent = result.error.message;
} else {
    // Redirects automatically to return_url on success
}
```

On success, browser auto-redirects to `return_url` with:
- `?payment_flow_id=pfw_xxx&payment_flow_client_secret=pfws_xxx`

(Setup Flow: `?setup_flow_id=sflw_xxx&setup_flow_client_secret=sflw_secret_xxx`)

## Confirming Setup Flow

```javascript
const result = await widgets.confirmSetup({
    return_url: 'https://example.com/setup-complete',
});
```

## PayjpPayments Methods

```javascript
// Retrieve Payment Flow status (frontend verification)
const paymentFlow = await payments.retrievePaymentFlow( clientSecret );
// Returns: { status: 'succeeded', id: 'pfw_xxx', ... }

// Retrieve Setup Flow status
const setupFlow = await payments.retrieveSetupFlow( clientSecret );

// Handle additional authentication (3DS, PayPay page) after server-side confirm
// returned requires_action. Redirects immediately; then goes to the flow's return_url
// (set return_url via Payment Flow Update API if missing).
await payments.handleNextAction({ clientSecret });
```

## Events

Form events (`form.on(...)`):

| Event | Trigger | Payload |
|-------|---------|---------|
| `ready` | Form initialized | — |
| `change` | User input changed | `{ complete, empty, value }` |
| `focus` | Field focused | — |
| `blur` | Field blurred | — |

Widgets event: `updateEnd` (widget update complete) — subscribe via `widgets.on( 'updateEnd', ... )`, not on the form.

### `change` payload

**Payment form:**
```javascript
form.on( 'change', ( event ) => {
    // event.complete  — boolean: all required fields filled
    // event.empty     — boolean: no data entered
    // event.value.type — 'card' | 'paypay' | 'apple_pay'
} );
```

**Address form:**
```javascript
addressForm.on( 'change', ( event ) => {
    // event.complete  — boolean
    // event.empty     — boolean
    // event.value     — address object
} );
```

## Error Handling

```javascript
const result = await widgets.confirmPayment({ return_url: '...' });
if ( result.error ) {
    // result.error.message — human-readable, user-displayable
    // result.error.code    — machine-readable error code
    // Validation errors do NOT redirect; user stays on form
}
```

## WordPress integration pattern

```php
public function payment_scripts(): void {
    if ( ! is_checkout() || is_order_received_page() ) return;

    wp_enqueue_script( 'payjp-payments-js', 'https://js.pay.jp/payments.js', [], null, true );
    wp_enqueue_script(
        'payjp-checkout',
        plugins_url( 'assets/js/checkout.js', PAYJP_PLUGIN_FILE ),
        [ 'jquery', 'payjp-payments-js' ],
        PAYJP_VERSION,
        true
    );

    // client_secret is created per-page-load in payment_fields()
    // and passed via wp_add_inline_script or localized data
}

public function payment_fields(): void {
    // Create Payment Flow here to get client_secret
    $flow = $this->create_payment_flow( WC()->cart->get_total( 'edit' ) );

    wp_localize_script( 'payjp-checkout', 'payjpData', [
        'publicKey'    => esc_js( $this->public_key ),
        'clientSecret' => esc_js( $flow['client_secret'] ),
        'returnUrl'    => esc_url( home_url( '/payjp/return' ) ),
    ] );

    echo '<div id="payjp-payment-form"></div>';
    echo '<div id="payjp-error" role="alert" aria-live="polite"></div>';
}
```
