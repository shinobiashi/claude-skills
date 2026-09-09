# WooCommerce Block Webpack Setup

This reference covers webpack configuration for WooCommerce block development, specifically how and why to use `@woocommerce/dependency-extraction-webpack-plugin`.

---

## Why @woocommerce/dependency-extraction-webpack-plugin is required

WooCommerce loads its JavaScript packages as WordPress scripts via `wp_enqueue_script`. These packages are already available on the page as global `window.wc.*` objects when WooCommerce is active.

If you bundle `@woocommerce/data` or `@woocommerce/blocks-checkout` directly into your plugin's JS bundle:

- Your bundle contains a duplicate copy of WooCommerce's code
- Version conflicts can cause subtle runtime bugs
- Bundle size increases unnecessarily

The `@woocommerce/dependency-extraction-webpack-plugin` solves this by **externalizing** WC packages — your bundle references the already-loaded globals instead of including its own copy.

**Important:** This plugin REPLACES (not extends) `@wordpress/dependency-extraction-webpack-plugin`. You must remove the WordPress plugin when adding the WooCommerce one, because the WooCommerce plugin already handles both `@wordpress/*` and `@woocommerce/*` packages.

---

## Installation

```bash
npm install --save-dev @woocommerce/dependency-extraction-webpack-plugin
```

---

## Minimal webpack.config.js

The minimal configuration needed for any WooCommerce block project:

```js
const defaultConfig = require( '@wordpress/scripts/config/webpack.config' );
const WooCommerceDependencyExtractionWebpackPlugin = require( '@woocommerce/dependency-extraction-webpack-plugin' );

module.exports = {
    ...defaultConfig,
    plugins: [
        // Remove the default WordPress dependency extraction plugin
        ...defaultConfig.plugins.filter(
            ( plugin ) => plugin.constructor.name !== 'DependencyExtractionWebpackPlugin'
        ),
        // Replace with WooCommerce's version (handles both @wordpress/* and @woocommerce/*)
        new WooCommerceDependencyExtractionWebpackPlugin(),
    ],
};
```

---

## Complete webpack.config.js with multiple entry points

For plugins that have an admin page, a checkout integration script, AND blocks:

```js
const defaultConfig = require( '@wordpress/scripts/config/webpack.config' );
const WooCommerceDependencyExtractionWebpackPlugin = require( '@woocommerce/dependency-extraction-webpack-plugin' );
const path = require( 'path' );

module.exports = {
    ...defaultConfig,
    entry: {
        // Admin settings page
        admin: path.resolve( __dirname, 'src/admin/index.js' ),
        // Checkout/Cart block integration script (loaded by IntegrationInterface, not block.json)
        'checkout-integration': path.resolve( __dirname, 'src/checkout/index.js' ),
        // Blocks are auto-detected by wp-scripts from src/blocks/*/block.json
        // Add manual entries here only if the block is not in the default src/ location
    },
    plugins: [
        ...defaultConfig.plugins.filter(
            ( plugin ) => plugin.constructor.name !== 'DependencyExtractionWebpackPlugin'
        ),
        new WooCommerceDependencyExtractionWebpackPlugin(),
    ],
};
```

Note: `@wordpress/scripts` auto-detects blocks from `src/blocks/*/block.json` when you use the `--blocks-manifest` flag or the default `build` script. Manual entry points are only needed for non-block scripts.

---

## package.json configuration

```json
{
    "scripts": {
        "build": "wp-scripts build",
        "start": "wp-scripts start",
        "lint:js": "wp-scripts lint-js"
    },
    "devDependencies": {
        "@woocommerce/dependency-extraction-webpack-plugin": "^3.0.0",
        "@wordpress/scripts": "^32.0.0"
    },
    "dependencies": {
        "@woocommerce/blocks-checkout": "*",
        "@woocommerce/data": "*",
        "@woocommerce/product-editor": "*",
        "@wordpress/blocks": "*",
        "@wordpress/block-editor": "*",
        "@wordpress/components": "*",
        "@wordpress/data": "*",
        "@wordpress/element": "*",
        "@wordpress/i18n": "*"
    }
}
```

**Why `"*"` for runtime dependencies?**

All `@woocommerce/*` and `@wordpress/*` runtime packages are externalized — they come from WooCommerce/WordPress at runtime, not from `node_modules`. Using `"*"` avoids version lock-in and makes this explicit. Only devDependencies (build tools) need pinned versions.

---

## How to verify externalization worked

