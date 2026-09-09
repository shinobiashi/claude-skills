# WooCommerce Data Stores

This reference covers how to read and write WooCommerce data in block editor scripts and frontend view scripts, using `@woocommerce/data` stores and the WooCommerce Store API.

---

## Overview: two contexts for data access

| Context | When it runs | Data access method |
|---------|-------------|-------------------|
| Block editor (`editorScript`) | WordPress admin, post/page editing | `@woocommerce/data` via `useSelect` |
| Frontend view (`viewScript`) | Site visitor-facing pages | WC Store API REST calls (`/wc/store/v1/`) |
| Server-side render (`render.php`) | PHP, on the server | `wc_get_products()`, `WC_Product` classes |

Do not use `@woocommerce/data` in viewScript — the Redux store is not initialized on the frontend. Use the REST API instead.

---

## Available WC data stores (WC 9.0+)

These stores are available via `@woocommerce/data` in the block editor context:

| Store key | Data | Common selectors |
|-----------|------|-----------------|
| `wc/store/products` | Products list and single products | `getProducts`, `getProduct` |
| `wc/store/product-categories` | Product categories | `getProductCategories` |
| `wc/store/orders` | Order data (admin only) | `getOrders`, `getOrder` |
| `wc/store/customers` | Customer data (admin only) | `getCustomers` |
| `wc/store/reports` | WC Analytics reports | `getReportItems`, `getReportStats` |
| `wc/store/settings` | WC settings groups | `getSetting` |
| `wc/store/plugins` | Plugin activation state | `isPluginActive` |
| `wc/store/onboarding` | Onboarding task state | `getTaskLists` |

For Cart/Checkout block extensions, `@woocommerce/blocks-checkout` provides its own in-page stores — do not confuse these with the admin `@woocommerce/data` stores.

---

## Reading product data in the block editor (editorScript)

### Basic product list with useSelect

```js
import { useSelect } from '@wordpress/data';
import { store as productsStore } from '@woocommerce/data';

const ProductList = ( { categoryId, limit = 10 } ) => {
    const { products, isLoading } = useSelect(
        ( select ) => {
            const store = select( productsStore );
            const query = {
                per_page: limit,
                status: 'publish',
                ...(categoryId ? { category: categoryId } : {}),
            };
            return {
                products: store.getProducts( query ),
                isLoading: ! store.hasFinishedResolution( 'getProducts', [ query ] ),
            };
        },
        [ categoryId, limit ]
    );

    if ( isLoading ) {
        return <p>Loading products...</p>;
    }

    if ( ! products || products.length === 0 ) {
        return <p>No products found.</p>;
    }

    return (
        <ul>
            { products.map( ( product ) => (
                <li key={ product.id }>
                    { product.name } — { product.price_html }
                </li>
            ) ) }
        </ul>
    );
};
```

### Fetching a single product by ID

```js
import { useSelect } from '@wordpress/data';
import { store as productsStore } from '@woocommerce/data';

const SingleProduct = ( { productId } ) => {
    const { product, isLoading } = useSelect(
        ( select ) => {
            const store = select( productsStore );
            return {
                product: store.getProduct( productId ),
                isLoading: ! store.hasFinishedResolution( 'getProduct', [ productId ] ),
            };
        },
        [ productId ]
    );

    if ( isLoading ) return <p>Loading...</p>;
    if ( ! product ) return <p>Product not found.</p>;

    return <h2>{ product.name }</h2>;
};
```

### Using product categories

```js
import { useSelect } from '@wordpress/data';
import { store as productCategoriesStore } from '@woocommerce/data';

const CategorySelector = ( { onSelect } ) => {
    const { categories, isLoading } = useSelect( ( select ) => {
        const store = select( productCategoriesStore );
        return {
            categories: store.getProductCategories( { per_page: 100 } ),
            isLoading: ! store.hasFinishedResolution( 'getProductCategories', [ { per_page: 100 } ] ),
        };
    }, [] );

    if ( isLoading ) return null;

    return (
        <select onChange={ ( e ) => onSelect( parseInt( e.target.value ) ) }>
            <option value="">All categories</option>
            { categories?.map( ( cat ) => (
                <option key={ cat.id } value={ cat.id }>
                    { cat.name }
                </option>
            ) ) }
        </select>
    );
};
```

