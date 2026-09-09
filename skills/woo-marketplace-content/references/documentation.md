# ドキュメント作成ガイド

Vendor Dashboard の Documentation セクションで管理するドキュメントの作成ガイド。
ユーザー向けドキュメントと開発者向けドキュメントの2種類がある。

> **重要**: WooCommerce公式ドキュメントポータルへのドキュメント掲載はUXレビューの審査対象。
> ドキュメントが未掲載だとUXレビューで審査がブロックされる（実績あり）。
> コードレビュー通過後すぐに着手し、UXレビュー開始前に公開を完了させること。

## ドキュメントポータルへの公開手順

1. Vendor Dashboard にログイン
2. **Documentation** セクションへ移動
3. **Add New Document** をクリック
4. **Gutenbergブロックエディタ** でコンテンツを作成（下記テンプレート参照）
5. スクリーンショットを **画像ブロック** で挿入（altテキスト必須）
6. **Publish** で公開
7. 公開後のURLを審査フォームの "Notes for reviewers" に記載しておくと審査がスムーズ

## ドキュメントワークフロー

1. **Organize（構成）** — 対象読者を考え、セクション構成を決める
2. **Write（執筆）** — Content Style Guide に従って書く
3. **Review（レビュー）** — 実際にプラグインを操作しながら手順を確認
4. **Publish（公開）** — Vendor Dashboard で公開
5. **Maintain（保守）** — バージョンアップごとに更新

## ユーザー向けドキュメント

### 基本テンプレート（一般的な拡張）

```markdown
# [製品名]

[製品名](リンク) allows your WooCommerce store to [1文で機能説明].

## Installation

1. Download the .zip file from your WooCommerce account.
2. Go to: **WordPress Admin > Plugins > Add New > Upload Plugin**
   and select the ZIP file you just downloaded.
3. Click **Install Now** and then **Activate** the extension.

More information at:
[Install and Activate Plugins/Extensions](https://woocommerce.com/document/how-to-install-and-activate-plugins-extensions/).

## Setup and Configuration

### Getting Started

After activating [製品名], navigate to
**WooCommerce > Settings > [タブ名]** to configure the extension.

### [設定セクション1の名前]

[このセクションで何ができるかを1〜2文で説明]

| Setting | Description | Default |
|---------|-------------|---------|
| **[設定項目1]** | [何をする設定か] | [デフォルト値] |
| **[設定項目2]** | [何をする設定か] | [デフォルト値] |
| **[設定項目3]** | [何をする設定か] | [デフォルト値] |

### [設定セクション2の名前]

[同様に設定項目を説明]

## Usage

### [ユースケース1: 基本的な使い方]

[ステップバイステップで操作手順を説明]

1. Go to **[メニューパス]**
2. Click **[ボタン名]**
3. [操作内容]
4. Click **Save changes**

### [ユースケース2: 応用的な使い方]

[同様にステップバイステップ]

## Frequently Asked Questions

### [質問1]?

[回答]

### [質問2]?

[回答]

## Troubleshooting

### [問題1の症状]

**Cause:** [原因]
**Solution:** [解決方法]

### [問題2の症状]

**Cause:** [原因]
**Solution:** [解決方法]

### Need More Help?

If you're still experiencing issues, please
[submit a support ticket](https://woocommerce.com/my-account/create-a-ticket/)
and our team will be happy to assist.
```

### 決済ゲートウェイ用テンプレート

