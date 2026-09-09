# PHPUnit Setup Reference

Complete reference for setting up PHPUnit in WordPress plugins.

---

## Directory structure

Recommended layout for a plugin with both unit and integration tests:

```
my-plugin/
├── bin/
│   └── install-wp-tests.sh      # WP test suite installer script
├── tests/
│   ├── bootstrap.php            # PHPUnit bootstrap (shared entry point)
│   ├── unit/                    # Fast tests — no WordPress loaded
│   │   ├── ExampleTest.php
│   │   └── ...
│   └── integration/             # Full WordPress (+ WooCommerce) tests
│       ├── ExampleTest.php
│       └── ...
├── phpunit.xml.dist             # Committed config template
├── phpunit.xml                  # Local overrides (git-ignored)
├── composer.json
└── my-plugin.php
```

Add `phpunit.xml` and `coverage/` to `.gitignore`.

---

## `phpunit.xml.dist` — full annotated reference

```xml
<?xml version="1.0"?>
<phpunit
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xsi:noNamespaceSchemaLocation="https://schema.phpunit.de/9.6/phpunit.xsd"
  bootstrap="tests/bootstrap.php"
  backupGlobals="false"
  colors="true"
  convertErrorsToExceptions="true"
  convertNoticesToExceptions="true"
  convertWarningsToExceptions="true"
>
  <!-- Test suites: run separately with --testsuite=unit -->
  <testsuites>
    <testsuite name="unit">
      <directory suffix="Test.php">tests/unit</directory>
    </testsuite>
    <testsuite name="integration">
      <directory suffix="Test.php">tests/integration</directory>
    </testsuite>
  </testsuites>

  <!-- Code coverage: include only first-party source files -->
  <coverage>
    <include>
      <directory suffix=".php">includes/</directory>
      <directory suffix=".php">src/</directory>
      <file>my-plugin.php</file>
    </include>
    <exclude>
      <directory>vendor/</directory>
      <directory>tests/</directory>
      <directory>node_modules/</directory>
    </exclude>
  </coverage>

  <!-- Environment variables available to tests -->
  <php>
    <env name="WP_TESTS_DIR" value="/tmp/wordpress-tests-lib"/>
    <env name="WP_PHPUNIT__TESTS_CONFIG" value="tests/wp-tests-config.php"/>
  </php>
</phpunit>
```

**PHPUnit version notes:**
- The WordPress core test suite targets **PHPUnit 9.x** (9.6) — use it for any WP/WC integration test. The config above (with `convertErrorsToExceptions` etc.) is 9.x syntax.
- PHPUnit 10.x+ (removes `convertErrorsToExceptions` etc.) only applies to pure unit tests that never load WordPress. Delete those attributes and bump the schema URL if you target 10+ there.
- Schema URL changes per version: `https://schema.phpunit.de/9.6/phpunit.xsd`

---

## `tests/bootstrap.php` — plain WordPress plugin

```php
<?php
/**
 * PHPUnit bootstrap file for a plain WordPress plugin.
 *
 * Usage:
 *   WP_TESTS_DIR=/path/to/wordpress-tests-lib vendor/bin/phpunit
 */

// 1. Composer autoloader (your plugin classes, test helpers, etc.).
require_once dirname( __DIR__ ) . '/vendor/autoload.php';

// 2. Resolve WordPress test library path.
$wp_tests_dir = getenv( 'WP_TESTS_DIR' );
if ( ! $wp_tests_dir ) {
    $wp_tests_dir = rtrim( sys_get_temp_dir(), '/\\' ) . '/wordpress-tests-lib';
}

if ( ! file_exists( $wp_tests_dir . '/includes/functions.php' ) ) {
    echo "ERROR: Cannot find WordPress test library at: {$wp_tests_dir}\n";
    echo "  Set WP_TESTS_DIR or run bin/install-wp-tests.sh first.\n";
    exit( 1 );
}

// 3. Load WP test functions (must happen before bootstrap.php).
require_once $wp_tests_dir . '/includes/functions.php';

// 4. Register plugin load via muplugins_loaded to replicate real WordPress load order.
tests_add_filter( 'muplugins_loaded', static function () {
    require dirname( __DIR__ ) . '/my-plugin.php';
} );

// 5. Start the WordPress testing environment.
require $wp_tests_dir . '/includes/bootstrap.php';
```

---

## `tests/bootstrap.php` — WooCommerce extension

