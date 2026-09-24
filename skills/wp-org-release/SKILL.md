---
name: wp-org-release
version: "1.1.0"
description: "Use when publishing or releasing a WordPress plugin to the WordPress.org plugin directory: initial submission, responding to a plugin review and uploading a corrected version (including the undocumented \"Additional Information\" field on the submission form), SVN workflow (trunk/tags/assets), readme.txt management, banner/icon/screenshot assets, and Stable tag updates."
compatibility: "Targets WordPress.org SVN-based plugin repository. Requires SVN client. Tested with WP-CLI 2.x and @wordpress/scripts for ZIP generation."
---

# WP.org Plugin Release

## When to use

Use this skill when:

- Submitting a plugin to WordPress.org for the first time
- Responding to a plugin review (uploading a corrected version)
- Releasing a new version of an existing WordPress.org plugin
- Updating readme.txt content (description, changelog, FAQ)
- Managing plugin directory assets (banners, icons, screenshots)
- Troubleshooting SVN commit or tagging issues

## Inputs required

- Plugin slug (WordPress.org directory name, e.g. `my-plugin`)
- Version number to release (e.g. `1.2.0`)
- SVN URL: `https://plugins.svn.wordpress.org/my-plugin/`
- WordPress.org username with commit access to the plugin

## Procedure

### 1) Pre-release checklist

Before touching SVN, verify all of the following:

