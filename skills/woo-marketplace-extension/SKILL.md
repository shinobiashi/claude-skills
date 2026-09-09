---
name: woo-marketplace-extension
description: >
  WooCommerce.com Marketplace向け有料プラグイン開発のためのスキル。プラグインのスキャフォールド、ファイル構造、必須ヘッダー、
  HPOS互換、Blocks/StoreAPI対応、UXガイドライン準拠、セキュリティ、国際化まで、マーケットプレイス審査に通過するための
  開発基準を網羅する。WooCommerce拡張プラグインの新規作成、マーケットプレイス対応の既存プラグイン改修、
  「Woo Marketplace」「WooCommerce.com販売」「有料プラグイン」「エクステンション開発」といったキーワードが出た場合に使用する。
  WooCommerceプラグインの構造設計やHPOS対応、Blocks対応について質問された場合にも積極的に参照すること。
---

# WooCommerce Marketplace Extension Development

WooCommerce.comマーケットプレイスで販売するプラグインは、通常のWordPressプラグインと同じ基盤だが、
追加の品質基準・UX規約・技術要件を満たす必要がある。このスキルは審査通過に必要な全要件をカバーする。

## プラグイン構造

### スキャフォールド

`create-woo-extension` を使用するか、以下の構造を手動で構成する:

```
my-extension/
├── my-extension.php          # メインプラグインファイル（ディレクトリ名と一致させる）
├── includes/                 # PHPクラス群
│   ├── class-main.php
│   ├── class-admin.php
│   └── class-frontend.php
├── src/                      # JS/React ソース（@wordpress/scripts でビルド）
│   └── index.js
├── build/                    # ビルド成果物（npm run build で生成、直接編集しない）
├── assets/
│   ├── css/
│   └── images/
├── languages/
│   └── my-extension.pot      # 翻訳テンプレート
├── templates/                # テンプレートオーバーライド用
├── changelog.txt             # 必須：マーケットプレイスアップロード時に検証される
├── readme.txt                # 必須：QIT Validation テストで存在が検証される
├── composer.json
├── package.json
├── .wp-env.json              # 開発環境設定
└── uninstall.php             # アンインストール時のクリーンアップ
```

ディレクトリ名、メインファイル名、テキストドメインを全て一致させる（ハイフン区切り、アンダースコア不可）。

### 必須プラグインヘッダー

```php
<?php
/**
 * Plugin Name:          My Extension for WooCommerce
 * Plugin URI:           https://woocommerce.com/products/my-extension/
 * Description:          プラグインの機能を簡潔に説明する
 * Version:              1.0.0
 * Author:               Your Name or Company
 * Author URI:           https://your-website.com/
 * License:              GPL v2 or later
 * License URI:          https://www.gnu.org/licenses/gpl-2.0.html
 * Text Domain:          my-extension
 * Domain Path:          /languages
 * Requires at least:    6.4
 * Tested up to:         7.1
 * Requires PHP:         8.0
 * WC requires at least: 10.0
 * WC tested up to:      11.1
 * Requires Plugins:     woocommerce
 */
```

`Author` / `Developer` フィールドは必須。プラグイン名は機能を端的に表すものにする
（例: "Appointments" であって "VendorXYZ Bookings Plugin for WooCommerce" ではない）。
製品名は Woo の商標ガイドラインに違反しないこと。他製品と区別できる独自のブランドとなる
ユニークな名前を選ぶ。

`Woo: 12345:abcdef...` ヘッダー（WooCommerce.com 上の製品識別子。アップデート配信に使われる）は、
提出時・新バージョンアップロード時に WooCommerce.com がメインファイルへ**自動付与**する。
手動で追加する必要はない（事前に含めておくことも可能）。

