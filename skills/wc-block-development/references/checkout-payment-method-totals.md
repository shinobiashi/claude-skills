# Checkout totals that depend on the payment method

Read this before adding a fee, surcharge or discount that depends on which payment method the shopper selected (a cash-on-delivery fee, a card surcharge, a bank-transfer discount) in the Checkout block.

Everything below was verified against WooCommerce source at release tags 9.8.1, 10.7.0, 10.8.0, 10.9.0 and 11.1.2, and in a browser on 11.2.0-rc.1 (2026-10-06).

---

## 1. What the Checkout block does on its own

Since **WooCommerce 9.8**, the block tells the server about a payment method change without any extension code:

1. The shopper picks another payment method.
2. About **1.5 seconds later** (debounced, `data/checkout/push-changes.ts`) the block sends `PUT /wc/store/v1/checkout?__experimental_calc_totals=true` with `{"payment_method":"<id>"}`.
3. The server stores the method in the session as **`chosen_payment_method`**, recalculates the cart totals, and returns the cart in `__experimentalCart`.
4. The block applies that cart to its cart store, so the totals on screen update.

`chosen_payment_method` is the same session key the classic checkout has always used. A fee that reads it works in both checkouts.

| Behaviour | Since |
|---|---|
| `PUT /checkout` carries `payment_method`; `__experimental_calc_totals` recalculates and returns the cart | 9.8 |
| Deferred draft order: `PUT` updates only the session (`update_session_from_request()`), fires `woocommerce_store_api_checkout_update_draft`, and the block restores the session's payment method when the page loads | 10.9 (the action's docblock says `@since 10.8.0`, but the 10.8.0 tag does not contain it) |
| Place-order `POST` compares the request's `expected_total` with the server total and answers 409 `woocommerce_rest_checkout_total_mismatch` when the server total is higher | in 11.1.2; not in 10.9.0 |

`woocommerce_store_api_checkout_update_order_from_request` no longer fires on `PUT` when no draft order exists (10.9+). It still fires on the place-order `POST`, against the real order.

---

## 2. Recommended pattern

Add the fee in `woocommerce_cart_calculate_fees` and decide from `chosen_payment_method`.

```php
add_action( 'woocommerce_cart_calculate_fees', function ( WC_Cart $cart ) {
    if ( is_admin() && ! wp_doing_ajax() ) {
        return;
    }
    if ( 'cod' !== My_Fee::gateway_id() ) {
        return;
    }
    $cart->fees_api()->add_fee( array(
        'id'     => 'my_cod_fee',
        'name'   => __( 'Cash on delivery fee', 'my-plugin' ),
        'amount' => 330,
    ) );
} );
```

Fees are cleared at the start of every `calculate_totals()`, so there is nothing to remove when another method is selected: simply do not add the fee.

### The place-order POST calculates before it applies the payment method

For the final `POST /wc/store/v1/checkout`, WooCommerce runs `calculate_totals()` first and only afterwards writes the request's `payment_method` to the session and the order. During that calculation the session can still hold a different method than the one being submitted (the shopper clicked "Place order" within the 1.5 s debounce, or a client sent the two deliberately out of step).

Capture the request's own value before the route runs, and prefer it:

```php
final class My_Fee {
    private static ?string $request_payment_method = null;

    public static function init(): void {
        add_filter( 'rest_request_before_callbacks', array( __CLASS__, 'capture' ), 10, 3 );
    }

    public static function capture( $response, $handler, $request ) {
        // A batch request serves several requests in one process: always reset.
        self::$request_payment_method = null;

        if ( $request instanceof WP_REST_Request && 0 === strpos( $request->get_route(), '/wc/store/v1/checkout' ) ) {
            // Same accessor WooCommerce uses (CheckoutTrait::get_request_payment_method_id()).
            $payment_method = $request->get_param( 'payment_method' );
            if ( is_string( $payment_method ) && '' !== $payment_method ) {
                self::$request_payment_method = wc_clean( wp_unslash( $payment_method ) );
            }
        }
        return $response;
    }

    public static function gateway_id(): string {
        if ( null !== self::$request_payment_method ) {
            $available = WC()->payment_gateways ? WC()->payment_gateways->get_available_payment_gateways() : array();
            if ( isset( $available[ self::$request_payment_method ] ) ) {
                return self::$request_payment_method;
            }
        }
        $chosen = WC()->session ? WC()->session->get( 'chosen_payment_method' ) : '';
        return is_string( $chosen ) ? $chosen : '';
    }
}
```

