# Submission Form Field Guide

Vendor Dashboard の Submit Product フォーム全フィールドに対する記入ガイド。
プラグイン情報をヒアリングした上で、各フィールドに適切な英語テキストを生成する。

## 手順

### ヒアリング項目

フォーム記入テキストを生成するために、以下の情報を確認する:

1. プラグイン名（英語）
2. 何をするプラグインか（1文で）
3. 主要機能（3〜5個）
4. ターゲットユーザー
5. なぜ作ったか / 市場にない理由
6. 競合製品（2〜3個、WooCommerce.com内）
7. 想定月間販売数
8. 希望価格（年額 USD）
9. 他のチャネルで販売しているか
10. 対応言語
11. 連携する他の拡張（あれば）
12. 前提となるプラグイン（あれば）
13. デモサイトURL
14. ウォークスルー動画URL

---

## Product Details セクション

### Name（4〜60文字、必須）

ルール:
- 4〜60文字
- 1〜5語に収める（少ないほど良い — 公式ガイダンス）
- アクセント文字（é, ü 等）を使わない
- "best" や "amazing" のような最上級の形容詞を使わない
- 既存のマーケットプレイス製品名と重複しない
- WooCommerce等の商標ガイドラインに準拠（https://woocommerce.com/trademark-guidelines/）:
  Wooマークを製品名そのものに組み込まない。「Product Name for WooCommerce」は可、
  「WooCommerce Product Name」は不可

良い例:
```
Token Expiry Notifier
Advanced Shipping Labels
Order Fulfillment Tracker
Bulk Price Editor
```

悪い例:
```
❌ WooCommerce Token Plugin        → 商標「WooCommerce」を冠にしない
❌ BestShop Pro Notification Tool  → ブランド名が前面に出すぎ
❌ Plugin                          → 4文字未満 / 汎用的すぎる
❌ Tökën Nötifier                  → アクセント文字
```

### Category（必須）

マーケットプレイスのカテゴリから最も適切なものを1つ選択。
主な選択肢:
- Customer service
- Marketing
- Payments
- Shipping, delivery and fulfillment
- Store management
- Merchandising
- Cart and checkout features
- Product type
- Store content and customizations
- Subscriptions and memberships

### Product short description（140文字以内、必須）

製品タグラインとして表示される。Google検索結果にも使われる。

テンプレート:
```
[動詞] [対象] when/for [条件/ユースケース].
```

例:
```
Notify customers when their saved payment tokens are about to expire.
```
```
Automatically generate and print shipping labels for major carriers.
```
```
Let customers schedule delivery dates at checkout.
```

ルール:
- 1文で完結
- 140文字以内
- 動詞から始めると強い印象
- 技術用語よりベネフィットを優先
- ピリオドで終える

---

## Business Details セクション

### List your product's 3-5 best features（必須）

箇条書きで3〜5個。各項目は1〜2文で機能とベネフィットを簡潔に。

テンプレート:
```
1. [機能名] — [マーチャントにとってのベネフィット]
2. [機能名] — [マーチャントにとってのベネフィット]
3. [機能名] — [マーチャントにとってのベネフィット]
4. [機能名] — [マーチャントにとってのベネフィット]
5. [機能名] — [マーチャントにとってのベネフィット]
```

例（Token Expiry Notifier の場合）:
```
1. Automatic email notifications — Customers receive timely alerts
   before their saved payment tokens expire, reducing failed renewals.
2. Customizable notification schedule — Store owners can set how many
   days before expiry to send reminders (e.g., 30, 14, 7 days).
3. WooCommerce email template integration — Notifications use the
   standard WooCommerce email system, matching your store's branding.
4. Admin dashboard widget — Quick overview of expiring tokens across
   all customers, helping support teams stay proactive.
5. HPOS and block checkout compatible — Built for modern WooCommerce
   stores with full HPOS and block-based checkout support.
```

### What are the product benefits?（必須）

機能ではなくビジネス上のベネフィットを記述。マーチャントの視点で
「これを使うと何が良くなるか」を説明する。

テンプレート:
```
[製品名] helps store owners [主要ベネフィット] by [手段].

Key benefits:
- [ベネフィット1]: [具体的な効果]
- [ベネフィット2]: [具体的な効果]
- [ベネフィット3]: [具体的な効果]

This results in [最終的なビジネスインパクト].
```

