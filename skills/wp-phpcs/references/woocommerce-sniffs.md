# WooCommerce-Specific PHPCS Sniffs

This reference covers PHPCS configuration for WooCommerce extension development.

## Installing woocommerce/woocommerce-sniffs

```bash
composer require --dev woocommerce/woocommerce-sniffs
```

With `dealerdirect/phpcodesniffer-composer-installer` already in place, the `WooCommerce` standard is registered automatically. Verify:

```bash
vendor/bin/phpcs -i
# Should include: WooCommerce
```

## WooCommerce sniff rules overview

`woocommerce/woocommerce-sniffs` provides the `WooCommerce` ruleset which covers:

| Sniff | Purpose |
|---|---|
| `WooCommerce.Commenting.CommentHooks` | Enforces `@hook` DocBlock annotations on `add_action`/`add_filter` |
| `WooCommerce.Functions.InternalInjectionMethod` | Flags use of `WC()->` internals not part of public API |
| `WooCommerce.PHP.DeprecatedFunctions` | Flags WooCommerce deprecated function calls |
| `WooCommerce.PHP.DeprecatedClasses` | Flags deprecated WooCommerce class usage |
| `WooCommerce.PHP.DeprecatedHooks` | Flags deprecated action/filter hooks |

## Deprecated function and hook detection

The WooCommerce deprecation sniffs compare your code against the WooCommerce deprecations list bundled with the package. This means:

- A function available in WooCommerce 3.x but removed in 5.x will produce a warning.
- Upgrade the `woocommerce/woocommerce-sniffs` package to update the list for newer WooCommerce versions.

```bash
# Update to check against the latest deprecations
composer update woocommerce/woocommerce-sniffs
```

## Example `.phpcs.xml.dist` for a WooCommerce extension

```xml
<?xml version="1.0"?>
<ruleset name="My WooCommerce Extension">
  <description>PHPCS ruleset for My WooCommerce Extension</description>

  <!-- Files to check -->
  <file>my-extension.php</file>
  <file>includes/</file>
  <file>src/</file>
  <file>templates/</file>

  <!-- Exclude patterns -->
  <exclude-pattern>*/vendor/*</exclude-pattern>
  <exclude-pattern>*/node_modules/*</exclude-pattern>
  <exclude-pattern>*/build/*</exclude-pattern>
  <exclude-pattern>*/tests/*</exclude-pattern>

  <!-- Display -->
  <arg value="sp" />
  <arg name="colors" />
  <arg name="extensions" value="php" />

  <!-- WordPress standards -->
  <rule ref="WordPress">
    <exclude name="WordPress.Files.FileName" />
  </rule>
  <rule ref="WordPress-Extra" />
  <rule ref="WordPress-Docs" />

  <!-- WooCommerce standard (deprecation detection + hook commenting) -->
  <rule ref="WooCommerce" />

  <!-- PHP version targets -->
  <config name="minimum_supported_wp_version" value="6.7" />
  <config name="testVersion" value="7.4-" />

  <!-- Text domain -->
  <rule ref="WordPress.WP.I18n">
    <properties>
      <property name="text_domain" type="array" value="my-extension" />
    </properties>
  </rule>

  <!-- Prefix enforcement -->
  <rule ref="WordPress.NamingConventions.PrefixAllGlobals">
    <properties>
      <property name="prefixes" type="array" value="my_extension,MyExtension" />
    </properties>
  </rule>

  <!-- Templates: relax doc requirements, WC templates deliberately omit full DocBlocks -->
  <rule ref="WordPress-Docs">
    <exclude-pattern>*/templates/*</exclude-pattern>
  </rule>
  <rule ref="WordPress.NamingConventions.PrefixAllGlobals">
    <exclude-pattern>*/templates/*</exclude-pattern>
  </rule>

</ruleset>
```

## Hook commenting convention

The `WooCommerce.Commenting.CommentHooks` sniff requires an `@hook` tag DocBlock before `add_action` / `add_filter` calls when they are inside a class method or at file scope outside of a function body.

```php
// BAD — no hook documentation
add_action( 'woocommerce_checkout_order_created', [ $this, 'on_order_created' ] );

// GOOD
/**
 * Fires after a new order is created at checkout.
 *
 * @hook woocommerce_checkout_order_created
 */
add_action( 'woocommerce_checkout_order_created', [ $this, 'on_order_created' ] );
```

To suppress this sniff globally if your team does not follow the WooCommerce hook comment style:

```xml
<rule ref="WooCommerce">
  <exclude name="WooCommerce.Commenting.CommentHooks" />
</rule>
```

## Handling WooCommerce deprecated function warnings

When a violation fires for a deprecated WooCommerce function, you have three options:

1. **Migrate to the replacement** (preferred):

   ```php
   // Deprecated (WC 3.0)
   $order->billing_email;

   // GOOD — use getter
   $order->get_billing_email();
   ```

2. **Add a version-gated fallback** when supporting older WooCommerce versions:

   ```php
   $email = method_exists( $order, 'get_billing_email' )
       ? $order->get_billing_email()
       : $order->billing_email; // phpcs:ignore WooCommerce.PHP.DeprecatedFunctions
   ```

3. **Suppress with reason** when the deprecated call is intentional:

   ```php
   // phpcs:ignore WooCommerce.PHP.DeprecatedFunctions.woocommerce_get_product_idFound -- Supporting WC < 3.0.
   $id = woocommerce_get_product_id( $sku );
   ```

## Minimum WooCommerce version configuration

If you declare a minimum WooCommerce version in your plugin headers, align `woocommerce-sniffs` accordingly. The package itself does not read your plugin headers — you manage this by keeping the package version up to date with your minimum supported WC version.

```bash
# See which WC version the currently installed sniffs target
composer show woocommerce/woocommerce-sniffs | grep versions
```
