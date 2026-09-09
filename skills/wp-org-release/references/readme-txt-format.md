# readme.txt Format

## Overview

`readme.txt` is the primary metadata and documentation file for WordPress.org plugins. It uses a custom Markdown-like format and is parsed by the WordPress.org plugin directory to generate the plugin page.

Validator tool: `https://wordpress.org/plugins/developers/readme-validator/`

---

## Complete Template

```
=== Plugin Name ===
Contributors:      myusername, contributor2
Donate link:       https://example.com/donate
Tags:              keyword1, keyword2, keyword3, keyword4, keyword5
Requires at least: 6.4
Tested up to:      7.0
Stable tag:        1.2.0
Requires PHP:      7.4
License:           GPLv2 or later
License URI:       https://www.gnu.org/licenses/gpl-2.0.html

Short description of the plugin. Keep it under 150 characters. No markup allowed.

== Description ==

Full description of your plugin. This supports Markdown-like formatting.

**Bold text** and *italic text* are supported.

Features:
* Feature one
* Feature two
* Feature three

== Installation ==

1. Upload the plugin files to the `/wp-content/plugins/my-plugin` directory, or install through the WordPress plugins screen.
2. Activate the plugin through the 'Plugins' screen in WordPress.
3. Use the Settings > My Plugin screen to configure the plugin.

== Frequently Asked Questions ==

= What does this plugin do? =

It does something useful.

= Is it compatible with WooCommerce? =

Yes, it works with WooCommerce 8.0 and later.

== Screenshots ==

1. The main settings page.
2. The plugin in action on the front end.
3. Example of a block in the editor.

== Changelog ==

= 1.2.0 =
* Added: New feature X
* Added: Support for WordPress 7.0
* Fixed: Bug where Y was broken
* Changed: Improved performance of Z

= 1.1.0 =
* Added: Feature W
* Fixed: Initial bug fixes

= 1.0.0 =
* Initial release

== Upgrade Notice ==

= 1.2.0 =
This update includes an important security fix. Please update immediately.

= 1.1.0 =
Minor bug fixes and improvements.
```

---

## Required Headers

These headers must be present in the plugin file header block at the top of `readme.txt`:

| Header | Required | Notes |
|--------|----------|-------|
| `Plugin Name` | Yes | The `=== Plugin Name ===` title line |
| `Contributors` | Yes | Comma-separated wordpress.org usernames |
| `Tags` | Yes | Up to 5 tags |
| `Requires at least` | Yes | Minimum WordPress version |
| `Tested up to` | Yes | Latest WP version tested against |
| `Stable tag` | Yes | Must match SVN tag exactly |
| `License` | Yes | Must be GPL v2 or later |
| `License URI` | Yes | URL to the license text |
| Short description | Yes | First paragraph after headers (150 chars max) |

## Optional Headers

| Header | Notes |
|--------|-------|
| `Donate link` | URL for donations |
| `Requires PHP` | Minimum PHP version |
| `WC requires at least` | Minimum WooCommerce version (for WC plugins) |
| `WC tested up to` | Latest WooCommerce version tested against |

---

## Required Sections

| Section | Required | Notes |
|---------|----------|-------|
| `== Description ==` | Yes | Full plugin description |
| `== Installation ==` | Yes | Step-by-step installation guide |
| `== Changelog ==` | Yes | History of changes |

## Optional Sections

| Section | Notes |
|---------|-------|
| `== Frequently Asked Questions ==` | FAQ section |
| `== Screenshots ==` | Caption list matching screenshot files |
| `== Upgrade Notice ==` | Per-version upgrade warnings (shown in WP admin) |
| `== Other Notes ==` | Additional notes |

---

## Formatting Guide

### Headings

```
== Second Level Heading ==

=== Third Level Heading ===
```

Note: The plugin name uses `=== ===` (third level), while content sections use `== ==` (second level).

### Lists

```
* Unordered item
* Another item

1. Ordered item
2. Another item
```

### Links

```
[Link text](https://example.com)
```

### Code

```
`inline code`
```

### Bold and Italic

```
**bold**
*italic*
```

---

## Changelog Format Best Practices

Use a consistent prefix system so users understand what changed:

```
= 2.0.0 =
* Added: New dashboard widget
* Added: Block support for Twenty Twenty-Five theme
* Changed: Renamed settings page to "My Plugin Settings"
* Fixed: Resolved conflict with Yoast SEO plugin
* Removed: Deprecated `my_plugin_legacy_function()` function
* Security: Fixed XSS vulnerability in user input display
```

Prefixes: `Added`, `Changed`, `Fixed`, `Removed`, `Security`

---

## Stable Tag vs. Version

The `Stable tag` in `readme.txt` must match the plugin's `Version:` header AND the SVN tag:

```
readme.txt:        Stable tag: 1.2.0
plugin-file.php:   Version: 1.2.0
SVN tag:           tags/1.2.0/
```

If `Stable tag: trunk`, WordPress.org serves the trunk version — only use this during development.

---

## Tags Recommendations

- Use generic terms, not your brand name
- Max 5 tags shown on the directory page (you can list more but only 5 are displayed)
- No spaces within a tag (use hyphens: `custom-post-type`)
- Check popular existing tags: `https://wordpress.org/plugins/tags/`

Good tags example:
```
Tags: woocommerce, payment, checkout, e-commerce, stripe
```

---

## Screenshot Captions

The `== Screenshots ==` section lists captions that correspond to `screenshot-1.png`, `screenshot-2.png`, etc. in the SVN `/assets/` directory:

```
== Screenshots ==

1. This is the admin settings page.
2. The block editor integration.
3. Front-end display of the widget.
```

Screenshot `screenshot-1.png` shows caption "This is the admin settings page.", and so on.