**バージョンサポート要件（マーケットプレイス）**: 公式の提出要件は WordPress / WooCommerce
それぞれ**直近2メジャーバージョン**のサポートと、最低 **PHP 7.4+** での動作（**PHP 8.3+ を強く推奨**）。
上記ヘッダー例の `Requires PHP: 8.0` は、より新しいPHP機能を使うプラグインが公式最低ライン
より高い要件を自主設定する例（その場合は `Requires PHP` ヘッダーで宣言し、QITの
PHP Compatibility テストの `testVersion` もこれに合わせる）。
`Tested up to` / `WC tested up to` は常に最新安定版（最終確認: 2026-09-09 時点で WP 7.1 / WC 11.1.0）に
追従させ、リリースごとに更新する。
QIT の Validation テストは提出時に readme.txt の存在と、`Requires PHP` / `Requires at least` /
`Tested up to` / `WC requires at least` / `WC tested up to` / `License` の各ヘッダーを検証する。

### 初期化パターン

```php
defined( 'ABSPATH' ) || exit;

// WooCommerceがアクティブか確認してから初期化する
add_action( 'plugins_loaded', 'my_extension_init', 10 );

function my_extension_init() {
    if ( ! class_exists( 'WooCommerce' ) ) {
        add_action( 'admin_notices', 'my_extension_wc_missing_notice' );
        return;
    }

    define( 'MY_EXTENSION_VERSION', '1.0.0' );
    define( 'MY_EXTENSION_PLUGIN_FILE', __FILE__ );
    define( 'MY_EXTENSION_PLUGIN_DIR', plugin_dir_path( __FILE__ ) );

    require_once MY_EXTENSION_PLUGIN_DIR . 'includes/class-main.php';
    My_Extension\Main::instance();
}
```

`plugins_loaded` の priority 10 で初期化し、WooCommerce関連機能が先に読み込まれることを保証する。

### Activation / Deactivation / Uninstall

```php
register_activation_hook( __FILE__, 'my_extension_activate' );
register_deactivation_hook( __FILE__, 'my_extension_deactivate' );

function my_extension_activate() {
    // DBテーブル作成、デフォルトオプション設定、capability追加など
    // flush_rewrite_rules() が必要な場合はここで
}

function my_extension_deactivate() {
    // スケジュールイベントのクリア、一時データの削除
    // ユーザーデータは残す（uninstall.php で削除）
    wp_clear_scheduled_hook( 'my_extension_cron_event' );
}
```

完全なデータ削除は `uninstall.php` で行う。deactivation ではユーザーデータを消さない。

---

## HPOS（High-Performance Order Storage）互換 — 必須

新規提出は全て HPOS 互換が必須。HPOS は注文データを `wp_posts` / `wp_postmeta` から
専用テーブル（`wp_wc_orders`, `wp_wc_orders_meta` 等）に移動する。

### 互換性宣言

```php
add_action( 'before_woocommerce_init', function() {
    if ( class_exists( \Automattic\WooCommerce\Utilities\FeaturesUtil::class ) ) {
        \Automattic\WooCommerce\Utilities\FeaturesUtil::declare_compatibility(
            'custom_order_tables',
            __FILE__,
            true
        );
    }
});
```

この宣言をメインプラグインファイルに含めないと、WooCommerceが非互換として警告を表示する。
QIT の Validation テストは HPOS 互換宣言と Cart/Checkout Blocks 互換宣言の有無を検証する
（HPOS 非互換を宣言するとエラー、Cart/Checkout Blocks 互換宣言は推奨扱い）。

### 注文データアクセスのルール

**やってはいけないこと:**
```php
// NG: 直接 post meta にアクセス
$value = get_post_meta( $order_id, '_billing_email', true );
update_post_meta( $order_id, '_custom_field', $value );

// NG: wp_posts テーブルを直接クエリ
$wpdb->get_results( "SELECT * FROM {$wpdb->posts} WHERE post_type = 'shop_order'" );
```