例:
```
Token Expiry Notifier helps store owners reduce involuntary churn
and failed subscription renewals by proactively alerting customers
before their saved payment methods expire.

Key benefits:
- Fewer failed payments: Customers update their card details before
  expiry, preventing declined transactions and lost revenue.
- Reduced support workload: Automated notifications eliminate the
  need for manual outreach to customers with expiring cards.
- Better customer experience: Proactive communication builds trust
  and reduces frustration from unexpected payment failures.

This results in higher subscription retention rates and more
predictable recurring revenue for store owners.
```

### Why was this product built? What is the supporting rationale?（必須）

審査チームはここで市場ニーズと製品の妥当性を判断する。
以下の3点を含める:

1. **問題の特定**: 市場にどんなギャップがあるか
2. **根拠**: フォーラム投稿、機能リクエスト、顧客の声、市場データ
3. **ソリューション**: この製品がどうその問題を解決するか

テンプレート:
```
Problem:
[具体的な市場の問題を2〜3文で]

Evidence:
- [根拠1: フォーラムリンク、機能リクエスト数、顧客フィードバック等]
- [根拠2]
- [根拠3]

Solution:
[この製品がどう問題を解決するかを2〜3文で]
```

例:
```
Problem:
WooCommerce stores using saved payment methods (tokenization) have
no built-in way to notify customers when their stored cards are
about to expire. This leads to failed renewal payments, involuntary
churn, and increased support tickets.

Evidence:
- Multiple feature requests in WooCommerce community forums asking
  for token expiry notifications.
- Subscription-based stores report 5-10% of renewals fail due to
  expired payment methods.
- No existing extension on the WooCommerce Marketplace addresses
  this specific need.

Solution:
Token Expiry Notifier fills this gap by monitoring stored payment
tokens and automatically sending customizable email reminders
before expiry. This gives customers time to update their payment
details, preventing failed charges and reducing churn.
```

注意: WooCommerceの公式ガイドラインに記載されている通り、
「feature requests, mention custom customers or number of interactions
with prospective customers (forums, social media, support), and showcase trends」
を含めること。

### How many monthly sales do you anticipate?

正直な数字を記入。過大な数字は信頼性を下げる。

目安:
- ニッチなプラグイン: 5–20/月
- 中程度の需要: 20–50/月
- 広い需要: 50–200/月

例:
```
15-30 sales per month initially, growing to 50+ as the product
gains reviews and marketplace visibility.
```

### How does your product compare to similar products?（必須）

2〜3個の競合製品と比較。マーケットプレイス内外の製品を含めてよい。
自社製品の強みを客観的に説明する。

テンプレート:
```
Currently, there is no direct equivalent on the WooCommerce
Marketplace that specifically addresses [機能].

The closest alternatives are:

1. [競合A] ($XX/year) — [何をするか]. However, [差別化ポイント].
2. [競合B] ($XX/year) — [何をするか]. However, [差別化ポイント].

[製品名] differentiates by [独自の価値提案].
```

---

## Pricing セクション

### Suggested price（必須）

ドロップダウンから選択（$75, $99, $149, $199, $249 等）。

選択の根拠をスキルの価格フレームワークで算出する。
マーケットプレイスはシングルサイトライセンスのみで販売される。自社サイトで販売している場合は、
自社のシングルサイトライセンス価格と揃え（closely match）、それより高くしない。

### Is this product sold elsewhere?（必須）

他のチャネル（自社サイト、他マーケットプレイス等）で販売している場合は
「Yes」を選択し、URLと価格を記入。

マーケットプレイス価格 ≒ 他チャネルのシングルサイトライセンス価格（それより高くしない）のルールを遵守。

---

## Languages セクション

対応言語を選択。最低限 English (United States) を含める。
日本市場向けの場合は Japanese も追加。

---

## Integrations and requirements セクション

### Products with which your product offers special integration

連携する他のWooCommerce拡張があれば選択。
例: WooCommerce Subscriptions, WooCommerce Payments

### Other WooCommerce.com product(s) that needs to be activated

前提となるマーケットプレイス製品があれば記入。
依存関係がない場合は空欄。

### WordPress.org plugin slugs

前提となるWordPress.orgプラグインのスラッグを記入。
例: `hello-dolly, akismet`
依存関係がない場合は空欄（"Leave blank if none"）。

---

## Testing セクション

### Provide instructions on how to install, configure, and use the product（必須）

審査チームがテストする手順。明確で再現可能な手順を記述。

