# WooCommerce Gateway Class Patterns

Last updated: 2026-07-02 (WooCommerce current stable: 10.9; 11.0 scheduled 2026-07-28)

## Plugin file structure

```
payjp-for-woocommerce/
├── payjp-for-woocommerce.php       # Plugin header + bootstrap
├── includes/
│   ├── class-payjp-api.php         # PAY.JP API wrapper
│   ├── class-wc-gateway-payjp.php  # Abstract base gateway
│   ├── class-wc-gateway-payjp-card.php
│   ├── class-wc-gateway-payjp-paypay.php
│   └── class-payjp-webhook-handler.php
├── assets/
│   ├── js/
│   │   └── checkout.js             # payments.js integration
│   └── css/
│       └── checkout.css
└── readme.txt
```

## Plugin bootstrap

```php
<?php
/**
 * Plugin Name: PAY.JP for WooCommerce
 * Plugin URI:  https://example.com
 * Description: PAY.JP v2 payment gateway for WooCommerce
 * Version:     1.0.0
 * Requires at least: 6.4
 * Requires PHP: 8.0
 * WC requires at least: 8.0
 * WC tested up to: 10.9
 * Author:      Your Name
 * License:     GPL-2.0-or-later
 */

defined( 'ABSPATH' ) || exit;

define( 'PAYJP_VERSION', '1.0.0' );
define( 'PAYJP_PLUGIN_FILE', __FILE__ );

// HPOS + Cart/Checkout Blocks compatibility declaration
add_action( 'before_woocommerce_init', function () {
    if ( class_exists( \Automattic\WooCommerce\Utilities\FeaturesUtil::class ) ) {
        \Automattic\WooCommerce\Utilities\FeaturesUtil::declare_compatibility(
            'custom_order_tables',
            __FILE__,
            true
        );
        \Automattic\WooCommerce\Utilities\FeaturesUtil::declare_compatibility(
            'cart_checkout_blocks',
            __FILE__,
            true
        );
    }
} );

add_filter( 'woocommerce_payment_gateways', function ( array $gateways ): array {
    $gateways[] = 'WC_Gateway_Payjp_Card';
    $gateways[] = 'WC_Gateway_Payjp_Paypay';
    return $gateways;
} );

add_action( 'plugins_loaded', function () {
    if ( ! class_exists( 'WC_Payment_Gateway' ) ) return;

    require_once __DIR__ . '/includes/class-payjp-api.php';
    require_once __DIR__ . '/includes/class-wc-gateway-payjp.php';
    require_once __DIR__ . '/includes/class-wc-gateway-payjp-card.php';
    require_once __DIR__ . '/includes/class-wc-gateway-payjp-paypay.php';
    require_once __DIR__ . '/includes/class-payjp-webhook-handler.php';

    Payjp_Webhook_Handler::init();
}, 0 );
```

## Abstract base gateway

Extend `WC_Payment_Gateway`, NOT `WC_Payment_Gateway_CC`. Both PAY.JP gateways
fully override `payment_fields()` (payments.js widgets render the form), so the
only thing `_CC` adds — the default classic-checkout card form via
`payment_fields()`/`form()`/`field_name()` — is never used. The tokenization
helpers the card gateway needs (`tokenization_script()`, `saved_payment_methods()`,
`save_payment_method_checkbox()`) are defined on `WC_Payment_Gateway` itself
(since WC 2.6), so nothing is lost. Extending `_CC` would also make PayPay a
"card gateway" for any `instanceof WC_Payment_Gateway_CC` check.

