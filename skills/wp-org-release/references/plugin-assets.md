# Plugin Assets — Banners, Icons, Screenshots

## Overview

Plugin directory assets are stored in the SVN `/assets/` directory and are served separately from the plugin code. They are NOT included in the plugin ZIP download.

Assets URL: `https://plugins.svn.wordpress.org/my-plugin/assets/`

---

## Required and Recommended Files

### Icons

| File | Dimensions | Purpose |
|------|-----------|---------|
| `icon-256x256.png` | 256×256 px | High-DPI displays (recommended) |
| `icon-128x128.png` | 128×128 px | Standard displays |
| `icon-256x256.jpg` | 256×256 px | JPG alternative (if preferred) |
| `icon.svg` | Vector | SVG alternative (replaces both PNG sizes) |

**Notes:**
- At least one icon file is recommended (the plugin will show a default grey icon without it)
- SVG icons are recommended as they scale perfectly
- Keep the icon design simple and recognizable at small sizes

### Banners

| File | Dimensions | Purpose |
|------|-----------|---------|
| `banner-1544x500.png` | 1544×500 px | High-DPI displays (Retina) |
| `banner-772x250.png` | 772×250 px | Standard displays |
| `banner-1544x500.jpg` | 1544×500 px | JPG alternative |
| `banner-772x250.jpg` | 772×250 px | JPG alternative |

**Notes:**
- Banners are shown at the top of your plugin page on WordPress.org
- Either PNG or JPG is accepted, but not mixed (use one format consistently)
- High-DPI versions are optional but strongly recommended

### Screenshots

| File Pattern | Dimensions | Notes |
|-------------|-----------|-------|
| `screenshot-1.png` | Any | Must correspond to caption in readme.txt |
| `screenshot-2.png` | Any | Sequential numbering required |
| `screenshot-N.png` | Any | No gaps in numbering |

**Notes:**
- Screenshot files must be numbered sequentially starting from 1
- Captions are defined in the `== Screenshots ==` section of `readme.txt`
- PNG or JPG accepted
- Recommended width: 1200px or larger for clarity

---

## SVN Assets Workflow

### Initial Setup

```bash
# Check out only the assets directory
svn checkout https://plugins.svn.wordpress.org/my-plugin/assets ~/svn/my-plugin/assets

# Or if you have the full repo checked out
ls ~/svn/my-plugin/assets/
```

### Adding New Assets

```bash
# Copy image files to the assets directory
cp ~/images/banner-1544x500.png ~/svn/my-plugin/assets/
cp ~/images/banner-772x250.png ~/svn/my-plugin/assets/
cp ~/images/icon-256x256.png ~/svn/my-plugin/assets/
cp ~/images/icon-128x128.png ~/svn/my-plugin/assets/
cp ~/images/screenshot-1.png ~/svn/my-plugin/assets/

# Add all new files
svn add ~/svn/my-plugin/assets/*.png

# Verify what will be committed
svn status ~/svn/my-plugin/assets/

# Commit
svn commit ~/svn/my-plugin/assets/ -m "Add plugin icons, banners, and screenshots"
```

### Updating Existing Assets

```bash
# Simply overwrite the file — no svn add needed for existing files
cp ~/images/new-banner.png ~/svn/my-plugin/assets/banner-1544x500.png

svn status ~/svn/my-plugin/assets/
# Should show: M   assets/banner-1544x500.png

svn commit ~/svn/my-plugin/assets/ -m "Update plugin banner"
```

### Removing Old Assets

```bash
svn delete ~/svn/my-plugin/assets/old-screenshot.png
svn commit ~/svn/my-plugin/assets/ -m "Remove outdated screenshot"
```

---

## Design Guidelines

### Icons

- Use a simple, bold design recognizable at 32px
- Avoid text in icons (especially at small sizes)
- Use a transparent background (PNG with alpha)
- Consistent visual style with your plugin's branding

### Banners

- Dimensions: 772×250px (standard), 1544×500px (retina)
- Avoid placing important content near edges (20px margin recommended)
- Include the plugin name/logo prominently
- Avoid excessive text
- High contrast for readability

### Screenshots

- Show real functionality, not placeholder content
- Use realistic data in screenshots
- Add descriptive captions in `readme.txt`
- Consider localized screenshots if your plugin has a specific audience

---

## Localized Assets

You can provide locale-specific versions of banners and screenshots:

| File | Locale |
|------|--------|
| `banner-772x250-ja.png` | Japanese |
| `banner-772x250-de_DE.png` | German (Germany) |
| `screenshot-1-ja.png` | Japanese screenshot |

WordPress.org will serve the localized version when a user views the plugin page in that locale.

---

## Propagation Time

After committing assets to SVN:

- **Icons**: appear on plugin page within ~15 minutes
- **Banners**: appear within ~15 minutes
- **Screenshots**: appear within ~15 minutes

If assets don't appear after 1 hour, verify:
1. Files are in the correct SVN `/assets/` directory (not in trunk)
2. File names match exactly (case-sensitive)
3. File dimensions meet requirements
4. The commit was successful (`svn log` to verify)

---

## Common Mistakes

### Putting Assets in trunk

```
WRONG: trunk/assets/icon-256x256.png
CORRECT: assets/icon-256x256.png  (top-level assets/ directory)
```

### Wrong Dimensions

Common errors:
- Banner that is not exactly 772×250 or 1544×500 — will not display
- Icon that is not exactly 128×128 or 256×256 — may display incorrectly

Check dimensions before upload:
```bash
# macOS
sips -g pixelWidth -g pixelHeight ~/images/banner-772x250.png

# Linux
identify ~/images/banner-772x250.png
```

### Broken Screenshot Numbering

```
WRONG: screenshot-1.png, screenshot-3.png (gap at 2)
CORRECT: screenshot-1.png, screenshot-2.png, screenshot-3.png
```

### Missing Retina Banner

WordPress.org will serve the standard banner on all displays if the retina version is missing. Provide both sizes for the best appearance.