`rest_request_before_callbacks` is the only hook that sees the request before the totals are calculated. `WC()->payment_gateways` can be `null` depending on init order, hence the guard.

### Optional: show the fee without the 1.5 s wait

To update the totals immediately, send the selection through `extensionCartUpdate` as well. The callback must write **`chosen_payment_method` itself**, after checking the value:

```php
woocommerce_store_api_register_update_callback( array(
    'namespace' => 'my-plugin-payment-method',
    'callback'  => function ( $data ) {
        // Unauthenticated endpoint: the value is fully client-controlled.
        if ( empty( $data['gateway_id'] ) || ! is_string( $data['gateway_id'] ) ) {
            return;
        }
        $available = WC()->payment_gateways ? WC()->payment_gateways->get_available_payment_gateways() : array();
        if ( isset( $available[ $data['gateway_id'] ] ) ) {
            WC()->session->set( 'chosen_payment_method', $data['gateway_id'] );
        }
    },
) );
```

`is_string()` must come before the array lookup: a non-empty array passes `empty()` and is a `TypeError` as an array offset.

---

## 3. Anti-pattern: a session key of your own

Do **not** keep the selected method in your own session key (`my_plugin_gateway_id`) and read that in the fee calculation. It predates WooCommerce 9.8 and now races with the block's own request:

- Your `extensionCartUpdate` request starts about 0.3 s after the click, the block's `PUT` about 1.5 s after it. On a server that takes longer than ~1.2 s to recalculate totals, they overlap.
- The `PUT` reads the session before your request has saved it, so it calculates the fee from your **stale** key even though WooCommerce set `chosen_payment_method` correctly in that same request. Its response lands last and overwrites the correct totals.
- The WooCommerce session is saved as one database row. Whichever request finishes last writes its whole copy back, undoing the other's change, so the two keys can stay out of step until the order is placed.

Symptoms: the fee stays on screen after switching away from the method, or appears and then disappears after switching to it. It does not reproduce on a fast local environment.

Writing the same key WooCommerce writes removes the race: both requests store the same value and calculate from the method they were told about.

---

## 4. Reproducing a timing problem

A fast local site hides this class of bug. To make it visible:

1. Log the two requests with their timing and the `total_fees` they return (Playwright `page.on('request'/'response')`, filtering `/wc/store/v1/batch` and `__experimental_calc_totals`).
2. Slow the server down **after the session has been read** with a temporary mu-plugin:

```php
add_action( 'woocommerce_after_calculate_totals', function () {
    static $slept = false;
    if ( $slept || ! defined( 'REST_REQUEST' ) || ! REST_REQUEST || 'GET' === ( $_SERVER['REQUEST_METHOD'] ?? 'GET' ) ) {
        return;
    }
    $slept = true;
    usleep( 1800000 );
} );
```

Sleeping earlier (at plugin load, or in `rest_pre_dispatch`) does not reproduce it: the Store API loads the cart and session inside the route, so both requests would simply read the session later.

Remove the mu-plugin afterwards.

---

## 5. Testing notes (Playwright)

- The block settles on its initial payment method a moment after the radio buttons render (10.9+ restores the session's method). Wait for `input[name="radio-control-wc-payment-method-options"]:checked` to have a count of 1 before clicking, or the click can be undone.
- Assert on what is rendered — the fee row, the total — not on a particular request being sent. Whether and when the block pushes the method depends on the version and on what the session already holds.
- Check "no fee" from a state where the fee row was just visible; an absent row on a freshly loaded page proves nothing.
- Change the quantity without reloading through the cart store: `wp.data.dispatch( 'wc/store/cart' ).changeCartItemQuantity( key, quantity )`, with the key from `wp.data.select( 'wc/store/cart' ).getCartData().items`.
- A new store is in "coming soon" mode: the checkout is hidden from everyone except administrators and shop managers, customers included. Test as an administrator or set `woocommerce_coming_soon` to `no`.

---

## 6. The Cart block runs the same hook

Store API cart requests also fire `woocommerce_cart_calculate_fees`, and `is_checkout()` is `false` in a REST request. A fee guarded only by `is_checkout() || REST_REQUEST` therefore appears in the Cart block and mini-cart once a payment method has been chosen in the session. Decide deliberately whether that is wanted.