```php
abstract class WC_Gateway_Payjp extends WC_Payment_Gateway {

    protected string $public_key  = '';
    protected string $secret_key  = '';
    protected bool   $test_mode   = false;

    protected function init_payjp_settings(): void {
        $this->title      = $this->get_option( 'title' );
        $this->public_key = $this->test_mode
            ? $this->get_option( 'test_public_key' )
            : $this->get_option( 'live_public_key' );
        $this->secret_key = $this->test_mode
            ? $this->get_option( 'test_secret_key' )
            : $this->get_option( 'live_secret_key' );
    }

    public function init_form_fields(): void {
        $this->form_fields = [
            'enabled' => [
                'title'   => '有効化',
                'type'    => 'checkbox',
                'label'   => 'この決済方法を有効にする',
                'default' => 'no',
            ],
            'title' => [
                'title'   => '表示タイトル',
                'type'    => 'text',
                'default' => $this->method_title,
            ],
            'test_mode' => [
                'title'   => 'テストモード',
                'type'    => 'checkbox',
                'label'   => 'テスト環境で動作させる',
                'default' => 'yes',
            ],
            'test_public_key' => [
                'title' => 'テスト公開鍵',
                'type'  => 'text',
            ],
            'test_secret_key' => [
                'title' => 'テスト秘密鍵',
                'type'  => 'password',
            ],
            'live_public_key' => [
                'title' => '本番公開鍵',
                'type'  => 'text',
            ],
            'live_secret_key' => [
                'title' => '本番秘密鍵',
                'type'  => 'password',
            ],
            'webhook_secret' => [
                'title'       => 'Webhookシークレット',
                'type'        => 'text',
                'description' => 'PAY.JPダッシュボードで設定したWebhookトークン',
            ],
        ];
    }

    protected function api_post( string $endpoint, array $body ): array {
        $response = wp_remote_post( 'https://api.pay.jp/v2' . $endpoint, [
            'headers' => [
                'Authorization' => 'Bearer ' . $this->secret_key,
                'Content-Type'  => 'application/json',
            ],
            'body'    => wp_json_encode( $body ),
            'timeout' => 30,
        ] );

        if ( is_wp_error( $response ) ) {
            throw new RuntimeException( $response->get_error_message() );
        }

        $data = json_decode( wp_remote_retrieve_body( $response ), true );

        if ( isset( $data['error'] ) ) {
            throw new RuntimeException(
                esc_html( $data['detail'] ?? ( $data['error']['message'] ?? 'PAY.JP error' ) )
            );
        }

        return $data;
    }

    protected function api_get( string $endpoint ): array {
        $response = wp_remote_get( 'https://api.pay.jp/v2' . $endpoint, [
            'headers' => [
                'Authorization' => 'Bearer ' . $this->secret_key,
            ],
            'timeout' => 30,
        ] );

        if ( is_wp_error( $response ) ) {
            throw new RuntimeException( $response->get_error_message() );
        }

        return json_decode( wp_remote_retrieve_body( $response ), true );
    }
}
```

## Card gateway

```php
class WC_Gateway_Payjp_Card extends WC_Gateway_Payjp {

    public function __construct() {
        $this->id                 = 'payjp_card';
        $this->has_fields         = true;
        $this->method_title       = 'PAY.JP クレジットカード';
        $this->method_description = 'PAY.JP v2 によるクレジットカード決済（Visa、Mastercard、JCB など）';
        $this->supports           = [ 'products', 'refunds' ];

        $this->init_form_fields();
        $this->init_settings();

        $this->test_mode = 'yes' === $this->get_option( 'test_mode' );
        $this->init_payjp_settings();

        add_action(
            'woocommerce_update_options_payment_gateways_' . $this->id,
            [ $this, 'process_admin_options' ]
        );
        add_action( 'wp_enqueue_scripts', [ $this, 'payment_scripts' ] );
    }

    public function payment_scripts(): void {
        if ( ! is_checkout() || is_order_received_page() ) return;
        if ( ! $this->is_available() ) return;

        wp_enqueue_script(
            'payjp-payments-js',
            'https://js.pay.jp/payments.js',
            [],
            null,
            true
        );
        wp_enqueue_script(
            'payjp-card-checkout',
            plugins_url( 'assets/js/checkout.js', PAYJP_PLUGIN_FILE ),
            [ 'payjp-payments-js' ],
            PAYJP_VERSION,
            true
        );
    }

    public function payment_fields(): void {
        try {
            $amount = (int) round( WC()->cart->get_total( 'edit' ) );
            $flow   = $this->api_post( '/payment_flows', [
                'amount'               => $amount,
                'currency'             => 'jpy',
                'payment_method_types' => [ 'card' ],
                'capture_method'       => 'automatic',
            ] );

            wp_add_inline_script(
                'payjp-card-checkout',
                'var payjpData = ' . wp_json_encode( [
                    'publicKey'    => $this->public_key,
                    'clientSecret' => $flow['client_secret'],
                    'returnUrl'    => home_url( '/payjp/return' ),
                ] ) . ';',
                'before'
            );
        } catch ( \Exception $e ) {
            echo '<p class="woocommerce-error">' . esc_html( $e->getMessage() ) . '</p>';
            return;
        }

        echo '<div id="payjp-payment-form"></div>';
        echo '<div id="payjp-error" role="alert" aria-live="polite" style="color:red;"></div>';
    }

    public function process_payment( $order_id ): array {
        $order = wc_get_order( $order_id );

        // Payment Flow was already created in payment_fields().
        // The client_secret from JS confirmPayment() gives us the flow ID on return_url.
        // Here we just mark pending and let return_url handler or webhook finalize.
        $order->update_status( 'pending', 'PAY.JP 決済処理中' );
        $order->save();

        return [
            'result'   => 'success',
            'redirect' => false,
        ];
    }

    public function process_refund( $order_id, $amount = null, $reason = '' ): bool|\WP_Error {
        $order   = wc_get_order( $order_id );
        $flow_id = $order->get_meta( '_payjp_payment_flow_id' );

        if ( ! $flow_id ) {
            return new \WP_Error( 'payjp_refund', 'Payment Flow ID が見つかりません。' );
        }

        $body = [ 'payment_flow' => $flow_id ];
        if ( null !== $amount ) {
            $body['amount'] = (int) round( $amount );
        }
        if ( $reason ) {
            $body['reason'] = 'requested_by_customer';
        }

        try {
            $this->api_post( '/payment_refunds', $body );
            return true;
        } catch ( \Exception $e ) {
            return new \WP_Error( 'payjp_refund', $e->getMessage() );
        }
    }
}
```

