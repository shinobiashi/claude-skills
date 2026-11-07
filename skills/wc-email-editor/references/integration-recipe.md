# Integration recipe (PHP)

Modeled on `plugins/woocommerce/src/Internal/EmailEditor/{Integration,PageRenderer}.php`
(WooCommerce trunk, 2026-10-07) and on Signal Mail's `Editor\Container` / `Editor\Bootstrap`
(PR-17, 2026-10-24). Replace `Vendor\` with your Strauss prefix, `my_email` with your post
type, `MY_PLUGIN_DIR` / `MY_PLUGIN_URL` with your constants. PHP 8 (`str_ends_with`).

## Adapter: the only class that knows both namespaces

```php
namespace My\Plugin\Editor;

use Vendor\Automattic\WooCommerce\EmailEditor\Bootstrap as BundledBootstrap;
use Vendor\Automattic\WooCommerce\EmailEditor\Email_Editor_Container as BundledContainer;

final class Package {
    private const BUNDLED = 'Vendor\\Automattic\\WooCommerce\\EmailEditor\\';
    private const HOST    = 'Automattic\\WooCommerce\\EmailEditor\\';
    private const SUFFIX  = 'Automattic\\WooCommerce\\EmailEditor\\Bootstrap';

    /** Services called on the live copy => methods used; a host copy must provide them all. */
    private const REQUIRED_HOST_API = [
        'Engine\\Assets_Manager'     => [ 'set_assets_path', 'set_assets_url', 'load_editor_assets', 'render_email_editor_html' ],
        'Engine\\Renderer\\Renderer' => [ 'render' ],
    ];

    /** Root namespace of the live copy; '' for a copy that cannot be named; null until decided. */
    private static ?string $live   = null;
    private static bool    $usable = true;

    public static function register(): void {
        // Late enough to see a copy WooCommerce hooked, before the package's own init work (10).
        add_action( 'init', [ self::class, 'decide' ], 9 );
    }

    public static function decide(): void {
        if ( null !== self::$live ) {
            return;
        }
        $other = self::booted_copy_namespace();
        if ( null !== $other || did_action( 'woocommerce_email_editor_initialized' ) > 0 ) {
            self::$live   = $other ?? '';
            self::$usable = null !== $other && self::compatible( $other );
            return; // When ! usable(), the edit screen shows a notice (below).
        }
        self::$live = self::BUNDLED;
        BundledContainer::container()->get( BundledBootstrap::class )->init();
    }

    public static function usable(): bool {
        return null !== self::$live && '' !== self::$live && self::$usable;
    }

    /** Class name in the live copy, for `new` and constants, e.g. cls( 'Engine\\PersonalizationTags\\Personalization_Tag' ). */
    public static function cls( string $relative ): string {
        return self::$live . $relative;
    }

    /** A package service from the live copy, e.g. get( 'Engine\\Renderer\\Renderer' ). */
    public static function get( string $relative ): object {
        $container_class = self::$live . 'Email_Editor_Container';
        return $container_class::container()->get( self::$live . $relative );
    }

    /** Read from the hook table only; WooCommerce's feature flag is not consulted. */
    private static function booted_copy_namespace(): ?string {
        $hook = $GLOBALS['wp_filter']['init'] ?? null;
        if ( ! $hook instanceof \WP_Hook ) {
            return null;
        }
        foreach ( $hook->callbacks as $callbacks ) {
            foreach ( $callbacks as $callback ) {
                $function = $callback['function'] ?? null;
                if ( ! is_array( $function ) || ! is_object( $function[0] ?? null ) ) {
                    continue;
                }
                if ( is_a( $function[0], self::HOST . 'Bootstrap' ) ) {
                    return self::HOST; // WooCommerce, or any unprefixed copy
                }
                $class = get_class( $function[0] );
                if ( self::BUNDLED . 'Bootstrap' !== $class && str_ends_with( $class, '\\' . self::SUFFIX ) ) {
                    return substr( $class, 0, -strlen( 'Bootstrap' ) ); // another plugin's prefixed copy
                }
            }
        }
        return null;
    }

    /** On instances, not class names: autoload or Strauss' aliases would answer for a missing class. */
    private static function compatible( string $root ): bool {
        $container_class = $root . 'Email_Editor_Container';
        if ( ! class_exists( $container_class, false ) ) {
            return false;
        }
        try {
            foreach ( self::REQUIRED_HOST_API as $relative => $methods ) {
                $service = $container_class::container()->get( $root . $relative );
                foreach ( $methods as $method ) {
                    if ( ! method_exists( $service, $method ) ) {
                        return false;
                    }
                }
                $file = wp_normalize_path( (string) ( new \ReflectionClass( $service ) )->getFileName() );
                if ( '' === $file || str_starts_with( $file, wp_normalize_path( MY_PLUGIN_DIR ) ) ) {
                    return false;
                }
            }
        } catch ( \Throwable $e ) {
            return false; // that copy has no such service
        }
        return true;
    }
}
```

Set your logger on the bundled container before `init()` (SKILL.md §2), check the bundled
copy's `Engine\Dependency_Check::are_dependencies_met()` if your plugin can run on a WordPress
older than 6.7, and count `woocommerce_email_editor_initialized` at `init` `PHP_INT_MAX` for the
"two copies" notice.

## Post type, page detection, editor screen

```php
function my_email_args(): array {
    // Set every key the package defaults too (public, publicly_queryable, has_archive,
    // hierarchical, default_rendering_mode, …) if you want exactly these arguments:
    // the package array_merge()s them over its defaults.
    return [
        'labels'          => [ 'name' => __( 'Campaigns', 'my-plugin' ), 'singular_name' => __( 'Campaign', 'my-plugin' ) ],
        'rewrite'         => [ 'slug' => 'my_email' ],
        'supports'        => [ 'title', 'editor' => [ 'default-mode' => 'template-locked' ], 'excerpt', 'custom-fields' ],
        'capability_type' => 'my_email',
        'capabilities'    => array_fill_keys(
            [ 'edit_post', 'read_post', 'delete_post', 'edit_posts', 'edit_others_posts', 'delete_posts', 'publish_posts', 'read_private_posts', 'create_posts' ],
            'manage_woocommerce'
        ),
        'map_meta_cap'    => false,
    ];
}

