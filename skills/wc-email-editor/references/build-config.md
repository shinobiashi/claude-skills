# Build configuration

## webpack (`@wordpress/scripts`)

```js
// webpack.config.js
const fs = require( 'fs' );
const path = require( 'path' );
const webpack = require( 'webpack' );
const defaultConfig = require( '@wordpress/scripts/config/webpack.config' );
const WooCommerceDependencyExtractionWebpackPlugin = require( '@woocommerce/dependency-extraction-webpack-plugin' );

const BUNDLE_LOCALLY = [ '@woocommerce/email-editor', '@wordpress/ui', '@wordpress/global-styles-engine' ];
const isBundled = ( request ) => BUNDLE_LOCALLY.some( ( pkg ) => request === pkg || request.startsWith( `${ pkg }/` ) );

// Only if you must not send through wp_mail() (SKILL.md §3): the package's "Send a test email"
// (Preview menu item + modal) has no setting, so its component is swapped for a stub. Fail the
// build when an update moves the file, instead of silently shipping the item again.
const SEND_PREVIEW = path.resolve( __dirname, 'node_modules/@woocommerce/email-editor/build-module/components/preview/send-preview.js' );
if ( ! fs.existsSync( SEND_PREVIEW ) ) {
	throw new Error( `${ SEND_PREVIEW } is missing: point the SendPreview replacement at its new path.` );
}

module.exports = {
	...defaultConfig,
	entry: {
		'editor/index': path.resolve( __dirname, 'assets/src/editor/index.js' ),
		'editor/style': path.resolve( __dirname, 'assets/src/editor/editor.scss' ), // NOT style.scss, see below
		'admin/index':  path.resolve( __dirname, 'assets/src/admin/index.js' ),
	},
	output: { ...defaultConfig.output, path: path.resolve( __dirname, 'assets/build' ) },
	plugins: [
		...defaultConfig.plugins.filter( ( p ) => p.constructor.name !== 'DependencyExtractionWebpackPlugin' ),
		new WooCommerceDependencyExtractionWebpackPlugin( {
			// false = keep out of the externals (bundle it); undefined = default mapping (wp.* / wc.*).
			requestToExternal: ( request ) => ( isBundled( request ) ? false : undefined ),
			requestToHandle: ( request ) => ( isBundled( request ) ? false : undefined ),
		} ),
		new webpack.NormalModuleReplacementPlugin(
			/@woocommerce[\\/]email-editor[\\/]build(-module)?[\\/]components[\\/]preview[\\/]send-preview\.js$/,
			path.resolve( __dirname, 'assets/src/editor/send-preview.js' ) // export function SendPreview() { return null; }
		),
		new webpack.DefinePlugin( {
			__i18n_text_domain__: JSON.stringify( 'my-plugin' ),
		} ),
	],
};
```

Notes:

- `requestToExternal` / `requestToHandle` must return **`false`** for the three packages:
  `undefined` defers to the plugin's default list, which externalizes `@wordpress/*` to `wp.*`
  and `@woocommerce/*` to `wc.*`. `@wordpress/ui` and `@wordpress/global-styles-engine` are not
  shipped by WordPress as scripts, and `@woocommerce/email-editor` is not a `wc.*` global.
  Verify with `grep -o '"[^"]*"' assets/build/editor/index.asset.php` that none of the three
  appears in the dependencies list.
- Style entry: `@import '../../../node_modules/@woocommerce/email-editor/build-style/style.css';`
  by relative path (the package's `exports` maps only `.`, so `~@woocommerce/email-editor/…`
  does not resolve). Do not name the source `style.scss`: `@wordpress/scripts` splits any
  `style.*` source into a separate `style-<entry>` chunk, and `Assets_Manager` loads exactly
  `style.css` + `style.asset.php` from the directory given to `set_assets_path()`.
- The `SendPreview` swap is also applied when WooCommerce's copy is the live one: on your post
  type's screen the host's `Assets_Manager` loads your bundle. An E2E test must open the Preview
  menu and check the item is absent.