---

## Accessing WC data in render.php (server-side)

For dynamic blocks, use WC PHP functions in `render.php`. This runs on every page load — use transients or WP object cache for expensive queries:

```php
<?php
/**
 * Block render callback.
 *
 * @param array    $attributes Block attributes.
 * @param string   $content    Inner block content.
 * @param WP_Block $block      Block instance.
 */

$number_of_products = isset( $attributes['numberOfProducts'] ) ? (int) $attributes['numberOfProducts'] : 4;
$category_ids       = isset( $attributes['categoryIds'] ) ? array_map( 'intval', $attributes['categoryIds'] ) : [];

$products = wc_get_products(
    [
        'status'   => 'publish',
        'limit'    => $number_of_products,
        'category' => $category_ids,
        'orderby'  => 'date',
        'order'    => 'DESC',
    ]
);

if ( empty( $products ) ) {
    return '';
}

$wrapper_attributes = get_block_wrapper_attributes( [ 'class' => 'my-plugin-product-list' ] );
?>
<ul <?php echo $wrapper_attributes; // phpcs:ignore WordPress.Security.EscapeOutput.OutputNotEscaped ?>>
    <?php foreach ( $products as $product ) : ?>
        <li class="product-item">
            <a href="<?php echo esc_url( $product->get_permalink() ); ?>">
                <?php echo wp_kses_post( $product->get_image( 'thumbnail' ) ); ?>
                <span class="product-name"><?php echo esc_html( $product->get_name() ); ?></span>
                <span class="product-price"><?php echo wp_kses_post( $product->get_price_html() ); ?></span>
            </a>
        </li>
    <?php endforeach; ?>
</ul>
```

---

## Accessing cart data in viewScript (frontend)

The Redux data stores from `@woocommerce/data` are NOT available on the frontend. Use the WC Store API REST endpoint directly.

### Fetching cart with the Store API

```js
// src/blocks/my-block/view.js (viewScript)

/**
 * Load cart data from the WooCommerce Store API.
 * The wcSettings global is provided by WooCommerce when blocks are present.
 *
 * @return {Promise<Object>} Cart data object.
 */
async function loadCartData() {
    const nonce = window.wcSettings?.storeApiNonce ?? '';

    const response = await fetch( '/wp-json/wc/store/v1/cart', {
        credentials: 'include',
        headers: {
            'Content-Type': 'application/json',
            'X-WC-Store-API-Nonce': nonce,
        },
    } );

    if ( ! response.ok ) {
        throw new Error( `Store API error: ${ response.status }` );
    }

    return response.json();
}

// Usage: display cart item count on page load
document.addEventListener( 'DOMContentLoaded', async () => {
    const counterEl = document.querySelector( '.my-cart-counter' );
    if ( ! counterEl ) return;

    try {
        const cart = await loadCartData();
        counterEl.textContent = cart.items_count;
    } catch ( err ) {
        // Graceful degradation — do not expose errors to the frontend
        console.error( 'Could not load cart data.', err );
    }
} );
```