```markdown
# [ゲートウェイ名]

[ゲートウェイ名](リンク) allows your WooCommerce store to accept [決済方法].

* [特徴1]
* [特徴2]
* [特徴3]

## Requirements

* WooCommerce [version]+
* WordPress [version]+
* [決済プロバイダのアカウント]
* SSL certificate (HTTPS required)

## Installation

1. Download the .zip file from your WooCommerce account.
2. Go to: **WordPress Admin > Plugins > Add New > Upload Plugin**
   and select the ZIP file you just downloaded.
3. Click **Install Now** and then **Activate** the extension.

## Setup and Configuration

### 1. Create a [プロバイダ名] Account

[アカウント作成手順とAPIキー取得方法]

### 2. Connect [プロバイダ名] to WooCommerce

1. Go to **WooCommerce > Settings > Payments**
2. Locate **[ゲートウェイ名]** and click **Manage**
3. Check **Enable [ゲートウェイ名]**
4. Enter your **API Key** and **Secret Key**
5. For initial testing, enable **Test Mode**
6. Click **Save changes**

### 3. Test Your Setup

1. Enable **Test Mode** in the gateway settings
2. Place a test order using [テスト用カード番号等]
3. Verify the order appears in **WooCommerce > Orders**
4. Confirm the payment in your [プロバイダ名] dashboard
5. When satisfied, disable **Test Mode** for live transactions

### Payment Settings

| Setting | Description | Default |
|---------|-------------|---------|
| **Enable/Disable** | Enable this payment method | Disabled |
| **Title** | Payment method title shown at checkout | [デフォルト名] |
| **Description** | Payment method description at checkout | [デフォルト文] |
| **Test Mode** | Enable test/sandbox mode | Enabled |
| **API Key** | Your [プロバイダ名] API key | — |
| **Secret Key** | Your [プロバイダ名] secret key | — |

## Refunds

[製品名] supports both full and partial refunds:

1. Go to **WooCommerce > Orders** and select the order
2. Click **Refund**
3. Enter the refund amount
4. Click **Refund via [ゲートウェイ名]**

## Troubleshooting

### Payment fails with "[エラーメッセージ]"

**Cause:** [原因]
**Solution:** [解決方法]

### Gateway not showing at checkout

**Cause:** The gateway may not be enabled or your store currency
may not be supported.
**Solution:**
1. Go to **WooCommerce > Settings > Payments** and verify
   the gateway is enabled
2. Check that your store currency is in the supported list
3. If using block checkout, clear your browser cache
```

## 開発者向けドキュメント

### フック & フィルター一覧

```markdown
# Developer Documentation

## Actions

### `my_extension_before_process`

Fires before the extension processes an order.

**Parameters:**
* `$order` (WC_Order) — The order being processed.

**Example:**
\```php
add_action( 'my_extension_before_process', function( $order ) {
    // Custom logic before processing
}, 10, 1 );
\```

### `my_extension_after_process`

Fires after the extension has processed an order.

**Parameters:**
* `$order` (WC_Order) — The processed order.
* `$result` (array) — Processing result data.

## Filters

### `my_extension_default_settings`

Filters the default settings array.

**Parameters:**
* `$settings` (array) — Default settings.

**Returns:** array

**Example:**
\```php
add_filter( 'my_extension_default_settings', function( $settings ) {
    $settings['custom_option'] = 'value';
    return $settings;
} );
\```

## Template Overrides

Copy template files to your theme's directory to customize output:

| Template | Description |
|----------|-------------|
| `templates/frontend/display.php` | Main frontend display |
| `templates/emails/notification.php` | Email notification |

To override, copy to:
`your-theme/my-extension/frontend/display.php`
```

## 文体ルール

### US English

WooCommerce.com はUS Englishを使用:
- "color" not "colour"
- "customize" not "customise"
- "center" not "centre"
- 3項目以上の列挙には Oxford comma を使用
- 強調のための ALL CAPS は使わない

### 用語

WooCommerce公式用語に従う:
- **add-on**（名詞/形容詞）, **add on**（動詞）
- **admin** — 管理者ユーザーを指す場合
- **checkout** — 1語（check-outではない）
- **ecommerce** — eのあとにハイフンなし（e-commerceではない）
- **email** — e-mailではない
- **plugin** — add-on/extensionと互換で使える
- **setup**（名詞）, **set up**（動詞）
- **WooCommerce** — 常にキャメルケース

### 見出しレベル

- h1は使わない（製品名が自動的にh1）
- h2でメインセクション
- h3でサブセクション
- レベルをスキップしない（h2の次にh4を置かない）
- h4以降は避ける（深すぎると読みにくい）
- 見出しはセンテンスケース（先頭語と固有名詞のみ大文字）

### UIパスの記述

WordPressのメニューパスは太字で:
```
Go to **WooCommerce > Settings > Payments**
```

ボタン名も太字:
```
Click **Save changes**
```

### スクリーンショットの挿入

ドキュメント内のスクリーンショットに関するルール:
- 設定画面やUI要素を説明する箇所に添える
- 個人情報・テストデータを隠す
- 適切なサイズ（幅800–1200pxが目安）
- altテキストを必ず付ける
- 高解像度ディスプレイ対応（2x推奨）

## ドキュメントの保守

バージョンアップ時に以下をチェック:

- [ ] 新機能のドキュメントを追加
- [ ] 変更された設定項目を更新
- [ ] 削除された機能の記述を削除
- [ ] スクリーンショットが最新UIと一致しているか
- [ ] バージョン番号の参照を更新
- [ ] トラブルシューティングに新しい既知の問題を追加
- [ ] FAQに新しい質問を追加（サポートチケットから頻出質問を抽出）
