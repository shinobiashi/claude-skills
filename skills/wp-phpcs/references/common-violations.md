# Common WordPress PHPCS Violations

Top violations encountered in WordPress plugin and theme codebases, with fix examples.

---

## 1. WordPress.Security.EscapeOutput

Missing output escaping. All dynamic data rendered to HTML must be escaped.

```php
// BAD
echo $user_input;
echo '<p>' . get_option( 'my_option' ) . '</p>';

// GOOD
echo esc_html( $user_input );
echo '<p>' . esc_html( get_option( 'my_option' ) ) . '</p>';
```

Escape function selection guide:

| Context | Function |
|---|---|
| Plain text inside HTML | `esc_html()` |
| HTML attribute value | `esc_attr()` |
| URL in `href`/`src` | `esc_url()` |
| Rich HTML content | `wp_kses_post()` |
| Translated string inline | `esc_html_e()` / `esc_attr_e()` |
| JavaScript string | `esc_js()` |

---

## 2. WordPress.Security.NonceVerification

Processing `$_POST`, `$_GET`, or `$_REQUEST` without verifying a nonce.

```php
// BAD
if ( isset( $_POST['my_field'] ) ) {
    update_option( 'my_key', $_POST['my_field'] );
}

// GOOD — form/admin action
if ( isset( $_POST['my_nonce'] ) && check_admin_referer( 'my_action', 'my_nonce' ) ) {
    update_option( 'my_key', sanitize_text_field( wp_unslash( $_POST['my_field'] ) ) );
}

// GOOD — AJAX handler
check_ajax_referer( 'my_ajax_nonce', 'nonce' );
```

---

## 3. WordPress.DB.DirectDatabaseQuery

Direct `$wpdb` queries without caching annotation.

```php
// BAD
$results = $wpdb->get_results( "SELECT * FROM {$wpdb->posts} WHERE post_status = 'publish'" );

// GOOD — use WP_Query or WP APIs when possible
$query = new WP_Query( [ 'post_status' => 'publish' ] );

// ACCEPTABLE — when direct query is truly necessary; add phpcs:ignore with reason
// phpcs:ignore WordPress.DB.DirectDatabaseQuery.DirectQuery, WordPress.DB.DirectDatabaseQuery.NoCaching -- Custom table with no WP API equivalent.
$results = $wpdb->get_results(
    $wpdb->prepare( "SELECT * FROM {$wpdb->prefix}my_custom_table WHERE status = %s", $status )
);
```

Always use `$wpdb->prepare()` when queries contain variable input.

---

## 4. WordPress.WP.I18n

Wrong text domain, missing domain, or non-translatable string passed to i18n functions.

```php
// BAD — wrong text domain
echo esc_html__( 'Hello world', 'wrong-domain' );

// BAD — variable as text domain (not extractable by tools)
echo esc_html__( 'Hello world', $textdomain );

// GOOD
echo esc_html__( 'Hello world', 'my-plugin' );

// BAD — passing a variable as the string (not translatable)
$msg = 'Hello world';
echo esc_html__( $msg, 'my-plugin' );

// GOOD
echo esc_html__( 'Hello world', 'my-plugin' );
```

---

## 5. WordPress.NamingConventions.PrefixAllGlobals

Global functions, classes, constants, and variables must use the plugin's prefix.

```php
// BAD
function get_settings() { ... }
define( 'VERSION', '1.0.0' );
$data = [];  // at global scope

// GOOD
function my_plugin_get_settings() { ... }
define( 'MY_PLUGIN_VERSION', '1.0.0' );
$my_plugin_data = [];
```

For class-based code in a namespace, globals defined inside the namespace are exempt.

---

## 6. WordPress.Files.FileName

WordPress convention: class files must be named `class-{classname}.php` with lowercase and hyphens.

```
// WordPress convention
class-my-feature.php  →  class My_Feature {}

// PSR-4 convention (common in modern plugins)
MyFeature.php  →  class MyFeature {}
```

For PSR-4 autoloaded code, exclude this sniff in `.phpcs.xml.dist`:

```xml
<rule ref="WordPress">
  <exclude name="WordPress.Files.FileName" />
</rule>
```

---

## 7. Generic.Commenting.DocComment / WordPress-Docs

Missing or malformed DocBlock on functions, classes, and methods.

```php
// BAD — no DocBlock
function my_plugin_process( $data, $context ) {
    ...
}

// GOOD
/**
 * Process the incoming data.
 *
 * @param array  $data    The data to process.
 * @param string $context Processing context identifier.
 * @return array Processed result.
 */
function my_plugin_process( $data, $context ) {
    ...
}
```

---

## 8. Squiz.PHP.DiscouragedFunctions

