---
name: wp-i18n
version: "1.1.0"
description: "Use when setting up internationalization (i18n/l10n) for WordPress plugins or themes: text domain configuration, POT file generation, block JSON translations (make-json), wp_set_script_translations, and submitting to translate.wordpress.org."
compatibility: "Targets WordPress 6.6+. Requires WP-CLI 2.x. Node.js / @wordpress/scripts required for JS/block translation workflows."
---

# WP i18n (Internationalization)

## When to use

Use this skill when working on WordPress plugin or theme internationalization, for example:

- Setting up or auditing text domain configuration (plugin header, `load_plugin_textdomain`)
- Generating or regenerating `.pot` files for translators
- Adding a single new string to a bundled `.pot` / `.po` / `.mo` by hand inside a feature PR (no `msgmerge`)
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

### 3b) Add one string by hand inside a feature PR

A feature or fix PR that adds a user-facing PHP string should not regenerate the translation files: `msgmerge --update`
against a `.pot` that has not been regenerated for a while drops long-obsolete entries and rewraps the whole `.po`, so one
new string becomes a 1000+ line diff. Add only the new entry, and leave a full resync to a dedicated POT-regeneration PR.

`scripts/po-add-entry.py` does this and checks the result (python3 + GNU gettext `msgfmt` / `msgcat`):

```bash
P=<this skill's base directory>/scripts/po-add-entry.py

python3 "$P" --msgid 'Payment failed. Please try again.' \
    --pot i18n/my-plugin.pot \
    --po i18n/my-plugin-ja.po --msgstr '決済に失敗しました。もう一度お試しください。'
# _n(): --msgid-plural '%d items' and one --msgstr per plural form of the .po (ja: 1)
# _x(): --context 'noun'    translators comment: --comment 'translators: %s: order number'
# --ref PATH:LINE (repeatable) when the string is not a literal first argument of a gettext call
# --after '<existing msgid>' to place it next to a related entry; --dry-run to only print
```

- **References**: `git grep` finds the string as the first argument of a gettext call in the PHP files (untracked
  ones too), skipping `vendor/`, `node_modules/`, `test/` and `tests/` like `make-pot`. For `__(` alone on a line, the
  reference is the call's line, as WP-CLI writes it.
- **Placement and style**: next to the entry with the nearest earlier reference in the same source file, in each file's
  own style — one `#:` line per reference and no wrapping for a WP-CLI `.pot`, gettext wrapping at 79 columns (`msgcat`,
  which matches Poedit and `msgmerge`) for a wrapped `.po`. `#, php-format` is added the way `make-pot` decides it
  (same placeholder regex), and `msgfmt --check-format` checks the translation's placeholders.
- **The `.mo` check**: the `.mo` is rebuilt with `msgfmt` and compared with the old one entry by entry. Any difference
  besides the new string means the old `.mo` was not built from this `.po`; nothing is written (`--accept-mo-drift` keeps
  it anyway — better rebuild the `.mo` in its own commit first). With a `.l10n.php` next to the `.po`, it says to
  regenerate that too, since WordPress 6.5+ loads it instead of the `.mo`.
- **Already there**: a `.pot` that already has the entry is left alone (so one run per locale works); a `.po` that has it
  is refused — edit that entry by hand.
- Exit codes: `0` done (with `--dry-run`: would be done) / `1` refused or a check failed, nothing written / `2` usage or
  setup error (including a string it cannot find without `--ref`).
- PHP strings only. A string used by a script also needs its `{domain}-{locale}-{md5}.json` entry (step 4).
- A translation in the bundled `.po` / `.mo` reaches only sites without a WordPress.org language pack (the pack wins);
  also add it on translate.wordpress.org (step 8).
- Tests: `bash scripts/test-po-add-entry.sh "$PWD/scripts/po-add-entry.py"` (60 scenarios, no network; the path must be
  absolute).

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
