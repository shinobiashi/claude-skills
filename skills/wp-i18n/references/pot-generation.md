# POT File Generation

## WP-CLI `make-pot` Command

The `wp i18n make-pot` command scans PHP, JS, and block.json files for translatable strings and generates a `.pot` template file.

### Basic Usage

```bash
wp i18n make-pot . languages/my-plugin.pot --domain=my-plugin
```

### Full Options Reference

```bash
wp i18n make-pot <source> [<destination>] [--slug=<slug>] [--domain=<domain>]
    [--ignore-domain] [--merge[=<paths>]] [--subtract=<paths>]
    [--subtract-and-merge] [--include=<paths>] [--exclude=<paths>]
    [--headers=<headers>] [--location] [--no-location]
    [--skip-js] [--skip-php] [--skip-block-json] [--skip-theme-json]
    [--skip-audit] [--file-comment=<file-comment>]
    [--package-name=<name>]
```

### Recommended Production Command

```bash
wp i18n make-pot . languages/my-plugin.pot \
    --domain=my-plugin \
    --exclude=vendor,node_modules,tests,build,.git \
    --headers='{"Report-Msgid-Bugs-To":"https://wordpress.org/support/plugin/my-plugin","POT-Creation-Date":"2024-01-01","Last-Translator":"Translators <translators@example.com>","Language-Team":"English <en@li.org>"}'
```

### Exclude Patterns

Use `--exclude` to skip directories and files that should not be scanned:

```bash
--exclude=vendor,node_modules,tests,bin,build,.git,tmp
```

Patterns support glob syntax:
```bash
--exclude="vendor,tests/**,docs/**,*.min.js"
```

### Scanning Only Specific Paths

```bash
# Only scan src/ and includes/ directories
wp i18n make-pot . languages/my-plugin.pot \
    --domain=my-plugin \
    --include=src,includes
```

### Merging Existing .pot Files

When you want to keep manual translations that don't exist in source:

```bash
wp i18n make-pot . languages/my-plugin.pot \
    --domain=my-plugin \
    --merge=languages/my-plugin.pot
```

---

## npm Scripts Integration

Add i18n scripts to `package.json` for a consistent workflow:

### Basic Setup

```json
{
  "scripts": {
    "i18n:pot": "wp i18n make-pot . languages/my-plugin.pot --domain=my-plugin --exclude=vendor,node_modules,tests,build",
    "i18n:json": "wp i18n make-json languages/ --no-purge",
    "i18n": "npm run i18n:pot && npm run i18n:json"
  }
}
```

### With @wordpress/scripts

If using `@wordpress/scripts`, you can combine with the build step:

```json
{
  "scripts": {
    "build": "wp-scripts build",
    "build:i18n": "npm run build && npm run i18n",
    "i18n:pot": "wp i18n make-pot . languages/my-plugin.pot --domain=my-plugin --exclude=vendor,node_modules,tests,build",
    "i18n:json": "wp i18n make-json languages/ --no-purge"
  }
}
```

---

## Languages Directory Structure

After running `make-pot` and `make-json`, the `languages/` directory should look like:

```
languages/
├── my-plugin.pot              # Template for translators
├── my-plugin-ja.po            # Japanese translation source
├── my-plugin-ja.mo            # Compiled binary (for PHP)
├── my-plugin-ja.l10n.php      # PHP translations (OPcache; loaded instead of .mo)
├── my-plugin-ja-{hash}.json   # JS/block translations
├── my-plugin-de_DE.po
├── my-plugin-de_DE.mo
├── my-plugin-de_DE.l10n.php
└── my-plugin-de_DE-{hash}.json
```

Generate the `.l10n.php` files from `.po` with `wp i18n make-php languages/`. When present, WordPress loads them instead of `.mo` and benefits from PHP OPcache — the biggest runtime i18n win. Recommended for bundled locales, especially when distributing outside WordPress.org.

---

## Validating .pot Output

After generation, verify the `.pot` file:

```bash
# Check the number of strings extracted
grep -c '^msgid ' languages/my-plugin.pot

# View the header
head -40 languages/my-plugin.pot

# Check for untranslated placeholders or encoding issues
wp i18n make-pot . /dev/null --domain=my-plugin 2>&1 | grep -i "warning\|error"
```

---

## Common Issues

### Variables Used as Translatable Strings

WP-CLI's parser requires string literals, not variables:

```php
// WRONG — will not be extracted
$label = 'Save changes';
__( $label, 'my-plugin' );

// CORRECT — will be extracted
__( 'Save changes', 'my-plugin' );
```

### Translatable Strings in Concatenation

Avoid string concatenation inside translation functions:

```php
// WRONG
__( 'Hello ' . $name, 'my-plugin' );

// CORRECT — use sprintf
sprintf( __( 'Hello %s', 'my-plugin' ), $name );
```

### JS Strings Not Extracted

Ensure JS files are not excluded and that `@wordpress/i18n` functions are used:

```js
import { __, _n, sprintf } from '@wordpress/i18n';

const label = __( 'Save changes', 'my-plugin' );
const message = sprintf(
    _n( '%d item', '%d items', count, 'my-plugin' ),
    count
);
```
