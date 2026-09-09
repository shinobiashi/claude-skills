# WooCommerce Checkout/Cart Block Extensions

Extension patterns for the WooCommerce Checkout and Cart blocks.

---

## 1. IntegrationInterface — PHP Side

WooCommerce registers block integrations via the `woocommerce_blocks_integration` action hook. A class implementing `IntegrationInterface` is required.

### Full Implementation Example

```php
<?php
namespace MyPlugin\Blocks;

use Automattic\WooCommerce\Blocks\Integrations\IntegrationInterface;

class CheckoutIntegration implements IntegrationInterface {

    public function get_name(): string {
        return 'my-checkout-integration';
    }

    public function initialize(): void {
        $script_path  = '/build/checkout-integration.js';
        $script_asset = require MY_PLUGIN_DIR . '/build/checkout-integration.asset.php';

        wp_register_script(
            'my-checkout-integration',
            MY_PLUGIN_URL . $script_path,
            $script_asset['dependencies'],
            $script_asset['version'],
            true
        );

        wp_add_inline_script(
            'my-checkout-integration',
            'const myPluginSettings = ' . wp_json_encode( [
                'enabled' => (bool) get_option( 'my_plugin_enabled' ),
            ] ),
            'before'
        );
    }

    public function get_script_handles(): array {
        return [ 'my-checkout-integration' ];
    }

    public function get_editor_script_handles(): array {
        return [ 'my-checkout-integration' ];
    }

    public function get_script_data(): array {
        return [
            'pluginVersion' => MY_PLUGIN_VERSION,
        ];
    }
}
```

### Registration via Action Hook

```php
add_action( 'woocommerce_blocks_loaded', function() {
    if ( ! class_exists( 'Automattic\WooCommerce\Blocks\Package' ) ) {
        return;
    }
    add_action(
        'woocommerce_blocks_checkout_block_registration',
        function( $integration_registry ) {
            $integration_registry->register( new CheckoutIntegration() );
        }
    );
    add_action(
        'woocommerce_blocks_cart_block_registration',
        function( $integration_registry ) {
            $integration_registry->register( new CheckoutIntegration() );
        }
    );
} );
```

---

## 2. registerCheckoutFilters — JS Side

`registerCheckoutFilters` allows modifying labels, classes, and payment methods.

### Available Filters

| Filter | Description |
|---|---|
| `couponsLabel` | Label for the coupon section |
| `subtotalLabel` | Subtotal label |
| `totalLabel` | Total label |
| `cartItemClass` | CSS class for cart items |
| `cartItemPrice` | Price display for cart items |
| `itemName` | Item name |
| `saleBadgeLabel` | Sale badge label |
| `showRemoveItemLink` | Show/hide the remove item link |
| `placeOrderButtonLabel` | Label for the place order button |
| `paymentMethodSortOrder` | Sort order for payment methods |
| `additionalCartCheckoutSidebarInnerBlockTypes` | Block types that can be added to the sidebar |

### Full Code Example (multiple filters in one file)

```js
import { registerCheckoutFilters } from '@woocommerce/blocks-checkout';

const NAMESPACE = 'my-plugin/checkout-filters';

// Modify the place order button label
registerCheckoutFilters( NAMESPACE, {
    placeOrderButtonLabel: ( value, extensions, args ) => {
        // args.paymentMethodSlug is available
        return __( 'Complete Secure Payment', 'my-plugin' );
    },
} );

// Hide the remove item link for certain products
registerCheckoutFilters( NAMESPACE, {
    showRemoveItemLink: ( value, extensions, args ) => {
        // args.cartItem contains the cart item data
        if ( args?.cartItem?.type === 'subscription' ) {
            return false;
        }
        return value;
    },
} );

// Modify cart item price display
registerCheckoutFilters( NAMESPACE, {
    cartItemPrice: ( value, extensions, args ) => {
        const { currency_minor_unit, currency_symbol } = args.cartItem.prices;
        // value is a formatted price string; return modified string
        return value;
    },
} );
```

---

## 3. Slot/Fill — UI Injection

### Available Slot Components

| Component | Description |
|---|---|
| `ExperimentalOrderMeta` | Order summary section |
| `ExperimentalOrderLocalPickupPackages` | Local pickup packages |
| `ExperimentalOrderShippingPackages` | Shipping packages |
| `ExperimentalPaymentMethods` | Payment methods section |
| `ExperimentalCartMeta` | Cart meta information |

### Injecting UI into ExperimentalOrderMeta

```js
import { registerPlugin } from '@wordpress/plugins';
import { ExperimentalOrderMeta } from '@woocommerce/blocks-checkout';
import { __ } from '@wordpress/i18n';

const MyOrderMetaFill = () => {
    return (
        <ExperimentalOrderMeta>
            <div className="my-plugin-order-meta">
                <p>{ __( 'Custom order message', 'my-plugin' ) }</p>
            </div>
        </ExperimentalOrderMeta>
    );
};

registerPlugin( 'my-plugin-checkout-extension', {
    render: MyOrderMetaFill,
    scope: 'woocommerce-checkout',
} );
```

> **Important:** The `scope` for `registerPlugin` must always be `'woocommerce-checkout'` or `'woocommerce-cart'`.

---

## 4. Inner Blocks for Checkout

Adding a custom block inside the Checkout block (e.g., custom fields).

### block.json

```json
{
    "name": "my-plugin/checkout-custom-field",
    "title": "Custom Field",
    "parent": ["woocommerce/checkout-fields-block"],
    "category": "woocommerce",
    "supports": { "html": false, "multiple": false }
}
```

### PHP Registration via additionalCartCheckoutInnerBlockTypes Filter

```js
registerCheckoutFilters( NAMESPACE, {
    additionalCartCheckoutSidebarInnerBlockTypes: ( value ) => [
        ...value,
        'my-plugin/checkout-custom-field',
    ],
} );
```

---

## Key Notes

- `IntegrationInterface::get_script_data()` values are exposed as `wc.wcBlocksRegistry.getRegisteredBlocks()` extensions data on the JS side.
- `registerCheckoutFilters` callbacks receive `( value, extensions, args )`. Always return a value — returning `undefined` may break the filter chain.
- Slot/Fill components prefixed with `Experimental` are subject to change in future WooCommerce versions. Pin your WooCommerce peer dependency version accordingly.
- When using `registerPlugin` with checkout scopes, the plugin is only rendered when the corresponding block is on the page.
