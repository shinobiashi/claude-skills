# claude-skills — Shinobiashi / SAAI 共有 Claude Code スキル

WordPress / WooCommerce プラグイン開発で使う Claude Code スキルの**元本リポジトリ**。
`~/.claude/skills/` はこのリポジトリのビルド出力として扱い、直接編集しない。

## インストール / 更新

```bash
git clone https://github.com/shinobiashi/claude-skills.git ~/Dev/claude-skills
cd ~/Dev/claude-skills
bash install.sh              # 全スキルを ~/.claude/skills/ に配置（既存は上書き）
bash install.sh wc-development   # 1 つだけ
bash install.sh --check      # 配置済みコピーとの差分を検出（変更なし）
```

更新後は Claude Code を再起動する。プロジェクト固有のスキル（例: `spw-*`）は各リポジトリの `.claude/skills/` に置き、ここには入れない。

## 変更のルール

1. スキルの編集はこのリポジトリで行い、`bash install.sh` で配置する。
2. バージョンや「最終確認」日付を含む記述を直したら、`CHANGELOG.md` に 1 行残す。
3. `wp-*` の一部は [WordPress/agent-skills](https://github.com/WordPress/agent-skills) からの取り込みに WooCommerce 向けの加筆を重ねたもの。上流を取り込むときは `cp` で上書きせず差分を手でマージする。
4. 各プロジェクトの `.claude/skills/` に共有スキルのコピーを置かない（2026-09 以前のコピーは古いので削除する）。

## スキル一覧

### 開発環境

| スキル | 用途 |
|---|---|
| [`dev-env`](skills/dev-env/SKILL.md) | ローカル開発環境のポート台帳を一元管理するスキル。wp-env を使う各リポジトリに 10 ポートずつの「スロット」を割り当て、Word… |

### WooCommerce 開発

| スキル | 用途 |
|---|---|
| [`wc-development`](skills/wc-development/SKILL.md) | WooCommerce extension development skill covering HPOS, payment gateways, Blocks/StoreAPI… |
| [`wc-block-development`](skills/wc-block-development/SKILL.md) | Use when developing WooCommerce-specific Gutenberg blocks: frontend blocks using WC data… |
| [`wc-action-scheduler`](skills/wc-action-scheduler/SKILL.md) | Use when a WooCommerce extension needs deferred, recurring, or batch background work wit… |
| [`wc-wp-env`](skills/wc-wp-env/SKILL.md) | WooCommerce 拡張プラグインのリポジトリに wp-env のローカル開発環境を「構築」するスキル。.wp-env.json を書くだけでなく、他リポジトリと衝突しないポートの割り当て、同梱プラグ… |
| [`wc-email-editor`](skills/wc-email-editor/SKILL.md) | WooCommerce のブロックメールエディタ 2 パッケージ（Composer `woocommerce/email-editor`、npm `@woocommerce/email-editor`）を自前プラグインに同梱して使う手順。投稿タイプ登録・エディタ画面・レンダリング・差し込みタグ・webpack / Strauss・WC 本体との共存 |
| [`ssm-provider`](skills/ssm-provider/SKILL.md) | Signal Mail for WooCommerce の配信プロバイダ（コア Resend / 有料アドオン Brevo・SES・Mailgun）の実装手順。契約・retryable 規則・Webhook 正規化・必須テスト・アドオン骨格・Webhook 署名スクリプト |
| [`saai-admin-react`](skills/saai-admin-react/SKILL.md) | Use when building or extending a WordPress / WooCommerce admin page in React the SAAI wa… |
| [`payjp-v2-woocommerce`](skills/payjp-v2-woocommerce/SKILL.md) | Use when developing WooCommerce payment gateway plugins using PAY.JP v2 API: credit card… |

### WooCommerce.com Marketplace

| スキル | 用途 |
|---|---|
| [`woo-marketplace-extension`](skills/woo-marketplace-extension/SKILL.md) | WooCommerce.com Marketplace向け有料プラグイン開発のためのスキル。プラグインのスキャフォールド、ファイル構造、必須ヘッダー、 HPOS互換、Block… |
| [`woo-marketplace-qit`](skills/woo-marketplace-qit/SKILL.md) | WooCommerce.com Marketplace向けプラグインの品質テストスキル。QIT（Quality Insights Toolkit）の全テストスイート （Acti… |
| [`woo-marketplace-submission`](skills/woo-marketplace-submission/SKILL.md) | WooCommerce.com Marketplaceへのプラグイン提出から審査通過、リリース後の継続運用までをカバーするスキル。 Vendor Dashboard の Sub… |
| [`woo-marketplace-content`](skills/woo-marketplace-content/SKILL.md) | WooCommerce.com Marketplace向け製品ページ・ドキュメント・FAQなどの販売用コンテンツを作成するスキル。 製品ページ（名前、短い説明、長い説明、メディ… |
| [`woo-marketplace-pricing`](skills/woo-marketplace-pricing/SKILL.md) | WooCommerce.com Marketplaceで販売するプラグインの価格設定を提案するスキル。 プラグインの機能カテゴリ・複雑度・ターゲット市場をヒアリングし、マーケッ… |

### WordPress 開発（WordPress/agent-skills 由来。ローカルで WC 向けに加筆済み）

| スキル | 用途 |
|---|---|
| [`wp-plugin-development`](skills/wp-plugin-development/SKILL.md) | Use when developing WordPress plugins: architecture and hooks, activation/deactivation/u… |
| [`wp-rest-api`](skills/wp-rest-api/SKILL.md) | Use when building, extending, or debugging WordPress REST API endpoints/routes: register… |
| [`wp-block-development`](skills/wp-block-development/SKILL.md) | Use when developing WordPress (Gutenberg) blocks: block.json metadata, register_block_ty… |
| [`wp-interactivity-api`](skills/wp-interactivity-api/SKILL.md) | Use when building or debugging WordPress Interactivity API features (data-wp-* directive… |
| [`wp-abilities-api`](skills/wp-abilities-api/SKILL.md) | Use when working with the WordPress Abilities API (wp_register_ability, wp_register_abil… |
| [`wp-performance`](skills/wp-performance/SKILL.md) | Use when investigating or improving WordPress performance (backend-only agent): profilin… |
| [`wp-wpcli-and-ops`](skills/wp-wpcli-and-ops/SKILL.md) | Use when working with WP-CLI (wp) for WordPress operations: safe search-replace, db expo… |
| [`wp-phpstan`](skills/wp-phpstan/SKILL.md) | Use when configuring, running, or fixing PHPStan static analysis in WordPress projects (… |
| [`wp-playground`](skills/wp-playground/SKILL.md) | Use as the WordPress Playground routing wrapper for ambiguous Playground work, local CLI… |
| [`blueprint`](skills/blueprint/SKILL.md) | Use when the deliverable is WordPress Playground Blueprint JSON or a Blueprint bundle, i… |
| [`wp-plugin-directory-guidelines`](skills/wp-plugin-directory-guidelines/SKILL.md) | Use when reviewing WordPress plugins for GPL compliance, checking license headers or com… |

### 品質・テスト・CI・リリース

| スキル | 用途 |
|---|---|
| [`wp-phpcs`](skills/wp-phpcs/SKILL.md) | Use when setting up, configuring, or running PHP_CodeSniffer (PHPCS/PHPCBF) in WordPress… |
| [`wp-phpunit`](skills/wp-phpunit/SKILL.md) | Use when setting up, writing, or fixing PHPUnit tests for WordPress plugins: phpunit.xml… |
| [`wp-e2e-playwright`](skills/wp-e2e-playwright/SKILL.md) | Use when setting up or writing Playwright end-to-end tests for WordPress plugins and Woo… |
| [`wp-github-actions`](skills/wp-github-actions/SKILL.md) | Use when setting up or updating GitHub Actions CI/CD workflows for WordPress plugins: PH… |
| [`wp-security-check`](skills/wp-security-check/SKILL.md) | Use for security audits of WordPress plugins: nonce validation, capability checks, input… |
| [`wp-i18n`](skills/wp-i18n/SKILL.md) | Use when setting up internationalization (i18n/l10n) for WordPress plugins or themes: te… |
| [`wp-org-release`](skills/wp-org-release/SKILL.md) | Use when publishing or releasing a WordPress plugin to the WordPress.org plugin director… |

### 開発ワークフロー

| スキル | 用途 |
|---|---|
| [`dev-cycle`](skills/dev-cycle/SKILL.md) | WordPress / WooCommerce プラグイン開発向けの開発サイクル司令塔。「計画(plan mode)→ ブランチ作成 → 実装 → review-loop → … |
| [`review-loop`](skills/review-loop/SKILL.md) | 重大度ベースの終了条件を持つ収束型コードレビューループを実行するスキル。 「レビューして」「review-loop」「再レビュー」「レビューを回して」「マージ前チェック」 など… |
| [`start-task`](skills/start-task/SKILL.md) | 「issue 作成 → ブランチ作成 → コミット → プッシュ → PR 作成」を一気通貫で行うタスク開始/完了フロー。ワーキングツリーに変更がある状態なら PR まで、変更… |
| [`check-pr`](skills/check-pr/SKILL.md) | 指定した PR の head を scratchpad の worktree に取得し、PHPCS / PHPStan / PHPUnit の 3 点チェックを実行して結果を報… |
| [`ci-triage`](skills/ci-triage/SKILL.md) | GitHub Actions の CI 失敗を「コード起因」か「インフラ起因（課金・ランナー・ ワークフロー設定・キャッシュ）」かに切り分けるスキル。失敗ジョブの所要時間と ス… |
| [`fix-copilot-review`](skills/fix-copilot-review/SKILL.md) | Fetch unresolved PR review comments from any bot reviewer — GitHub Copilot, Codex (chatg… |
| [`post-merge`](skills/post-merge/SKILL.md) | PRがマージされた後の後始末を行う。デフォルトブランチの最新化、マージ済みローカルブランチとworktreeの片付け、今回の学びをCLAUDE.mdへ蒸留＋剪定、繰り返しパター… |
| [`adr`](skills/adr/SKILL.md) | ADR（Architecture Decision Record）を起票・更新・Supersede するスキル。 「ADR を起票して」「ADR-000X を書いて」「この設計… |

### ドキュメント

| スキル | 用途 |
|---|---|
| [`md-to-docx-manual`](skills/md-to-docx-manual/SKILL.md) | 複数の Markdown ファイルを、画像を埋め込んだまま1つの docx にまとめるスキル。生成した docx は Google ドライブにアップロードするとそのまま Goo… |

## 動作確認済み環境（2026-09-09）

WordPress 7.1 / WooCommerce 11.1.0 / PHP 8.3 / @wordpress/scripts 34 / WPCS 3.4.1 + PHPCS 3.13 / PHPUnit 9.6（WP テストスイート）/ Action Scheduler 4.1 / qit-cli 1.3.1 / Plugin Check 2.1.0
