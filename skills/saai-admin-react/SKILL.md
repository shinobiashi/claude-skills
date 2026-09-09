---
name: saai-admin-react
description: >
  Use when building or extending a WordPress / WooCommerce admin page in React the SAAI way:
  a single-page, multi-tab settings UI under the WooCommerce menu (or the SAAI top-level menu),
  built with @wordpress/scripts and @woocommerce/dependency-extraction-webpack-plugin, using
  @wordpress/components (TabPanel, Card, Notice, Spinner, Button), @wordpress/api-fetch with the
  REST nonce middleware against a plugin REST namespace, optional @wordpress/data store, tab
  selection via query parameter, and PHP-side registration (menu, asset.php enqueue,
  wp_set_script_translations, inline bootstrap data). Trigger on "管理画面", "settings page",
  "React admin", "TabPanel", "WooCommerce > (plugin) page", or when ARCHITECTURE says to follow
  the existing SAAI admin pattern. Reference implementations: saai-ti4t
  (src/saai/admin/, includes/saai_framework/class-saai-admin-page.php) and
  Japanized-for-WooCommerce (src/js/jp4wc/admin/settings/).
compatibility: >
  WordPress 7.1 / WooCommerce 11.1 (verified 2026-09-09), @wordpress/scripts 34.x,
  @woocommerce/dependency-extraction-webpack-plugin 5.x, PHP 8.3. Admin-only; no Interactivity
  API, no external UI libraries.
---

# saai-admin-react

One React app per admin page, mounted into a single `<div id="{slug}-root">`, talking to the
plugin's own REST namespace. Tabs are `TabPanel` from `@wordpress/components`; nothing else is
used for layout so the page inherits WordPress admin styling and accessibility.

## Procedure

### 1) Decide where the page lives

| Placement | Menu call | Capability | Screen ID for enqueue |
|---|---|---|---|
| Under WooCommerce (default for WC extensions) | `add_submenu_page( 'woocommerce', ... )` | `manage_woocommerce` | `woocommerce_page_{slug}` |
| SAAI top-level (shared framework) | `SAAI\Admin\SAAI_Admin_Page` (`add_menu_page`, slug `saai-overview`) | `manage_options` | `toplevel_page_saai-overview` |

Tabs are switched with the `tab` query parameter (`?page={slug}&tab=settings`). Do not add
`@wordpress/router` or React Router.

### 2) PHP: menu, container, assets

```php
final class Menu {
    public const SLUG = 'spw-admin';
    public function register(): void {
        add_action( 'admin_menu', function () {
            add_submenu_page( 'woocommerce', __( 'Points', 'text-domain' ), __( 'Points', 'text-domain' ),
                'manage_woocommerce', self::SLUG, [ $this, 'render' ] );
        } );
        add_filter( 'admin_body_class', [ $this, 'body_class' ] );
    }
    public function render(): void { echo '<div class="wrap"><div id="' . esc_attr( self::SLUG ) . '-root"></div></div>'; }
    public function body_class( string $classes ): string {
        $screen = get_current_screen();
        return $screen && 'woocommerce_page_' . self::SLUG === $screen->id ? $classes . ' saai-admin-page' : $classes;
    }
}

final class Assets {
    public function register(): void { add_action( 'admin_enqueue_scripts', [ $this, 'enqueue' ] ); }
    public function enqueue(): void {
        $screen = get_current_screen();
        if ( ! $screen || 'woocommerce_page_' . Menu::SLUG !== $screen->id ) { return; }
        $asset = require PLUGIN_DIR . 'assets/build/admin.asset.php'; // ['dependencies' => [...], 'version' => '...']
        wp_enqueue_script( 'spw-admin', PLUGIN_URL . 'assets/build/admin.js', $asset['dependencies'], $asset['version'], true );
        wp_enqueue_style( 'spw-admin', PLUGIN_URL . 'assets/build/admin.css', [ 'wp-components' ], $asset['version'] );
        wp_set_script_translations( 'spw-admin', 'text-domain', PLUGIN_DIR . 'languages' );
        wp_add_inline_script( 'spw-admin', 'window.spwAdmin = ' . wp_json_encode( [
            'restRoot'  => esc_url_raw( rest_url() ),
            'nonce'     => wp_create_nonce( 'wp_rest' ),
            'namespace' => 'wc-points-wallet/v1',
            'tab'       => sanitize_key( $_GET['tab'] ?? 'settings' ), // phpcs:ignore WordPress.Security.NonceVerification.Recommended
            'currency'  => [ 'symbol' => get_woocommerce_currency_symbol(), 'decimals' => wc_get_price_decimals() ],
            'version'   => PLUGIN_VERSION,
        ] ) . ';', 'before' );
    }
}
```

- Read dependencies and version from the generated `*.asset.php`; never hard-code handles.
- Pass bootstrap data with `wp_add_inline_script` + `wp_json_encode` (keeps types).
  `wp_localize_script` casts scalars to strings; use it only for legacy code.
- Style dependency `wp-components` ensures the components CSS is present.

### 3) REST endpoints for the page

- Namespace per plugin (`{slug}/v1`, or `wc-{slug}/v1` when WooCommerce API-key auth is wanted).
- `permission_callback` → `current_user_can( 'manage_woocommerce' )`. Never `__return_true` for
  settings.
- Provide `get_item_schema()`; validate and sanitize with `rest_validate_value_from_schema()` /
  `rest_sanitize_value_from_schema()`.
- Return `{ settings, settings_version }` and reject a PUT whose `settings_version` is stale
  with HTTP 409 (optimistic locking across two admins).
