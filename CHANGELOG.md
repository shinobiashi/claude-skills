# Changelog

このリポジトリのスキルに対する変更履歴。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.0.0/)。

## [Unreleased]

### Added
- `fix-copilot-review`: `scripts/gate-threads.sh`（`dev-cycle` で実績のあるスレッド一覧・返信・
  Resolve ヘルパーを移植）。返信本文を必ずファイル/stdin から渡すため `gh pr comment --body "..."`
  のシェルエスケープ事故を防ぎ、`done`/`reply` がスレッド ID 1 つから返信先と Resolve 先の両方を
  解決するため取り違えも防ぐ。50 件超のスレッドも自動でページングする
- `wp-phpunit`: `references/wp-testcase-patterns.md` に「不確実なコア挙動を使い捨てテストで実測する」
  手法の節を追加（実例: `WC_Product_Variable::get_price()` が親商品では `''` を返す、
  `DateTimeImmutable::getLastErrors()` が PHP 8.2+ で「報告なし」を空配列ではなく `false` で返す）

### Fixed
- `review-loop`: ソース側に反映されていなかった「R1/R2 で独立サブエージェントを併用する」手順を
  取り込み、`~/.claude/skills/review-loop/SKILL.md`（installed）と再同期。installed 側が
  2026-09-12 頃に直接手編集されソースより進んでいたため、`install.sh` を実行すると
  この手順が失われる drift 状態になっていた（`install.sh --check` で検出）

### Changed
- `fix-copilot-review`: スレッドの Resolve と PR への対応サマリコメント投稿を上記
  `gate-threads.sh` 経由に統一（手順 6・7）。従来は Resolve の GraphQL mutation だけが例示され、
  スレッドへの返信手段そのものが明文化されていなかった
- `dev-cycle`: ゲートラウンドの TIMEOUT を「bot が指摘を出し尽くした」ではなく「応答が待ち時間より
  遅れているだけの可能性が高い」と明記（Codex・Copilot とも push から数時間かかった応答実績あり）。
  3 ラウンドで打ち切って先へ進む場合、状態は「収束」ではなく「未確認」と記録し、最終報告で
  `fix-copilot-review` による後日の再確認を案内するよう変更。修正がコアロジック層に及ぶ場合、
  プロジェクト固有の機械的な不変条件チェックを commit 前に流す手順も追加（レビュー指摘の修正自体が
  新しい規約違反を持ち込み、次のラウンドで指摘され返す事例があったため）
- `fix-copilot-review`: 同様に、修正がコアロジック層に及ぶ場合はプロジェクト固有の機械的チェックを
  commit 前に流す手順を追加
- `fix-copilot-review`: Copilot の review 本文も指摘の取得元に追加。判定見出しが `Needs a closer look` のとき Copilot はインラインコメントを投稿せず（`Comments generated: 0 new`）、指摘を本文の `Suppressed comments`（`Previously missed` 含む）に畳むため、従来の `reviewThreads` だけの取得では取り逃がしていた。手順 2 を「2a スレッド / 2b レビュー本文 / 2c 早期終了判定」に分け、終了条件を「未解決スレッド 0 件 かつ 本文指摘 0 件」に変更。本文指摘は `B<k>` の連番で扱い、Resolve 対象が無いため対応サマリコメントに処理結果を必ず残す（再レビュー時の重複判断防止）。判定が `Needs a closer look` で指摘も無い場合は「人間の確認を求めている」として総評文を提示する
- バージョン表記を 2026-09-09 時点に更新（WP 7.1 / WC 11.1.0、WPCS 3.4.1 + PHPCS 3.13.5、Playwright 1.63 / e2e-utils 1.54、`Tested up to: 7.1`、GitHub Actions を checkout@v7 / setup-node@v7 / cache@v6 / upload-artifact@v7 に）: `wp-github-actions`、`wp-phpcs`、`wp-e2e-playwright`、`wp-phpunit`、`wp-phpstan`、`wp-rest-api`、`wp-plugin-development`、`wp-wpcli-and-ops`、`wp-block-development`、`wp-abilities-api`、`wc-block-development`、`wp-org-release`、`payjp-v2-woocommerce`、`woo-marketplace-qit`（CI 例）
- `wp-abilities-api`: WordPress/agent-skills trunk（d87ee69）の更新を取り込み。`references/php-registration.md` を新 API 形（`execute_callback`、必須 `permission_callback`、`meta.annotations`、`meta.mcp.public`、ID は `plugin/verb-noun`）に置換し、参照 7 本（domain-vs-projection、grouping-heuristic、shared-core-service、plugin-family-patterns、error-code-vocabulary、input-schema-gotchas、delegate-helper-pattern）を追加。ローカル加筆（6.9 でコア入り、JS パッケージ 2 種）は維持

## 2026-09-09 — 初回統合

### Added
- リポジトリ新設。`~/.claude/skills/` に散在していた 37 スキルを `skills/` に集約し、`install.sh`（`--check` で差分検出）を追加
- 新規: `adr`（ADR 起票・Supersede）、`wc-action-scheduler`（Action Scheduler 4.1 の API・チャンク処理・PHPUnit）、`saai-admin-react`（SAAI 流 React 管理画面）
- 汎用化して追加: `dev-cycle`、`check-pr`、`ci-triage`（各プロジェクト固有版から固有名を除去し、コマンドは CLAUDE.md / composer.json から読む）
- WordPress/agent-skills（trunk d87ee69, 2026-08-16）から `wp-plugin-directory-guidelines`、`wp-playground`、`blueprint` を取り込み

### Changed
- `wc-development`、`woo-marketplace-extension` / `-submission` / `-qit` / `-content` / `-pricing`、`wp-security-check`: 各プロジェクトに分岐していた版を日本語系（saai-knowledge / saai-ten4wc）をベースに統合し、payjp-for-wc 系の事実（QIT 自動テスト、価格ルール、商標、SaaS Billing API、HPOS sync-on-read、Fulfillments API、PCI DSS 4.0.1）を移植。公式ドキュメントで再確認し、WP 7.1 / WC 11.1.0 / qit-cli 1.3.1 / Plugin Check 2.1.0 / WPCS 3.4.1 に更新
- `woo-marketplace-qit`: Plugin Check を「任意」、PHPStan を「推奨」に（公式の提出時必須リストに基づく）。CLI フラグを `--plugin` / `--test-package` に修正
- `woo-marketplace-pricing`: 価格表を公開 API で再検証。「マーケットプレイスを安くする」戦略は公式ルール（シングルサイト価格と揃える）と矛盾するため削除。`scripts/analyze_competitors.sh` を API ベースに置換
- `review-loop`: APPROVE 条件を「R1 の Critical/High/Medium 全解消 かつ 新規 Critical/High ゼロ」に強化。CLAUDE.md の絶対ルールを第一級のレビュー観点に

### Removed
- `~/.claude/commands/wp-security-check.md`（9 行の旧コマンド）は同名スキルに統合

## 2026-05-22 — saai-blocks-for-wc バンドル（前身）

- `wc-block-development`、`wp-i18n`、`wp-org-release`、`wp-phpcs`、`wp-phpunit`、`wp-github-actions`、`wp-e2e-playwright` 1.0.0 を `saai-blocks-for-wc/.claude/skills/` に `install.sh` 付きで配置（本リポジトリの前身）
