---
name: fix-copilot-review
description: >
  Fetch unresolved PR review comments from any bot reviewer — GitHub Copilot, Codex
  (chatgpt-codex-connector), or similar — fix the valid ones, commit, push, resolve the
  threads, and post a reply comment. Also reads the Copilot review body itself: the verdict
  headline ("Needs a closer look" / "Changes recommended") and the "Suppressed comments"
  findings that have no inline thread, so a review with zero inline comments is still
  examined and acted on. Use when the user asks to handle PR review comments, respond to
  Copilot or Codex review feedback, or "Resolve conversation" on a PR — e.g.
  "PR#197のCopilotコメントに対応して", "Codexのレビューコメントに対応して", "Codexの指摘を直して",
  "レビューコメントを修正してResolveして", "CopilotがNeeds a closer lookを出したので対応して".
  Optional arguments: PR number (defaults to the current branch's PR) and comment language
  `en` or `ja` (defaults to Japanese).
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

**指摘の取得元は 2 系統ある。** 片方だけ見て「指摘なし」と判断しない。

| 系統 | 取得元 | 対応後の記録 |
|---|---|---|
| A. インラインスレッド | `reviewThreads`（`isResolved: false`） | スレッドを Resolve + 対応サマリコメント |
| B. レビュー本文の指摘 | Copilot の review `body`（判定見出し + `Suppressed comments`） | 対応サマリコメントのみ（Resolve 対象がない） |

Copilot は判定が **`Needs a closer look`** のとき、インラインコメントを 1 件も投稿せず
（`Comments generated: 0 new`）、指摘を review 本文の `Suppressed comments` に畳んで
書くことがある。系統 A だけを見るとこの指摘を取り逃がすため、本スキルは必ず系統 B も読む。

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

## 補助スクリプト

スレッドへの返信・Resolve・PR への対応サマリコメント投稿には、本スキル同梱の
`scripts/gate-threads.sh`（起動時に表示される「Base directory for this skill:」配下）を使う。
手書きの `gh` コマンドに戻さない理由:

- `gh pr comment --body "..."` や `gh api graphql -f query='...'` にコメント本文を直接埋め込むと、
  括弧・バッククォート・改行を含む文面でシェルのパースが壊れる（複数プロジェクトの実運用で発生済み）。
  本文は必ずファイル（または stdin）から渡す。
- 返信と Resolve を別々のスレッド ID で手打ちすると、片方のスレッドに返信してもう片方を
  Resolve する取り違えが起こりうる。`done`/`reply` はスレッド ID 1 つから両方を解決するため、
  この種の事故を防ぐ。

```bash
S=<Base directory for this skill>/scripts/gate-threads.sh

"$S" list <PR> [SINCE_ISO8601]              # 未解決スレッドを TSV で一覧（50件超も自動でページング）
"$S" show <THREAD_ID>                        # 1件の全文を読む（評価に使う）
"$S" status <PR> [SINCE_ISO8601]             # bot ごとの未解決件数 + 現 HEAD への Copilot レビュー本文の件数
"$S" bodies <PR> [SINCE_ISO8601]             # 現 HEAD への Copilot レビュー本文（URL / 判定見出し / Suppressed comments）
"$S" done  <PR> <THREAD_ID> <BODY_FILE|->    # 修正した指摘: 返信してから Resolve
"$S" reply <PR> <THREAD_ID> <BODY_FILE|->    # 保留した指摘: 返信のみ（Resolve しない）
```

`status` / `bodies` は系統 B（レビュー本文）の入口で、手順 2b の GraphQL を手書きせずに済む
（`bodies` は HTML を落とし、File summaries の表は指摘の無い行だけ落として判定見出し・総評・
`**Critical/High/Moderate/Medium/Minor/Low:**` 付きの表セル・`Suppressed comments` を表示する
— 表セルにしか指摘が無い回（PR #60 の G1 ラウンド）を読み落とさないため。`SINCE` は包含比較、
対象は PR の現 HEAD への review のみ）。

`--dry-run` を付けると書き込み系コマンドの実行内容だけを表示する。`done` は返信が失敗したら
Resolve しない（説明のないままスレッドを閉じないため）。PR 本文への対応サマリコメント
（手順 7）も同じ理由で `gh pr comment <PR> --body-file <ファイル>` を使い、`--body` に直接
書かない。

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

### 2. 指摘の収集（系統 A・B の両方）

#### 2a. 未解決スレッドの取得（系統 A）

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

#### 2b. Copilot レビュー本文の取得（系統 B）

Copilot（login `copilot-pull-request-reviewer`）の review を取得し、**最新の 1 件**
（`submittedAt` が最大のもの）の `body` を読む:

```bash
gh api graphql -f query='
query {
  repository(owner: "<OWNER>", name: "<REPO>") {
    pullRequest(number: <N>) {
      reviews(last: 20) {
        nodes {
          databaseId
          url
          state
          submittedAt
          body
          author { login }
          comments(first: 1) { totalCount }
        }
      }
    }
  }
}' --jq '.data.repository.pullRequest.reviews.nodes
        | map(select(.author.login == "copilot-pull-request-reviewer"))
        | sort_by(.submittedAt) | last'
```

本文の構造（実際の Copilot review で確認済みの形式）:

```
### 🔵 Needs a closer look                 ← 1 行目 = 判定見出し。他に「### 🟡 Changes recommended」
<総評 1〜2 文>                             ← 何を懸念しているかの要約。人間確認を求める文言のことがある
<details><summary>Pull request overview</summary> … </details>   ← 初回レビューのみ
<details><summary>File summaries</summary>                       ← 初回レビューのみ
| File | Reviewed changes and final findings |
| `src/Foo.php` | 概要。**Moderate (1 vote):** 具体的指摘 |   ← 表のセルに重大度付きの指摘が入ることがある
</details>
<details><summary>Review details</summary>
### Suppressed comments (N)                ← インラインに投稿されなかった指摘。ここが本命
**Previously missed (M)** — in code that hasn't changed since the last review.   ← 任意の小見出し
**path/to/file.php:123**                   ← 1 指摘 = 「**path:line**」+ 「* 本文」(+ 任意のコードフェンス)
* 指摘の本文 …
**path/to/other.php:45**
* 指摘の本文 …
- **Files reviewed:** 111/111 changed files
- **Comments generated:** 0 new           ← 「0 new」ならインラインスレッドは無い
- **Review effort level:** Lite
</details>
```

旧形式（`> [!NOTE] Copilot was unable to run its full agentic suite…` で始まり
`Copilot reviewed X out of Y changed files … and generated N comments.` の後に
`<details><summary>Suppressed comments (N)</summary>` が続く）でも、指摘 1 件の書式は同じ。

本文から拾う指摘（以下「本文指摘」）:

1. `Suppressed comments` 内の各 `**path:line**` + `* 本文` のブロック。
   `Previously missed` の小見出し配下も含める（「前回から変わっていないコードに残る指摘」で、
   Copilot がインライン投稿を見送っただけであり、未対応の指摘である）。
2. `File summaries` 表のセルにある `**Critical / Moderate / Minor …:**` 付きの具体的指摘。
3. 判定見出し直下の総評文（指摘の要約と、人間確認を求めているかどうかの判断材料）。

本文指摘には `B1`, `B2`… の連番を振り、系統 A のスレッドと **path:line と要旨で重複排除**する
（同じ内容がインラインにもある場合はスレッド側で処理し、本文指摘としては数えない）。
Codex など他の bot の review 本文にも「スレッドの無い path:line 付きの具体的指摘」があれば
同様に本文指摘として扱う。

#### 2c. 提示と早期終了の判定

- 対象一覧（系統 A: path / line / 要旨、系統 B: `B<k>` / path:line / 要旨、および Copilot の
  判定見出しと総評）を先にユーザーへ簡潔に提示してから修正に入る。
- **終了してよいのは「未解決スレッド 0 件 かつ 本文指摘 0 件」のときだけ**。その旨を日本語で
  報告して終了する。
- 判定が `Needs a closer look` で本文指摘も 0 件の場合（総評だけが「人間の最終確認を求める」
  内容のとき）は、「指摘なし」ではなく **「Copilot が人間の確認を求めている」として総評文を
  ユーザーに提示**し、確認してもらって終了する。

### 3. 各指摘の評価と修正

各未解決スレッドと各本文指摘について、系統に関係なく同じ基準で扱う:

1. 該当ファイル・行とその周辺コードを読み、指摘が妥当か自分で検証する。
   Copilot の指摘は鵜呑みにしない（誤検知・既に対応済み・仕様上問題なし、がありうる）。
   Copilot が付けた重大度（`Critical` / `Moderate` 等）や「Suppressed（抑制された）」という
   扱いも判断材料にすぎない。**抑制されていた＝軽微、ではない**。内容で判断する。
2. **妥当** → 修正する。修正はプロジェクトのコーディング規約（CLAUDE.md、WPCS 等）に従い、
   指摘の趣旨に対する最小限の変更にとどめる。
3. **妥当でない／対応不要と判断** → 修正せず、**AskUserQuestion で 1 件ずつユーザーに
   確認する**。選択肢の例:
   - 「対応不要としてResolve」→ 判断理由をスレッドに返信（指定されたコメント言語で）
     してから Resolve する。本文指摘の場合は Resolve 対象がないので、理由を手順 7 の
     対応サマリコメントに書く
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

**レビュー指摘の修正自体が新しい規約違反を持ち込むことがある**（実例: ある修正が丸め処理の
集約ルールに違反する独自実装を混入させ、次のレビューラウンドで指摘され返した）。標準の
lint/test だけでなく、そのプロジェクトに「不変条件」「アーキテクチャ規約」を機械的に
チェックするスキル・スクリプト（CLAUDE.md や `.claude/skills/` から該当するものを探す。
例: grep ベースの規約チェック、静的解析の追加ルールセット）があり、かつ今回の修正が
その対象範囲（コアロジック層など）に触れるなら、コミット前に軽く流す。無ければこの手順は
スキップしてよい。

### 5. コミット・プッシュ

- 修正内容を表す英語のコミットメッセージでコミットする。本文に「どの指摘への対応か」が
  分かる説明を含める（例: レビュー指摘の問題シナリオを 2〜3 行で）。本文指摘への対応なら
  「Copilot review body (suppressed comment) on path:line」のように出所が分かるようにする。
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
  停止状態を維持する。本文指摘については、前回の対応サマリコメント（手順 7）に同じ
  path:line の指摘が「対応済み」または「対応不要」として記載済みなら再評価しない
  （Copilot は再レビューのたびに未対応の本文指摘を繰り返し載せるため、記録が無いと
  同じ判断を何度も求められる）。

### 6. スレッドの Resolve

対応した（またはユーザーが対応不要を承認した）スレッドを、上記「補助スクリプト」の
`gate-threads.sh done`（修正した指摘）または `reply`（保留した指摘）で処理する。単独の
resolve コマンドは無い — 返信なしでスレッドが閉じられることを防ぐため、常に返信とセットで行う。

本文指摘（系統 B）にはスレッドが無いため Resolve する対象は無い。手順 7 の対応サマリコメントが
唯一の記録になるので、本文指摘を 1 件でも扱った場合は手順 7 を省略しない。
Copilot の再レビュー依頼（`gh pr edit <N> --add-reviewer @copilot`）は本スキルでは行わない
（dev-cycle のゲート、またはユーザーの判断で行う）。

### 7. PR への対応コメント投稿

`gh pr comment <N> --body-file <ファイル>` で対応サマリを投稿する（`--body` に本文を直接
書かない。上記「補助スクリプト」参照）。言語は引数で指定されたもの（デフォルト: 日本語）。
含める内容:

- 対応したレビューコメントへのリンク
  （`https://github.com/<owner>/<repo>/pull/<N>#discussion_r<databaseId>`）
- 本文指摘を扱った場合は、元の review へのリンク
  （`https://github.com/<owner>/<repo>/pull/<N>#pullrequestreview-<review databaseId>`、
  GraphQL の `url` と同じ）と Copilot の判定見出し（例: `Needs a closer look`）、
  各本文指摘の `path:line` と処理結果（修正コミット / 対応不要とその理由 / 保留）
- 対応コミットのハッシュ
- 何をどう修正したか（指摘されていた問題と修正方法を 2〜4 行で）
- テスト・lint の実行結果（例:「既存の単体テスト84件すべてパス」）
- 対応不要と判断した指摘があれば、その理由

### 8. 最終報告

ユーザーへ日本語で報告する: Copilot の判定見出し・対応した件数（スレッド / 本文指摘の内訳）・
コミットハッシュ・Resolve 済みスレッド・保留にした指摘とその理由・テスト結果。

## 注意事項

- Resolve は「修正をプッシュした後」または「ユーザーが対応不要を承認した後」のみ行う。
  修正前に Resolve しない。
- **`Needs a closer look` は「指摘なし」ではない。** `Comments generated: 0 new` でも
  review 本文の `Suppressed comments` に具体的な指摘が入っていることが多い。未解決スレッドが
  0 件でも、手順 2b を飛ばして終了しない。
- `Suppressed comments` の `Previously missed` は「前回レビュー以降に変更が無いコードへの
  指摘」で、Copilot がインライン投稿を抑制しただけ。未対応として評価対象に含める。
- 本文指摘は Resolve できないため、対応サマリコメント（手順 7）に処理結果を残すことが
  再レビュー時の重複判断を防ぐ唯一の手段になる。
- `isOutdated: true` でも未解決なら対象に含める（コードが既に変わって解消済みの場合は
  「対応不要」としてユーザー確認に回す）。
- スレッド数が 50 を超える場合は GraphQL のページネーション（`after` カーソル）で
  全件取得する（`gate-threads.sh list` は自動でページングする）。
- bot（Copilot・Codex等）ではなく **人間のレビュアー** による未解決コメントが混ざっている
  場合は、勝手に Resolve せず、対象に含めるかどうかをユーザーに確認する。bot同士の区別
  （例: CopilotとCodexの両方が指摘している）は不要 — bot由来のコメントはすべて通常通り
  手順3〜7で処理してよい。