テンプレート:
```
Installation:
1. Upload the ZIP file via WordPress Admin > Plugins > Add New > Upload Plugin
2. Activate the plugin
3. Navigate to WooCommerce > Settings > [Tab Name]

Configuration:
1. Enter your [API key / settings] at WooCommerce > Settings > [Tab]
2. Enable [Feature A] by checking the checkbox
3. Set [Option B] to your preferred value
4. Click "Save changes"

Testing the main flow:
1. [Step 1: specific action]
2. [Step 2: expected result]
3. [Step 3: verification]

Testing with block checkout:
1. Ensure a block-based checkout page is active
2. [Steps to test block checkout compatibility]

Admin features:
1. Navigate to [Admin page]
2. [What to look for]
```

### Walkthrough video（必須）

審査チーム専用（一般公開されない）。YouTube/Vimeo/Loom の限定公開URLを記入。

内容:
- インストールとアクティベーション（30秒）
- 設定画面のウォークスルー（1〜2分）
- 主要機能のデモ（2〜3分）
- 合計3〜5分程度

例:
```
https://www.loom.com/share/xxxxxxxxxxxx
```

### Demo site URL（必須）

審査チームが実際に操作できるデモ環境のURL。

例:
```
https://demo.your-domain.com/
```

InstaWP を使う場合:
```
https://your-demo.instawp.xyz/
```

### Testing data URL

テスト用のインポートデータがある場合にURLを記入。
なければ空欄可。

例:
```
https://your-domain.com/test-data/sample-orders.csv
```

### Testing login credentials

デモサイトのログイン情報。

例:
```
Admin: https://demo.your-domain.com/wp-admin/
Username: reviewer
Password: SecureTestPass123!

Customer account (for frontend testing):
Email: customer@test.com
Password: TestCustomer123!
```

---

## Product Upload セクション

### Product slug（必須）

プラグインのディレクトリ名と一致させる。一度設定すると変更不可。

ルール:
- 全て小文字
- ハイフン区切り（アンダースコア不可）
- 簡潔で機能を表す

例:
```
token-expiry-notifier
```

### Currently listed on WordPress.org

WordPress.orgに無料版がある場合はチェック。
チェックすると一部フィールドが自動入力される。

### Zip file

Product slug 入力後にアップロード可能。30MB以下。
ZIPのファイル名とルートディレクトリ名がProduct slugと一致すること。

```
token-expiry-notifier.zip
└── token-expiry-notifier/
    ├── token-expiry-notifier.php
    ├── changelog.txt
    └── ...
```

---

## Additional Information セクション

### Notes for reviewers

審査チームへの補足情報。以下を含めると審査がスムーズ:

テンプレート:
```
Thank you for reviewing [製品名].

Key points for review:
- This extension is fully HPOS-compatible and declares
  compatibility via FeaturesUtil.
- Block-based checkout is fully supported with a dedicated
  Blocks integration class.
- All settings are located under WooCommerce > Settings > [Tab],
  no top-level menu items are created.
- [その他の審査で気になりそうなポイントへの回答]

If you have any questions during the review, please don't
hesitate to reach out. I'm happy to provide additional
information or make adjustments.
```

---

## 出力フォーマット

全フィールドの記入テキストを以下の形式でまとめて出力する:

```
=== WooCommerce Marketplace Submission Form ===
Plugin: [プラグイン名]
Generated: [日付]

─── Product Details ───
Name: [記入テキスト]
Category: [選択値]
Short description: [記入テキスト]

─── Business Details ───
Best features:
[記入テキスト]

Benefits:
[記入テキスト]

Rationale:
[記入テキスト]

Monthly sales estimate: [記入テキスト]

Competitive comparison:
[記入テキスト]

─── Pricing ───
Suggested price: $[XX]
Sold elsewhere: [Yes/No + 詳細]

─── Languages ───
[選択言語リスト]

─── Integrations ───
Special integrations: [記入テキスト or N/A]
Required WooCommerce.com products: [記入テキスト or N/A]
Required WordPress.org plugins: [記入テキスト or N/A]

─── Testing ───
Install/configure instructions:
[記入テキスト]

Walkthrough video: [URL]
Demo site URL: [URL]
Testing data URL: [URL or N/A]
Login credentials:
[記入テキスト]

─── Product Upload ───
Product slug: [スラッグ]
Listed on WordPress.org: [Yes/No]

─── Additional ───
Notes for reviewers:
[記入テキスト]

=== END ===
```
