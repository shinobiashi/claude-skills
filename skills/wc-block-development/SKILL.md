---
name: wc-block-development
version: "1.0.0"
description: "Use when developing WooCommerce-specific Gutenberg blocks: frontend blocks using WC data stores, checkout/cart block extensions (registerCheckoutFilters, Slot/Fill, IntegrationInterface), and Store API schema extensions (ExtendSchema). NOTE: WooCommerce Product Editor blocks (@woocommerce/product-editor) are retired — deprecated in WC 10.9, removed from core in WC 11.0 (2026-07-28); do not build new work on them. Complements wp-block-development which covers general block fundamentals."
compatibility: "Targets WooCommerce 9.0+, WordPress 6.6+ (current stable: WC 11.1.0, WP 7.1; verified 2026-09-09), @woocommerce/dependency-extraction-webpack-plugin 3.x+ (latest 5.1.0). Requires Composer and Node.js."
---

# WooCommerce Block Development

## When to use

Use this skill when:

- Building a custom block that reads WC product/cart/order data on the frontend
- Adding a custom field, section, or UI to the WooCommerce Cart or Checkout blocks
- Extending the WooCommerce Store API to pass custom data to blocks
- Maintaining **existing** WooCommerce Product Editor blocks (retired: deprecated WC 10.9, removed core WC 11.0 — do not start new work here)
- Setting up `@woocommerce/dependency-extraction-webpack-plugin` in webpack.config.js
- Debugging why a WC block integration script is not loading

## Inputs required

- Which type of WC block (see `references/block-types-and-decisions.md`)
- WooCommerce version minimum requirement
- Whether checkout extensions need custom Store API data (PHP-side schema extension)

## Procedure

### 0) Identify the block type

Read `references/block-types-and-decisions.md` and pick the correct category before writing any code. The implementation differs substantially across types.

### 1) Set up webpack with WooCommerce dependency extraction

WooCommerce packages must be externalized via `@woocommerce/dependency-extraction-webpack-plugin`, which replaces the standard `@wordpress/dependency-extraction-webpack-plugin`. Without this, WC packages are bundled instead of loaded from the host WordPress/WooCommerce installation.

See: `references/webpack-setup.md`

### 2A) Frontend block using WC data

If building a block that displays WC data (products, cart, etc.):

- Use `@woocommerce/data` selectors in the block editor script
- Use WooCommerce Store API (`/wc/store/v1/`) for frontend (viewScript) data fetching
- Use `useSelect` with `wc/store/products`, `wc/store/cart` stores

See: `references/wc-data-stores.md`

### 2B) Checkout/Cart block extension

If extending the WooCommerce Checkout or Cart blocks:

- Implement `IntegrationInterface` on the PHP side to register scripts and pass data
- Use `registerCheckoutFilters` for modifying labels/classes
- Use Slot/Fill components (`ExperimentalOrderMeta`, etc.) for injecting UI
- Extend Store API schema with `ExtendSchema::instance()->register_endpoint_data()` for custom PHP data

Key references:
- `references/block-types-and-decisions.md` (checkout extension overview)
- `references/wc-data-stores.md` (passing PHP data via IntegrationInterface)

### 2C) Product Editor block

> **RETIRED — do not build new work here.** The block-based Product Editor and `@woocommerce/product-editor` were deprecated in WC 10.9 (2026-06-23) and **removed from core in WC 11.0 (2026-07-28)**. Stores revert to the classic product editor; no drop-in replacement ships with 11.0 (future product-management work will build on WordPress DataViews/DataForms, still experimental). Only use the guidance below to maintain or migrate off existing integrations before 11.0.

If maintaining existing blocks in the WooCommerce Product Editor:

- Register a block template using `BlockTemplateController`
- Use `@woocommerce/product-editor` components
- Connect to the product data via the WC REST API product schema

See: `references/block-types-and-decisions.md` (Path C section)

### 3) Register the block / integration in PHP

For **frontend blocks**: use standard `register_block_type()` pointing to `build/blocks/{name}/`.

For **checkout extensions**: use the `IntegrationInterface` pattern registered via `woocommerce_blocks_integration` action hook.

### 4) Build and verify

- `npm run build` — confirm no webpack errors
- Check `build/blocks/{name}/index.asset.php` lists correct WC package dependencies
- Activate plugin, open Cart/Checkout/Product Editor, verify script loads

### 5) Test

- Write PHPUnit tests for PHP integration classes
- Write Playwright E2E tests for checkout flows (see `wp-e2e-playwright` skill)

## Failure modes

- `@woocommerce/blocks-checkout` not found at runtime: `@woocommerce/dependency-extraction-webpack-plugin` not installed or misconfigured; check `build/index.asset.php` dependencies
- Integration script not loading on checkout: `IntegrationInterface::get_script_handles()` returns wrong handle; verify script is registered in `initialize()`
- `registerCheckoutFilters` has no effect: filter registered after store is initialized; move registration to the top level of the viewScript, not inside a React component
- Slot Fill component renders nothing: Slot name misspelled or WooCommerce version does not support it; check WC version requirements
- Product Editor block not appearing: block template not registered for correct product type; verify `woocommerce_rest_product_object_type` and template area

## Escalation

- If the target WooCommerce version is below 8.9, the checkout extension APIs changed significantly; ask for the exact WC version before writing code.
- The `@experimental*` prefix on some Slot Fill components means the API can change; verify against the installed WC version.
