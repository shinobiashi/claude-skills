# Changelog

このリポジトリのスキルに対する変更履歴。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.0.0/)。

## [Unreleased]

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
