# translate.wordpress.org — Submitting and Managing Translations

## Overview

translate.wordpress.org (GlotPress) is the official translation platform for all WordPress.org-hosted plugins and themes. Once your plugin is published on WordPress.org, the translation infrastructure is automatically available.

**URL pattern:** `https://translate.wordpress.org/projects/wp-plugins/{slug}/`

Example: `https://translate.wordpress.org/projects/wp-plugins/my-plugin/`

---

## How It Works

1. You publish a plugin on WordPress.org via SVN
2. WordPress.org automatically detects the `languages/{slug}.pot` file in SVN trunk
3. GlotPress imports the strings from your `.pot` file
4. Community translators contribute translations through the web UI
5. WordPress sites download approved translations via the WordPress.org Translations API

### Automatic .pot Import

WordPress.org scans the following locations for `.pot` files (in order of preference):

1. `languages/{slug}.pot`
2. `languages/{slug}-{version}.pot`
3. Any `.pot` file in `languages/`

Keep your `.pot` file at `languages/my-plugin.pot` for reliable detection.

---

## Initial Setup

### Step 1: Publish on WordPress.org

Your plugin must be approved and published before translations infrastructure is available.

Review submission URL: `https://wordpress.org/plugins/developers/add/`

### Step 2: Commit .pot File to SVN Trunk

```bash
# After running wp i18n make-pot
svn add languages/my-plugin.pot
svn commit -m "Add POT file for translations"
```

### Step 3: Wait for Import

After committing, GlotPress will import strings within 24-48 hours. Check:
`https://translate.wordpress.org/projects/wp-plugins/my-plugin/`

---

## Translation Approval Process

Translations go through a review workflow:

```
Contributor submits translation
    ↓
Status: "Waiting" (awaiting review)
    ↓
Translation Editor or PTE approves
    ↓
Status: "Current" (approved, available for download)
```

### Translation Roles

| Role | Scope | Description |
|------|-------|-------------|
| General Translation Editor (GTE) | Global | Can approve for all projects in a locale |
| Project Translation Editor (PTE) | Per project | Can approve translations for your plugin |
| Contributor | Per project | Can suggest translations (need approval) |

### Requesting a PTE for Your Plugin

If you want to manage translations for your own plugin:

1. Go to `https://make.wordpress.org/polyglots/`
2. Create a post using the template for PTE requests
3. Tag it with the locale code (e.g., `#ja`, `#de`)

Template:
```
I'd like to request PTE status for [Your Name] for the [Plugin Name] plugin.
- Plugin: https://wordpress.org/plugins/my-plugin/
- GlotPress: https://translate.wordpress.org/projects/wp-plugins/my-plugin/
```

---

## Translation Completeness for Language Packs

WordPress.org generates language packs (`.zip` files with `.po`/`.mo`/`.json`) when a locale reaches **95% translation** for the `stable` sub-project.

Language packs are distributed via `api.wordpress.org/translations/plugins/1.0/`.

### Sub-projects

GlotPress creates sub-projects for different release branches:

- `stable` — current stable version (from SVN `tags/{version}/`)
- `dev` — development version (from SVN `trunk/`)
- `stable-readme` — readme.txt translations

---

## Updating Translations After a New Release

When you release a new version:

1. Update `languages/my-plugin.pot` with new/changed strings
2. Commit to SVN trunk AND copy to tags:

```bash
# Update pot in trunk
wp i18n make-pot . languages/my-plugin.pot --domain=my-plugin
svn commit -m "Update POT for version 2.0.0"

# Copy trunk to new tag
svn copy https://plugins.svn.wordpress.org/my-plugin/trunk \
         https://plugins.svn.wordpress.org/my-plugin/tags/2.0.0 \
         -m "Tagging version 2.0.0"
```

GlotPress will detect new strings and mark existing translations as "fuzzy" if the original string changed.

---

## Downloading Translations Locally

To test translations or bundle them with your plugin:

```bash
# Download a specific locale's translations (via WordPress.org API)
curl "https://api.wordpress.org/translations/plugins/1.0/?slug=my-plugin&version=1.0.0" \
    | jq '.translations[] | select(.language == "ja") | .package'

# Download and extract
wp language plugin install my-plugin --all
```

---

## GlotPress Translation Statuses

| Status | Meaning |
|--------|---------|
| `current` | Approved and active |
| `waiting` | Submitted, awaiting review |
| `fuzzy` | Source string changed, needs review |
| `old` | Superseded by a newer `current` entry |
| `rejected` | Declined by a translation editor |
| `changesrequested` | Needs modification before approval |

---

## For Plugins NOT on WordPress.org

If your plugin is not hosted on WordPress.org, you must handle translations yourself:

### Option 1: Bundle .mo files

Generate `.po` files manually, compile to `.mo`, and ship them in the `languages/` directory:

```bash
# Compile .po to .mo using msgfmt
msgfmt languages/my-plugin-ja.po -o languages/my-plugin-ja.mo
```

### Option 2: Custom Translation Loading

```php
// Load from a custom path
add_action( 'init', function() {
    $locale = determine_locale();
    $mofile = WP_LANG_DIR . '/plugins/my-plugin-' . $locale . '.mo';

    if ( ! load_textdomain( 'my-plugin', $mofile ) ) {
        // Fallback to plugin's own languages directory
        load_plugin_textdomain(
            'my-plugin',
            false,
            dirname( plugin_basename( __FILE__ ) ) . '/languages'
        );
    }
} );
```

### Option 3: Use translate.wordpress.org for Commercial Plugins

Some commercial plugins use the Translating WordPress.org API by pointing their translations to GlotPress. This requires a wordpress.org account and coordination with the Polyglots team.
