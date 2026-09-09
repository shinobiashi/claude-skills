# WooCommerce Block Types and Decisions

This reference helps you identify which type of WooCommerce block you are building before writing any code. The implementation path differs substantially across types.

---

## Decision tree

Answer these questions in order:

1. **Where does the block appear?**
   - In posts/pages/templates inserted by the site editor → **Path A: Frontend display block**
   - Inside the Cart or Checkout block on the storefront → **Path B: Checkout/Cart extension**
   - In the WooCommerce Product Edit screen → **Path C: Product Editor block**

2. **Does it only read WC data, or does it also modify checkout behavior?**
   - Read only → Path A (or Store API GET calls in Path B)
   - Modify labels, payment methods, shipping, order meta → Path B with `registerCheckoutFilters` or Slot/Fill

3. **Does it need custom PHP data that is not in the Store API?**
   - Yes → Path B with `ExtendSchema` and `IntegrationInterface`
   - No → standard block registration is sufficient

---

## Path A — Frontend display block

**Examples:** "Featured Products", "Recently Viewed Products", "Product Category Grid"

**Characteristics:**
- Inserted by site editors in posts, pages, or FSE templates
- Reads product/category/cart data from WC REST API or `@woocommerce/data` stores
- Rendered in the block editor (edit.js) and on the frontend (render.php or viewScript)

**Implementation checklist:**
- `block.json` with `editorScript`, `viewScript` (or `render`)
- `edit.js` uses `useSelect` with `@woocommerce/data` stores
- `render.php` uses `wc_get_products()` or WP REST API for SSR
- Standard `register_block_type()` in PHP — no `IntegrationInterface` needed
- webpack uses `@woocommerce/dependency-extraction-webpack-plugin`

**Key package:** `@woocommerce/data`

**Store API access:** Read only (`/wc/store/v1/products`, `/wc/store/v1/cart`)

---

## Path B — Checkout/Cart block extension

**Examples:** Custom order note field, loyalty points display, custom shipping message, gift wrap option

**Characteristics:**
- Runs inside the existing WooCommerce Cart or Checkout blocks
- PHP side ALWAYS requires `IntegrationInterface` to register scripts
- JS side uses `@woocommerce/blocks-checkout` APIs

**Sub-paths:**

### B1 — UI injection via Slot/Fill

Inject a React component into an existing Slot in the Checkout or Cart block.

Common slots (WC 9.0+):
- `ExperimentalOrderMeta` — below the order summary
- `ExperimentalOrderShippingPackages` — within shipping packages
- `ExperimentalDiscountsMeta` — below discount fields
- `ExperimentalPaymentMethodIcons` — payment method icon area

```js
import { ExperimentalOrderMeta } from '@woocommerce/blocks-checkout';

const MySlotFillComponent = () => (
    <ExperimentalOrderMeta.Fill>
        <p>Custom order meta content</p>
    </ExperimentalOrderMeta.Fill>
);
```

### B2 — Filter hooks via registerCheckoutFilters

Modify existing labels, classes, or data without injecting UI.

```js
import { registerCheckoutFilters } from '@woocommerce/blocks-checkout';

registerCheckoutFilters( 'my-plugin', {
    // Modify coupon code label
    couponName: ( value, extensions, args ) => {
        if ( args?.coupon?.code === 'SPECIAL' ) {
            return 'Special Discount';
        }
        return value;
    },
    // Modify cart item subtotal
    cartItemPrice: ( value, extensions, args ) => {
        return value;
    },
} );
```

Available filters: `couponName`, `cartItemPrice`, `cartItemName`, `subtotalPriceFormat`, `paymentMethodLabel`, `placeOrderButtonLabel`, `saleBadgePriceFormat`, `showRemoveItemLink`, `isCouponFeatureEnabled`, `totalLabel`.

### B3 — Inner blocks

A block that can be placed inside the Checkout block via InnerBlocks configuration. This requires registering the block as a valid inner block of the checkout template.

**PHP side for all Path B sub-paths:**

```php
use Automattic\WooCommerce\StoreApi\Schemas\ExtendSchema;
use Automattic\WooCommerce\Blocks\Integrations\IntegrationInterface;

class My_Checkout_Integration implements IntegrationInterface {

    public function get_name(): string {
        return 'my-plugin';
    }

    public function initialize(): void {
        wp_register_script(
            'my-checkout-integration',
            plugin_dir_url( __FILE__ ) . 'build/checkout-integration.js',
            [],
            '1.0.0',
            true
        );
        wp_add_inline_script(
            'my-checkout-integration',
            'const myPluginData = ' . wp_json_encode( [ 'apiUrl' => rest_url( 'my-plugin/v1/' ) ] ),
            'before'
        );
    }

    public function get_script_handles(): array {
        return [ 'my-checkout-integration' ];
    }

    public function get_editor_script_handles(): array {
        return [];
    }

    public function get_script_data(): array {
        return [
            'someFlag' => get_option( 'my_plugin_flag', true ),
        ];
    }
}

// Register the integration
add_action( 'woocommerce_blocks_checkout_block_registration', function ( $integration_registry ) {
    $integration_registry->register( new My_Checkout_Integration() );
} );
add_action( 'woocommerce_blocks_cart_block_registration', function ( $integration_registry ) {
    $integration_registry->register( new My_Checkout_Integration() );
} );
```