- [ ] `readme.txt` has all required headers (see references)
- [ ] Plugin file `Stable tag:` matches the version being released
- [ ] `Version:` in plugin header matches `Stable tag:` in readme.txt
- [ ] `Tested up to:` matches between the main plugin file header and readme.txt — Plugin Check (PCP) now flags a mismatch; keep it current with core (7.0, moving to 7.1)
- [ ] License is GPL v2 or later (WordPress.org requirement)
- [ ] No hardcoded external service URLs without disclosure
- [ ] All user-facing strings are translatable
- [ ] No debug code (`var_dump`, `print_r`, `console.log`) left in production files
- [ ] Plugin Check (PCP) passes — run the [Plugin Check plugin](https://wordpress.org/plugins/plugin-check/)
      or `wp plugin check <slug>` and resolve all issues except confirmed false-positives.
      The submission form requires confirming this via checkbox

See: `references/review-checklist.md`

### 2) Update readme.txt

Ensure `readme.txt` is valid and complete:

```
=== My Plugin ===
Contributors:      myusername
Tags:              tag1, tag2, tag3
Requires at least: 6.4
Tested up to:      7.1
Stable tag:        1.2.0
Requires PHP:      7.4
License:           GPLv2 or later
License URI:       https://www.gnu.org/licenses/gpl-2.0.html

Short description (max 150 characters, no markup).

== Description ==

Full description here.

== Installation ==

1. Upload the plugin files to `/wp-content/plugins/my-plugin`
2. Activate the plugin through the 'Plugins' screen in WordPress

== Changelog ==

= 1.2.0 =
* Added: New feature X
* Fixed: Bug in Y

= 1.1.0 =
* Initial release

== Upgrade Notice ==

= 1.2.0 =
Important security fix. Upgrade immediately.
```

See: `references/readme-txt-format.md`

### 3) Generate plugin ZIP (optional, for local testing)

```bash
# Using @wordpress/scripts
npm run plugin-zip

# Or using WP-CLI
wp dist-archive . --plugin-dirname=my-plugin
```

Test the ZIP by installing on a clean WordPress site before releasing.

### 4) SVN workflow — first-time setup

```bash
# Check out the full SVN repo (takes time for large plugins)
svn checkout https://plugins.svn.wordpress.org/my-plugin/ /path/to/svn/my-plugin

# Or check out only trunk to save time
svn checkout https://plugins.svn.wordpress.org/my-plugin/trunk /path/to/svn/my-plugin/trunk
```

See: `references/svn-workflow.md`

### 5) SVN workflow — releasing a new version

```bash
# 1. Sync your local trunk with the current state
svn update trunk/

# 2. Copy your plugin files to trunk (exclude dev-only files)
rsync -av --exclude='.git' --exclude='node_modules' --exclude='tests' \
    --exclude='.github' --exclude='vendor' \
    /path/to/your/plugin/ trunk/

# 3. Check status
svn status trunk/

# 4. Add any new files
svn status trunk/ | grep '^?' | awk '{print $2}' | xargs svn add

# 5. Remove deleted files
svn status trunk/ | grep '^!' | awk '{print $2}' | xargs svn delete

# 6. Commit trunk
svn commit trunk/ -m "Release version 1.2.0"

# 7. Create the version tag by copying trunk
svn copy https://plugins.svn.wordpress.org/my-plugin/trunk \
         https://plugins.svn.wordpress.org/my-plugin/tags/1.2.0 \
         -m "Tagging version 1.2.0"
```

See: `references/svn-workflow.md`

### 6) Update plugin assets

Plugin assets (banners, icons, screenshots) live in the SVN `/assets/` directory, which is separate from the plugin code:

```bash
# Check out only the assets directory
svn checkout https://plugins.svn.wordpress.org/my-plugin/assets /path/to/svn/my-plugin/assets

# Add or update files
cp ~/images/banner-1544x500.png assets/
cp ~/images/icon-256x256.png assets/

svn add assets/banner-1544x500.png   # if new
svn commit assets/ -m "Update plugin banner and icon"
```

Required asset files and their dimensions:

| File | Dimensions | Format |
|------|-----------|--------|
| `icon-256x256.png` | 256×256 px | PNG or JPG |
| `icon-128x128.png` | 128×128 px | PNG or JPG |
| `banner-1544x500.png` | 1544×500 px | PNG or JPG |
| `banner-772x250.png` | 772×250 px | PNG or JPG |
| `screenshot-1.png` | Any | PNG or JPG |

See: `references/plugin-assets.md`

### 7) Verify the release

After SVN commit:

1. Check the plugin page: `https://wordpress.org/plugins/my-plugin/`
2. Confirm `Stable tag:` is reflected — **plugin version updates go through a
   WordPress.org check that can take up to 24 hours** before the new version is
   served (plugin API `version`, ZIP build, and update notifications). Do not
   treat a slow switch as a failed release, and do not re-commit to force it;
   poll the plugin info API once every few hours at most:
   `https://api.wordpress.org/plugins/info/1.0/<slug>.json`
3. Schedule releases with this lag in mind: commit the tag at least one day
   before any announced release date/time so the 24-hour check completes first
4. Test auto-update from an older version on a staging site

```bash
# Test with WP-CLI on staging
wp plugin install my-plugin --force
wp plugin update my-plugin
```

---

## First-time Submission Flow

### Step 1: Apply for a WordPress.org Account

If you don't have one: `https://login.wordpress.org/register`

### Step 2: Submit the Plugin

Go to: `https://wordpress.org/plugins/developers/add/`

The submission form (as of 2026) requires confirming a series of checkboxes
before the upload control is usable:

1. **Pre-submission confirmations**: you have read the Developer FAQ and the
   Plugin Directory Guidelines, and the plugin has been **tested with the
   Plugin Check plugin** with all issues resolved (false-positives excepted)
2. **Naming and ownership (Guideline 17)**: the name is distinctive and not
   confusingly similar to existing plugins/projects/trademarks — generic names
   ("AI Writer", "Image Optimization") are rejected even if the slug is free;
   prefix with your own brand instead. Names *beginning* with a company/
   project/trademark name may only be submitted by the verified owner
   (ownership is verified via the WordPress.org account email — update the
   profile first if needed). Non-owners must place the third-party name at
   the end with clear distinction (e.g. "MyPlugin – Foo for Acme")
3. **Trialware (Guidelines 5 & 6)**: confirm the code contains no artificial
   limitations — no paywalls, license/feature gating, time-limited trials,
   or usage cutoffs on functionality implemented in the plugin itself
4. **Submission acknowledgement**: non-compliant submissions may be rejected;
   hosting is conditional on continued guideline compliance

Categories of plugins that are **not accepted at all** (do not submit):

- Arbitrary code insertion/execution: PHP/JS editors, file managers, AI tools
  that execute generated code on the site (escaped HTML insertion is fine)
- Plugins downloading executable code from external sources (Guideline 8)
- Plugins whose functionality is already represented by hundreds of comparable
  plugins with no meaningful differentiation (Guideline 18)

Then upload the `.zip` (**max 10 MB**) and wait for the review email —
typically 1-10 days, with a target of 5 business days.

The form also has an **"Additional Information"** free-text field next to the
file input. It has no help text or placeholder, so its purpose is easy to
misread: see "Step 2b" below for what it actually does and what to write in it.

Notes after submitting:

- The slug is derived from `Plugin Name:` in the main plugin file. It can be
  changed **once** from the submission page before review begins; after that,
  email `plugins@wordpress.org` (or reply to the review email). Once approved,
  the slug is permanent
- The most common review failures are unescaped output, unsanitized input,
  and form processing without a nonce

Since 2026-03 an official Plugin Directory MCP server also lets you validate and submit plugins via AI/MCP tooling (`https://developer.wordpress.org/plugins/wordpress-org/using-the-mcp-server/`) — but submissions still go through the same human review as the web form.

### Step 2b: Responding to a Review

When the review team asks for changes, the plugin moves to `pending` and you
get an email listing the issues. **Corrected versions are uploaded from the
submission page, not emailed**: `https://wordpress.org/plugins/developers/add/`
shows an **"Upload updated "<Plugin>" plugin for review."** control for each
plugin of yours that is still in review. You can re-upload at any time.

That form carries the same **"Additional Information"** textarea as the initial
submission form. What it actually is, per the directory's own source
(`plugin-directory/shortcodes/class-upload.php` and `class-upload-handler.php`
in the `WordPress/wordpress.org` repository):

- It is a plain `<textarea name="comment">` with **no help text, placeholder, or
  length limit**. The `rows="3"` sizing signals a short note, not an essay
- On submit, the handler stores it via `Tools::audit_log()` as an entry titled
  `Upload Comment for <link to the uploaded ZIP>`, attached to the plugin post.
  **Reviewers read it in their admin tool next to the file you uploaded**
- It is **not an email and sends no notification**. Do not rely on it alone to
  tell the reviewer you have responded — also reply in the review email thread

So write it as a changelog aimed at the reviewer, not as a letter: no greeting,
no signature, one numbered point per item in the review email, in the reviewer's
own order and wording. Quote the exact `file.php:123` locations they cited when
the fix is a removal, and name the verification you ran (Plugin Check with its
full flags, PHPCS sniff names) rather than claiming the code is fine.

Gotchas:

- **An identical ZIP is rejected.** The handler compares `sha1_file()` against
  the `uploaded_zip_hash` post meta and fails with "You've already uploaded that
  ZIP file." Bump the version and rebuild; do not re-upload the reviewed file
- Build the ZIP the same way you would for release (see step 3) and verify it
  before uploading — Plugin Check must be run against the **extracted ZIP**, not
  the source tree, or you will be reading errors from files you do not ship
- The review team aims to reply within ten business days; a plugin with code
  issues takes as long as the back-and-forth takes

### Step 3: After Approval

You will receive an email with SVN access:
```
SVN URL: https://plugins.svn.wordpress.org/my-plugin/
```

Follow steps 4-6 above to commit your plugin.

---

## Verification

- Plugin page is accessible at `https://wordpress.org/plugins/my-plugin/`
- Version number shown matches the released `Stable tag`
- Downloading the plugin from WordPress.org and installing produces expected results
- Auto-update works correctly from a previous version

## Failure modes / debugging

- **SVN authentication fails**: Use `svn info` to confirm credentials; use `--username` and `--password` flags
- **Tag not appearing**: Ensure `svn copy` used remote-to-remote URL format (not local path)
- **Plugin not updating on .org**: Check `Stable tag:` in `readme.txt` matches the tag in SVN exactly
- **Assets not showing**: Assets must be in `/assets/` (not in trunk); may take up to 1 hour to propagate
- **Review rejected**: See `references/review-checklist.md` for common rejection reasons

## Escalation

- For plugin guideline questions: `https://developer.wordpress.org/plugins/wordpress-org/`
- For SVN access issues: `https://wordpress.org/support/forum/wp-advanced/`
- For translation infrastructure: `https://make.wordpress.org/polyglots/`
