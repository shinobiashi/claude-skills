# Block JSON Translations

## Overview

WordPress blocks (Gutenberg) use JavaScript for their editor UI. Translatable JS strings require:

1. A `.po` file compiled into `.json` files via `wp i18n make-json`
2. `wp_set_script_translations()` registered in PHP
3. `"textdomain"` declared in each `block.json`

---

## block.json: textdomain Field

Every block's `block.json` must include the `textdomain` field:

```json
{
  "apiVersion": 3,
  "name": "my-plugin/my-block",
  "title": "My Block",
  "description": "A custom block.",
  "textdomain": "my-plugin",
  "editorScript": "file:./index.js",
  "viewScript": "file:./view.js",
  "style": "file:./style.css",
  "editorStyle": "file:./editor.css"
}
```

Without `"textdomain"`, `wp i18n make-pot` will not extract strings from this block's `block.json` metadata (title, description, keywords).

---

## Generating JSON Translation Files

After obtaining `.po` files (from translators or translate.wordpress.org), run:

```bash
# Generate JSON from all .po files in languages/
wp i18n make-json languages/ --no-purge
```

### Output File Naming

The generated JSON files are named using a hash of the script path:

```
languages/my-plugin-ja-{md5-hash-of-relative-script-path}.json
```

Example output for `languages/my-plugin-ja.po`:
```
languages/my-plugin-ja-a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4.json
```

### --no-purge Flag

By default, `make-json` removes strings from the `.po` file that were moved to JSON. Use `--no-purge` to keep the `.po` files intact:

```bash
wp i18n make-json languages/ --no-purge
```

### Targeting Specific Scripts

```bash
# Only generate JSON for a specific script file
wp i18n make-json languages/ --no-purge --use-map=build/index.js
```

---

## PHP: Registering wp_set_script_translations

### For Blocks Registered via block.json

```php
function my_plugin_register_blocks() {
    $blocks = register_block_type_from_metadata( __DIR__ . '/build' );

    // Set script translations for the editor script
    if ( $blocks ) {
        wp_set_script_translations(
            'my-plugin-my-block-editor-script', // handle from block.json editorScript
            'my-plugin',
            plugin_dir_path( __FILE__ ) . 'languages'
        );
    }
}
add_action( 'init', 'my_plugin_register_blocks' );
```

### Resolving the Script Handle

The script handle is automatically generated from the block name and the script field:

- Block: `my-plugin/my-block`
- `editorScript`: `file:./index.js`
- Generated handle: `my-plugin-my-block-editor-script`

Pattern: `{namespace}-{block-slug}-{script-field-without-file-prefix}-script`

### Multiple Blocks

```php
function my_plugin_register_blocks() {
    // Register all blocks from the build directory
    $block_json_files = glob( plugin_dir_path( __FILE__ ) . 'build/*/block.json' );

    foreach ( $block_json_files as $block_json_file ) {
        $block_dir    = dirname( $block_json_file );
        $block_config = json_decode( file_get_contents( $block_json_file ), true );
        $block_name   = str_replace( '/', '-', $block_config['name'] );

        register_block_type( $block_dir );

        // Register translations for editor script
        wp_set_script_translations(
            $block_name . '-editor-script',
            'my-plugin',
            plugin_dir_path( __FILE__ ) . 'languages'
        );
    }
}
add_action( 'init', 'my_plugin_register_blocks' );
```

---

## JavaScript: Using @wordpress/i18n

In your block's JS source, import translation functions from `@wordpress/i18n`:

```js
import { __, _n, _x, sprintf } from '@wordpress/i18n';

// Basic translation
const label = __( 'Save changes', 'my-plugin' );

// Plural
const message = sprintf(
    _n( '%d item selected', '%d items selected', count, 'my-plugin' ),
    count
);

// With context
const title = _x( 'Add', 'button label', 'my-plugin' );

// In JSX
export default function Edit() {
    return (
        <div>
            <p>{ __( 'Block settings', 'my-plugin' ) }</p>
        </div>
    );
}
```

---

## Verifying Block Translations Work

1. Enable a non-English locale in WordPress (Settings > General > Site Language)
2. Place a compiled `.json` file in the `languages/` directory
3. Ensure `wp_set_script_translations` is registered for the script handle
4. Open the block editor and confirm the strings are translated

### Debug Script Translation Loading

```php
// Temporarily add to functions.php or plugin file
add_action( 'admin_enqueue_scripts', function() {
    global $wp_scripts;
    foreach ( $wp_scripts->registered as $handle => $script ) {
        if ( isset( $script->translations ) ) {
            error_log( "Script with translations: $handle" );
            error_log( print_r( $script->translations, true ) );
        }
    }
} );
```

---

## Common Issues

### JSON Files Not Loaded

- Confirm the language directory path passed to `wp_set_script_translations` is correct
- Confirm the `.json` filename matches the hash WP expects — use `wp i18n make-json` to regenerate

### Strings Appear in English Despite Translation

- Check the script handle in `wp_set_script_translations` matches the registered script handle exactly
- Run `wp i18n make-json` again after any changes to the `.po` file

### make-json Generates Empty Files

- Confirm `.po` files contain strings with `#: build/index.js` source references
- Ensure `make-pot` was run after the build step so JS source locations are recorded
