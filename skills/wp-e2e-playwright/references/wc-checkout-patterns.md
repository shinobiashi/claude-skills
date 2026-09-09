# WooCommerce checkout and payment E2E patterns

## Setting up WooCommerce for tests

Use `RequestUtils` to configure WooCommerce programmatically — no UI clicks needed.

```typescript
// tests/e2e/utils/setup-woocommerce.ts
import { RequestUtils } from '@wordpress/e2e-test-utils-playwright';

export async function setupWooCommerce( requestUtils: RequestUtils ) {
    // Enable Cash on Delivery
    await requestUtils.rest( {
        method: 'POST',
        path: '/wc/v3/payment_gateways/cod',
        data: { enabled: true },
    } );

    // Set store address (required for tax/shipping)
    await requestUtils.updateSiteSettings( {
        woocommerce_store_address: '1 Main St',
        woocommerce_store_city: 'San Francisco',
        woocommerce_default_country: 'US:CA',
        woocommerce_store_postcode: '94105',
    } );
}

export async function createSimpleProduct(
    requestUtils: RequestUtils,
    overrides: Record<string, unknown> = {}
) {
    return requestUtils.rest( {
        method: 'POST',
        path: '/wc/v3/products',
        data: {
            name: 'Test Product',
            type: 'simple',
            regular_price: '10.00',
            status: 'publish',
            ...overrides,
        },
    } );
}
```

---

## Classic shortcode checkout flow

```typescript
// tests/e2e/specs/classic-checkout.spec.ts
import { test, expect } from '@playwright/test';
import { RequestUtils } from '@wordpress/e2e-test-utils-playwright';
import { createSimpleProduct } from '../utils/setup-woocommerce';

test.describe( 'Classic checkout', () => {
    let productId: number;

    test.beforeAll( async ( { request } ) => {
        const requestUtils = await RequestUtils.setup( { request } );
        const product = await createSimpleProduct( requestUtils );
        productId = product.id;
    } );

    test( 'completes checkout with Cash on Delivery', async ( { page } ) => {
        // Add to cart via REST (faster than UI)
        await page.goto( `/shop/?add-to-cart=${ productId }` );

        // Navigate to checkout
        await page.goto( '/checkout/' );
        await page.waitForLoadState( 'networkidle' );

        // Fill billing fields
        await page.fill( '#billing_first_name', 'John' );
        await page.fill( '#billing_last_name', 'Doe' );
        await page.fill( '#billing_address_1', '1 Main St' );
        await page.fill( '#billing_city', 'San Francisco' );
        await page.fill( '#billing_state', 'CA' );
        await page.fill( '#billing_postcode', '94105' );
        await page.fill( '#billing_email', 'john@example.com' );
        await page.fill( '#billing_phone', '555-1234' );

        // Select Cash on Delivery
        await page.click( '#payment_method_cod' );

        // Place order
        await page.click( '#place_order' );

        // Assert thank you page
        await expect( page ).toHaveURL( /order-received/ );
        await expect( page.locator( 'h1.entry-title' ) ).toContainText( 'Order received' );
    } );
} );
```

---

## WooCommerce Blocks checkout flow

```typescript
// tests/e2e/specs/blocks-checkout.spec.ts
import { test, expect } from '@playwright/test';

test( 'completes WooCommerce Blocks checkout', async ( { page } ) => {
    await page.goto( '/cart/' );

    // WooCommerce Cart Block
    const cartBlock = page.locator( '[data-block-name="woocommerce/cart"]' );
    await expect( cartBlock ).toBeVisible();

    await page.click( '.wc-block-cart__submit-button' );
    await page.waitForURL( /checkout/ );

    // WooCommerce Checkout Block fields
    await page.fill( '#email', 'john@example.com' );
    await page.fill( '#billing-first_name', 'John' );
    await page.fill( '#billing-last_name', 'Doe' );
    await page.fill( '#billing-address_1', '1 Main St' );
    await page.fill( '#billing-city', 'San Francisco' );
    await page.fill( '#billing-postcode', '94105' );

    // Place order
    await page.click( '.wc-block-components-checkout-place-order-button' );

    await expect( page ).toHaveURL( /order-received/ );
} );
```

---

## Payment gateway testing (test mode / mock)

For payment gateways with iframe card fields (e.g., PAY.JP, Stripe):

```typescript
test( 'pays with credit card in test mode', async ( { page } ) => {
    await page.goto( '/checkout/' );
    // ... fill billing fields ...

    // Select the payment gateway
    await page.click( '#payment_method_my_gateway' );

    // Handle card input inside iframe
    const cardFrame = page.frameLocator( '#my-gateway-card-frame' );
    await cardFrame.locator( '[name="cardNumber"]' ).fill( '4242424242424242' );
    await cardFrame.locator( '[name="cardExpiry"]' ).fill( '12/28' );
    await cardFrame.locator( '[name="cardCvc"]' ).fill( '123' );

    await page.click( '#place_order' );

    // Handle 3DS redirect if needed
    if ( await page.locator( '.threed-secure-frame' ).isVisible() ) {
        const secureFrame = page.frameLocator( '.threed-secure-frame' );
        await secureFrame.locator( '[name="authenticate"]' ).click();
    }

    await expect( page ).toHaveURL( /order-received/ );
    await expect( page.locator( '.woocommerce-order-overview__payment-method' ) )
        .toContainText( 'My Gateway' );
} );
```

---

## Admin order status check

```typescript
test( 'order status is processing in WC admin', async ( { page } ) => {
    // Get latest order ID via REST
    const response = await page.request.get( '/wp-json/wc/v3/orders?per_page=1', {
        headers: { Authorization: 'Basic ' + btoa( 'admin:password' ) },
    } );
    const [ order ] = await response.json();

    await page.goto( `/wp-admin/post.php?post=${ order.id }&action=edit` );
    await expect( page.locator( '#order_status' ) ).toHaveValue( 'wc-processing' );
} );
```

---

## Common WooCommerce Blocks selectors

| Element | Selector |
|---------|----------|
| Cart block | `[data-block-name="woocommerce/cart"]` |
| Checkout block | `[data-block-name="woocommerce/checkout"]` |
| Email field | `#email` |
| First name | `#billing-first_name` |
| Place order button | `.wc-block-components-checkout-place-order-button` |
| Payment method label | `.wc-block-components-payment-method-label` |
| Order total | `.wc-block-components-totals-footer-item-tax-value` |
| Cart item name | `.wc-block-cart-item__product-name` |

---

## Waiting for WooCommerce async operations

WooCommerce Blocks use React and may update asynchronously:

```typescript
// Wait for cart to update after adding a product
await page.waitForResponse( resp =>
    resp.url().includes( '/wc/store/v1/cart' ) && resp.status() === 200
);

// Wait for payment processing spinner to disappear
await page.waitForSelector( '.wc-block-components-spinner', { state: 'hidden' } );

// Wait for checkout to fully load
await page.waitForLoadState( 'networkidle' );
```