**正しいパターン:**
```php
// OK: WooCommerce API 経由でアクセス
$order = wc_get_order( $order_id );
$email = $order->get_billing_email();
$order->update_meta_data( '_custom_field', $value );
$order->save();

// OK: wc_get_orders() でクエリ
$orders = wc_get_orders( array(
    'meta_key'   => '_custom_field',
    'meta_value' => 'target_value',
    'limit'      => 10,
) );

// OK: OrderUtil でストレージタイプ判定
use Automattic\WooCommerce\Utilities\OrderUtil;

if ( OrderUtil::custom_orders_table_usage_is_enabled() ) {
    // HPOS が有効な場合の処理
} else {
    // レガシー post storage の場合の処理
}
```

### カスタムメタボックス

```php
use Automattic\WooCommerce\Internal\DataStores\Orders\CustomOrdersTableController;

add_action( 'add_meta_boxes', function() {
    $screen = class_exists( CustomOrdersTableController::class )
        && wc_get_container()->get( CustomOrdersTableController::class )->custom_orders_table_usage_is_enabled()
        ? wc_get_page_screen_id( 'shop-order' )
        : 'shop_order';

    add_meta_box(
        'my-extension-meta-box',
        __( 'My Extension', 'my-extension' ),
        'render_meta_box',
        $screen,
        'side',
        'high'
    );
});
```

---

## Blocks / Store API 対応

Block-based Cart/Checkout は WooCommerce のデフォルト。拡張がこれと正しく連携する必要がある。
ショートコード依存をなくし、ブロック相当の機能を提供することが提出要件として重視される。

> **注**: ブロックベースの Product Editor（`@woocommerce/product-editor`）は WC 11.0（2026-07-28）で
> コアから削除された。商品編集画面の拡張はクラシックな商品データパネル（`woocommerce_product_data_tabs` /
> `woocommerce_product_data_panels` 等）を対象に実装し、Product Editor ブロックに依存しない。

### Cart/Checkout ブロック互換宣言

```php
add_action( 'before_woocommerce_init', function() {
    if ( class_exists( \Automattic\WooCommerce\Utilities\FeaturesUtil::class ) ) {
        \Automattic\WooCommerce\Utilities\FeaturesUtil::declare_compatibility(
            'cart_checkout_blocks',
            __FILE__,
            true
        );
    }
});
```

### IntegrationInterface 実装

Cart/Checkout ブロックにフロントエンドスクリプトやデータを注入する場合:

```php
use Automattic\WooCommerce\Blocks\Integrations\IntegrationInterface;

class My_Extension_Blocks_Integration implements IntegrationInterface {
    public function get_name() {
        return 'my-extension';
    }

    public function initialize() {
        $this->register_block_frontend_scripts();
        $this->register_block_editor_scripts();
    }

    public function get_script_handles() {
        return array( 'my-extension-blocks-frontend' );
    }

    public function get_editor_script_handles() {
        return array( 'my-extension-blocks-editor' );
    }

    public function get_script_data() {
        return array(
            'option_value' => get_option( 'my_extension_setting', '' ),
        );
    }
    // ...
}

add_action( 'woocommerce_blocks_loaded', function() {
    add_action(
        'woocommerce_blocks_checkout_block_registration',
        function( $integration_registry ) {
            $integration_registry->register( new My_Extension_Blocks_Integration() );
        }
    );
});
```

### Store API でのカスタムデータ

```php
use Automattic\WooCommerce\StoreApi\Schemas\V1\CartSchema;

// データ拡張
woocommerce_store_api_register_endpoint_data( array(
    'endpoint'        => CartSchema::IDENTIFIER,
    'namespace'       => 'my-extension',
    'data_callback'   => function() {
        return array( 'custom_data' => 'value' );
    },
    'schema_callback' => function() {
        return array(
            'custom_data' => array(
                'description' => 'Custom data from My Extension',
                'type'        => 'string',
                'context'     => array( 'view', 'edit' ),
                'readonly'    => true,
            ),
        );
    },
));

// フロントからのコールバック更新
woocommerce_store_api_register_update_callback( array(
    'namespace' => 'my-extension',
    'callback'  => function( $data ) {
        // バリデーション後にセッションやメタに保存
        WC()->session->set( 'my_extension_data', sanitize_text_field( $data['value'] ) );
    },
));
```

