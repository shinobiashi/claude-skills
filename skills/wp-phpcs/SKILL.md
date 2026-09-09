---
name: wp-phpcs
version: "1.0.0"
description: "Use when setting up, configuring, or running PHP_CodeSniffer (PHPCS/PHPCBF) in WordPress projects: .phpcs.xml.dist setup, WordPress-Coding-Standards installation, running phpcs/phpcbf, fixing common violations, and integrating with composer scripts and CI."
compatibility: "Targets WordPress Coding Standards 3.3.0 with PHP_CodeSniffer 3.13.x. Requires Composer. Note: PHPCS 4.0 is released but WPCS does not yet support it — stay on PHPCS 3.13.x for WordPress work."
---

# WP PHP_CodeSniffer (PHPCS)

## When to use

Use this skill when working on PHP_CodeSniffer in a WordPress plugin or theme, for example:

- Setting up PHPCS in a new WordPress plugin/theme project
- Updating an existing `.phpcs.xml.dist` configuration
- Running `phpcs` to find violations or `phpcbf` to auto-fix them
- Fixing specific PHPCS errors/warnings in PHP files
- Adding PHPCS to composer scripts or GitHub Actions CI

## Inputs required

- Project type (plugin vs. theme)
- Plugin text domain and PHP/namespace prefix
- PHP minimum version for the project
- Whether WooCommerce-specific rules are needed

## Procedure

### 0) Discover existing PHPCS setup

Check what is already in place before making changes:

```bash
# Look for existing config files
ls .phpcs.xml .phpcs.xml.dist phpcs.xml phpcs.xml.dist 2>/dev/null

# Check composer.json for existing packages and scripts
cat composer.json | grep -A5 '"phpcs\|phpcbf\|wpcs\|php_codesniffer"'

# Confirm installed binary and registered standards
vendor/bin/phpcs --version
vendor/bin/phpcs -i
```

If a composer script already exists (e.g. `composer run phpcs`), prefer that over calling the binary directly.

### 1) Install PHPCS and WordPress Coding Standards

```bash
composer require --dev \
  "squizlabs/php_codesniffer:^3.13.4" \
  "wp-coding-standards/wpcs:^3.3" \
  dealerdirect/phpcodesniffer-composer-installer
```

> **Stay on PHPCS 3.13.x.** PHPCS 4.0 is released (4.0.1), but WPCS 3.3.0 requires
> `squizlabs/php_codesniffer ^3.13.4` and does not yet support 4.0 — pinning avoids Composer
> resolving an incompatible major. (WPCS latest is 3.3.0; it pulls in PHPCSUtils ^1.1 and
> PHPCSExtra ^1.5.)

`dealerdirect/phpcodesniffer-composer-installer` auto-registers all installed standards paths — no manual `--config-set installed_paths` needed.

For WooCommerce extension projects, also add:

```bash
composer require --dev woocommerce/woocommerce-sniffs
```

Verify after install:

```bash
vendor/bin/phpcs -i
# Expected output includes: WordPress, WordPress-Core, WordPress-Docs, WordPress-Extra
```

### 2) Create `.phpcs.xml.dist`

Place the config at the project root. Commit `.phpcs.xml.dist`; add `.phpcs.xml` to `.gitignore` for local overrides.

Template for a typical WordPress plugin:

```xml
<?xml version="1.0"?>
<ruleset name="My Plugin">
  <description>PHPCS ruleset for My Plugin</description>

  <!-- Files to check -->
  <file>my-plugin.php</file>
  <file>includes/</file>
  <file>src/</file>

  <!-- Exclude patterns -->
  <exclude-pattern>*/vendor/*</exclude-pattern>
  <exclude-pattern>*/node_modules/*</exclude-pattern>
  <exclude-pattern>*/build/*</exclude-pattern>
  <exclude-pattern>*/tests/*</exclude-pattern>

  <!-- Standards -->
  <rule ref="WordPress">
    <!-- Allow PSR-4 class file naming (common in modern plugins) -->
    <exclude name="WordPress.Files.FileName" />
  </rule>
  <rule ref="WordPress-Extra" />
  <rule ref="WordPress-Docs" />

  <!-- PHP compatibility target -->
  <config name="minimum_supported_wp_version" value="6.7" />
  <config name="testVersion" value="7.4-" />

  <!-- Text domain check -->
  <rule ref="WordPress.WP.I18n">
    <properties>
      <property name="text_domain" type="array" value="my-plugin" />
    </properties>
  </rule>

  <!-- Global prefix enforcement -->
  <rule ref="WordPress.NamingConventions.PrefixAllGlobals">
    <properties>
      <property name="prefixes" type="array" value="my_plugin,MyPlugin" />
    </properties>
  </rule>
</ruleset>
```

See `references/configuration.md` for the full annotated template, per-directory rule overrides, and WooCommerce-specific additions.

### 3) Add composer scripts

```json
"scripts": {
  "phpcs": "vendor/bin/phpcs",
  "phpcbf": "vendor/bin/phpcbf",
  "lint": ["@phpcs"]
}
```

Usage:

```bash
composer run phpcs    # find violations
composer run phpcbf   # auto-fix safe violations
```

### 4) Fix violations

Run `phpcbf` first to auto-fix formatting and safe issues, then handle remaining errors manually:

```bash
composer run phpcbf
composer run phpcs
```

For the most common violation types and their fixes, see `references/common-violations.md`.

### 5) Verification

```bash
composer run phpcs
# Must exit 0 with no errors or warnings reported
```

No new violations should be introduced by any change. If CI is set up, confirm the workflow passes.

## Failure modes / debugging

- **"Referenced sniff ... does not exist"**: run `vendor/bin/phpcs -i` to confirm standards are installed. Re-run `composer install` if `dealerdirect` plugin did not register paths.
- **High violation count on first run**: run `phpcbf` first, then triage remaining issues. Consider adding `<exclude-pattern>` for legacy directories you are not ready to clean up yet.
- **PSR-4 filenames conflicting with `WordPress.Files.FileName`**: exclude that sniff as shown in step 2 — this is intentional and acceptable for modern plugins using class autoloading.
- **`minimum_supported_wp_version` not recognized**: confirm `wp-coding-standards/wpcs` is installed (not just `squizlabs/php_codesniffer`).
- **WooCommerce sniffs not found after install**: run `vendor/bin/phpcs -i`; if `WooCommerce` is missing, check that `dealerdirect/phpcodesniffer-composer-installer` ran its post-install script (`composer install` from scratch, or `composer run-script post-install-cmd`).

## Escalation

- If the project mixes generated code (e.g. block build output) in PHP-tracked directories, confirm which paths to exclude before adding `<exclude-pattern>` entries.
- If a WooCommerce sniff version is incompatible with the installed PHPCS version, confirm package constraints with the user before changing `composer.json`.
