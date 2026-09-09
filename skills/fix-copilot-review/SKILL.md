---
name: fix-copilot-review
description: >
  Fetch unresolved PR review comments from any bot reviewer — GitHub Copilot, Codex
  (chatgpt-codex-connector), or similar — fix the valid ones, commit, push, resolve the
  threads, and post a reply comment. Use when the user asks to handle PR review comments,
  respond to Copilot or Codex review feedback, or "Resolve conversation" on a PR — e.g.
  "PR#197のCopilotコメントに対応して", "Codexのレビューコメントに対応して", "Codexの指摘を直して",
  "レビューコメントを修正してResolveして". Optional arguments: PR number (defaults to the
  current branch's PR) and comment language `en` or `ja` (defaults to Japanese).
---

# PRレビューコメント対応スキル（Copilot / Codex 等のbotレビュアー全般）

GitHub PR 上の未解決（unresolved）レビュースレッドを取得し、妥当な指摘は修正 → テスト →
コミット → プッシュ → Resolve → 対応コメント投稿まで自動で行う。誤検知・対応不要と
判断した指摘は **必ずユーザーに確認してから** 処理する。

**対象は Copilot に限らない。** 手順2のGraphQL取得は投稿者でフィルタしない
（`isResolved: false` のみで絞り込む）ため、GitHub Copilot・Codex
（`chatgpt-codex-connector`）・その他のレビューbot全般をデフォルトで区別なく処理する。
除外が必要なのは「Copilot 以外（人間のレビュアー）」のコメントのみ（注意事項参照）—
これはbotかどうかの区別であって、Copilot以外のbotを除外する意味ではない。

## 引数

引数は順不同・省略可。数字は PR 番号、`en` / `ja`（または `english` / `japanese`、
「英語」/「日本語」）はコメント言語として解釈する。

- **PR 番号** — 省略時は現在のブランチの PR。
- **コメント言語** — GitHub に投稿する文章（PR の対応サマリコメント、スレッドへの返信）の
  言語。省略時は `ja`（日本語）。OSS など英語圏のリポジトリでは `en` を指定する。

例: `/fix-copilot-review 197 en` → PR#197 を対象に、GitHub への投稿は英語で行う。

## 前提・言語ルール

- git 操作・GitHub 操作は `gh` コマンドを使う。
- コミットメッセージは常に英語。
- GitHub に投稿するコメント（PR コメント・スレッド返信）は**引数で指定された言語**
  （デフォルト: 日本語）。
- ユーザーへの報告・確認（AskUserQuestion 含む）は常に日本語。
- コミットメッセージ末尾の Co-Authored-By はシステムプロンプトの指定に従う。

## 手順

### 1. 対象 PR の特定

- 引数で PR 番号が指定されていればそれを使う。なければ現在のブランチの PR を使う:
  ```bash
  gh pr view --json number,url,headRefName,title
  ```
- PR の URL から `owner/repo` を取り出す（フォークから base リポジトリへの PR の場合、
  `git remote` と PR のリポジトリが異なることがある。GraphQL には **PR URL 側の
  owner/repo** を使うこと）。
- 現在のブランチが `headRefName` と一致しない場合は作業を止め、ユーザーに確認する。
- `git status` を確認し、無関係な未コミット変更がある場合はユーザーに報告してから進める。

### 2. 未解決スレッドの取得

REST の comments API は resolved 状態を返さないため、**必ず GraphQL** を使う:

```bash
gh api graphql -f query='
query {
  repository(owner: "<OWNER>", name: "<REPO>") {
    pullRequest(number: <N>) {
      reviewThreads(first: 50) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          comments(first: 10) {
            nodes { databaseId body author { login } createdAt }
          }
        }
      }
    }
  }
}'
```

- `isResolved: false` のスレッドだけを対象にする。
- 未解決スレッドが 0 件なら、その旨を日本語で報告して終了する。
- 対象コメントの一覧（path / line / 要旨）を先にユーザーへ簡潔に提示してから修正に入る。

### 3. 各指摘の評価と修正

各未解決スレッドについて:

1. 該当ファイル・行とその周辺コードを読み、指摘が妥当か自分で検証する。
   Copilot の指摘は鵜呑みにしない（誤検知・既に対応済み・仕様上問題なし、がありうる）。
2. **妥当** → 修正する。修正はプロジェクトのコーディング規約（CLAUDE.md、WPCS 等）に従い、
   指摘の趣旨に対する最小限の変更にとどめる。
3. **妥当でない／対応不要と判断** → 修正せず、**AskUserQuestion で 1 件ずつユーザーに
   確認する**。選択肢の例:
   - 「対応不要としてResolve」→ 判断理由をスレッドに返信（指定されたコメント言語で）
     してから Resolve する
   - 「やはり修正する」→ 妥当な指摘として修正フローに戻す
   - 「保留（未解決のまま残す）」→ 何もせず最終報告に含める

### 4. 検証

修正した場合は、プロジェクト標準の検証コマンドを実行する（CLAUDE.md や composer.json /
package.json を確認）。例:

```bash
composer lint          # PHPCS
composer test          # PHPUnit（DB 未セットアップなら composer test-install を先に実行）
```

テストや lint が失敗した場合はコミットせず、修正して再実行する。解決できない場合は
状況をユーザーに報告して指示を仰ぐ。

### 5. コミット・プッシュ

- 修正内容を表す英語のコミットメッセージでコミットする。本文に「どの指摘への対応か」が
  分かる説明を含める（例: レビュー指摘の問題シナリオを 2〜3 行で）。
- 複数の指摘が論理的に独立している場合は、指摘ごとにコミットを分けてよい。
- `git push` する。
- **`git commit` が権限設定でブロックされる環境の場合**（プロジェクトの
  「コミットはユーザーが手動で行う」ルールが権限側でも強制されているリポジトリ）:
  回避を試みず、①対応内容と検証結果、②英語のコミットメッセージ案（コードブロックで
  コピーしやすく）を提示して**停止**し、手動コミット・プッシュ後にこのスキルを
  再実行するよう案内する。
- **再実行時の継続判定**: スキル起動時に対象 PR のブランチで `git log --oneline` と
  `git status -sb` を確認し、前回提示した修正がコミット・プッシュ済み
  （作業ツリーがクリーンで origin と同期）なら、手順 2〜5 を繰り返さず
  **手順 6（Resolve）から継続**する。未コミットの修正が残ったままなら手順 5 の
  停止状態を維持する。

### 6. スレッドの Resolve

対応した（またはユーザーが対応不要を承認した）スレッドを GraphQL mutation で Resolve する:

```bash
gh api graphql -f query='
mutation {
  resolveReviewThread(input: {threadId: "<THREAD_ID>"}) {
    thread { id isResolved }
  }
}'
```

### 7. PR への対応コメント投稿

`gh pr comment <N> --body "..."` で対応サマリを投稿する（言語は引数で指定されたもの。
デフォルト: 日本語）。含める内容:

- 対応したレビューコメントへのリンク
  （`https://github.com/<owner>/<repo>/pull/<N>#discussion_r<databaseId>`）
- 対応コミットのハッシュ
- 何をどう修正したか（指摘されていた問題と修正方法を 2〜4 行で）
- テスト・lint の実行結果（例:「既存の単体テスト84件すべてパス」）
- 対応不要と判断した指摘があれば、その理由

### 8. 最終報告

ユーザーへ日本語で報告する: 対応した件数・コミットハッシュ・Resolve 済みスレッド・
保留にした指摘とその理由・テスト結果。

## 注意事項

- Resolve は「修正をプッシュした後」または「ユーザーが対応不要を承認した後」のみ行う。
  修正前に Resolve しない。
- `isOutdated: true` でも未解決なら対象に含める（コードが既に変わって解消済みの場合は
  「対応不要」としてユーザー確認に回す）。
- スレッド数が 50 を超える場合は GraphQL のページネーション（`after` カーソル）で
  全件取得する。
- bot（Copilot・Codex等）ではなく **人間のレビュアー** による未解決コメントが混ざっている
  場合は、勝手に Resolve せず、対象に含めるかどうかをユーザーに確認する。bot同士の区別
  （例: CopilotとCodexの両方が指摘している）は不要 — bot由来のコメントはすべて通常通り
  手順3〜7で処理してよい。
