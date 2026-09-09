# WooCommerce Testing Patterns

Patterns for writing PHPUnit tests for WooCommerce extensions using `WC_Unit_Test_Case`.

---

## `WC_Unit_Test_Case` base class

`WC_Unit_Test_Case` extends `WP_UnitTestCase` and adds WooCommerce-specific setup
(session, customer, cart initialization). Use it as your base class for integration tests
that interact with WooCommerce objects.

```php
<?php
class My_Plugin_Order_Test extends WC_Unit_Test_Case {

    public function test_order_created(): void {
        $order = WC_Helper_Order::create_order();
        $this->assertInstanceOf( WC_Order::class, $order );
    }
}
```

Make sure `WC_Unit_Test_Case` is loaded in `tests/bootstrap.php` (see `references/setup.md`).

---

## WooCommerce factory helpers

### Products

```php
// Simple product.
$product = WC_Helper_Product::create_simple_product();
$this->assertSame( 'simple', $product->get_type() );
$this->assertGreaterThan( 0, $product->get_id() );

// Simple product with custom price.
$product = WC_Helper_Product::create_simple_product( true, [
    'regular_price' => '19.99',
    'sale_price'    => '14.99',
    'sku'           => 'TEST-SKU-001',
] );

// Variable product with variations.
$variable = WC_Helper_Product::create_variation_product();
$this->assertSame( 'variable', $variable->get_type() );

// External/affiliate product.
$external = WC_Helper_Product::create_external_product();

// Cleanup (important — products are NOT auto-rolled back the same way posts are).
$product->delete( true );
```

### Orders

```php
// Create a basic order with one line item.
$order = WC_Helper_Order::create_order();
$this->assertInstanceOf( WC_Order::class, $order );
$this->assertSame( 'pending', $order->get_status() );

// Create an order for a specific customer.
$customer_id = WC_Helper_Customer::create_customer();
$order = WC_Helper_Order::create_order( $customer_id );
$this->assertSame( $customer_id, $order->get_customer_id() );

// Access order properties.
$order_id   = $order->get_id();
$total      = $order->get_total();
$items      = $order->get_items();
$first_item = reset( $items );
$this->assertInstanceOf( WC_Order_Item_Product::class, $first_item );

// Cleanup.
$order->delete( true );
```

### Customers

```php
// Create a WooCommerce customer (WP user + customer data).
$customer_id = WC_Helper_Customer::create_customer();
$this->assertGreaterThan( 0, $customer_id );

// Load as WC_Customer object.
$customer = new WC_Customer( $customer_id );
$this->assertSame( 'Jeroen', $customer->get_first_name() );
$this->assertSame( 'Netherlands', $customer->get_billing_country() );

// Create with custom data.
$customer_id = WC_Helper_Customer::create_customer(
    'myuser',
    'password123',
    'custom@example.com'
);
```

---

## Testing payment gateways

### Basic gateway class test

```php
<?php
class My_Gateway_Test extends WC_Unit_Test_Case {

    private My_Payment_Gateway $gateway;

    protected function setUp(): void {
        parent::setUp();
        // Ensure WooCommerce payment gateways are initialized.
        WC()->payment_gateways()->init();
        $this->gateway = new My_Payment_Gateway();
    }

    public function test_gateway_id(): void {
        $this->assertSame( 'my_gateway', $this->gateway->id );
    }

    public function test_gateway_is_available(): void {
        $this->gateway->enabled = 'yes';
        $this->assertTrue( $this->gateway->is_available() );
    }

    public function test_gateway_disabled(): void {
        $this->gateway->enabled = 'no';
        $this->assertFalse( $this->gateway->is_available() );
    }

    public function test_process_payment_returns_success(): void {
        $order  = WC_Helper_Order::create_order();
        $result = $this->gateway->process_payment( $order->get_id() );

        $this->assertIsArray( $result );
        $this->assertSame( 'success', $result['result'] );
        $this->assertArrayHasKey( 'redirect', $result );

        $order->delete( true );
    }

    public function test_process_payment_on_invalid_order_returns_failure(): void {
        $result = $this->gateway->process_payment( 999999 );

        $this->assertIsArray( $result );
        $this->assertSame( 'failure', $result['result'] );
    }
}
```

### Mocking gateway API calls

Use the `pre_http_request` filter (see `wp-testcase-patterns.md`) to intercept calls
to the payment API:

```php
protected function setUp(): void {
    parent::setUp();
    add_filter( 'pre_http_request', [ $this, 'mock_payment_api' ], 10, 3 );
}

public function mock_payment_api( $preempt, array $args, string $url ) {
    if ( str_contains( $url, 'api.mypayment.com/charges' ) ) {
        return [
            'response' => [ 'code' => 200, 'message' => 'OK' ],
            'body'     => wp_json_encode( [
                'id'     => 'ch_test_123',
                'status' => 'succeeded',
                'amount' => 1000,
            ] ),
            'headers'  => [ 'content-type' => 'application/json' ],
        ];
    }
    return $preempt;
}
```

---

## Testing WooCommerce hooks

### `woocommerce_payment_complete`

```php
public function test_payment_complete_triggers_fulfillment(): void {
    $order   = WC_Helper_Order::create_order();
    $fired   = false;

    add_action( 'woocommerce_payment_complete', function( $order_id ) use ( &$fired ) {
        $fired = true;
    } );

    $order->payment_complete();

    $this->assertTrue( $fired );
    $this->assertSame( 'processing', $order->get_status() );

    $order->delete( true );
}
```