## PayPay gateway

```php
class WC_Gateway_Payjp_Paypay extends WC_Gateway_Payjp {

    public function __construct() {
        $this->id                 = 'payjp_paypay';
        $this->has_fields         = true;
        $this->method_title       = 'PAY.JP PayPay';
        $this->method_description = 'PAY.JP v2 による PayPay 決済';
        $this->supports           = [ 'products', 'refunds' ]; // PayPay refunds are async: API returns 'pending', final result via refund.created webhook

        $this->init_form_fields();
        $this->init_settings();

        $this->test_mode = 'yes' === $this->get_option( 'test_mode' );
        $this->init_payjp_settings();

        add_action(
            'woocommerce_update_options_payment_gateways_' . $this->id,
            [ $this, 'process_admin_options' ]
        );
        add_action( 'wp_enqueue_scripts', [ $this, 'payment_scripts' ] );
    }

    public function payment_scripts(): void {
        if ( ! is_checkout() || is_order_received_page() ) return;
        if ( ! $this->is_available() ) return;

        wp_enqueue_script( 'payjp-payments-js', 'https://js.pay.jp/payments.js', [], null, true );
        wp_enqueue_script(
            'payjp-paypay-checkout',
            plugins_url( 'assets/js/checkout.js', PAYJP_PLUGIN_FILE ),
            [ 'payjp-payments-js' ],
            PAYJP_VERSION,
            true
        );
    }

    public function payment_fields(): void {
        try {
            $amount = (int) round( WC()->cart->get_total( 'edit' ) );
            $flow   = $this->api_post( '/payment_flows', [
                'amount'               => $amount,
                'currency'             => 'jpy',
                'payment_method_types' => [ 'paypay' ],
            ] );

            wp_add_inline_script(
                'payjp-paypay-checkout',
                'var payjpData = ' . wp_json_encode( [
                    'publicKey'    => $this->public_key,
                    'clientSecret' => $flow['client_secret'],
                    'returnUrl'    => home_url( '/payjp/return' ),
                    'method'       => 'paypay',
                ] ) . ';',
                'before'
            );
        } catch ( \Exception $e ) {
            echo '<p class="woocommerce-error">' . esc_html( $e->getMessage() ) . '</p>';
            return;
        }

        echo '<div id="payjp-payment-form"></div>';
        echo '<div id="payjp-error" role="alert" aria-live="polite" style="color:red;"></div>';
    }

    public function process_payment( $order_id ): array {
        $order = wc_get_order( $order_id );
        $order->update_status( 'pending', 'PAY.JP PayPay 決済処理中' );
        $order->save();

        return [ 'result' => 'success', 'redirect' => false ];
    }
}
```

## HPOS compatibility notes

- Use `$order->get_meta()` / `$order->update_meta_data()` + `$order->save()` — never `get_post_meta()` / `update_post_meta()`
- Use `wc_get_orders( [ 'meta_key' => ..., 'meta_value' => ... ] )` for queries
- Declare HPOS compatibility in plugin bootstrap (shown above)
- Use `WC_Order` methods for order status: `$order->update_status()`, `$order->payment_complete()`

## Settings page URL

```
WooCommerce > 設定 > 決済 > PAY.JP クレジットカード
```

Admin link:
```php
admin_url( 'admin.php?page=wc-settings&tab=checkout&section=payjp_card' )
```
