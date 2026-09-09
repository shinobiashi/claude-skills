# Setup Reference: Playwright + wp-env for WordPress/WooCommerce

## Directory structure

```
my-plugin/
├── .wp-env.json
├── playwright.config.ts
├── package.json
├── auth/
│   └── admin.json          # Generated — add to .gitignore
└── tests/e2e/
    ├── auth.setup.ts       # Login once, save storage state
    ├── specs/
    │   ├── checkout.spec.ts
    │   ├── settings.spec.ts
    │   └── blocks.spec.ts
    └── utils/
        └── helpers.ts
```

Add to `.gitignore`:

```
auth/
playwright-report/
test-results/
```

---

## Complete `playwright.config.ts`

```typescript
import { defineConfig, devices } from '@playwright/test';
import { fileURLToPath } from 'url';

// Load .env.test if present (test-mode credentials, etc.)
import dotenv from 'dotenv';
dotenv.config({ path: '.env.test' });

const BASE_URL = process.env.WP_BASE_URL ?? 'http://localhost:8889';

export default defineConfig( {
  testDir: './tests/e2e',

  // Maximum time one test can run.
  timeout: 60_000,

  // Time to wait for an assertion (e.g. expect().toBeVisible()).
  expect: {
    timeout: 10_000,
  },

  // Retry once in CI to reduce flakiness noise.
  retries: process.env.CI ? 1 : 0,

  // Run tests in parallel (increase workers for faster CI).
  workers: process.env.CI ? 2 : undefined,

  reporter: [
    [ 'html', { open: 'never' } ],
    [ 'list' ],
  ],

  use: {
    baseURL: BASE_URL,

    // Reuse the logged-in admin session across all tests.
    storageState: 'auth/admin.json',

    // Record video and screenshot only on failure.
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    trace: 'retain-on-failure',

    // Increase action / navigation timeouts for slow Docker environments.
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
  },

  projects: [
    // 1. Setup project — runs first, creates auth/admin.json.
    {
      name: 'setup',
      testMatch: /auth\.setup\.ts/,
      use: {
        // Do NOT inherit storageState here; we are creating it.
        storageState: undefined,
      },
    },

    // 2. Main test project — depends on setup.
    {
      name: 'chromium',
      use: { ...devices[ 'Desktop Chrome' ] },
      dependencies: [ 'setup' ],
    },
  ],
} );
```

### JavaScript version (`playwright.config.js`)

```javascript
// @ts-check
const { defineConfig, devices } = require( '@playwright/test' );

const BASE_URL = process.env.WP_BASE_URL ?? 'http://localhost:8889';

/** @type {import('@playwright/test').PlaywrightTestConfig} */
module.exports = defineConfig( {
  testDir: './tests/e2e',
  timeout: 60_000,
  expect: { timeout: 10_000 },
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 2 : undefined,
  reporter: [ [ 'html', { open: 'never' } ], [ 'list' ] ],
  use: {
    baseURL: BASE_URL,
    storageState: 'auth/admin.json',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    trace: 'retain-on-failure',
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
  },
  projects: [
    {
      name: 'setup',
      testMatch: /auth\.setup\.ts/,
      use: { storageState: undefined },
    },
    {
      name: 'chromium',
      use: { ...devices[ 'Desktop Chrome' ] },
      dependencies: [ 'setup' ],
    },
  ],
} );
```

---

## `.wp-env.json` for E2E

```json
{
  "core": null,
  "plugins": [
    "https://downloads.wordpress.org/plugin/woocommerce.zip",
    "."
  ],
  "themes": [
    "https://downloads.wordpress.org/theme/storefront.zip"
  ],
  "config": {
    "WP_DEBUG": true,
    "WP_DEBUG_LOG": true,
    "SCRIPT_DEBUG": true,
    "WP_ENVIRONMENT_TYPE": "local"
  },
  "mappings": {}
}
```

Pin a specific WooCommerce version:

```json
"plugins": [
  "https://downloads.wordpress.org/plugin/woocommerce.10.9.3.zip",
  "."
]
```

---

## Admin login fixture (`tests/e2e/auth.setup.ts`)

```typescript
import { test as setup, expect } from '@wordpress/e2e-test-utils-playwright';
import path from 'path';
import fs from 'fs';

const AUTH_FILE = 'auth/admin.json';

setup( 'authenticate as admin', async ( { page, requestUtils } ) => {
  // Ensure the auth directory exists.
  const dir = path.dirname( AUTH_FILE );
  if ( ! fs.existsSync( dir ) ) {
    fs.mkdirSync( dir, { recursive: true } );
  }

  // Navigate to wp-login.php.
  await page.goto( '/wp-login.php' );

  // Fill credentials (wp-env defaults).
  await page.fill( '#user_login', process.env.WP_ADMIN_USER ?? 'admin' );
  await page.fill( '#user_pass', process.env.WP_ADMIN_PASSWORD ?? 'password' );
  await page.click( '#wp-submit' );

  // Verify login succeeded.
  await expect( page ).toHaveURL( /wp-admin/ );

  // Persist the authenticated state.
  await page.context().storageState( { path: AUTH_FILE } );
} );
```