After `npm run build`, inspect the generated `*.asset.php` files in the `build/` directory.

**For a checkout integration script** (`build/checkout-integration.asset.php`):

```php
<?php
// Good: WC packages listed as dependencies (they are externalized)
return array(
    'dependencies' => array(
        'wc-blocks-checkout',     // @woocommerce/blocks-checkout
        'wc-settings',            // @woocommerce/settings
        'wp-element',             // @wordpress/element
        'wp-i18n',                // @wordpress/i18n
    ),
    'version' => 'abc123...',
);
```

**For a frontend block** (`build/blocks/my-block/index.asset.php`):

```php
<?php
return array(
    'dependencies' => array(
        'wc-data',         // @woocommerce/data
        'wp-blocks',       // @wordpress/blocks
        'wp-block-editor', // @wordpress/block-editor
        'wp-element',      // @wordpress/element
    ),
    'version' => 'abc123...',
);
```

**Red flag — externalization is broken** if `@woocommerce/data` does NOT appear in the dependencies array. This means the package was bundled instead of externalized. Check that:

1. `@woocommerce/dependency-extraction-webpack-plugin` is installed
2. The old `DependencyExtractionWebpackPlugin` from `@wordpress/scripts` is filtered out
3. Your import uses the exact package name (e.g., `@woocommerce/data`, not a path alias)

---

## Package-to-wp_enqueue_script handle mapping

The plugin generates these handle mappings automatically. Useful for manual `wp_enqueue_script` calls and debugging:

| npm package | wp_enqueue_script handle | Global variable |
|-------------|--------------------------|----------------|
| `@woocommerce/blocks-checkout` | `wc-blocks-checkout` | `window.wc.blocksCheckout` |
| `@woocommerce/blocks-registry` | `wc-blocks-registry` | `window.wc.wcBlocksRegistry` |
| `@woocommerce/data` | `wc-data` | `window.wc.wcData` |
| `@woocommerce/product-editor` | `wc-product-editor` | `window.wc.productEditor` |
| `@woocommerce/settings` | `wc-settings` | `window.wcSettings` |
| `@woocommerce/components` | `wc-components` | `window.wc.components` |
| `@wordpress/blocks` | `wp-blocks` | `window.wp.blocks` |
| `@wordpress/block-editor` | `wp-block-editor` | `window.wp.blockEditor` |
| `@wordpress/data` | `wp-data` | `window.wp.data` |
| `@wordpress/element` | `wp-element` | `window.wp.element` |
| `@wordpress/i18n` | `wp-i18n` | `window.wp.i18n` |

---

## PHP script registration using the asset file

Always use the generated `*.asset.php` file to register scripts. This ensures correct dependency ordering:

```php
$asset_file = plugin_dir_path( __FILE__ ) . 'build/checkout-integration.asset.php';

if ( file_exists( $asset_file ) ) {
    $asset = require $asset_file;

    wp_register_script(
        'my-plugin-checkout-integration',
        plugins_url( 'build/checkout-integration.js', __FILE__ ),
        $asset['dependencies'],
        $asset['version'],
        true
    );
}
```

This pattern is used inside `IntegrationInterface::initialize()` for checkout extensions, or inside the `init` action for frontend blocks.

---

## Common webpack errors and fixes

**Error: `Module not found: Error: Can't resolve '@woocommerce/data'`**

This means `@woocommerce/data` is not installed in `node_modules` AND not properly externalized. The plugin needs the package in node_modules to resolve the external mapping during the build step. Run:

```bash
npm install @woocommerce/data
```

Even though the package is externalized at runtime, webpack still needs it locally to resolve imports during compilation.

**Error: `DependencyExtractionWebpackPlugin is not a constructor`**

You may have accidentally imported the wrong plugin. Ensure your import is:

```js
const WooCommerceDependencyExtractionWebpackPlugin = require( '@woocommerce/dependency-extraction-webpack-plugin' );
```

Not the WordPress version:

```js
// WRONG for WooCommerce blocks:
const { DependencyExtractionWebpackPlugin } = require( '@wordpress/scripts' );
```

**Build succeeds but `wc-blocks-checkout` is missing from asset.php dependencies**

Verify that the import actually uses the package name, not a relative path:

```js
// Correct — will be externalized
import { registerCheckoutFilters } from '@woocommerce/blocks-checkout';

// Wrong — relative path bypasses externalization
import { registerCheckoutFilters } from '../../node_modules/@woocommerce/blocks-checkout/src/index';
```