```php
<?php
/**
 * PHPUnit bootstrap for a WooCommerce extension.
 *
 * Requires WooCommerce to be installed alongside WordPress or loaded via Composer.
 *
 * Usage:
 *   WP_TESTS_DIR=/tmp/wordpress-tests-lib \
 *   WC_DIR=/path/to/woocommerce \
 *   vendor/bin/phpunit
 */

// 1. Composer autoloader.
require_once dirname( __DIR__ ) . '/vendor/autoload.php';

// 2. Resolve paths.
$wp_tests_dir = getenv( 'WP_TESTS_DIR' ) ?: rtrim( sys_get_temp_dir(), '/\\' ) . '/wordpress-tests-lib';
$wc_dir       = getenv( 'WC_DIR' ) ?: dirname( __DIR__ ) . '/vendor/woocommerce/woocommerce';

if ( ! file_exists( $wp_tests_dir . '/includes/functions.php' ) ) {
    echo "ERROR: WordPress test library not found at: {$wp_tests_dir}\n";
    exit( 1 );
}

if ( ! file_exists( $wc_dir . '/woocommerce.php' ) ) {
    echo "ERROR: WooCommerce not found at: {$wc_dir}\n";
    exit( 1 );
}

// 3. Load WP test functions.
require_once $wp_tests_dir . '/includes/functions.php';

// 4. Load WooCommerce and the plugin under test.
tests_add_filter( 'muplugins_loaded', static function () use ( $wc_dir ) {
    // WooCommerce must load before your plugin.
    require $wc_dir . '/woocommerce.php';

    // Now load your plugin.
    require dirname( __DIR__ ) . '/my-wc-plugin.php';
} );

// 5. Boot WordPress test environment.
require $wp_tests_dir . '/includes/bootstrap.php';

// 6. Load WooCommerce test helpers (WC_Helper_Product, WC_Helper_Order, etc.).
$wc_tests_framework = $wc_dir . '/tests/legacy/bootstrap.php';
if ( file_exists( $wc_tests_framework ) ) {
    echo "Loading WooCommerce test framework...\n";
    require_once $wc_tests_framework;
}
```

> If using the `woocommerce/woocommerce` Composer package, the helpers are at
> `vendor/woocommerce/woocommerce/tests/legacy/`.

---

## `bin/install-wp-tests.sh`

This script downloads WordPress core and the WP test library. Generated by `wp scaffold plugin-tests`, but you can create it manually.

```bash
#!/usr/bin/env bash
# Usage: bash bin/install-wp-tests.sh <db-name> <db-user> <db-pass> [db-host] [wp-version]

DB_NAME=${1}
DB_USER=${2}
DB_PASS=${3}
DB_HOST=${4:-localhost}
WP_VERSION=${5:-latest}

WP_TESTS_DIR=${WP_TESTS_DIR:-/tmp/wordpress-tests-lib}
WP_CORE_DIR=${WP_CORE_DIR:-/tmp/wordpress}

# Download WordPress
if [ ! -d "$WP_CORE_DIR" ]; then
    mkdir -p "$WP_CORE_DIR"
    wp core download --version="$WP_VERSION" --path="$WP_CORE_DIR" --force
fi

# Download WP test library
if [ ! -d "$WP_TESTS_DIR" ]; then
    mkdir -p "$WP_TESTS_DIR"
    svn co --quiet \
      "https://develop.svn.wordpress.org/tags/${WP_VERSION}/tests/phpunit/includes/" \
      "$WP_TESTS_DIR/includes"
    svn co --quiet \
      "https://develop.svn.wordpress.org/tags/${WP_VERSION}/tests/phpunit/data/" \
      "$WP_TESTS_DIR/data"
fi

# Create wp-tests-config.php
cat > "$WP_TESTS_DIR/wp-tests-config.php" <<EOF
<?php
define( 'ABSPATH',       '${WP_CORE_DIR}/' );
define( 'WP_DEBUG',      true );
define( 'DB_NAME',       '${DB_NAME}' );
define( 'DB_USER',       '${DB_USER}' );
define( 'DB_PASSWORD',   '${DB_PASS}' );
define( 'DB_HOST',       '${DB_HOST}' );
define( 'DB_CHARSET',    'utf8' );
define( 'DB_COLLATE',    '' );
\$table_prefix = 'wptests_';
EOF

# Create the test database
mysql -u "$DB_USER" -p"$DB_PASS" -h "$DB_HOST" -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
```

---

## wp-env integration

When using `@wordpress/env`, the test database is already running inside Docker.

1. Start wp-env: `npx wp-env start`
2. Install the WP test library inside wp-env:
   ```bash
   npx wp-env run tests-cli bash -c "bash /var/www/html/wp-content/plugins/my-plugin/bin/install-wp-tests.sh wordpress_test root password localhost"
   ```
3. Run PHPUnit inside wp-env:
   ```bash
   npx wp-env run tests-cli vendor/bin/phpunit
   ```
4. Alternatively, map `WP_TESTS_DIR` to the path inside the container if running PHPUnit locally against a remote DB.

---

## Environment variables reference

| Variable | Default | Description |
|---|---|---|
| `WP_TESTS_DIR` | `/tmp/wordpress-tests-lib` | Path to WP test library (functions.php, bootstrap.php) |
| `WP_CORE_DIR` | `/tmp/wordpress` | Path to WordPress core installation |
| `WC_DIR` | `vendor/woocommerce/woocommerce` | Path to WooCommerce plugin |
| `WC_UNIT_TESTS_DIR` | `$WC_DIR/tests/legacy` | Path to WC test helpers |
| `WP_PHP_BINARY` | `php` | PHP binary to use when running tests |
| `WP_TESTS_TABLE_PREFIX` | `wptests_` | Table prefix for test database |