If `@wordpress/e2e-test-utils-playwright` does not expose its test fixture in your version, use plain `@playwright/test`:

```typescript
import { test as setup, expect } from '@playwright/test';
import path from 'path';
import fs from 'fs';

const AUTH_FILE = 'auth/admin.json';

setup( 'authenticate as admin', async ( { page } ) => {
  const dir = path.dirname( AUTH_FILE );
  if ( ! fs.existsSync( dir ) ) {
    fs.mkdirSync( dir, { recursive: true } );
  }

  await page.goto( '/wp-login.php' );
  await page.fill( '#user_login', process.env.WP_ADMIN_USER ?? 'admin' );
  await page.fill( '#user_pass', process.env.WP_ADMIN_PASSWORD ?? 'password' );
  await page.click( '#wp-submit' );
  await expect( page ).toHaveURL( /wp-admin/ );
  await page.context().storageState( { path: AUTH_FILE } );
} );
```

---

## Using `RequestUtils` for programmatic WP/WC setup

`RequestUtils` from `@wordpress/e2e-test-utils-playwright` wraps the WP REST API to set up state without UI interactions.

```typescript
import { test, expect, RequestUtils } from '@wordpress/e2e-test-utils-playwright';

test.beforeAll( async ( { requestUtils } ) => {
  // Activate a plugin.
  await requestUtils.activatePlugin( 'my-plugin' );

  // Update an option via REST (requires the option to be registered with show_in_rest).
  await requestUtils.updateSiteSettings( {
    woocommerce_default_country: 'JP',
    woocommerce_currency: 'JPY',
  } );
} );
```

For WooCommerce-specific setup (products, orders), use the WC REST API directly via `page.request`:

```typescript
test.beforeAll( async ( { page } ) => {
  // Create a simple product.
  const response = await page.request.post(
    '/wp-json/wc/v3/products',
    {
      data: {
        name: 'Test Product',
        type: 'simple',
        regular_price: '1000',
        status: 'publish',
      },
      // Use Basic Auth with application password, or rely on storageState cookie.
    }
  );
  const product = await response.json();
  productId = product.id;
} );
```

---

## Environment variables (`.env.test`)

```dotenv
WP_BASE_URL=http://localhost:8889
WP_ADMIN_USER=admin
WP_ADMIN_PASSWORD=password

# Payment gateway test-mode credentials (never commit real keys)
PAYJP_TEST_PUBLIC_KEY=pk_test_xxxx
PAYJP_TEST_SECRET_KEY=sk_test_xxxx
STRIPE_TEST_PUBLIC_KEY=pk_test_xxxx
```

Load in `playwright.config.ts`:

```typescript
import dotenv from 'dotenv';
dotenv.config( { path: '.env.test' } );
```

---

## Running a single spec

```bash
# Run one file
npx playwright test tests/e2e/specs/checkout.spec.ts

# Run tests matching a title pattern
npx playwright test -g "complete checkout"

# Run with visible browser (headed)
npx playwright test --headed

# Debug a single test (Playwright Inspector)
npx playwright test tests/e2e/specs/checkout.spec.ts --debug

# Open interactive UI mode
npx playwright test --ui
```

---

## GitHub Actions CI workflow

```yaml
name: E2E Tests

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main ]

jobs:
  e2e:
    runs-on: ubuntu-latest
    timeout-minutes: 30

    steps:
      - name: Checkout
        uses: actions/checkout@v7

      - name: Setup Node
        uses: actions/setup-node@v7
        with:
          node-version: '24'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Install Playwright browsers
        run: npx playwright install --with-deps chromium

      - name: Start wp-env
        run: npx wp-env start

      - name: Wait for WordPress to be ready
        run: |
          until curl -s http://localhost:8889 > /dev/null; do
            echo "Waiting for wp-env..."
            sleep 2
          done

      - name: Run E2E tests
        run: npm run test:e2e
        env:
          WP_BASE_URL: http://localhost:8889
          CI: true

      - name: Upload Playwright report
        uses: actions/upload-artifact@v7
        if: ${{ failure() }}
        with:
          name: playwright-report
          path: playwright-report/
          retention-days: 14
```
