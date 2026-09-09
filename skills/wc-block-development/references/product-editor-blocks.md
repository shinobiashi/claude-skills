# WooCommerce Product Editor Blocks

> **⚠️ RETIRED — do not build new work on this.** The block-based Product Editor and the `@woocommerce/product-editor` package were **deprecated in WC 10.9 (2026-06-23)** and **removed from core in WC 11.0 (2026-07-28)**. Stores revert to the classic product editor; there is no drop-in replacement in 11.0 (future product-management work will build on WordPress **DataViews/DataForms**, still experimental). Everything below applies only to **maintaining or migrating off** existing integrations before 11.0. New product-admin UI should not import from `@woocommerce/product-editor` or register product-editor blocks.

Extending the WooCommerce block-based Product Editor. Applies to WooCommerce 8.6–10.9 (removed in 11.0).

---

## 1. Product Editor Structure

The Product Editor (enabled by default in WC 8.6+) is fully block-based. Its hierarchy:

```
Area        (e.g., product-form/header, product-form/general, product-form/pricing)
└── Section (e.g., product-form/general/details-section)
    └── Block (e.g., woocommerce/product-name, your custom block)
```

### Common Area IDs

| Area ID | Description |
|---|---|
| `product-form/header` | Top header area (product name, status) |
| `product-form/general` | General tab content |
| `product-form/pricing` | Pricing tab content |
| `product-form/inventory` | Inventory tab content |
| `product-form/shipping` | Shipping tab content |

---

## 2. Adding a Custom Block to the Product Editor

### Step 1: block.json — Declare Product Editor Support

```json
{
    "name": "my-plugin/product-custom-field",
    "title": "My Custom Field",
    "description": "A custom field for the product editor.",
    "category": "woocommerce",
    "keywords": ["product", "custom"],
    "supports": {
        "html": false,
        "multiple": false,
        "__experimentalToolbar": false
    },
    "$schema": "https://schemas.wp.org/trunk/block.json",
    "apiVersion": 3
}
```

### Step 2: edit.js — Use @woocommerce/product-editor Components

```js
import { useWooBlockProps } from '@woocommerce/block-editor';
import { useEntityProp } from '@wordpress/core-data';
import { TextControl } from '@wordpress/components';
import { __ } from '@wordpress/i18n';

export default function Edit( { attributes, context } ) {
    const { property } = attributes;
    const blockProps = useWooBlockProps( attributes );

    const [ metaValue, setMetaValue ] = useEntityProp(
        'postType',
        context.postType,
        'meta'
    );

    return (
        <div { ...blockProps }>
            <TextControl
                label={ __( 'Custom Field', 'my-plugin' ) }
                value={ metaValue?.my_custom_field ?? '' }
                onChange={ ( value ) => setMetaValue( {
                    ...metaValue,
                    my_custom_field: value,
                } ) }
            />
        </div>
    );
}
```

### Step 3: PHP — Register Block in the Product Editor Template

```php
use Automattic\WooCommerce\Admin\BlockTemplates\BlockTemplateInterface;

add_action(
    'woocommerce_block_template_area_product-form_after_instantiation',
    function( BlockTemplateInterface $template ) {
        // Find the "General" tab
        $general_group = $template->get_block( 'product-form/general' );
        if ( ! $general_group ) {
            return;
        }

        // Add after the existing blocks
        $general_group->add_block( [
            'id'         => 'my-plugin-custom-field',
            'blockName'  => 'my-plugin/product-custom-field',
            'order'      => 60,
            'attributes' => [
                'property' => 'meta_data',
            ],
        ] );
    }
);
```

---

## 3. Saving Product Data via the REST API

Register product meta for REST API exposure so `useEntityProp` can read and write it automatically.

```php
// Register product meta for REST API exposure
register_post_meta( 'product', 'my_custom_field', [
    'type'         => 'string',
    'single'       => true,
    'show_in_rest' => [
        'schema' => [
            'type'        => 'string',
            'description' => 'Custom field for the product.',
        ],
    ],
] );
```

`useEntityProp` on the JS side reads and writes via the WC REST API automatically. No custom save logic is required.

---

## 4. Controlling Visibility by Product Type

Show a block only for specific product types:

```js
import { useEntityProp } from '@wordpress/core-data';

export default function Edit( { context } ) {
    const [ productType ] = useEntityProp(
        'postType',
        'product',
        'type'
    );

    if ( productType !== 'simple' && productType !== 'variable' ) {
        return null; // Hide for other product types
    }

    // ... render the block
}
```

### Hiding via PHP Template Conditions

```php
$general_group->add_block( [
    'id'             => 'my-plugin-custom-field',
    'blockName'      => 'my-plugin/product-custom-field',
    'order'          => 60,
    'hideConditions' => [
        [
            'expression' => 'editedProduct.type === "external"',
        ],
    ],
] );
```

---

## 5. wp-env.json for Product Editor Testing

The Product Editor requires WC 8.6+ and specific configuration flags.

```json
{
    "plugins": [
        "https://downloads.wordpress.org/plugin/woocommerce.zip",
        "."
    ],
    "config": {
        "WOOCOMMERCE_BLOCKS_PHASE": 3,
        "WP_DEBUG": true
    }
}
```

Enable the new product editor via WP-CLI after `wp-env start`:

```bash
wp option set woocommerce_feature_product_block_editor_enabled yes
```

---

## 6. Removing or Moving Existing Blocks

### Remove a Core Block from the Template

```php
add_action(
    'woocommerce_block_template_area_product-form_after_instantiation',
    function( BlockTemplateInterface $template ) {
        $block = $template->get_block( 'product-form/general/basic-details/product-name' );
        if ( $block ) {
            $block->remove();
        }
    }
);
```

### Move a Block to a Different Section

Retrieve the block, remove it from the current parent, then add it to the target parent.

---

## Key Notes

- `useWooBlockProps` is required instead of the standard `useBlockProps` for product editor blocks; it wires up the necessary context.
- The `order` property in `add_block()` controls rendering order within the section. Core blocks typically use values 10–50; use 60+ for custom blocks to append after core content.
- `hideConditions` expressions are evaluated against the Jexl expression language with `editedProduct` in scope.
- Always guard the `woocommerce_block_template_area_*` action with a `class_exists` check on `BlockTemplateInterface` to avoid fatal errors when WooCommerce is inactive.
- Product Editor was stable from WC 9.0 but is now **retired**: deprecated in WC 10.9 and removed from core in WC 11.0. Migrate any custom blocks off it before upgrading to 11.0.
