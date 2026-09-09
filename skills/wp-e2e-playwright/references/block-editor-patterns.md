# Gutenberg block editor E2E patterns

## Editor utility from @wordpress/e2e-test-utils-playwright

```typescript
import { test, expect } from '@playwright/test';
import { Editor, Admin } from '@wordpress/e2e-test-utils-playwright';

test.use( { storageState: 'tests/e2e/auth.json' } );

test.beforeEach( async ( { admin } ) => {
    await admin.createNewPost();
} );
```

---

## Insert a block

```typescript
test( 'inserts my-plugin/product-card block', async ( { editor, page } ) => {
    // Via slash command in the editor
    await editor.canvas.locator( '[data-type="core/paragraph"]' ).click();
    await page.keyboard.type( '/product-card' );
    await page.keyboard.press( 'Enter' );

    // OR via the block inserter button
    await editor.showBlockToolbar();
    await page.getByRole( 'button', { name: 'Toggle block inserter' } ).click();
    await page.getByPlaceholder( 'Search' ).fill( 'Product Card' );
    await page.getByRole( 'option', { name: 'Product Card' } ).click();

    // Assert block was inserted
    await expect(
        editor.canvas.locator( '[data-type="my-plugin/product-card"]' )
    ).toBeVisible();
} );
```

---

## Set block attributes via Inspector Controls (sidebar)

```typescript
test( 'configures block attributes in sidebar', async ( { editor, page } ) => {
    await editor.insertBlock( { name: 'my-plugin/product-card' } );

    // Open block settings sidebar
    await editor.openDocumentSettingsSidebar();

    // Set a text input attribute
    await page.getByLabel( 'Number of products' ).fill( '4' );

    // Set a select attribute
    await page.getByRole( 'combobox', { name: 'Layout' } ).selectOption( 'grid' );

    // Toggle a boolean attribute
    await page.getByLabel( 'Show price' ).check();

    // Confirm the block reflects the change
    const block = editor.canvas.locator( '[data-type="my-plugin/product-card"]' );
    await expect( block ).toHaveAttribute( 'data-layout', 'grid' );
} );
```

---

## Assert frontend rendering

```typescript
test( 'renders correctly on the frontend', async ( { editor, page } ) => {
    await editor.insertBlock( {
        name: 'my-plugin/product-card',
        attributes: { productId: 123, showPrice: true },
    } );

    // Publish the post
    await editor.publishPost();
    const postUrl = new URL( page.url() );

    // Visit the frontend
    await page.goto( postUrl.searchParams.get( 'postId' )
        ? `/?p=${ postUrl.searchParams.get( 'postId' ) }`
        : postUrl.href.replace( '/wp-admin/', '/' )
    );

    // Assert rendered output
    await expect(
        page.locator( '.wp-block-my-plugin-product-card' )
    ).toBeVisible();
    await expect(
        page.locator( '.product-card__price' )
    ).toContainText( '$' );
} );
```

---

## Test block validation (deprecated blocks)

```typescript
test( 'no block validation error for deprecated serialized content', async ( { editor, page } ) => {
    // Paste old serialized block content into the post
    const oldContent = `<!-- wp:my-plugin/product-card {"productId":1} /-->`;

    await editor.setContent( oldContent );

    // Assert no "This block contains unexpected or invalid content" notice
    await expect(
        page.locator( '.block-editor-warning' )
    ).not.toBeVisible();

    // Assert the block renders in the editor
    await expect(
        editor.canvas.locator( '[data-type="my-plugin/product-card"]' )
    ).toBeVisible();
} );
```

---

## Keyboard navigation and accessibility

```typescript
test( 'block is keyboard navigable', async ( { editor, page } ) => {
    await editor.insertBlock( { name: 'my-plugin/product-card' } );

    // Focus the block
    await editor.canvas.locator( '[data-type="my-plugin/product-card"]' ).click();

    // Tab through controls
    await page.keyboard.press( 'Tab' );
    const focused = page.locator( ':focus' );
    await expect( focused ).toBeVisible();

    // Check ARIA roles
    const block = editor.canvas.locator( '[data-type="my-plugin/product-card"]' );
    await expect( block ).toHaveAttribute( 'role', 'document' );
} );
```

---

## WooCommerce Blocks in the editor

```typescript
test( 'inserts WooCommerce checkout block', async ( { editor, page } ) => {
    await admin.createNewPost( { postType: 'page' } );

    await editor.insertBlock( { name: 'woocommerce/checkout' } );

    // The checkout block has inner blocks
    await expect(
        editor.canvas.locator( '[data-type="woocommerce/checkout"]' )
    ).toBeVisible();

    await expect(
        editor.canvas.locator( '[data-type="woocommerce/checkout-shipping-address-block"]' )
    ).toBeVisible();
} );
```

---

## Tips

- `editor.canvas` is the block editor iframe. Always use `editor.canvas.locator(...)` for block content.
- Use `editor.insertBlock( { name, attributes, innerBlocks } )` over UI insertion for speed and reliability.
- `editor.setContent( html )` accepts raw serialized block HTML — useful for migration/deprecation tests.
- After `editor.publishPost()`, the URL still points to the edit screen; extract the post ID from the URL or use `editor.getCurrentPostId()`.
