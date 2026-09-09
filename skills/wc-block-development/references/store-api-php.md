# WooCommerce Store API — PHP Extensions

Extending the WooCommerce Store API from the PHP side to inject custom data into REST responses.

---

## 1. ExtendSchema — Adding Custom Data to Store API Responses

`ExtendSchema::instance()->register_endpoint_data()` injects custom data into Store API responses.

### Available Endpoints

| Endpoint Constant | REST Path |
|---|---|
| `CartSchema::IDENTIFIER` | `/wc/store/v1/cart` |
| `CheckoutSchema::IDENTIFIER` | `/wc/store/v1/checkout` |
| `CartItemSchema::IDENTIFIER` | `/wc/store/v1/cart/items` |
| `OrderSchema::IDENTIFIER` | `/wc/store/v1/order/{id}` |
| `ProductSchema::IDENTIFIER` | `/wc/store/v1/products/{id}` |

### Full Implementation Example (Custom Fields on Cart)

```php
<?php
use Automattic\WooCommerce\Blocks\Package;
use Automattic\WooCommerce\Blocks\Domain\Services\ExtendRestApi;
use Automattic\WooCommerce\StoreApi\Schemas\V1\CartSchema;
use Automattic\WooCommerce\StoreApi\Schemas\V1\CheckoutSchema;

add_action( 'woocommerce_blocks_loaded', function() {
    $extend = Package::container()->get( ExtendRestApi::class );

    // Add data to /wc/store/v1/cart responses
    $extend->register_endpoint_data( [
        'endpoint'        => CartSchema::IDENTIFIER,
        'namespace'       => 'my-plugin',
        'data_callback'   => function() {
            return [
                'custom_message' => get_option( 'my_plugin_cart_message', '' ),
                'promo_active'   => (bool) get_option( 'my_plugin_promo' ),
            ];
        },
        'schema_callback' => function() {
            return [
                'custom_message' => [
                    'description' => 'Custom cart message.',
                    'type'        => 'string',
                    'context'     => [ 'view', 'edit' ],
                    'readonly'    => true,
                ],
                'promo_active'   => [
                    'description' => 'Whether a promotion is currently active.',
                    'type'        => 'boolean',
                    'context'     => [ 'view', 'edit' ],
                    'readonly'    => true,
                ],
            ];
        },
        'schema_type'     => ARRAY_A,
    ] );
} );
```

### Accessing Extended Data on the JS Side

```js
import { useSelect } from '@wordpress/data';
import { CART_STORE_KEY } from '@woocommerce/block-data';

const MyComponent = () => {
    const extensions = useSelect( ( select ) => {
        return select( CART_STORE_KEY ).getCartData()?.extensions;
    } );

    const myData = extensions?.[ 'my-plugin' ];
    return <p>{ myData?.custom_message }</p>;
};
```

---

## 2. Custom Checkout Field Validation

Add a custom field to the checkout endpoint with server-side validation.

```php
$extend->register_endpoint_data( [
    'endpoint'            => CheckoutSchema::IDENTIFIER,
    'namespace'           => 'my-plugin',
    'schema_callback'     => function() {
        return [
            'custom_field' => [
                'description' => 'A custom checkout field.',
                'type'        => 'string',
                'context'     => [ 'view', 'edit' ],
                'readonly'    => false,
            ],
        ];
    },
    'schema_type'         => ARRAY_A,
    'validation_callback' => function( $fields ) {
        if ( empty( $fields['my-plugin']['custom_field'] ) ) {
            throw new RouteException(
                'my-plugin/missing-custom-field',
                __( 'Custom field is required.', 'my-plugin' ),
                400
            );
        }
    },
] );
```

> **Note:** `RouteException` is `Automattic\WooCommerce\StoreApi\Exceptions\RouteException`. Import it at the top of the file.

---

## 3. Version-Compatible Class Paths (WooCommerce 9.x+)

WooCommerce occasionally reorganizes namespaces across major versions. Use version detection to stay compatible.

```php
if ( class_exists( '\Automattic\WooCommerce\StoreApi\Schemas\V1\CartSchema' ) ) {
    use Automattic\WooCommerce\StoreApi\Schemas\V1\CartSchema;
    $endpoint = CartSchema::IDENTIFIER;
} else {
    // Fallback for older WC versions
    $endpoint = 'cart';
}
```

### Recommended Import Pattern for Plugins

```php
<?php
// Guard against missing WooCommerce Blocks
if ( ! class_exists( 'Automattic\WooCommerce\Blocks\Package' ) ) {
    return;
}

// Guard against missing ExtendRestApi
if ( ! class_exists( 'Automattic\WooCommerce\Blocks\Domain\Services\ExtendRestApi' ) ) {
    return;
}
```

---

## 4. Registering Data for Cart Items

Injecting per-item data (e.g., custom product meta) into cart item responses:

```php
use Automattic\WooCommerce\StoreApi\Schemas\V1\CartItemSchema;

$extend->register_endpoint_data( [
    'endpoint'        => CartItemSchema::IDENTIFIER,
    'namespace'       => 'my-plugin',
    'data_callback'   => function( $cart_item ) {
        $product_id    = $cart_item['product_id'] ?? 0;
        $custom_value  = get_post_meta( $product_id, '_my_custom_meta', true );
        return [
            'custom_meta' => $custom_value,
        ];
    },
    'schema_callback' => function() {
        return [
            'custom_meta' => [
                'description' => 'Custom product meta value.',
                'type'        => 'string',
                'context'     => [ 'view', 'edit' ],
                'readonly'    => true,
            ],
        ];
    },
    'schema_type'     => ARRAY_A,
] );
```

Access on the JS side via `cartItem.extensions['my-plugin'].custom_meta`.

---

## Key Notes

- Always wrap Store API extension registration inside `woocommerce_blocks_loaded` to ensure the Blocks package is available.
- The `namespace` key in `register_endpoint_data()` is used as the key in the `extensions` object of the REST response. Use a unique, plugin-specific namespace (e.g., `my-plugin`).
- `data_callback` is called for each request; keep it lightweight. Avoid expensive database queries — use caching where possible.
- `schema_callback` must accurately describe the shape returned by `data_callback`; mismatches may cause REST API validation errors.
- `validation_callback` is only meaningful for the `checkout` endpoint, where client-submitted data needs server-side checks.
