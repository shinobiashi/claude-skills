# Build configuration

## webpack (`@wordpress/scripts`)

```js
// webpack.config.js
const defaultConfig = require( '@wordpress/scripts/config/webpack.config' );
const WooCommerceDependencyExtractionWebpackPlugin = require( '@woocommerce/dependency-extraction-webpack-plugin' );
const webpack = require( 'webpack' );
const path = require( 'path' );

const BUNDLE_LOCALLY = [ '@woocommerce/email-editor', '@wordpress/ui', '@wordpress/global-styles-engine' ];

module.exports = {
	...defaultConfig,
	entry: {
		'editor/index': path.resolve( 'assets/src/editor/index.js' ),
		'editor/style': path.resolve( 'assets/src/editor/style.scss' ), // imports the package styles → emits editor/style.css + style.asset.php
		'admin/index':  path.resolve( 'assets/src/admin/index.js' ),
	},
	output: { ...defaultConfig.output, path: path.resolve( 'assets/build' ) },
	plugins: [
		...defaultConfig.plugins.filter( ( p ) => p.constructor.name !== 'DependencyExtractionWebpackPlugin' ),
		new WooCommerceDependencyExtractionWebpackPlugin( {
			requestToExternal( request ) {
				if ( BUNDLE_LOCALLY.some( ( pkg ) => request === pkg || request.startsWith( pkg + '/' ) ) ) {
					return undefined; // bundle it
				}
				return undefined; // fall through to default mapping for everything else
			},
		} ),
		new webpack.DefinePlugin( {
			__i18n_text_domain__: JSON.stringify( 'my-plugin' ),
		} ),
	],
};
```

Notes:

- Returning `undefined` from `requestToExternal` defers to the plugin's default list, which
  externalizes `@wordpress/*` to `wp.*` and `@woocommerce/*` to `wc.*`. The three packages
  above must **not** be externalized: `@wordpress/ui` and `@wordpress/global-styles-engine` are
  not shipped by WordPress as scripts, and `@woocommerce/email-editor` is not a `wc.*` global.
  Verify with `grep -o '"[^"]*"' assets/build/editor/index.asset.php` that none of the three
  appears in the dependencies list.
- `style.scss` entry: `@import '~@woocommerce/email-editor/build-style/style.css';` (confirm
  the path that exists in the pinned npm release; if the npm package does not ship built CSS,
  build it from the package's `src/style.scss` the same way its `webpack.config.js` does).
- `make-pot` extracts the editor's strings from the built bundle under your domain because of
  `DefinePlugin`; run it after `npm run build`.

## Composer + Strauss

```json
{
  "require": { "woocommerce/email-editor": "2.18.0" },
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
        "~^Automattic\\\\WooCommerce\\\\EmailEditor(Vendor)?\\\\~": "My\\Plugin\\Vendor\\Automattic\\WooCommerce\\EmailEditor$1\\"
      },
      "delete_vendor_packages": true
    }
  },
  "scripts": { "post-install-cmd": [ "@strauss" ], "post-update-cmd": [ "@strauss" ], "strauss": "vendor/bin/strauss" }
}
```

After `composer strauss`, assert nothing unprefixed remains:

```bash
grep -rl "namespace Automattic\\\\WooCommerce\\\\EmailEditor" vendor-prefixed/ && echo "UNPREFIXED" || echo "ok"
```

The package's `vendor-prefixed/` already contains Mozart-prefixed Emogrifier
(`Automattic\WooCommerce\EmailEditorVendor\Pelago\…`) plus a `classes/symfony` classmap with
`EmailEditorVendor_` prefix; Strauss must rewrite those too (hence the `(Vendor)?` pattern and
the classmap entry), or two copies of Emogrifier with the same FQCN exist when WooCommerce
core's editor is active.