---

## UX ガイドライン — 審査で重点的にチェックされる

### メニュー配置

トップレベルメニューの作成は禁止。WooCommerce の既存メニュー構造に統合する:

```php
// OK: WooCommerce サブメニュー
add_action( 'admin_menu', function() {
    add_submenu_page(
        'woocommerce',
        __( 'My Extension Settings', 'my-extension' ),
        __( 'My Extension', 'my-extension' ),
        'manage_woocommerce',
        'my-extension',
        'render_settings_page'
    );
});

// OK: WooCommerce Settings タブ
add_filter( 'woocommerce_settings_tabs_array', function( $tabs ) {
    $tabs['my_extension'] = __( 'My Extension', 'my-extension' );
    return $tabs;
}, 50 );
```

### やってはいけないこと

- 独自のテレメトリ／トラッキングコードの挿入
- WP Admin に大きなバナー、ブランディング、広告を表示
- マーケットプレイス外へのアップセルリンク、アフィリエイトリンク、スパムリンク
- 初回起動時のレビュー依頼（セットアップ完了・一定期間使用後に表示する）
- コアインターフェースの見た目の変更（コンテナの形状変更など）

### 心がけること

- WordPress / WooCommerce 既存のUIコンポーネントを再利用する
- インターフェース内の案内テキストは120–140文字以内に収め、詳細はドキュメントに
- モバイルレスポンシブを確保する（マーチャントは24/7モバイルで店舗を確認する）
- セットアップフローをシンプルに、ユーザーを成功に導く

---

## セキュリティ

QIT の Security Test で自動スキャンされる。以下を徹底する:

```php
// Nonce 検証
if ( ! wp_verify_nonce( $_POST['_nonce'], 'my_extension_action' ) ) {
    wp_die( 'Security check failed' );
}

// Capability チェック
if ( ! current_user_can( 'manage_woocommerce' ) ) {
    wp_die( 'Unauthorized' );
}

// 入力サニタイズ
$value = sanitize_text_field( wp_unslash( $_POST['field'] ?? '' ) );
$email = sanitize_email( wp_unslash( $_POST['email'] ?? '' ) );
$int   = absint( $_POST['count'] ?? 0 );

// 出力エスケープ
echo esc_html( $value );
echo esc_attr( $attribute );
echo esc_url( $url );
echo wp_kses_post( $html_content );

// データベースクエリのプリペアドステートメント
$results = $wpdb->get_results(
    $wpdb->prepare(
        "SELECT * FROM {$wpdb->prefix}my_table WHERE id = %d AND status = %s",
        $id,
        $status
    )
);
```

機密データ（APIキー等）は `wp_options` に平文で保存しない。暗号化するか、
外部サービス認証の場合は OAuth フローを推奨。

外部ライブラリの利用は最小限にする。使用する場合は、必要部分のみ含め、
セキュリティ上の責任を負う覚悟で。WordPress互換のライブラリがあればそちらを優先する。

---

## 国際化（i18n）

すべてのテキストは英語で記述し、翻訳関数でラップする:

```php
// 翻訳文字列
__( 'Settings saved.', 'my-extension' )
_e( 'Enable feature', 'my-extension' )
esc_html__( 'Order total', 'my-extension' )

// プレースホルダー付き
sprintf(
    /* translators: %s: order number */
    __( 'Order #%s has been updated.', 'my-extension' ),
    $order_number
)

// 複数形
sprintf(
    /* translators: %d: number of items */
    _n( '%d item', '%d items', $count, 'my-extension' ),
    $count
)
```

