---
name: wp-e2e-playwright
version: "1.0.0"
description: "Use when setting up or writing Playwright end-to-end tests for WordPress plugins and WooCommerce extensions: @wordpress/e2e-test-utils-playwright setup, playwright.config.js, wp-env integration, WooCommerce checkout/payment flow testing, admin settings testing, and CI integration."
compatibility: "Targets @playwright/test 1.40+ (current stable 1.63.x), @wordpress/e2e-test-utils-playwright 1.x (current 1.54.0; the package has graduated from the 0.x line), WordPress 6.7+, WooCommerce 9.0+ (current stable: WP 7.1, WC 11.1.0; verified 2026-09-09). Requires wp-env (Docker) for local test environment."
---

# WP E2E Playwright

## When to use

Use this skill when working on Playwright E2E tests for WordPress plugins or WooCommerce extensions, for example:

- Setting up Playwright E2E tests from scratch
- Writing checkout or payment flow tests for WooCommerce payment gateways
- Testing admin settings pages
- Testing Gutenberg block rendering and interaction in the editor
- Writing tests for custom WooCommerce checkout extensions (Cart/Checkout Blocks)
- Debugging flaky E2E tests
- Adding E2E to GitHub Actions CI

## Inputs required

- What to test (checkout flow, admin settings, blocks in editor, etc.)
- Whether a payment gateway test requires test-mode credentials or mock responses
- wp-env configuration (plugins, themes, config)
- Whether existing tests need to be fixed or new ones written

## Procedure

### 0) Audit existing E2E setup

Inspect what is already in place before making changes:

- Check `package.json` for `@playwright/test`, `@wordpress/e2e-test-utils-playwright`
- Check for `playwright.config.js` / `playwright.config.ts`
- Check for `tests/e2e/` or `e2e/` directory
- Run `npx playwright --version` to verify installation

```bash
cat package.json | grep -E "playwright|e2e"
ls tests/e2e/ 2>/dev/null || ls e2e/ 2>/dev/null
npx playwright --version 2>/dev/null
```

### 1) Install dependencies

```bash
npm install --save-dev @playwright/test @wordpress/e2e-test-utils-playwright
npx playwright install chromium
```

Add to `.wp-env.json` any plugins needed for E2E (WooCommerce, etc.):

```json
{
  "plugins": [
    "https://downloads.wordpress.org/plugin/woocommerce.zip",
    "."
  ],
  "config": {
    "WP_DEBUG": true,
    "WP_DEBUG_LOG": true,
    "SCRIPT_DEBUG": true
  }
}
```

Then start the environment:

```bash
npx wp-env start
```

### 2) Create `playwright.config.ts`

Key settings:
- `baseURL`: `http://localhost:8889` (wp-env default for the frontend)
- `testDir`: `./tests/e2e`
- `projects`: separate `setup` project for auth, then main test project
- `use.storageState`: reuse admin login across tests

See `references/setup.md` for the complete annotated config.

### 3) Create admin login fixture

Create `tests/e2e/auth.setup.ts` to log in once and save `auth/admin.json` storage state. All subsequent tests reuse this state, avoiding redundant logins.

Use `@wordpress/e2e-test-utils-playwright` `Admin` class for WordPress-aware navigation and `RequestUtils` for programmatic REST API operations.

See `references/setup.md` for the complete auth setup file.

### 4) Write tests

Organize tests by feature:

```
tests/e2e/
├── auth.setup.ts          # Login once, save state
├── specs/
│   ├── checkout.spec.ts   # WooCommerce checkout flow
│   ├── settings.spec.ts   # Admin settings pages
│   └── blocks.spec.ts     # Block editor interactions
└── utils/
    └── helpers.ts         # Shared helpers (create product, etc.)
```

See:
- `references/wc-checkout-patterns.md` for WooCommerce-specific patterns
- `references/block-editor-patterns.md` for Gutenberg block testing

### 5) Add npm scripts

Add to `package.json`:

```json
{
  "scripts": {
    "test:e2e": "playwright test",
    "test:e2e:ui": "playwright test --ui",
    "test:e2e:debug": "playwright test --debug",
    "test:e2e:report": "playwright show-report"
  }
}
```

Run a single spec:

```bash
npx playwright test tests/e2e/specs/checkout.spec.ts
```

### 6) Add to GitHub Actions CI

Minimal CI job:

```yaml
e2e:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v7
    - uses: actions/setup-node@v7
      with:
        node-version: '24'
    - run: npm ci
    - run: npx playwright install --with-deps chromium
    - run: npx wp-env start
    - run: npm run test:e2e
    - uses: actions/upload-artifact@v7
      if: failure()
      with:
        name: playwright-report
        path: playwright-report/
```

See `references/setup.md` for a full CI workflow with environment variables and retry logic.

## Verification

- Run `npx wp-env start` before tests.
- Run `npm run test:e2e` and confirm all tests pass.
- Run `npm run test:e2e:report` to open the HTML report for failures.
- Confirm `auth/admin.json` is present after the setup project runs.

## Failure modes / debugging

- **Tests time out on login**: increase `timeout` in `playwright.config.ts`, verify wp-env is running (`npx wp-env status`), check `baseURL` port (frontend: 8889, admin: 8889/wp-admin).
- **"Page not found" for checkout**: WooCommerce not configured; use `RequestUtils` to set up WC settings programmatically (currency, country, payment methods).
- **Flaky tests due to animation or network**: use `page.waitForLoadState('networkidle')`, add explicit `await expect(locator).toBeVisible()` waits, or increase `actionTimeout`.
- **`storageState` expires or is invalid**: delete `auth/admin.json` and re-run the `setup` project; check that the admin credentials match the wp-env defaults (`admin` / `password`).
- **iframe fields not found (payment gateway)**: wait for the iframe to attach with `page.frameLocator('iframe[name="..."]')` and assert the frame is visible before interacting.
- **Block editor tests fail in headless mode**: some Gutenberg interactions require `headless: false` locally for debugging; in CI use `--reporter=html` and review screenshots.

## Escalation

- If a payment gateway requires live credentials for testing, ask the user whether a test-mode API key is available or whether mock/stub responses should be used instead.
- If WooCommerce Blocks selectors change across WC versions, confirm the WC version in `.wp-env.json` before hardcoding selectors.
