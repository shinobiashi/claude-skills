---
name: wp-phpunit
version: "1.0.0"
description: "Use when setting up, writing, or fixing PHPUnit tests for WordPress plugins: phpunit.xml configuration, bootstrap setup, WP_UnitTestCase patterns, WooCommerce test framework (WC_Unit_Test_Case), factory classes, mock HTTP requests, and test database isolation."
compatibility: "Targets PHPUnit 9.x (the version the WordPress core test suite requires) for WP/WooCommerce integration tests; WordPress 6.7+, WooCommerce 9.0+ (current stable: WP 7.0, WC 10.9). PHPUnit 10+ only works for pure unit tests that do not load the WP suite. Requires wp-env or a local WordPress install for integration tests."
---

# WP PHPUnit

## When to use

Use this skill when working on PHPUnit in a WordPress plugin codebase, for example:

- Setting up PHPUnit in a WordPress plugin for the first time
- Adding tests alongside new features
- Fixing broken test setup after dependency updates
- Writing WooCommerce-specific tests (orders, products, customers)
- Debugging test isolation issues (database rollback, hook cleanup)

## Inputs required

- Whether the plugin requires WooCommerce (affects bootstrap file and base test class)
- PHP version and PHPUnit version constraint
- Test directory structure preference (`tests/` vs `test/` vs `tests/php/`)
- Whether wp-env is used as the local environment

## Procedure

### 0) Discover existing test setup

Before making any changes, check what already exists:

```bash
# Check for existing PHPUnit config
ls phpunit.xml phpunit.xml.dist 2>/dev/null

# Check composer.json for test dependencies
cat composer.json | grep -A5 '"require-dev"'

# Check for bootstrap file
find . -name "bootstrap.php" -path "*/tests/*" | head -5

# Check installed PHPUnit version
vendor/bin/phpunit --version 2>/dev/null
```

Look for:
- `phpunit/phpunit` in `composer.json` `require-dev`
- `yoast/wp-test-utils` or `brain/monkey` for unit tests without WordPress
- `tests/bootstrap.php`, `tests/php/bootstrap.php`, or `bin/install-wp-tests.sh`

### 1) Install PHPUnit and WordPress test utilities

For plugins **not** requiring WooCommerce:

```bash
composer require --dev phpunit/phpunit:"^9.6" yoast/phpunit-polyfills:"^4.0" yoast/wp-test-utils
```

For **WooCommerce extensions**:

```bash
composer require --dev phpunit/phpunit:"^9.6" yoast/phpunit-polyfills:"^4.0" woocommerce/woocommerce:"*"
```

> Note: The WordPress core test suite still targets **PHPUnit 9.x** (currently 9.6), so integration
> tests that boot WordPress must run on 9.x — do NOT use PHPUnit 10/11/12/13 for them. Upstream
> PHPUnit has reached 13, but that is irrelevant for WP-suite tests; reserve 10+ for pure unit tests
> that never load WordPress. Use `yoast/phpunit-polyfills:^4.0` for the forward-compat assertions the
> WP core suite depends on. If you consume the WP test library via the `wp-phpunit/wp-phpunit`
> Composer package, pin it to the WordPress version you test against (e.g. `^7.0`).

### 2) Install the WordPress test suite

**Option A — WP-CLI scaffold (recommended for new setups):**

```bash
wp scaffold plugin-tests {plugin-slug}
# Creates: phpunit.xml.dist, tests/bootstrap.php, bin/install-wp-tests.sh
```

**Option B — Manual install script:**

```bash
bash bin/install-wp-tests.sh wordpress_test root '' localhost latest
```

**Option C — wp-env (no separate install needed):**

When using `@wordpress/env`, tests run against its internal database automatically.
Set `WP_TESTS_DIR` to `/var/www/html/wp-content/plugins/{plugin-slug}/vendor/wordpress/` or use the path provided by wp-env.

### 3) Create `phpunit.xml.dist`

See `references/setup.md` for the full annotated version. Minimal working config:

```xml
<?xml version="1.0"?>
<phpunit
  bootstrap="tests/bootstrap.php"
  backupGlobals="false"
  colors="true"
  convertErrorsToExceptions="true"
  convertNoticesToExceptions="true"
  convertWarningsToExceptions="true"
>
  <testsuites>
    <testsuite name="unit">
      <directory suffix="Test.php">tests/unit</directory>
    </testsuite>
    <testsuite name="integration">
      <directory suffix="Test.php">tests/integration</directory>
    </testsuite>
  </testsuites>
  <coverage>
    <include>
      <directory suffix=".php">includes/</directory>
      <file>plugin-name.php</file>
    </include>
  </coverage>
</phpunit>
```

### 4) Create `tests/bootstrap.php`

**For plain WordPress plugins:**

```php
<?php
/**
 * PHPUnit bootstrap for WordPress plugin tests.
 */

// Load Composer autoloader.
require_once dirname( __DIR__ ) . '/vendor/autoload.php';

// Load WP test functions.
$wp_tests_dir = getenv( 'WP_TESTS_DIR' ) ?: sys_get_temp_dir() . '/wordpress-tests-lib';

if ( ! file_exists( $wp_tests_dir . '/includes/functions.php' ) ) {
    echo "Could not find $wp_tests_dir/includes/functions.php\n";
    exit( 1 );
}

require_once $wp_tests_dir . '/includes/functions.php';

// Load the plugin under test.
tests_add_filter( 'muplugins_loaded', function() {
    require dirname( __DIR__ ) . '/plugin-name.php';
} );

require $wp_tests_dir . '/includes/bootstrap.php';
```

**For WooCommerce extensions:**

See `references/setup.md` for the WooCommerce bootstrap and `WC_Unit_Test_Case` setup.

### 5) Write tests

See `references/wp-testcase-patterns.md` for `WP_UnitTestCase` patterns and
`references/wc-testing.md` for WooCommerce-specific patterns.

### 6) Add composer scripts and run

```json
{
  "scripts": {
    "test":             "vendor/bin/phpunit",
    "test:unit":        "vendor/bin/phpunit --testsuite=unit",
    "test:integration": "vendor/bin/phpunit --testsuite=integration",
    "test:coverage":    "vendor/bin/phpunit --coverage-html coverage"
  }
}
```

Run all tests:

```bash
composer test
# or directly:
vendor/bin/phpunit
```

## Verification

- Run `vendor/bin/phpunit --version` to confirm the correct version is installed.
- Run `composer test` and confirm all tests pass (or the expected tests fail for the right reasons).
- Check that database changes from one test do not bleed into the next (use `WP_UnitTestCase`, which wraps each test in a transaction).
- After adding WooCommerce tests, verify `WC()` returns a valid instance in the bootstrap.

## Failure modes / debugging

- **"Cannot redeclare wp_..."** — multiple bootstrap loads; ensure `bootstrap.php` is only required once and that the install script is not re-run mid-test.
- **"Class WC_... not found"** — WooCommerce is not loaded in bootstrap; check load order in `tests/bootstrap.php` and that WooCommerce is activated before the plugin.
- **Tests affecting each other** — use `setUp()/tearDown()` with `$this->factory` for isolated data; avoid `static` state or global option mutations without cleanup.
- **Slow integration tests** — separate unit tests (no WP loaded, use Brain\Monkey or plain PHPUnit mocks) and integration tests (full WP + WooCommerce).
- **"Table wp_woocommerce_* does not exist"** — WooCommerce tables not installed; call `WC_Install::create_tables()` in bootstrap or ensure WooCommerce setup runs before tests.
- **PHPUnit 10/11 compatibility** — `@expectedException` annotation removed; replace with `$this->expectException( Foo::class )` method call.

## Escalation

- If the test environment requires a specific database or WP install not present in the repo, ask the user for `WP_TESTS_DIR` and database credentials before proceeding.
- If adding Composer dependencies (e.g., `woocommerce/woocommerce` in `require-dev`) significantly increases install time, confirm with the user first.
- If WooCommerce Subscriptions or other premium plugins are required for tests, ask whether stubs or a local copy are available.