テキストドメインはプラグインディレクトリ名と一致させる。
日本市場向けの場合、`languages/my-extension-ja.po` / `.mo` を同梱する。
POTファイルは `wp i18n make-pot . languages/my-extension.pot` で生成。

JavaScript の翻訳は `wp_set_script_translations()` を使用:

```php
wp_set_script_translations( 'my-extension-script', 'my-extension', plugin_dir_path( __FILE__ ) . 'languages' );
```

---

## 拡張性

他の開発者がカスタマイズできるよう、適切にアクション/フィルターを公開する:

```php
// アクションフック
do_action( 'my_extension_before_process', $order );
do_action( 'my_extension_after_process', $order, $result );

// フィルターフック
$settings = apply_filters( 'my_extension_default_settings', array(
    'enabled' => 'yes',
    'title'   => __( 'Default Title', 'my-extension' ),
));

// テンプレートオーバーライド対応
function my_extension_get_template( $template_name, $args = array() ) {
    $template = locate_template( 'my-extension/' . $template_name );
    if ( ! $template ) {
        $template = MY_EXTENSION_PLUGIN_DIR . 'templates/' . $template_name;
    }
    if ( $args ) {
        extract( $args, EXTR_SKIP );
    }
    include $template;
}
```

---

## コーディング規約

- WordPress Coding Standards に従う（PHPCS で `WordPress-Extra` ルールセット。
  wpcs 3.4.1 は PHPCS `^3.13.5` が必要で PHPCS 4.x は非対応。最終確認: 2026-09-09）
- PHP DocBlock コメントを全関数に付与
- God Object を避け、単一責任原則に従う
- ビジネスロジックとプレゼンテーションロジックを分離
- `WP_DEBUG` を有効にした状態でエラー・警告ゼロを確認
- `Automattic\WooCommerce\Internal` 名前空間のクラスは使用禁止（後方互換性保証なし）
- `@internal` マークされたコードも使用しない

---

## changelog.txt

マーケットプレイスアップロード時に `changelog.txt` の存在とフォーマットが検証される:

```
*** My Extension Changelog ***

= 1.0.0 - 2025-04-01 =
* Feature - Initial release
* Feature - HPOS support
* Feature - Block checkout compatibility
* Tweak - Improved settings UI
* Fix - Fixed validation error on checkout
```

バージョン番号はプラグインヘッダーの `Version` と一致させること。
アップロード時によくあるエラーは「`changelog.txt` のフォーマット不一致」「ヘッダーの `Version` と
アップロード時に入力したバージョンの不一致」「ヘッダーの `Version` と `changelog.txt` の不一致」。
新バージョンのデプロイには QIT の Activation / Security / Malware テスト通過が必須。

---

## 最新情報の確認先

本スキルのバージョン記述は 2026-09-09 時点（WordPress 7.1 / WooCommerce 11.1.0（2026-09-03）。
WC 11.0（2026-07-28）でブロックベース Product Editor がコアから削除済み）。バージョンに言及する前に
最新を確認すること:

- WooCommerce リリース: https://developer.woocommerce.com/releases/
- マーケットプレイス開発者ドキュメント: https://developer.woocommerce.com/docs/woo-marketplace/
  （旧 `woocommerce.com/document/` 配下の URL はここへリダイレクトされる）
- 提出要件: https://developer.woocommerce.com/docs/woo-marketplace/submitting-your-product/
- バージョンアップ時のガイドライン: https://developer.woocommerce.com/docs/woo-marketplace/product-update-guidelines/

## 関連スキル

- `wc-development` — WooCommerce拡張の実装詳細（HPOS、Blocks、決済、REST API）
- `woo-marketplace-qit` — QITテストと品質保証
- `woo-marketplace-submission` — 提出・審査・リリース後運用
- `woo-marketplace-content` — 製品ページ・ドキュメント作成
- `woo-marketplace-pricing` — 価格設定