- Log setting changes through `wc_get_logger()` with a plugin `source`.

### 4) JS: entry, App, tabs

```tsx
// client/admin/index.tsx
import { createRoot } from '@wordpress/element';
import apiFetch from '@wordpress/api-fetch';
import App from './App';
import './style.scss';

const boot = window.spwAdmin;
apiFetch.use( apiFetch.createRootURLMiddleware( boot.restRoot ) );
apiFetch.use( apiFetch.createNonceMiddleware( boot.nonce ) );

const el = document.getElementById( 'spw-admin-root' );
if ( el ) { createRoot( el ).render( <App initialTab={ boot.tab } /> ); }
```

```tsx
// client/admin/App.tsx
import { __ } from '@wordpress/i18n';
import { TabPanel } from '@wordpress/components';

const TABS = [
    { name: 'settings',  title: __( 'Settings', 'text-domain' ) },
    { name: 'customers', title: __( 'Customers', 'text-domain' ) },
];

export default function App( { initialTab }: { initialTab: string } ) {
    const onSelect = ( name: string ) => {
        const url = new URL( window.location.href );
        url.searchParams.set( 'tab', name );
        window.history.replaceState( {}, '', url );
    };
    return (
        <div className="spw-admin">
            <h1>{ __( 'Points Wallet', 'text-domain' ) }</h1>
            <TabPanel className="spw-admin__tabs" activeClass="is-active" tabs={ TABS }
                initialTabName={ TABS.some( ( t ) => t.name === initialTab ) ? initialTab : TABS[ 0 ].name }
                onSelect={ onSelect }>
                { ( tab ) => ( tab.name === 'settings' ? <SettingsTab /> : <CustomersTab /> ) }
            </TabPanel>
        </div>
    );
}
```

Tab component pattern (from saai-ti4t `SettingsTab.js`):

- `useState` for `settings`, `saving`, `notice`; `useEffect` loads via `apiFetch( { path } )`.
- Render `Spinner` while loading, `Notice` (status `success` / `error`, `isDismissible`) for
  results, `Card` / `CardHeader` / `CardBody` for groups, `Button variant="primary" isBusy`
  for save. Pass `__nextHasNoMarginBottom` and `__next40pxDefaultSize` to controls to avoid
  deprecation warnings under `SCRIPT_DEBUG`.
- `TabPanel` unmounts inactive tabs. State that must survive tab switches (loaded settings,
  dirty flag, list filters) lives in `App` or in a `@wordpress/data` store.
- Use a `@wordpress/data` store (`createReduxStore` + `register`, resolvers calling `apiFetch`)
  once two or more tabs share data or you need caching / optimistic updates. A single settings
  tab does not need it.
- All strings through `@wordpress/i18n` (`__`, `_n`, `sprintf`); no string concatenation.
- Warn on unsaved changes with a `beforeunload` listener while the form is dirty.

### 5) Build

```js
// webpack.config.js
const defaultConfig = require( '@wordpress/scripts/config/webpack.config' );
const WooCommerceDependencyExtractionWebpackPlugin = require( '@woocommerce/dependency-extraction-webpack-plugin' );
const path = require( 'path' );

module.exports = {
    ...defaultConfig,
    entry: { admin: './client/admin/index.tsx' },
    output: { path: path.resolve( __dirname, 'assets/build' ), filename: '[name].js' },
    plugins: [
        ...defaultConfig.plugins.filter( ( p ) => p.constructor.name !== 'DependencyExtractionWebpackPlugin' ),
        new WooCommerceDependencyExtractionWebpackPlugin(),
    ],
};
```

- `npm run build` → `assets/build/admin.js`, `admin.css`, `admin.asset.php`.
- Exclude `client/` and `node_modules/` via `.distignore`; ship only `assets/build/`.
- `wp i18n make-json languages/ --no-purge` after `make-pot` so `wp_set_script_translations`
  finds JS translations.

### 6) Verify

- `assets/build/admin.asset.php` lists `wp-components`, `wp-element`, `wp-api-fetch`, `wp-i18n`
  (and `wc-*` handles when `@woocommerce/*` is imported).
- Page loads with `SCRIPT_DEBUG` on and no console errors or component deprecation warnings.
- Removing the nonce yields `403 rest_cookie_invalid_nonce`; a non-admin gets 403 from the
  permission callback.
- Keyboard-only navigation works across tabs and controls; every control has a label.
- Japanese translations render after switching the site language.

## Conventions

- CSS class prefix = plugin slug (`spw-admin__...`), scoped under `.saai-admin-page`.
- Only `@wordpress/components`; no Tailwind, MUI, or custom design systems.
- One entry per admin page; blocks and frontend scripts are separate entries.
- Keep PHP page classes thin: menu + assets + inline data. Business logic stays in services
  behind REST.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Script not loaded | Screen ID mismatch (`woocommerce_page_{slug}` vs `toplevel_page_{slug}`) | Log `get_current_screen()->id` and match it |
| REST 403 `rest_cookie_invalid_nonce` | Nonce middleware not registered or nonce not `wp_rest` | `createNonceMiddleware( wp_create_nonce( 'wp_rest' ) )` |
| `wc is not defined` at runtime | `@woocommerce/*` import without the WooCommerce extraction plugin | Use `WooCommerceDependencyExtractionWebpackPlugin` |
| Form resets when switching tabs | State inside the tab component | Lift to `App` or a data store |
| Numbers arrive as strings | `wp_localize_script` | `wp_add_inline_script` + `wp_json_encode` |
| Deprecation warnings from components | Missing `__next*` props | Add `__nextHasNoMarginBottom`, `__next40pxDefaultSize` |