### Store API endpoints reference

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/wc/store/v1/cart` | GET | Full cart contents, totals, items |
| `/wc/store/v1/cart/items` | GET | Cart items only |
| `/wc/store/v1/cart/add-item` | POST | Add item to cart |
| `/wc/store/v1/products` | GET | Published products |
| `/wc/store/v1/products/{id}` | GET | Single product |
| `/wc/store/v1/products/categories` | GET | Product categories |
| `/wc/store/v1/checkout` | POST | Place order (requires authentication) |

---

## Passing PHP data to JS via IntegrationInterface

For data that cannot come from a REST API (plugin settings, feature flags, server-computed values), pass it from PHP to JS using `wp_add_inline_script` inside `IntegrationInterface::initialize()`.

### PHP side

```php
public function initialize(): void {
    $asset_file = plugin_dir_path( __FILE__ ) . 'build/checkout-integration.asset.php';
    $asset      = file_exists( $asset_file ) ? require $asset_file : [ 'dependencies' => [], 'version' => '1.0.0' ];

    wp_register_script(
        'my-plugin-checkout-integration',
        plugins_url( 'build/checkout-integration.js', __FILE__ ),
        $asset['dependencies'],
        $asset['version'],
        true
    );

    // Pass server-side data to JS before the script runs.
    wp_add_inline_script(
        'my-plugin-checkout-integration',
        'const myPluginData = ' . wp_json_encode(
            [
                'apiUrl'      => rest_url( 'my-plugin/v1/' ),
                'nonce'       => wp_create_nonce( 'wp_rest' ),
                'enabled'     => (bool) get_option( 'my_plugin_enabled', true ),
                'maxQuantity' => (int) get_option( 'my_plugin_max_quantity', 10 ),
            ]
        ),
        'before'
    );
}
```

### JS side

```js
// src/checkout/index.js
// myPluginData is injected by wp_add_inline_script before this script runs

const { apiUrl, nonce, enabled, maxQuantity } = window.myPluginData ?? {};

if ( enabled ) {
    // Use apiUrl and nonce for authenticated REST calls
    async function fetchCustomData() {
        const response = await fetch( `${ apiUrl }custom-endpoint`, {
            headers: {
                'X-WP-Nonce': nonce,
                'Content-Type': 'application/json',
            },
        } );
        return response.json();
    }
}
```

---

## Using wcSettings for WooCommerce settings

WooCommerce exposes a subset of settings via the `wcSettings` global (mapped to `@woocommerce/settings`):

```js
import { getSetting } from '@woocommerce/settings';

// Reading WC settings in the block editor
const currencyCode     = getSetting( 'currency' );        // 'USD'
const currencySymbol   = getSetting( 'currencySymbol' );  // '$'
const weightUnit       = getSetting( 'weightUnit' );      // 'kg'
const storePages       = getSetting( 'storePages', {} );  // Object with checkout/cart page URLs
const shippingEnabled  = getSetting( 'shippingEnabled' ); // boolean
```

In viewScript / plain JS (no module imports), read `window.wcSettings` directly:

```js
const currency = window.wcSettings?.currency ?? 'USD';
const storeApiNonce = window.wcSettings?.storeApiNonce ?? '';
```

---

## Common data access mistakes

**Mistake: Using @woocommerce/data in viewScript**

```js
// WRONG — @woocommerce/data store is not available on the frontend
import { useSelect } from '@wordpress/data';
import { store as productsStore } from '@woocommerce/data';
// This will throw: "store 'wc/store/products' is not registered"
```

Use the Store API REST endpoint instead (see "Accessing cart data in viewScript" above).

**Mistake: Missing nonce on Store API calls**

Without the `X-WC-Store-API-Nonce` header, POST requests to the Store API fail with 401. Always read the nonce from `window.wcSettings.storeApiNonce`.

**Mistake: Using /wc/v3/ instead of /wc/store/v1/ on the frontend**

The `/wc/v3/` REST API requires authentication (WooCommerce API key or cookie auth). For unauthenticated frontend use, always use `/wc/store/v1/`.

**Mistake: Calling hasFinishedResolution with wrong argument format**

```js
// WRONG — arguments must match the selector's parameter signature exactly
isLoading: store.hasFinishedResolution( 'getProducts', { per_page: 10 } ),

// CORRECT — second argument is an array of the selector's arguments
isLoading: ! store.hasFinishedResolution( 'getProducts', [ { per_page: 10 } ] ),
```