### `woocommerce_order_status_changed`

```php
public function test_order_status_change_hook(): void {
    $order      = WC_Helper_Order::create_order();
    $from_status = null;
    $to_status   = null;

    add_action(
        'woocommerce_order_status_changed',
        function( $order_id, $from, $to ) use ( &$from_status, &$to_status ) {
            $from_status = $from;
            $to_status   = $to;
        },
        10,
        3
    );

    $order->update_status( 'completed' );

    $this->assertSame( 'pending', $from_status );
    $this->assertSame( 'completed', $to_status );

    $order->delete( true );
}
```

### `woocommerce_checkout_order_created`

```php
public function test_plugin_reacts_to_new_order(): void {
    $order       = WC_Helper_Order::create_order();
    $plugin_meta = get_post_meta( $order->get_id(), '_my_plugin_processed', true );

    // Simulate checkout firing the hook.
    do_action( 'woocommerce_checkout_order_created', $order );

    $plugin_meta = get_post_meta( $order->get_id(), '_my_plugin_processed', true );
    $this->assertSame( '1', $plugin_meta );

    $order->delete( true );
}
```

---

## Testing product meta and custom order meta

### Custom product meta

```php
public function test_save_and_read_product_meta(): void {
    $product = WC_Helper_Product::create_simple_product();

    update_post_meta( $product->get_id(), '_my_plugin_data', 'test_value' );

    // Re-load product to confirm persistence.
    $loaded = wc_get_product( $product->get_id() );
    $meta   = $loaded->get_meta( '_my_plugin_data' );

    $this->assertSame( 'test_value', $meta );

    $product->delete( true );
}
```

### Custom order meta

```php
public function test_order_meta_stored_after_payment(): void {
    $order = WC_Helper_Order::create_order();

    // Simulate the gateway storing a transaction ID.
    $order->update_meta_data( '_my_gateway_transaction_id', 'txn_abc123' );
    $order->save();

    $loaded = wc_get_order( $order->get_id() );
    $this->assertSame( 'txn_abc123', $loaded->get_meta( '_my_gateway_transaction_id' ) );

    $order->delete( true );
}
```

---

## Database assertions

Sometimes you need to confirm data was written directly to WooCommerce tables.

```php
public function test_order_item_meta_in_database(): void {
    global $wpdb;

    $order = WC_Helper_Order::create_order();
    $items = $order->get_items();
    $item  = reset( $items );

    // Assert the order item exists in wp_woocommerce_order_items.
    $row = $wpdb->get_row( $wpdb->prepare(
        "SELECT * FROM {$wpdb->prefix}woocommerce_order_items WHERE order_item_id = %d",
        $item->get_id()
    ) );

    $this->assertNotNull( $row );
    $this->assertSame( (string) $order->get_id(), (string) $row->order_id );

    $order->delete( true );
}
```

---

## WooCommerce Subscriptions (WCS)

When WCS is available as a Composer dev dependency or local install:

```php
public function test_subscription_created(): void {
    if ( ! class_exists( 'WC_Subscriptions' ) ) {
        $this->markTestSkipped( 'WooCommerce Subscriptions not available.' );
    }

    $subscription = WCS_Helper_Subscription::create_subscription();
    $this->assertInstanceOf( WC_Subscription::class, $subscription );
    $this->assertSame( 'pending', $subscription->get_status() );
}

public function test_renewal_order_created(): void {
    if ( ! class_exists( 'WC_Subscriptions' ) ) {
        $this->markTestSkipped( 'WooCommerce Subscriptions not available.' );
    }

    $subscription    = WCS_Helper_Subscription::create_subscription();
    $renewal_order   = wcs_create_renewal_order( $subscription );

    $this->assertInstanceOf( WC_Order::class, $renewal_order );
    $this->assertSame(
        (string) $subscription->get_id(),
        $renewal_order->get_meta( '_subscription_renewal' )
    );
}
```

Use `$this->markTestSkipped()` to gracefully skip WCS tests when the plugin is absent,
rather than failing with a fatal error.

---

## Setting up the WooCommerce test environment

Minimum required environment variables for WooCommerce integration tests:

```bash
# Required
export WP_TESTS_DIR=/tmp/wordpress-tests-lib
export WC_DIR=/path/to/woocommerce          # or vendor/woocommerce/woocommerce

# Optional overrides
export WC_UNIT_TESTS_DIR="${WC_DIR}/tests/legacy"
export WP_CORE_DIR=/tmp/wordpress
```

For wp-env, run inside the container:

```bash
npx wp-env run tests-cli bash -c "
  WP_TESTS_DIR=/tmp/wp-tests \
  WC_DIR=/var/www/html/wp-content/plugins/woocommerce \
  vendor/bin/phpunit
"
```

---

## Common assertion helpers

```php
// Assert an order is in a specific status.
$this->assertSame( 'completed', $order->get_status() );

// Assert an order has a specific number of items.
$this->assertCount( 2, $order->get_items() );

// Assert a product's price.
$this->assertSame( '9.99', $product->get_price() );

// Assert a customer has a specific billing country.
$customer = new WC_Customer( $customer_id );
$this->assertSame( 'US', $customer->get_billing_country() );

// Assert a notice was added (e.g., from wc_add_notice).
// Note: WC notices are stored in the session; check via WC()->session or notice functions.
$notices = WC()->session->get( 'wc_notices', [] );
$this->assertArrayHasKey( 'error', $notices );
```
