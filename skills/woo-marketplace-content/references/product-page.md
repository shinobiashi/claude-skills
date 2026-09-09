# 製品ページコンテンツ

## 製品名

製品名はマーケットプレイス検索で最初に目に入る要素。以下のルールに従う:

**やるべきこと:**
- 機能を端的に表す名前にする（例: "Appointments", "Advanced Shipping"）
- 1〜5語に収める（少ないほど良い — 公式ガイダンス）
- ユーザーが検索しそうなキーワードを含める
- 独自性のある名前にする
- WooCommerce に言及する場合は「Product Name for WooCommerce」形式にする

**やってはいけないこと:**
- ブランド名を前面に出す（❌ "VendorXYZ Bookings Plugin for WooCommerce"）
- WooCommerce 商標を先頭に置く（❌ "WooCommerce Product Name"）
- "best" や "amazing" のような最上級の形容詞を使う
- 既存のマーケットプレイス製品名に酷似する名前
- WooCommerce の商標ガイドラインに違反する名前
  （https://woocommerce.com/trademark-guidelines/）
- 製品の説明文をそのまま名前にする

名前の変更は公開後にはマーケットプレイスチームへの依頼が必要。

## 短い説明（Short Description）

製品カードやGoogle検索結果に表示される。最も重要なセールスコピー。

**ルール:**
- 1〜2文で製品の価値を伝える
- 検索エンジン最適化を意識（キーワードを自然に含める）
- 機能ではなくベネフィットを先に

**テンプレート:**

```
[製品名] enables your WooCommerce store to [主要ベネフィット].
[差別化ポイントまたは具体的な機能を1文で].
```

**例:**

```
Advanced Shipping Labels enables your WooCommerce store to automatically generate
and print shipping labels for major carriers. Save hours on order fulfillment
with batch processing and real-time rate calculation.
```

**日本語例:**

```
Advanced Shipping Labels を使えば、主要な配送業者の送り状を自動生成・印刷できます。
バッチ処理とリアルタイム料金計算で、出荷作業を大幅に効率化します。
```

## 長い説明（Description）

製品ページのメインコンテンツ。以下の構成で作成する:

### 推奨構成

```markdown
## [製品が解決する問題/ベネフィット — 導入部]

[2〜3文で、どんなマーチャントのどんな課題を解決するかを説明。
共感を示し、この製品がなぜ必要かを伝える。]

## Key Benefits

* **[ベネフィット1]** — [具体的な効果を1文で]
* **[ベネフィット2]** — [具体的な効果を1文で]
* **[ベネフィット3]** — [具体的な効果を1文で]
* **[ベネフィット4]** — [具体的な効果を1文で]

## How It Works

[製品の基本的な使い方を3〜5ステップで簡潔に。
技術的な詳細はドキュメントに任せ、ここでは概要のみ。]

1. Install and activate the extension
2. [セットアップステップ]
3. [主要な操作]
4. [結果/ベネフィットの体験]

## Use Cases

**[ユースケース1のタイトル]**
[ターゲットユーザーと具体的なシナリオを1〜2文で]

**[ユースケース2のタイトル]**
[ターゲットユーザーと具体的なシナリオを1〜2文で]

## Compatibility

* WooCommerce [minimum] and above
* WordPress [minimum] and above
* Compatible with block-based checkout
* Works with [関連する主要拡張]
```

### AI最適化のポイント（2026年推奨）

公式の Product page content and assets ガイド（最終確認: 2026-09-09）が「Optimize for AI」として、
AI/生成エンジンがコンテンツを引用しやすい書き方を推奨している:

- **直接的で事実的なトーン**を使う（「〜かもしれません」ではなく「〜します」）
- 見出しを「what is」「how to」の形式にする
- 最も重要な情報を各セクションの冒頭に置く
- 具体的な数値や機能名を含める

### 書き方の原則

**Focus on Sales, Not Specs（スペックより販売）:**
技術的な詳細はドキュメントに。説明文ではベネフィットを前面に。

```
❌ "Uses WC_Payment_Gateway class with tokenization support via WC_Payment_Token API"
✅ "Securely saves customer payment methods for faster repeat purchases"
```

**Start With Top Benefits（トップベネフィットから）:**
スキャンしやすいリスト形式で最も説得力のあるポイントを先に。

**Visual Aids（ビジュアル補助）:**
設定画面のスクリーンショットはドキュメントに。製品ページではフロントエンドの
見た目や結果を見せる画像を使う。

## FAQ セクション

FAQは購入前の不安を解消し、コンバージョンを上げる重要なセクション。

### 必須FAQ項目

```markdown
**Does this extension work with the block-based checkout?**
Yes, [製品名] is fully compatible with the WooCommerce block-based checkout
as well as the classic shortcode checkout.

**Is this extension compatible with [主要な関連拡張]?**
Yes, [製品名] works seamlessly with [拡張名]. [簡単な説明].

**What version of WooCommerce and WordPress do I need?**
[製品名] requires WooCommerce [version]+ and WordPress [version]+.
We recommend always running the latest versions for the best experience.

**Do you offer support?**
Yes, we provide dedicated support through the WooCommerce.com helpdesk.
If you need assistance, please submit a support ticket from your
WooCommerce.com account.

**Can I try before I buy?**
[デモがある場合: Yes, check out our live demo at [URL].]
[デモがない場合: We offer a 30-day money-back guarantee, so you can
purchase with confidence.]

**Will this slow down my store?**
[製品名] is built with performance in mind. [具体的なパフォーマンス
配慮点を1文で].
```

### 効果的なFAQの作り方

- 購入を迷っている人の視点で考える
- 互換性・パフォーマンス・サポートの3つは必ずカバー
- 技術的な質問はドキュメントへリンク
- サポートの安心感を与える
- トラブルシューティングガイドへの直接リンクを含める

## メディアギャラリー

### Featured Image（アイキャッチ）
製品ページのトップに表示される画像。フロントエンド（ショッパーが見る画面）の
スクリーンショットが最適。

### ギャラリー画像の推奨構成

ギャラリー画像は 896×550px 以上（公式要件）。製品ごとに1本の埋め込み動画（YouTube / Vimeo）も
掲載でき、動画を含めるとギャラリーの先頭に表示される。

1. **フロントエンドのメイン画面** — ショッパーが実際に見る画面
2. **管理画面の設定ページ** — マーチャントが操作する画面
3. **主要機能のハイライト** — 差別化ポイントの視覚的説明
4. **ビフォー/アフター** — 導入前後の比較（該当する場合）
5. **モバイル表示** — レスポンシブ対応の証拠

### デモ環境の準備

審査チームと潜在顧客の両方に向けて:

- フロントエンド（ショッパー視点）とバックエンド（管理者視点）の両方を見せる
- テスト用の商品・注文データを入れておく
- 拡張の全機能が動作する状態にする
- ログイン情報を明確に提供する（審査用）
- InstaWP や wp-env ベースのデモが便利

## 製品アイコン

- 160×160px（JPG or PNG）、表示は80×80px
- 製品のロゴ（ブランドロゴではない）
- シンボル/アイコン推奨（小さいと文字は読めない）
- 実際のコンテンツは112×112pxの中心領域に収める
- 角丸はCSSで適用されるので画像自体には不要
- 透過背景の場合はハイライトカード背景色を設定

## ハイライトカード背景色

- 製品アイコンの背景に表示されるカラー
- マーケットプレイスのホームページなどで使用
- Vendor Dashboard > Product Data > Woo Product Data > Highlight card background color
- HEXカラーコードで指定