**Extending Store API (optional):**

```php
use Automattic\WooCommerce\StoreApi\Schemas\ExtendSchema;
use Automattic\WooCommerce\StoreApi\StoreApi;

add_action( 'woocommerce_blocks_loaded', function () {
    $extend = StoreApi::container()->get( ExtendSchema::class );
    $extend->register_endpoint_data( [
        'endpoint'        => \Automattic\WooCommerce\StoreApi\Schemas\V1\CartSchema::IDENTIFIER,
        'namespace'       => 'my-plugin',
        'data_callback'   => function () {
            return [
                'loyalty_points' => get_user_meta( get_current_user_id(), 'loyalty_points', true ),
            ];
        },
        'schema_callback' => function () {
            return [
                'loyalty_points' => [
                    'description' => 'Loyalty points for the current user.',
                    'type'        => 'integer',
                    'readonly'    => true,
                ],
            ];
        },
        'schema_type' => ARRAY_A,
    ] );
} );
```

---

## Path C — Product Editor block

> **⚠️ RETIRED — do not choose this path for new work.** The block-based Product Editor and `@woocommerce/product-editor` were deprecated in WC 10.9 and **removed from core in WC 11.0 (2026-07-28)**. Stores revert to the classic product editor; no drop-in replacement ships with 11.0 (future work builds on WordPress DataViews/DataForms, still experimental). The guidance below applies only to maintaining or migrating off existing integrations before 11.0.

**Examples:** Custom product field, custom product section, additional product data tab

**Characteristics:**
- Runs in the WooCommerce Product Edit screen (block-based product editor, WC 8.6+)
- Uses `@woocommerce/product-editor` components and templates
- Data saved via WC REST API `/wc/v3/products`

**Implementation checklist:**
- Register block with `block.json` as normal
- Register block in a product editor template area
- Use `@woocommerce/product-editor` components for consistent UI
- Save custom data via `woocommerce_rest_insert_product_object` hook or custom meta

**Example: Adding a custom section to the product editor**

```php
use Automattic\WooCommerce\Admin\BlockTemplates\BlockTemplateInterface;

add_action( 'woocommerce_block_template_area_product-form_after_load', function ( BlockTemplateInterface $template ) {
    $basic_details = $template->get_block( 'woocommerce/product-section-basic-details' );
    if ( $basic_details ) {
        $basic_details->add_block( [
            'id'         => 'my-plugin/custom-field',
            'blockName'  => 'my-plugin/custom-field',
            'order'      => 40,
            'attributes' => [
                'label'    => 'Custom Field',
                'property' => 'meta_data',
            ],
        ] );
    }
} );
```

**Key package:** `@woocommerce/product-editor`

**Store API access:** Write via `/wc/v3/products` (admin REST API, not Store API)

---

## Comparison table

| Aspect | Path A: Frontend | Path B: Checkout/Cart | Path C: Product Editor |
|--------|-----------------|----------------------|----------------------|
| Entry point | `block.json` editorScript + viewScript | `IntegrationInterface::get_script_handles()` | block.json + product editor template |
| WC version min | 9.0 | 9.0 | 8.6 |
| PHP class required | None | `IntegrationInterface` | None (template hook) |
| Key JS package | `@woocommerce/data` | `@woocommerce/blocks-checkout` | `@woocommerce/product-editor` |
| Store API usage | Read only | Read + extend | Write via /wc/v3/products |
| Inserted by | Site editor / block inserter | Always present in Checkout block | Always present in Product Editor |

---

## Common WooCommerce packages and their purpose

| Package | Purpose |
|---------|---------|
| `@woocommerce/data` | Redux-like data stores for WC entities (products, orders, settings) |
| `@woocommerce/blocks-checkout` | Checkout/Cart block extension APIs (filters, Slot/Fill) |
| `@woocommerce/blocks-registry` | Block registry for WC blocks |
| `@woocommerce/components` | WooCommerce UI components for admin screens |
| `@woocommerce/product-editor` | Product Editor blocks and templates |
| `@woocommerce/dependency-extraction-webpack-plugin` | Externalize WC packages in webpack builds |
| `@woocommerce/e2e-utils` | E2E testing utilities for WooCommerce |
| `@woocommerce/settings` | Access to WooCommerce settings exposed via `wcSettings` |

---

## Version compatibility notes

- **WC 8.6+**: Block-based Product Editor became stable — **but now retired: deprecated WC 10.9, removed from core WC 11.0 (2026-07-28). Do not build new Path C work; migrate existing blocks off `@woocommerce/product-editor` before 11.0.**
- **WC 8.9+**: `ExtendSchema` API stabilized; avoid ExtendSchema patterns from older docs that use `Automattic\WooCommerce\StoreApi\Schemas\ExtendSchema` directly without the `StoreApi::container()` pattern
- **WC 9.0+**: All Path A, B, C APIs are stable as documented here
- **@experimental prefix**: Slot Fill components prefixed with `Experimental` (e.g., `ExperimentalOrderMeta`) can change API between WC minor versions — always verify against the installed version
