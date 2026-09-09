# WordPress.org Plugin Review Checklist

## Overview

The WordPress.org Plugin Review Team checks every new plugin submission and may audit existing plugins. Understanding their requirements prevents delays and rejection.

Official guidelines: `https://developer.wordpress.org/plugins/wordpress-org/detailed-plugin-guidelines/`

---

## Submission Requirements

### Pre-submission Checklist

Before submitting at `https://wordpress.org/plugins/developers/add/`:

- [ ] Plugin has a unique, descriptive name (see "Naming and Ownership" below)
- [ ] Plugin file header is complete (Plugin Name, Description, Version, Author, License, Text Domain)
- [ ] `readme.txt` is present and valid (test at: `https://wordpress.org/plugins/developers/readme-validator/`)
- [ ] Plugin does not duplicate existing functionality (check the directory first)
- [ ] Tested with the Plugin Check plugin (`wp plugin check <slug>` or the
      [Plugin Check plugin](https://wordpress.org/plugins/plugin-check/)) and all
      issues resolved — the submission form requires confirming this
- [ ] No obfuscated code (no base64-encoded executable code)
- [ ] No calling home without user consent
- [ ] All external service usage is clearly disclosed
- [ ] ZIP is 10 MB or smaller (form upload limit)

### Naming and Ownership (Guideline 17)

The submission form requires explicit confirmation of these:

- The name must be **distinctive**: generic names ("AI Writer", "Image
  Optimization") or names similar to existing plugins are rejected even when
  the slug is available. Add your own brand/project name to differentiate
- Names **beginning with** a company, project, organization, or trademark name
  may only be submitted by the **verified owner** — verified via the email on
  the submitting WordPress.org account. Update the account profile before
  submitting if the email does not represent the owner
- If referencing a third-party product you do not own, put its name at the end
  with clear distinction (e.g. "MyPlugin – Foo for Acme"); never imply
  affiliation
- Search the internet for similar names before submitting (the form asks you
  to confirm you did)

### Trialware Prohibition (Guidelines 5 & 6)

Plugins may not artificially restrict functionality included in the plugin
code itself: no paywalls, license/feature gating, time-limited trials, or
usage cutoffs. Building a business around the plugin is fine (e.g. a separate
paid add-on or SaaS backend), but limitations built into shipped code are
grounds for rejection and can lead to indefinite plugin/account suspension.

### Plugin Types Not Accepted

- Plugins that allow arbitrary code insertion/execution (PHP/JS editors, file
  managers, AI tools executing generated code on the site). Correctly escaped
  HTML insertion is acceptable
- Plugins downloading executable code from external sources (Guideline 8)
- Plugins whose functionality is already well represented in the directory
  with no meaningful differentiation or innovation (Guideline 18)

---

## License Requirements

### GPL v2 or Later

All code in the plugin must be licensed under GPL v2 or a compatible license.

```php
// Plugin file header — required
 * License:           GPL v2 or later
 * License URI:       https://www.gnu.org/licenses/gpl-2.0.html
```

```
// readme.txt — required
License: GPLv2 or later
License URI: https://www.gnu.org/licenses/gpl-2.0.html
```

### Bundled Libraries

If your plugin bundles third-party libraries:
- Each must be GPL-compatible (MIT, Apache 2.0, BSD are compatible)
- Include the library's original license file
- Declare the library in `readme.txt` or documentation

---

## Security Requirements

### Input Sanitization

All data received from users or external sources must be sanitized:

```php
// User input
$title = sanitize_text_field( $_POST['title'] );
$email = sanitize_email( $_POST['email'] );
$url   = esc_url_raw( $_POST['url'] );
$int   = absint( $_POST['count'] );
$html  = wp_kses_post( $_POST['content'] );

// Database queries — always use $wpdb->prepare()
$results = $wpdb->get_results(
    $wpdb->prepare(
        'SELECT * FROM %i WHERE user_id = %d AND status = %s',
        $table_name,
        $user_id,
        $status
    )
);
```

### Output Escaping

All output must be escaped:

```php
// HTML output
echo esc_html( $title );
echo esc_attr( $attribute );
echo esc_url( $url );
echo wp_kses_post( $html_content );
echo absint( $number );

// In translations
echo esc_html__( 'Translatable string', 'my-plugin' );
echo esc_html_e( 'Translatable string', 'my-plugin' );
esc_attr_e( 'Attribute value', 'my-plugin' );
```

### Nonce Verification

All form submissions and AJAX requests must verify nonces:

```php
// In form
wp_nonce_field( 'my_plugin_action', 'my_plugin_nonce' );

// On form submission
if ( ! isset( $_POST['my_plugin_nonce'] ) ||
     ! wp_verify_nonce( sanitize_key( $_POST['my_plugin_nonce'] ), 'my_plugin_action' ) ) {
    wp_die( esc_html__( 'Security check failed.', 'my-plugin' ) );
}

// For AJAX
check_ajax_referer( 'my_plugin_nonce', 'nonce' );
```

### Capability Checks

Always verify user capabilities before performing privileged operations:

```php
if ( ! current_user_can( 'manage_options' ) ) {
    wp_die( esc_html__( 'You do not have sufficient permissions.', 'my-plugin' ) );
}
```

---

## Data Handling Requirements

### External Services Disclosure

If your plugin calls external services (APIs, CDNs, etc.), you must disclose this in `readme.txt`:

```
== Third-Party Services ==

This plugin uses the ExampleAPI service to process payments.
- Service URL: https://api.example.com
- Privacy Policy: https://example.com/privacy
- Terms of Service: https://example.com/terms

Data sent: user email address and order total.
This only occurs when a purchase is made.
```

### User Data Storage

If you store user data:
- Provide clear disclosure in the plugin description
- Support data deletion on user request (consider `wp_privacy_personal_data_eraser`)
- Support data export (consider `wp_privacy_personal_data_exporter`)

---

## Code Quality Requirements

### No Obfuscated Code

```php
// REJECTED — obfuscated/encoded code
eval( base64_decode( 'ZWNobyAiSGVsbG8gV29ybGQiOw==' ) );

// ACCEPTABLE — clear, readable code
echo 'Hello World';
```

### No Hardcoded Credentials

```php
// REJECTED
$api_key = 'sk_live_abc123xyz';

// CORRECT — use options
$api_key = get_option( 'my_plugin_api_key' );
```

### Proper Use of WordPress APIs

Use WordPress core functions instead of direct PHP equivalents:

```php
// PREFERRED over file_get_contents() for HTTP requests
$response = wp_remote_get( 'https://api.example.com/data' );

// PREFERRED over mkdir()
wp_mkdir_p( $upload_dir['path'] . '/my-plugin' );

// PREFERRED over json_encode()
wp_json_encode( $data );
```

---

## Internationalization (i18n) Requirements

- All user-facing strings must be wrapped in translation functions
- Text domain must match plugin slug
- No variables as text domain:

```php
// WRONG
__( 'Hello', $domain );

// CORRECT
__( 'Hello', 'my-plugin' );
```

---

## Common Rejection Reasons

### 1. Calling External URLs Without Disclosure

Any HTTP request to an external server must be disclosed in `readme.txt` and ideally require user opt-in.

### 2. Using eval() or base64_decode()

These are almost always red flags for obfuscated code. Reviewers will reject the plugin or request explanation.

### 3. Direct Database Queries Without Prepare

```php
// REJECTED
$wpdb->query( "SELECT * FROM $wpdb->posts WHERE ID = " . $_GET['id'] );

// CORRECT
$wpdb->get_row( $wpdb->prepare( "SELECT * FROM $wpdb->posts WHERE ID = %d", absint( $_GET['id'] ) ) );
```

### 4. No Stable tag in readme.txt

A missing or `trunk` Stable tag causes the plugin page to show incorrect version info.

### 5. Outdated or Missing Changelog

The changelog must accurately reflect what changed in each version.

### 6. GPL-Incompatible Bundled Libraries

If a bundled library uses a non-GPL-compatible license (e.g., proprietary), the plugin will be rejected.

### 7. Calling die() or exit() Without Context

```php
// NOT RECOMMENDED in hooks
add_action( 'init', function() {
    if ( something_wrong() ) {
        die(); // Kills the entire page load
    }
} );

// BETTER
add_action( 'init', function() {
    if ( something_wrong() ) {
        return; // Return early instead
    }
} );
```

### 8. Missing or Incorrect Plugin Headers

Required headers in the main plugin file:
- `Plugin Name:`
- `Version:`
- `Author:`
- `License:` (must be GPL v2 or compatible)
- `Text Domain:`

---

## Post-Approval Compliance

Even after approval, plugins must remain compliant. The review team may audit live plugins and can:
- Request changes within 7 days
- Temporarily close a plugin that violates guidelines
- Permanently close plugins with serious violations

Monitor the Plugin Developer mailing list and reply promptly to review team emails.