add_filter( 'woocommerce_email_editor_post_types', static function ( array $types ): array {
    $types[] = [
        'name' => 'my_email',
        'args' => my_email_args(),
        'meta' => [], // [ [ 'key' => '_my_subject', 'args' => [ 'type' => 'string', 'single' => true, 'show_in_rest' => true ] ], … ]
    ];
    return $types;
} );

// Fallback only: no copy registered it (a host copy too old for the filter, or yours could not run).
add_action( 'init', static function (): void {
    if ( ! post_type_exists( 'my_email' ) ) {
        register_post_type( 'my_email', my_email_args() );
    }
}, 11 );

// Runs on init 10, before current_screen exists: read the query string.
add_filter( 'woocommerce_is_email_editor_page', static function ( $is ): bool {
    if ( $is || ! is_admin() ) {
        return (bool) $is;
    }
    // phpcs:disable WordPress.Security.NonceVerification.Recommended -- read-only screen detection.
    if ( isset( $_GET['post'], $_GET['action'] ) && 'edit' === $_GET['action'] ) {
        return 'my_email' === get_post_type( (int) $_GET['post'] );
    }
    if ( isset( $_GET['post_type'] ) && 'my_email' === $_GET['post_type'] ) {
        return 'post-new.php' === ( $GLOBALS['pagenow'] ?? '' );
    }
    // phpcs:enable WordPress.Security.NonceVerification.Recommended
    return false;
} );

add_filter( 'replace_editor', static function ( $replace, $post ) {
    static $rendered = false;
    if ( ! $post instanceof \WP_Post || 'my_email' !== $post->post_type ) {
        return $replace;
    }
    if ( ! get_current_screen() ) {
        return $replace; // WP_Screen::get() is still setting the screen up; render in post.php / post-new.php
    }
    if ( $rendered ) {
        return true; // applied again while admin-header.php prints
    }
    $rendered = true;

    if ( ! Package::usable() ) {
        require_once ABSPATH . 'wp-admin/admin-header.php';
        echo '<div class="wrap"><div class="notice notice-error"><p>'
            . esc_html__( 'The email editor cannot open: update WooCommerce or turn off its block email editor.', 'my-plugin' )
            . '</p></div></div>';
        return true;
    }

    $assets = Package::get( 'Engine\\Assets_Manager' );
    $assets->set_assets_path( MY_PLUGIN_DIR . 'assets/build/editor/' ); // holds style.css + style.asset.php
    $assets->set_assets_url( MY_PLUGIN_URL . 'assets/build/editor/' );

    $asset = require MY_PLUGIN_DIR . 'assets/build/editor/index.asset.php';
    wp_register_script( 'my-plugin-email-editor', MY_PLUGIN_URL . 'assets/build/editor/index.js', $asset['dependencies'], $asset['version'], true );
    wp_set_script_translations( 'my-plugin-email-editor', 'my-plugin', MY_PLUGIN_DIR . 'languages' );
    wp_enqueue_script( 'my-plugin-email-editor' );

    add_filter( 'woocommerce_email_editor_script_localization_data', static function ( array $data ): array {
        // Point these at pages that exist now; a missing admin page is a broken back link.
        $data['urls']['listings'] = admin_url( 'edit.php?post_type=my_email' );
        $data['urls']['send']     = admin_url( 'edit.php?post_type=my_email' );
        $data['urls']['back']     = admin_url( 'edit.php?post_type=my_email' );
        $data['editor_settings']['isFullScreenForced']     = true;
        $data['editor_settings']['displaySendEmailButton'] = false; // header button only; see SKILL.md §3
        return $data;
    } );

    $assets->load_editor_assets( $post, 'my-plugin-email-editor' );
    $assets->render_email_editor_html(); // includes admin-header.php and prints <div id="woocommerce-email-editor">
    return true;
}, 10, 2 );

// The package sends test emails through wp_mail(): refuse it for your post type (before its own handler on 11).
// $data is the request parameters (`email`, `postId`), or a bool once another handler answered.
add_filter( 'woocommerce_email_editor_send_preview_email', static function ( $data ) {
    if ( ! is_array( $data ) || ! isset( $data['postId'] ) || 'my_email' !== get_post_type( (int) $data['postId'] ) ) {
        return $data;
    }
    return false; // the route answers 400; or send through your own transport and return true
}, 10 );
```

`load_editor_assets()` also sets block categories, bootstraps server-side block definitions
and preloads REST responses for the post, the post type, global styles, patterns, templates and
settings; do not duplicate that work. Keep the `replace_editor` gate in a method you can call
from PHPUnit and the rendering in another: `render_email_editor_html()` loads admin-header.php.

## JS entry (`assets/src/editor/index.js`)

```js
import domReady from '@wordpress/dom-ready';
import { initializeEditor } from '@woocommerce/email-editor';

domReady( () => {
	initializeEditor( 'woocommerce-email-editor' );
} );
```

Add your own sidebar panels / personalization UI via `@wordpress/plugins` `registerPlugin`
in the same entry; the package exposes the standard editor Slot/Fills.