- `wp_set_script_translations()` adds `wp-i18n` to the script's dependencies.

## i18n (`make-pot`)

The editor's strings run under your domain because of `DefinePlugin`, but they live in the
built bundle, which the usual `make-pot` excludes with the rest of the build directory. Add a
second pass that reads only the editor bundle and merges into the same POT (after
`npm run build`):

```bash
wp i18n make-pot . languages/my-plugin.pot --domain=my-plugin --exclude=vendor,vendor-prefixed,node_modules,assets/build,tests
wp i18n make-pot . languages/my-plugin.pot --domain=my-plugin --include=assets/build/editor/index.js --merge=languages/my-plugin.pot
```

`--include` beats `--exclude=assets/build`; `--merge` reads the existing POT first. About 115
strings with the test send removed (the package hardcodes three under `woocommerce`).

## Composer + Strauss

```json
{
  "require": { "woocommerce/email-editor": "~2.19.0" },
  "extra": {
    "strauss": {
      "target_directory": "vendor-prefixed",
      "namespace_prefix": "My\\Plugin\\Vendor\\",
      "classmap_prefix": "MyPlugin_",
      "packages": [ "woocommerce/email-editor" ],
      "override_autoload": {
        "woocommerce/email-editor": { "classmap": [ "src/", "vendor-prefixed/" ] }
      },
      "namespace_replacement_patterns": {
        "~^Automattic\\\\WooCommerce\\\\EmailEditor(Vendor)?\\\\~": "My\\\\Plugin\\\\Vendor\\\\Automattic\\\\WooCommerce\\\\EmailEditor$1\\\\"
      },
      "delete_vendor_packages": true
    }
  },
  "scripts": {
    "post-install-cmd": [ "@strauss" ],
    "post-update-cmd": [ "@strauss" ],
    "strauss": [ "test ! -x vendor/bin/strauss || strauss", "@composer dump-autoload" ]
  }
}
```

Pin the exact version in `composer.lock` (`~2.19.0` allows patch releases only). The
`dump-autoload` after Strauss drops the deleted original package from Composer's classmap; the
`test` guard lets a `--no-dev` install (no Strauss) get through the script.

After `composer strauss`, assert nothing unprefixed remains:

```bash
grep -rl "namespace Automattic\\\\WooCommerce\\\\EmailEditor" vendor-prefixed/ && echo "UNPREFIXED" || echo "ok"
```

The package's `vendor-prefixed/` already contains Mozart-prefixed Emogrifier
(`Automattic\WooCommerce\EmailEditorVendor\Pelago\…`) plus a `classes/symfony` classmap with
`EmailEditorVendor_` prefix; Strauss must rewrite those too (hence the `(Vendor)?` pattern and
the classmap entry), or two copies of Emogrifier with the same FQCN exist when WooCommerce
core's editor is active. A dev install also gets Strauss' `vendor/composer/autoload_aliases.php`;
make sure Composer never loads it (it would map the original names to your prefixed classes and
hide a leak in tests) and never ship it.

## Release zip

`composer install --no-dev` reinstalls the unprefixed package into `vendor/` (it is a
`require`; Strauss is a dev package and does not run). In the zip script, after the `--no-dev`
install:

1. Require `vendor-prefixed/woocommerce/email-editor/` and compare its `composer.json` version
   with the one `composer.lock` locks (after a lock update followed by a `--no-dev` install
   alone, `vendor-prefixed/` still holds the previous version).
2. Remove `vendor/woocommerce/email-editor/` and run `composer dump-autoload --no-dev --optimize`.
3. Refuse the stage if it contains `vendor/woocommerce/email-editor/`,
   `vendor/composer/autoload_aliases.php`, or `vendor/composer/autoload_classmap.php` /
   `autoload_static.php` entries starting with `'Automattic\\WooCommerce\\EmailEditor` or
   `'EmailEditorVendor_`, or if `vendor-prefixed/woocommerce/email-editor/` is missing.
