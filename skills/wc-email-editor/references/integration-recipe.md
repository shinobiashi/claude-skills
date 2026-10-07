# Integration recipe (PHP)

Modeled on `plugins/woocommerce/src/Internal/EmailEditor/{Integration,PageRenderer}.php`
(WooCommerce trunk, 2026-10-07). Replace `Vendor\` with your Strauss prefix and `my_email`
with your post type.

## Bootstrap adapter

```php
namespace My\Plugin\Editor;

use Vendor\Automattic\WooCommerce\EmailEditor\Email_Editor_Container as Bundled;
use Vendor\Automattic\WooCommerce\EmailEditor\Bootstrap;

final class Package {
    private static ?object $container = null;

    public static function boot(): void {
        add_action( 'plugins_loaded', static function (): void {
            if ( self::host_editor_active() ) {
                return; // WooCommerce's instance will register our post type via the shared filter.
            }
            Bundled::container()->get( Bootstrap::class )->init();
        }, 20 );
    }

    /** @return object DI container of whichever package instance is live. */
    public static function container(): object {
        if ( null === self::$container ) {
            self::$container = self::host_editor_active()
                ? \Automattic\WooCommerce\EmailEditor\Email_Editor_Container::container()
                : Bundled::container();
        }
        return self::$container;
    }

    /** Class name of a package service in the live instance. */
    public static function cls( string $relative ): string {
        $ns = self::host_editor_active() ? 'Automattic\\WooCommerce\\EmailEditor\\' : 'Vendor\\Automattic\\WooCommerce\\EmailEditor\\';
        return $ns . $relative;
    }

    public static function host_editor_active(): bool {
        // Confirm the feature id against WooCommerce's FeaturesController for your minimum version.
        return class_exists( \Automattic\WooCommerce\Utilities\FeaturesUtil::class )
            && \Automattic\WooCommerce\Utilities\FeaturesUtil::feature_is_enabled( 'block_email_editor' );
    }
}
```

## Post type, page detection, editor screen

```php
add_filter( 'woocommerce_email_editor_post_types', static function ( array $types ): array {
    $types[] = [
        'name' => 'my_email',
        'args' => [
            'labels'          => [ 'name' => __( 'Campaigns', 'my-plugin' ), 'singular_name' => __( 'Campaign', 'my-plugin' ) ],
            'rewrite'         => [ 'slug' => 'my_email' ],
            'supports'        => [ 'title', 'editor' => [ 'default-mode' => 'template-locked' ], 'excerpt', 'custom-fields' ],
            'capability_type' => 'my_email',
            'capabilities'    => array_fill_keys(
                [ 'edit_post', 'read_post', 'delete_post', 'edit_posts', 'edit_others_posts', 'delete_posts', 'publish_posts', 'read_private_posts', 'create_posts' ],
                'manage_woocommerce'
            ),
            'map_meta_cap'    => false,
        ],
        'meta' => [], // [ [ 'key' => '_my_subject', 'args' => [ 'type' => 'string', 'single' => true, 'show_in_rest' => true ] ], … ]
    ];
    return $types;
} );

add_filter( 'woocommerce_is_email_editor_page', static function ( bool $is ): bool {
    if ( $is || ! is_admin() || ! isset( $_GET['post'], $_GET['action'] ) || 'edit' !== $_GET['action'] ) { // phpcs:ignore WordPress.Security.NonceVerification.Recommended
        return $is;
    }
    $post = get_post( (int) $_GET['post'] ); // phpcs:ignore WordPress.Security.NonceVerification.Recommended
    return $post instanceof \WP_Post && 'my_email' === $post->post_type;
} );

add_filter( 'replace_editor', static function ( $replace, \WP_Post $post ) {
    if ( 'my_email' !== $post->post_type ) {
        return $replace;
    }
    $container = Package::container();
    $assets    = $container->get( Package::cls( 'Engine\\Assets_Manager' ) );
    $assets->set_assets_path( MY_PLUGIN_DIR . 'assets/build/editor/' ); // holds style.css + style.asset.php
    $assets->set_assets_url( MY_PLUGIN_URL . 'assets/build/editor/' );

    $asset = require MY_PLUGIN_DIR . 'assets/build/editor/index.asset.php';
    wp_register_script( 'my-plugin-email-editor', MY_PLUGIN_URL . 'assets/build/editor/index.js', $asset['dependencies'], $asset['version'], true );
    wp_set_script_translations( 'my-plugin-email-editor', 'my-plugin' );
    wp_enqueue_script( 'my-plugin-email-editor' );

    add_filter( 'woocommerce_email_editor_script_localization_data', static function ( array $data ): array {
        $data['urls']['listings'] = admin_url( 'admin.php?page=my-plugin' );
        $data['urls']['send']     = admin_url( 'admin.php?page=my-plugin' );
        $data['urls']['back']     = admin_url( 'admin.php?page=my-plugin' );
        $data['editor_settings']['isFullScreenForced']     = true;
        $data['editor_settings']['displaySendEmailButton'] = false; // we send previews through our own transport
        return $data;
    } );

    $assets->load_editor_assets( $post, 'my-plugin-email-editor' );
    $assets->render_email_editor_html(); // includes admin-header.php and prints <div id="woocommerce-email-editor">
    return true;
}, 10, 2 );
```

`load_editor_assets()` also sets block categories, bootstraps server-side block definitions
and preloads REST responses for the post, the post type, global styles, patterns, templates and
settings; do not duplicate that work.

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
