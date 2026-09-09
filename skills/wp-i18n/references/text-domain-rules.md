# Text Domain Rules

## WordPress.org Requirements

WordPress.org enforces strict rules about text domains for plugins and themes hosted in the official directory. Violations will result in rejection during the review process.

---

## Rule 1: Text Domain Must Match the Plugin Slug

The text domain **must** be identical to the plugin's WordPress.org slug (the directory name in the SVN repository).

```
Plugin slug:    my-plugin
SVN URL:        https://plugins.svn.wordpress.org/my-plugin/
Text domain:    my-plugin   ← must be the same
```

### Plugin File Header

```php
<?php
/**
 * Plugin Name:       My Plugin
 * Plugin URI:        https://example.com/my-plugin
 * Description:       A WordPress plugin.
 * Version:           1.0.0
 * Author:            Plugin Author
 * Author URI:        https://example.com
 * License:           GPL v2 or later
 * License URI:       https://www.gnu.org/licenses/gpl-2.0.html
 * Text Domain:       my-plugin
 * Domain Path:       /languages
 */
```

---

## Rule 2: Use Hyphens, Not Underscores

WordPress.org slugs use hyphens (`-`), not underscores (`_`).

```php
// CORRECT
__( 'Hello World', 'my-plugin' );
load_plugin_textdomain( 'my-plugin', false, 'my-plugin/languages' );

// WRONG — underscores in text domain
__( 'Hello World', 'my_plugin' );
load_plugin_textdomain( 'my_plugin', false, 'my_plugin/languages' );
```

---

## Rule 3: Consistency Across PHP and JS

The same text domain string must be used in:

- Plugin file `Text Domain:` header
- `load_plugin_textdomain()` call
- All `__()`, `_e()`, `esc_html__()`, `esc_html_e()`, `_n()`, `_x()`, etc. calls in PHP
- All `__()`, `_n()`, `_x()`, `sprintf()` calls in JavaScript (via `@wordpress/i18n`)
- `"textdomain"` field in every `block.json`
- `wp_set_script_translations()` calls

---

## Rule 4: Domain Path Must Be Correct

The `Domain Path:` header in the plugin file should point to the `languages/` subdirectory:

```php
 * Domain Path:       /languages
```

And `load_plugin_textdomain` must reference the same path:

```php
load_plugin_textdomain(
    'my-plugin',
    false,
    dirname( plugin_basename( __FILE__ ) ) . '/languages'
);
```

---

## Auditing Text Domains

### Quick Grep Audit

```bash
# Find all text domain usages in PHP
grep -rn "'my-plugin'" --include="*.php" . | grep -E "__\(|_e\(|_n\(|_x\(|esc_html__|esc_attr__|esc_html_e\("

# Find mismatched text domains (replace 'my-plugin' with your slug)
grep -rn "load_plugin_textdomain\|Text Domain:" --include="*.php" .

# Find text domain in JS files
grep -rn "'my-plugin'" --include="*.js" src/
```

### WP-CLI Audit

```bash
# The --skip-audit flag is off by default, so make-pot will warn about issues
wp i18n make-pot . /dev/null --domain=my-plugin 2>&1
```

Common warnings from `make-pot`:
- `Warning: Could not extract the text domain from file.php`
- `Warning: Only the first text domain is used`

---

## Theme vs. Plugin Rules

| Aspect | Plugin | Theme |
|--------|--------|-------|
| Load function | `load_plugin_textdomain()` | `load_theme_textdomain()` |
| Hook | `init` | `after_setup_theme` |
| Path helper | `plugin_dir_path( __FILE__ )` | `get_template_directory()` |
| Domain source | Plugin file header | `style.css` `Text Domain:` header |

### Theme Example

```php
// In functions.php
function my_theme_setup() {
    load_theme_textdomain( 'my-theme', get_template_directory() . '/languages' );
}
add_action( 'after_setup_theme', 'my_theme_setup' );
```

---

## Common Mistakes and Fixes

### Using a Variable as Text Domain

```php
// WRONG — text domain must be a string literal
$domain = 'my-plugin';
__( 'Hello', $domain );

// CORRECT
__( 'Hello', 'my-plugin' );
```

WP-CLI and static analysis tools cannot detect variable text domains, and WordPress.org reviewers will flag this.

### Wrong Hook for load_plugin_textdomain

```php
// WRONG — too late
add_action( 'wp_loaded', 'my_plugin_load_textdomain' );

// CORRECT — use 'init'
add_action( 'init', 'my_plugin_load_textdomain' );
```

### Calling load_plugin_textdomain Inside a Class Constructor

```php
// Works but not recommended
class My_Plugin {
    public function __construct() {
        add_action( 'init', array( $this, 'load_textdomain' ) );
    }
    public function load_textdomain() {
        load_plugin_textdomain( 'my-plugin', false, dirname( plugin_basename( __FILE__ ) ) . '/languages' );
    }
}
```

### Missing Text Domain in block.json

```json
// WRONG — missing textdomain
{
  "name": "my-plugin/my-block",
  "title": "My Block"
}

// CORRECT
{
  "name": "my-plugin/my-block",
  "title": "My Block",
  "textdomain": "my-plugin"
}
```

---

## WordPress.org Review Checklist for i18n

Reviewers check for:

- [ ] `Text Domain:` header present and matches plugin slug
- [ ] `load_plugin_textdomain()` called with correct slug
- [ ] All user-facing strings wrapped in translation functions
- [ ] No variables used as text domain arguments
- [ ] No hardcoded translated strings (must use `__()` etc.)
- [ ] Correct escaping used with translation functions (`esc_html__()`, `esc_attr__()`)
