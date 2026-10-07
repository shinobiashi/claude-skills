# Add-on plugin skeleton (paid provider)

```
saai-signal-mail-{id}/
├── saai-signal-mail-{id}.php     # bootstrap only
├── src/
│   ├── Plugin.php                # registers the provider; licensing client
│   ├── Provider/{Id}Provider.php # extends \Saai\SignalMail\Provider\AbstractProvider
│   └── License/Client.php        # add-on's own; core has no licensing hooks
├── tests/phpunit/…               # same checklist as core providers
├── readme.txt                    # external service disclosure for the service
└── languages/
```

```php
<?php
/**
 * Plugin Name: Signal Mail – {Service} Provider
 * Requires Plugins: saai-signal-mail
 * Text Domain: saai-signal-mail-{id}
 */
declare( strict_types=1 );

add_action( 'plugins_loaded', static function (): void {
    if ( ! class_exists( \Saai\SignalMail\Provider\ProviderInterface::class ) ) {
        add_action( 'admin_notices', static function (): void {
            echo '<div class="notice notice-error"><p>' .
                esc_html__( 'Signal Mail – {Service} Provider requires Signal Mail for WooCommerce.', 'saai-signal-mail-{id}' ) .
                '</p></div>';
        } );
        return;
    }
    require_once __DIR__ . '/vendor/autoload.php';
    add_filter( 'ssm_providers', static function ( array $providers ): array {
        $providers['{id}'] = \Saai\SignalMail\{Id}\Provider\{Id}Provider::class;
        return $providers;
    } );
}, 20 );
```

Rules (ARCHITECTURE §13):

1. Only the `ssm_providers` filter touches core. No admin pages; settings come from
   `settings_fields()` and render in core's provider settings.
2. If the service has no webhook signature, implement a source-IP allowlist in
   `verify_webhook()` and document it; the URL secret alone is not enough.
3. `default_daily_quota()` = the service's free-tier daily cap.
4. Deactivating the add-on must not break core: `ProviderRegistry` falls back to `resend`
   with a notice. Do not try to "clean up" core options on deactivation.
5. Licensing, updates, and sales are the add-on's concern; nothing about them in core.