Debug output functions left in production code.

```php
// BAD — these trigger the sniff
print_r( $data );
var_dump( $data );
var_export( $data );
error_log( print_r( $data, true ) );

// GOOD — remove entirely, or gate behind a debug constant
if ( defined( 'WP_DEBUG' ) && WP_DEBUG ) {
    // phpcs:ignore WordPress.PHP.DevelopmentFunctions
    error_log( print_r( $data, true ) );
}
```

---

## 9. WordPress.PHP.YodaConditions

Value must be on the left side of comparison operators to prevent accidental assignment.

```php
// BAD
if ( $status == 'active' ) { ... }
if ( $count != 0 ) { ... }

// GOOD
if ( 'active' === $status ) { ... }
if ( 0 !== $count ) { ... }
```

Note: `===` and `!==` are preferred over `==` and `!=` in WordPress coding standards.

---

## 10. WordPress.Arrays.CommaAfterLast

Trailing comma required after the last element in multi-line arrays.

```php
// BAD
$args = [
    'post_type'   => 'post',
    'post_status' => 'publish'  // missing trailing comma
];

// GOOD
$args = [
    'post_type'   => 'post',
    'post_status' => 'publish',
];
```

`phpcbf` auto-fixes this violation.

---

## 11. PEAR.Functions.FunctionCallSignature

Incorrect indentation or alignment in multi-line function calls.

```php
// BAD
$result = some_function( $arg1,
$arg2,
    $arg3
);

// GOOD
$result = some_function(
    $arg1,
    $arg2,
    $arg3
);
```

`phpcbf` fixes most of these automatically.

---

## 12. Generic.WhiteSpace.DisallowSpaceIndent

WordPress coding standards require tabs for indentation, not spaces.

```php
// BAD (spaces)
function my_plugin_example() {
    $a = 1;  // 4 spaces
}

// GOOD (tab)
function my_plugin_example() {
	$a = 1;  // 1 tab
}
```

`phpcbf` auto-converts spaces to tabs. In editors, set "indent using tabs" for PHP files.

---

## 13. WordPress.Security.ValidatedSanitizedInput

Superglobal input used without sanitization.

```php
// BAD
$name = $_POST['name'];
update_option( 'my_name', $_POST['name'] );

// GOOD
$name = isset( $_POST['name'] ) ? sanitize_text_field( wp_unslash( $_POST['name'] ) ) : '';

// Common sanitize functions by data type:
// sanitize_text_field()     — plain text, removes tags
// sanitize_email()          — email addresses
// sanitize_url() / esc_url_raw() — URLs stored in DB
// absint() / intval()       — integers
// sanitize_key()            — slugs/keys
// wp_kses_post()            — rich HTML
// sanitize_textarea_field() — multi-line plain text
```

Always call `wp_unslash()` before `sanitize_*` on superglobal values.

---

## 14. WordPress.WP.AlternativeFunctions

PHP native functions that have WordPress wrapper equivalents.

```php
// BAD
$body = file_get_contents( 'https://example.com/api' );
$json = json_encode( $data );

// GOOD
$response = wp_remote_get( 'https://example.com/api' );
$body     = wp_remote_retrieve_body( $response );

$json = wp_json_encode( $data );
```

Common replacements:

| PHP native | WordPress alternative |
|---|---|
| `file_get_contents( URL )` | `wp_remote_get()` |
| `json_encode()` | `wp_json_encode()` |
| `json_decode()` | allowed (no WP alternative) |
| `parse_url()` | allowed (no WP alternative) |
| `rand()` | `wp_rand()` |
| `str_replace()` | allowed |

---

## 15. WordPress.PHP.StrictInArray

`in_array()` called without `true` as the third (strict) argument risks type coercion bugs.

```php
// BAD
if ( in_array( $user_id, $allowed_ids ) ) { ... }

// GOOD — strict comparison
if ( in_array( $user_id, $allowed_ids, true ) ) { ... }
```

This applies to `array_search()` as well:

```php
// GOOD
$key = array_search( $value, $haystack, true );
```

---

## Quick reference: phpcs:ignore syntax

Use inline suppression sparingly and always include a reason:

```php
// Suppress a single line
$result = $wpdb->query( $sql ); // phpcs:ignore WordPress.DB.DirectDatabaseQuery.DirectQuery -- Bulk delete with no WP API.

// Suppress a block
// phpcs:disable WordPress.Security.NonceVerification
if ( isset( $_GET['page'] ) ) { ... }
// phpcs:enable WordPress.Security.NonceVerification

// Suppress a specific sniff for a file (at top of file)
// phpcs:disable WordPress.Files.FileName
```
