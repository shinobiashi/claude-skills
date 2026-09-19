# 同梱プラグイン カタログ

`.wp-env.json` の `plugins` に書く URL と、入れる／入れないの判断基準。URL はすべて実際に稼働している
`.wp-env.json`（jp4wc-rakusync / saai-points-wallet）で取得できることを確認済みのもの。

## 並び順（重要）

```
1. WooCommerce
2. 依存先プラグイン（Japanized for WooCommerce など、開発対象が依存するもの）
3. "."（開発対象のプラグイン）
4. 開発補助プラグイン
```

開発対象が `Requires Plugins: woocommerce` を宣言している場合、依存先が先に有効化されていないと
有効化に失敗する。`"."` を先頭に置かない。

## 常に入れる（baseline）

| プラグイン | URL | development | tests | 用途 |
|---|---|---|---|---|
| WooCommerce | `https://downloads.wordpress.org/plugin/woocommerce.zip` | ✅ | ✅ | 動作基盤 |
| Query Monitor | `https://downloads.wordpress.org/plugin/query-monitor.zip` | ✅ | ✅ | SQL・フック・HTTP API（`wp_remote_request`）・Action Scheduler の可視化 |
| WP Mail Logging | `https://downloads.wordpress.org/plugin/wp-mail-logging.zip` | ✅ | ✅ | 送信メールを DB に記録。実メールを飛ばさず内容確認 |
| User Switching | `https://downloads.wordpress.org/plugin/user-switching.zip` | ✅ | ✅ | `manage_woocommerce` など権限別の動作確認 |

## 既定で入れる（default ON）

| プラグイン | URL | development | tests | 用途 |
|---|---|---|---|---|
| WP Crontrol | `https://downloads.wordpress.org/plugin/wp-crontrol.zip` | ✅ | ✅ | WP-Cron イベントの確認・手動実行 |
| Plugin Check (PCP) | `https://downloads.wordpress.org/plugin/plugin-check.zip` | ✅ | ✅ | WordPress.org 審査前チェック |
| WC Smooth Generator | `https://github.com/woocommerce/wc-smooth-generator/releases/latest/download/wc-smooth-generator.zip` | ✅ | ❌ | 商品・注文・顧客のダミーデータ大量生成 |

WC Smooth Generator は **tests 環境に入れない**。自動テストは fixture 起点で決定的に保つ。
wordpress.org では配布されておらず、GitHub Releases の zip を指定する。

## リポジトリの内容から判断して提案する（contextual）

提案するときは「なぜ必要と判断したか」を添えてユーザーに確認する。黙って足さない。

| プラグイン / テーマ | URL | 提案する条件 |
|---|---|---|
| Japanized for WooCommerce | `https://downloads.wordpress.org/plugin/woocommerce-for-japan.zip` | コードや CLAUDE.md に `jp4wc` / `JP4WC` / `woocommerce-for-japan` への言及がある、または都道府県・配送時間帯・日本の決済など JP4WC の機能と連携する |
| Health Check & Troubleshooting | `https://downloads.wordpress.org/plugin/health-check.zip` | 他プラグインとの競合切り分けや Loopback/HTTP 到達性の確認が必要（外部 API 連携プラグインなど） |
| Storefront（テーマ） | `https://downloads.wordpress.org/theme/storefront.zip`（`themes` に書く） | クラシックテーマ上の表示・テンプレート上書きを確認する必要がある |
| Debug Bar | `https://downloads.wordpress.org/plugin/debug-bar.zip` | 既定では入れない（Query Monitor と役割が重なる）。ユーザーが明示的に望んだ場合のみ |

Japanized for WooCommerce の wordpress.org 上のスラッグは **`woocommerce-for-japan`**。プラグイン名と
異なるので URL を推測で書かない。

## バージョンの固定

- `woocommerce.zip` は最新安定版。特定の版で検証したいときは
  `https://downloads.wordpress.org/plugin/woocommerce.<version>.zip`（例: `woocommerce.11.0.0.zip`）
- WordPress 本体は `"core": null`（最新の製品版）が既定。固定するときは `"WordPress/WordPress#7.0"` の形
- 「対応最小バージョンでの動作確認」は CI のマトリクスで担うのが基本。ローカルは最新で開発し、
  再現確認が必要なときだけ一時的に固定する
