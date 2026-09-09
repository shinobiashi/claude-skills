---
name: wp-i18n
version: "1.0.0"
description: "Use when setting up internationalization (i18n/l10n) for WordPress plugins or themes: text domain configuration, POT file generation, block JSON translations (make-json), wp_set_script_translations, and submitting to translate.wordpress.org."
compatibility: "Targets WordPress 6.6+. Requires WP-CLI 2.x. Node.js / @wordpress/scripts required for JS/block translation workflows."
---

# WP i18n (Internationalization)

## When to use

Use this skill when working on WordPress plugin or theme internationalization, for example:

- Setting up or auditing text domain configuration (plugin header, `load_plugin_textdomain`)
- Generating or regenerating `.pot` files for translators
- Generating block translation JSON files (`wp i18n make-json`)
- Registering `wp_set_script_translations` for JS/block scripts
- Adding `i18n` npm scripts to `package.json`
- Submitting `.pot` files to translate.wordpress.org

## Inputs required

- Plugin/theme slug (must match the text domain exactly — use hyphens, not underscores)
- Whether the plugin contains Gutenberg blocks (affects block JSON translation setup)
- Whether WP-CLI is available in the local environment
- Whether `@wordpress/scripts` is used for the build pipeline

## Procedure

### 1) Audit text domain consistency

Check that all three locations use the same text domain string:

1. Plugin file header: `Text Domain: my-plugin`
2. PHP calls: `load_plugin_textdomain( 'my-plugin', ... )`
3. All `__()`, `_e()`, `esc_html__()`, etc. calls use `'my-plugin'` as the second argument

Common mistakes to look for:
- Using underscores instead of hyphens (`my_plugin` vs `my-plugin`)
- Hardcoding a different slug in `load_plugin_textdomain` than in the plugin header
- Missing `Text Domain:` line in the plugin header entirely
- Using `get_template_directory()` in a plugin (use `plugin_dir_path()`)

See: `references/text-domain-rules.md`

### 2) Register `load_plugin_textdomain` (PHP side)

Ensure textdomain loading is hooked early:

```php
add_action( 'init', 'my_plugin_load_textdomain' );
function my_plugin_load_textdomain() {
    load_plugin_textdomain(
        'my-plugin',
        false,
        dirname( plugin_basename( __FILE__ ) ) . '/languages'
    );
}
```

For themes, use `load_theme_textdomain()` hooked on `after_setup_theme`.

### 3) Generate the .pot file

**With WP-CLI (preferred):**

```bash
wp i18n make-pot . languages/my-plugin.pot \
    --domain=my-plugin \
    --exclude=vendor,node_modules,tests,build \
    --headers='{"Report-Msgid-Bugs-To":"https://wordpress.org/support/plugin/my-plugin","POT-Creation-Date":"2024-01-01"}'
```

**With npm scripts (add to `package.json`):**

```json
{
  "scripts": {
    "i18n:pot": "wp i18n make-pot . languages/my-plugin.pot --domain=my-plugin --exclude=vendor,node_modules,tests,build",
    "i18n:json": "wp i18n make-json languages/ --no-purge",
    "i18n:php": "wp i18n make-php languages/",
    "i18n": "npm run i18n:pot && npm run i18n:json && npm run i18n:php"
  }
}
```

See: `references/pot-generation.md`

### 4) Generate block translation JSON files (if blocks exist)

After generating the `.pot` file and obtaining `.po` files from translators:

```bash
# Generate JSON files from .po files
wp i18n make-json languages/ --no-purge

# This creates files like:
# languages/my-plugin-ja-my-plugin-editor-script.json
# languages/my-plugin-ja-my-plugin-view-script.json
```

The `--no-purge` flag preserves original `.po` files.

See: `references/block-json-translations.md`

### 4b) Generate `.l10n.php` PHP translation files (best practice)

`.l10n.php` translation files (Performant Translations, in core since WP 6.5) are loaded instead of `.mo` when present and leverage PHP OPcache — the single biggest i18n runtime win. Generate them from your `.po` files:

```bash
# Creates languages/my-plugin-{locale}.l10n.php from each .po file
wp i18n make-php languages/
```

Ship `.l10n.php` alongside `.mo` for bundled locales, especially when distributing outside WordPress.org (where language packs won't generate them for you). `make-pot` and `make-json` are unchanged.

### 5) Register `wp_set_script_translations` (blocks / JS)

For each registered JS/block script that contains translatable strings:

```php
add_action( 'enqueue_block_editor_assets', 'my_plugin_set_script_translations' );
function my_plugin_set_script_translations() {
    wp_set_script_translations(
        'my-plugin-editor-script', // script handle
        'my-plugin',               // text domain
        plugin_dir_path( __FILE__ ) . 'languages'
    );
}
```

For blocks registered via `block.json`, ensure `"textdomain": "my-plugin"` is set and use:

```php
register_block_type( __DIR__ . '/build' ); // block.json is read automatically
// wp_set_script_translations must still be called separately
```

See: `references/block-json-translations.md`

### 6) Verify `block.json` textdomain fields

Each `block.json` must declare the `textdomain`:

```json
{
  "name": "my-plugin/my-block",
  "title": "My Block",
  "textdomain": "my-plugin",
  "editorScript": "file:./index.js"
}
```

### 7) Add language directory to `.gitignore` (selectively)

Commit `.pot` files and any bundled `.po`/`.mo` files, but ignore compiled assets if auto-generated:

```
# .gitignore — example for i18n
!languages/
languages/*.mo   # optional: exclude compiled binaries if generated on deploy
```

### 8) Submit .pot to translate.wordpress.org

1. Ensure the plugin is published on WordPress.org
2. The `.pot` file is auto-detected from `languages/{slug}.pot` in the SVN trunk
3. Translations are managed at `https://translate.wordpress.org/projects/wp-plugins/{slug}/`

See: `references/wp-org-translations.md`

## Verification

- Run `wp i18n make-pot` and confirm the output file contains expected strings
- Run `wp i18n make-json` and confirm JSON files appear in `languages/`
- In the WordPress admin, switch locale to a translated language and confirm strings load
- Use Query Monitor or `WP_DEBUG` to surface any `__doing_it_wrong` notices for textdomain

## Failure modes / debugging

- **Strings not loading in JS**: Check that `wp_set_script_translations` uses the exact script handle registered with `wp_register_script` / `wp_enqueue_script`
- **`make-json` produces no files**: Ensure `.po` files exist in `languages/` and are named `{domain}-{locale}.po`
- **Text domain mismatch warning**: `load_plugin_textdomain` was called with a slug that doesn't match `Text Domain:` header
- **Missing strings in .pot**: Verify `__()`, `_n()`, `_x()` etc. use string literals (not variables) as the first argument — WP-CLI's parser requires this

## Escalation

- If the plugin does not yet have a WordPress.org listing, translate.wordpress.org is not available — advise bundling translations or using a custom translation loading approach
- If the codebase uses a build step that transforms JS (e.g. Webpack), confirm the built file handles are used in `wp_set_script_translations`, not source handles
