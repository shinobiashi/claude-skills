# PHPCS Configuration (WordPress)

This reference documents the full `.phpcs.xml.dist` setup for WordPress plugins and themes.

## Difference between `.phpcs.xml.dist` and `.phpcs.xml`

| File | Purpose |
|---|---|
| `.phpcs.xml.dist` | Committed to version control; the shared team standard |
| `.phpcs.xml` | Local override (add to `.gitignore`); not committed |

PHPCS searches for config files in this order: `.phpcs.xml`, `phpcs.xml`, `.phpcs.xml.dist`, `phpcs.xml.dist`. The local `.phpcs.xml` always wins over the committed `.dist` file.

## Full annotated template for a WooCommerce plugin

```xml
<?xml version="1.0"?>
<ruleset name="My WooCommerce Plugin">
  <description>PHPCS ruleset for My WooCommerce Plugin</description>

  <!-- =====================================================================
       FILES TO CHECK
       List the plugin entry file and each first-party source directory.
       ===================================================================== -->
  <file>my-plugin.php</file>
  <file>includes/</file>
  <file>src/</file>
  <file>templates/</file>

  <!-- =====================================================================
       EXCLUDE PATTERNS
       Paths matched here are skipped even if listed under <file> above.
       Use */dir/* to match at any depth.
       ===================================================================== -->
  <exclude-pattern>*/vendor/*</exclude-pattern>
  <exclude-pattern>*/node_modules/*</exclude-pattern>
  <exclude-pattern>*/build/*</exclude-pattern>
  <exclude-pattern>*/bin/*</exclude-pattern>
  <!-- Exclude tests if you prefer a separate ruleset for them -->
  <exclude-pattern>*/tests/*</exclude-pattern>
  <exclude-pattern>*/Test/*</exclude-pattern>
  <!-- Exclude generated or minified files -->
  <exclude-pattern>*.min.js</exclude-pattern>
  <exclude-pattern>*.min.css</exclude-pattern>

  <!-- =====================================================================
       DISPLAY
       Show sniff codes in output so you can target them precisely.
       ===================================================================== -->
  <arg value="sp" /><!-- Show sniff codes and progress -->
  <arg name="colors" />
  <arg name="extensions" value="php" />

  <!-- =====================================================================
       STANDARDS
       WordPress  = WordPress-Core + WordPress-Extra + WordPress-Docs
       Start with WordPress, then add individual sub-rulesets for clarity.
       ===================================================================== -->
  <rule ref="WordPress">
    <!--
      Exclude WordPress.Files.FileName when using PSR-4 autoloading
      (class files named after the class, not WordPress snake_case convention).
      Safe to exclude for modern plugins using Composer autoloading.
    -->
    <exclude name="WordPress.Files.FileName" />
  </rule>

  <!-- WordPress-Extra adds stricter rules on top of WordPress-Core -->
  <rule ref="WordPress-Extra" />

  <!-- WordPress-Docs enforces inline documentation standards -->
  <rule ref="WordPress-Docs" />

  <!-- =====================================================================
       PHP VERSION AND WP VERSION TARGETS
       testVersion drives PHPCompatibility checks (min-max PHP range).
       "7.4-" means PHP 7.4 and above (no upper bound).
       ===================================================================== -->
  <config name="minimum_supported_wp_version" value="6.7" />
  <config name="testVersion" value="7.4-" />

  <!-- =====================================================================
       TEXT DOMAIN ENFORCEMENT
       List all text domains used in the plugin.
       ===================================================================== -->
  <rule ref="WordPress.WP.I18n">
    <properties>
      <property name="text_domain" type="array" value="my-plugin" />
    </properties>
  </rule>

  <!-- =====================================================================
       GLOBAL PREFIX ENFORCEMENT
       List every prefix (function prefix and class namespace root).
       ===================================================================== -->
  <rule ref="WordPress.NamingConventions.PrefixAllGlobals">
    <properties>
      <property name="prefixes" type="array" value="my_plugin,MyPlugin" />
    </properties>
  </rule>

  <!-- =====================================================================
       PER-DIRECTORY RULE OVERRIDES
       Example: relax rules inside templates/ where HTML mixed with PHP
       is intentional and full DocBlocks are not expected.
       ===================================================================== -->
  <rule ref="WordPress-Docs">
    <exclude-pattern>*/templates/*</exclude-pattern>
  </rule>

</ruleset>
```

## Common `<exclude-pattern>` patterns

```xml
<!-- Entire vendor directory at any depth -->
<exclude-pattern>*/vendor/*</exclude-pattern>

<!-- A specific legacy file you are not ready to fix yet -->
<exclude-pattern>includes/legacy/class-old-thing.php</exclude-pattern>

<!-- All files inside a directory -->
<exclude-pattern>src/generated/*</exclude-pattern>

<!-- Files matching a glob pattern -->
<exclude-pattern>*-template.php</exclude-pattern>
```

## `minimum_supported_wp_version` and `testVersion`

`minimum_supported_wp_version` controls which WordPress-version-dependent deprecation warnings fire (e.g. functions deprecated before this version are flagged).

`testVersion` is consumed by the `PHPCompatibility` standard (if installed). Format:

| Value | Meaning |
|---|---|
| `7.4-` | PHP 7.4 and newer (open upper bound) |
| `7.4-8.3` | PHP 7.4 through 8.3 |
| `8.0` | Exactly PHP 8.0 |

If `PHPCompatibility` is not installed, `testVersion` is silently ignored.

## Per-directory rule overrides

You can enable or disable specific rules for a subset of files:

```xml
<!-- Disable nonce check requirement inside REST API handlers
     that use permission_callback instead -->
<rule ref="WordPress.Security.NonceVerification">
  <exclude-pattern>*/rest-api/*</exclude-pattern>
</rule>

<!-- Allow direct DB queries in a migration script -->
<rule ref="WordPress.DB.DirectDatabaseQuery">
  <exclude-pattern>*/migrations/*</exclude-pattern>
</rule>
```

## Running PHPCS on a single file

```bash
# Lint one file
vendor/bin/phpcs path/to/File.php

# Auto-fix one file
vendor/bin/phpcbf path/to/File.php

# Show specific sniff details
vendor/bin/phpcs --standard=WordPress path/to/File.php -s
```

## GitHub Actions integration example

```yaml
name: PHPCS

on: [push, pull_request]

jobs:
  phpcs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - name: Setup PHP
        uses: shivammathur/setup-php@v2
        with:
          php-version: '8.3'
          tools: composer

      - name: Install dependencies
        run: composer install --no-progress --prefer-dist

      - name: Run PHPCS
        run: composer run phpcs
```
