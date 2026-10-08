---
name: dev-cycle
description: >
  WordPress / WooCommerce プラグイン開発向けの開発サイクル司令塔。「計画(plan mode)→ ブランチ作成 →
  実装 → review-loop → push・PR 作成 → CI 待ち → Codex/Copilot ゲート(bot ごとに最大3ラウンド)→
  最終報告」を1コマンドで通す。`sequential` を付けると Codex → Copilot → Codex … と1体ずつ順番にゲートを回す
  (既定は同時依頼)。
  「dev-cycle」「次の開発を進めて」「Phase N を実装して PR まで」「サイクルを再開して」「G2-3 を直して」
  などと言われたら使う。人間の判断が必要な場面(計画の承認・各ゲートラウンドの commit 判断・想定外の
  事象)では必ず停止して確認し、勝手に重要な判断をしない。
---

# /dev-cycle — 計画から Codex/Copilot ゲートまでの開発サイクル

既存スキル `review-loop`(PR 前レビュー)を組み込み、`start-task` / `fix-copilot-review` と同じ
規約・コマンドで push・PR 作成・レビュー対応を行う司令塔。人間の判断が入るゲートは次の3種類で、
**いずれも AskUserQuestion で停止し、返答があるまで先に進まない**。

| ゲート | タイミング | 何を判断してもらうか |
|---|---|---|
| 計画承認 | Step 1 | 実装計画(ExitPlanMode) |
| 確認ゲート | Step 7 の各ラウンド | bot 指摘への修正を commit/push してよいか。保留分の追加修正 |
| 想定外事象 | いつでも | 「人間に確認する条件」に該当した時の進め方 |

## プロジェクト設定の読み取り

このスキルはリポジトリ固有の値をハードコードしない。Step 0 でリポジトリ直下の `CLAUDE.md`
(および `.claude/` 配下の補足)を読み、以下を決める。CLAUDE.md に記載が無い項目は既定値を使う。

| 項目 | CLAUDE.md から読む内容 | 既定値 |
|---|---|---|
| 品質チェック | lint / 静的解析 / テスト / ビルドのコマンド一式 | `composer lint` → `composer analyze` → `composer test` → `npm run build`(`composer.json` / `package.json` の scripts に存在するものだけ) |
| ブランチ命名 | ブランチ名の規則 | `feat/<短い説明>` |
| 計画ドキュメント | フェーズ・TODO の定義(例: `docs/ROADMAP.md`、`docs/TODO.md`) | 無ければタスク概要のみで計画する |
| 設計ドキュメント | 設計・要件(例: `docs/ARCHITECTURE.md`、`docs/REQUIREMENTS.md`、`docs/ADR/`、`docs/DESIGN.md`) | 無ければ CLAUDE.md 本文を設計の根拠とする |
| 絶対ルール | 「絶対に守るルール」「設計上の不変条件」「やってはいけないこと」等の節 | CLAUDE.md の禁止事項全般 |
| レビュー基準 | `docs/review-criteria.md` | `review-loop` スキルの重大度定義 |
| PR 本文 | PR 本文に書く項目 | 「対応フェーズ / 変更概要 / テスト内容 / 設計ドキュメントからの逸脱(あれば)」 |
| ローカル環境 | 実装前に必要な環境(wp-env / docker compose / nvm 等) | 特に無し |

以下、「品質チェック」はこの表で決めたコマンド一式を順に実行し、すべて成功することを指す。

## 引数

順不同・省略可。

- **タスクの概要**(日本語可。例: `Phase 2 Step3〜5 UI`)— 新規開始。計画ドキュメントの節番号や
  フェーズ名で指定してよい。省略時は計画ドキュメントの推奨順から次の対象を提案し、ユーザーに確認して
  から始める(計画ドキュメントが無ければタスク概要の入力を求める)
- `resume` — 現在のブランチの状態ファイル(後述)から中断箇所を再開する
- `fix <ID>...`(例: `fix G1-2 G2-1`)— 最終報告後に、保留にした指摘を人間の判断で修正する
- `auto-commit` — Step 7 の確認ゲートを飛ばし、各ラウンドの修正を自動で commit/push する。
  **デフォルトは確認ゲートあり**。ユーザーが明示した時のみ使う
- `sequential` — Codex と Copilot を同じラウンドで同時に依頼せず、**1 体ずつ順番に**回す
  (Codex → Copilot → Codex → … 各 bot 最大 3 回)。前の bot の修正が入った HEAD を次の bot がレビューする。
  詳細は「順番実行」節。**デフォルトは同時依頼**

## 前提: commit / push / PR 作成の権限

グローバル CLAUDE.md の「明示的な指示があるまで commit/push しない」ルールに対し、
**ユーザーが現在のセッションでこのスキルを起動したことをもって次の操作の明示的な指示とみなす**
(`start-task` と同じ扱い):

- Step 2 の実装コミット、Step 3 の review-loop 内コミット、Step 4 の初回 push と PR 作成
- Step 7 で**確認ゲートを通過した後**の commit/push、および Step 7・8 の記録用 `docs:` コミット

逆に、以下は起動をもってしても許可されない(「絶対にしないこと」参照)。上記に列挙されていない
commit/push/PR 操作が必要になった場合は、勝手に行わず AskUserQuestion で確認する。
レビュー・説明・報告は日本語、コード・コミットメッセージは英語。

## 絶対にしないこと

- PR のマージ(`gh pr merge`)。マージは常に人間が行う
- `main` への push、force push、履歴の書き換え(`rebase`/`reset --hard`/`commit --amend` で push 済み
  コミットを変える)、ブランチ削除
- 確認ゲートを飛ばして commit/push する(`auto-commit` 指定時を除く)
- 修正していないレビュースレッドを Resolve する(保留分は理由を返信して**未解決のまま残す**)
- 同じ bot へ 4 回目のレビュー依頼をする
- 設計ドキュメント(ARCHITECTURE / ADR / DESIGN 等)をユーザーの合意なく書き換える
- 「後で報告すればよい」と判断して確認をスキップする。迷ったら止まる

## 人間に確認する条件(該当したら必ず AskUserQuestion で停止)

状況・選択肢・推奨案を示し、返答があるまで進めない。選択肢には必ず「ここで中断」を含める。

計画・実装中:
- 設計ドキュメント / 計画ドキュメントと矛盾する、または計画に無い変更が必要になった
- main にマージ済みの DB スキーマ・マイグレーションを変更しないと実現できない
- CLAUDE.md の絶対ルールの解釈に踏み込む設計判断が必要
- 依存関係の追加・更新(`composer.json` / `package.json`)、環境設定ファイル(`.env.example`・
  `.wp-env.json` 等)の変更、新しい外部サービス呼び出し
- 品質チェックが2回の修正でも green にならない
- CLAUDE.md が実装前提として要求するツール・環境が未導入

review-loop / PR:
- review-loop が R3 でも APPROVE にならない(review-loop 自身が停止する。その報告を引き継ぐ)
- 作業ツリーにタスクと無関係な差分がある / リモートが無い / PR が既に存在する
- CI が red で、ローカルの品質チェックでは再現しない、または原因が非自明
- main が進んでコンフリクトする、rebase が必要

ゲートラウンド:
- bot が 15 分待っても応答しない(`request-gate-review.sh` が exit 1。`--wait-only` で待ち直す / 待たずに進める /
  中断)。**「応答しない」は「これ以上指摘が無い」と同義ではない**(Codex・Copilot とも push から数時間経ってから
  応答した実績がある)。「待たずに進める」を選んだ場合も、最終報告で後日 `fix-copilot-review` による再確認を案内する
- Copilot の依頼が登録されない(同スクリプトが exit 2。ユーザーが UI から手動で依頼して `--wait-only` で待つ /
  待たずに進める / 中断。Step 6 参照)
- 指摘の仕分けで迷う: 修正すると設計や絶対ルールの解釈に踏み込む、修正範囲が大きい
  (目安: 変更ファイル 5 超・新規テーブル・公開 API の契約変更)、妥当かどうか判断しきれない
- 人間のレビュアー(bot 以外)のコメントが PR に付いた(対象に含めるか)

その他:
- `gh` の認証切れ・API レート制限・ローカル環境(wp-env / Docker 等)の停止など環境側の障害
- このスキルに書かれていない状況全般

## 状態ファイルとレジューム

`docs/reviews/<ブランチ名>/dev-cycle.md` に進行状況を記録し、各ステップ完了時に更新する。
`resume` 指定時、または引数なしで feat ブランチ上で起動された時はこのファイルを読んで再開する。
ファイルが無い feat ブランチ上で起動された場合は「このブランチで dev-cycle を始めるか」を確認する。

```markdown
# dev-cycle 状態: feat/example-feature
- タスク: <タスク概要>
- 開始: 2026-09-06
- PR: #12 https://github.com/<owner>/<repo>/pull/12(未作成なら「未作成」)
- 現在のステップ: 7(ゲート G2・確認ゲート待ち)
- Copilot: 依頼 2 回 / 未収束
- Codex: 依頼 1 回 / 収束(G1 で新規指摘なし)
- 次のターン: Copilot 3 回目(`sequential` の時のみ)

## ログ
| 日時(JST) | ステップ | 内容 |
|---|---|---|
| 2026-09-06 10:05 | 1 | 計画承認 |
| 2026-09-06 11:40 | 2 | 実装コミット 3 件、品質チェック green |
```

## 手順

### Step 0. 起動チェック

```bash
git status --short && git branch --show-current
[ -f .nvmrc ] && { node -v; cat .nvmrc; }
```

- リポジトリの `CLAUDE.md` を読み、「プロジェクト設定の読み取り」の表を埋める
- 作業ツリーに差分があれば内容を確認する。タスクと無関係な差分は「人間に確認する条件」
- `.nvmrc` があり `node -v` と一致しない場合、以降の Bash 呼び出しはすべて
  `export PATH=~/.nvm/versions/node/v<.nvmrc の版>/bin:$PATH` を先頭に付ける(シェル状態は
  呼び出し間で保持されない。不一致のままだと `npm install` が optionalDependencies を無言でスキップする)
- CLAUDE.md がローカル環境(wp-env / docker compose 等)を要求していれば起動状態を確認し、動いて
  いなければ起動する。失敗したら停止して報告
- CLAUDE.md がモデル運用(例: opusplan = plan mode は Opus、実行は Sonnet)を指定しており、現在の
  モデルがそれに沿っていない場合は1行で伝え、続行してよいか確認する
- 引数と現在ブランチから「新規 / resume / fix」を判定する

### Step 1. 計画(ゲート: 計画承認)

1. EnterPlanMode で plan mode に入る
2. 計画ドキュメントの該当フェーズ・節、設計ドキュメントの関連節、CLAUDE.md の絶対ルールを読む
3. 計画に含めるもの: 対象スコープ(計画ドキュメントの項目番号)、ブランチ名(ブランチ命名規則に従う)、
   変更するファイル、追加するテスト、完了条件、**設計ドキュメントからの逸脱候補と要判断事項**
   (あれば必ず明示)
4. ExitPlanMode で承認を待つ。承認されるまで実装に入らない。差し戻されたら計画を直して再提示する

### Step 2. ブランチ作成と実装

```bash
git switch main && git pull
git switch -c <ブランチ名>    # ブランチ命名規則に従う(既定: feat/<slug>)
```

1. 状態ファイル `docs/reviews/<ブランチ>/dev-cycle.md` を作成する
2. 承認された計画どおりに実装する。計画外の変更が必要になったら「人間に確認する条件」に従い停止する
3. 品質チェックを green にする(2回の修正で無理なら停止)
4. 論理単位ごとに commit する(Conventional Commits・英語・`git add <path>` で明示的に追加。
   `git add -A` は使わない)。review-loop は `git diff main...HEAD` を対象にするため、
   **実装は commit 済みの状態で Step 3 へ進む**

### Step 3. review-loop(PR 前レビュー)

`review-loop` スキルを起動する。次の2点を上書きする:

- review-loop 内では **push しない**(初回 push は Step 4 で行う)。commit は review-loop の規約どおり行う
  (本スキル起動により commit は許可済み)
- R3 で APPROVE にならなかった場合は review-loop の報告をそのまま引き継いで**停止**する
  (設計レベルの問題の可能性。人間の判断)

### Step 4. push と PR 作成

`start-task` の規約に従う。issue を作成するかは CLAUDE.md の運用に従う(指定が無ければ作成しない)。
レビュー bot の起動もここでは行わない(CI 通過後に Step 6 で行う)。

```bash
G=<Base directory for this skill>/scripts/gate-round.sh
"$G" push                    # 初回 push。`HEAD=<sha>` と `T=<UTC 時刻>` を出力する
gh pr create --base main --title "<type>: <summary>" --body-file <本文ファイル>
```

**初回 push も `gate-round.sh push` で行い、出力された `T` を控える**(`-u`/upstream 設定も面倒を見る)。
Step 6 の `--since` に渡す値はすべてこの出力から取る(Step 6 の警告を参照)。

PR 本文(日本語)は「プロジェクト設定の読み取り」で決めた項目(既定: 「対応フェーズ / 変更概要 /
テスト内容 / 設計ドキュメントからの逸脱(あれば)」)に、review-loop のサマリ(ラウンド数・修正数・
backlog 数と `docs/reviews/<ブランチ>/R*.md` への参照)を加える。末尾にシステムプロンプト指定の
署名を付ける。PR 番号と URL を状態ファイルに記録する。

### Step 5. CI 待ち

Bash を `run_in_background` で実行する(前面の `sleep` は使えない。完了時に1回通知が来る):

```bash
N=<PR番号>
until gh pr checks "$N" --json name --jq 'length' 2>/dev/null | grep -qE '^[1-9]'; do sleep 15; done
gh pr checks "$N" --watch --fail-fast
```

timeout は 600000ms。

Step 6 の依頼の直前の CI 待ちは、`request-gate-review.sh` の `--wait-ci` でまとめられる(下記。CI が
green になってから依頼し、red なら何も依頼せずに exit 3 で返る)。その場合この節の until ループは要らない。
最終ラウンドの修正の後(再依頼しない)と、`--wait-ci` を使わない時はこの節のとおり待つ。

- green → Step 6(または最終ラウンド後なら Step 8)
- red → `gh run view <run-id> --log-failed` で原因を確認し、ローカルで品質チェックを実行する。
  ローカルで再現し軽微(lint・format・型)なら修正して **Step 7 の確認ゲート**を通してから
  commit/push する。再現しない・原因が非自明なら停止して確認する(`ci-triage` スキルが使える)

### Step 6. bot へのレビュー依頼と待ち

`sequential` 指定時は本節の同時依頼ではなく、下の「順番実行」節に従う。

対象は「未収束 かつ 依頼回数 < 3」の bot のみ。**push 直前**の UTC 時刻 `T` を `--since` で渡す。

> **`T` は必ず `scripts/gate-round.sh push` の出力から取る**(初回 push も含む。Step 4 参照)。
> あとから `git log` で作り直そうとすると取り違えやすい——`--date=format:%Y-%m-%dT%H:%M:%SZ` は
> **コミット自身のタイムゾーンのまま**整形して末尾に `Z` を付けるだけなので、JST のコミットは
> 9時間先の「UTC」になる(`format-local:` でないと UTC にならない)。実際にこれで `T` が未来になり、
> `gate-threads.sh list/status` が新規指摘を1件も返さなかったことがある。bot の応答判定自体は
> `commit_id` で行うので `request-gate-review.sh` は正常に応答を検出し、**スレッドだけが 0 件**という
> 気づきにくい形で出る。手で作る場合は `TZ=UTC git log -1 --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd`。

依頼と待ちは本スキル同梱の `scripts/request-gate-review.sh` で行う
(手書きの `gh` ループに戻さない。理由は後述):

```bash
R=<Base directory for this skill>/scripts/request-gate-review.sh

"$R" <N> --since <T>                        # Copilot 依頼 + 両 bot の応答待ち(Codex は push 時の自動レビューを待つ)
"$R" <N> --since <T> --request-codex        # Codex の自動レビューが無いリポジトリ: "@codex review" も投稿する
"$R" <N> --since <T> --copilot-only         # Codex が収束済み
"$R" <N> --since <T> --codex-only           # Copilot が収束済み
"$R" <N> --since <T> --wait-only [--copilot-only]   # 依頼せず待つだけ(exit 2 の後にユーザーが UI から依頼した時、exit 1 の後に待ち直す時)
"$R" <N> --since <T> --wait-ci [...]        # 先に PR の CI の完了を待ち、green の時だけ依頼する(Step 5 の待ちを兼ねる)
```

Codex の自動レビュー(push で自動起動する設定)が有効かどうかは CLAUDE.md の記載や過去 PR の
コメントで判断する(有効なリポジトリで `@codex review` を投稿しても「Codex アカウントを接続して」
という案内が返るだけ)。

Bash `run_in_background`、**timeout 1800000ms**(依頼と登録確認が最大約 5 分 + 応答待ち最大 `--timeout`
〔既定 900 秒〕≒ 最悪 1,200 秒。短いと `DONE` / 終了コードを出す前にスクリプトが殺される)。出力は `| tail` などに
流さずファイルに書き出し、終了コードを取ってから読む(パイプに流すと終了コードが失われる)。

スクリプトがやること:

- 依頼は待つ前にまとめて出す。Codex(`--request-codex` 時の "@codex review" 投稿。失敗したら 10 秒後に 1 回だけ
  再試行し、それでも失敗なら Codex は待たない)→ Copilot の順
- **Copilot への依頼は GitHub が文書化した方法だけを使う**: まず `gh pr edit <N> --add-reviewer @copilot`
  (gh 2.88 以降。Web UI と同じ GraphQL mutation)、登録が確認できなければ REST の
  `POST pulls/<N>/requested_reviewers` に `copilot-pull-request-reviewer[bot]`。以前の REST `reviewers[]=Copilot`
  は文書化されていない値で、2026-09-21 頃から 201 を返しながら 6 回に 1 回程度しか登録されなかった
  (jp4wc-rakusync PR #4〜#11: timeline に `review_requested` が出ず、pending にもならず、レビューも来ない。
  同じ PR への UI からの依頼は毎回登録された)。omotegae-project で「登録確認は通らないがレビューは届く」と
  記録した件も、timeline には依頼イベントがあり登録自体はされていた — 遅すぎたのは確認手段(60 秒の pending
  一覧・timeline)であって、確認をやめる根拠ではない
- **登録は必ず確認してから待つ**(確認せずに待つと、未登録の依頼 1 回ごとに `--timeout` の 15 分を失う)。
  証拠は 3 系統のどれか: pending reviewer 一覧に Copilot が現れる(GraphQL `reviewRequests` と REST
  `requested_reviewers` の両方を見る。依頼前に不在だった場合のみ有効)/ timeline の `review_requested` イベント
  (依頼時刻以降。timeline API は数分遅れることがあるので単独では頼らない)/ 現 HEAD への Copilot レビュー到着。
  方法ごとに最大 90 秒、その後も最初の依頼から合計 5 分までは証拠を待ち(timeline の遅延と、レビュー本体の
  到着を拾う)、それでも無ければ **exit 2**。以前のように 15 分待ってから諦めない。実 PR(jp4wc-rakusync #12、
  2026-09-24)では `gh pr edit` の依頼が 0 秒で pending 一覧に現れ、2 分後にレビューが届いた
- 応答の判定は提出時刻ではなく **review の `commit_id` が現 HEAD と一致するか**で行う(両 bot とも
  1 時間以上遅れて、古い push へのレビューを今ラウンド中に投稿することがある)。Codex は加えて
  `issues/<N>/comments` の `T` 以降のコメント(指摘なしの "Didn't find any major issues")も応答と見なす
- `--since` を渡さないと `T` が「今」になり、CI 待ちの間に届いた Codex の自動レビューが Step 7 の
  `gate-threads.sh list <N> <T>` で「この push 以前」として除外される
- `--wait-ci` の時は依頼より前に `gh pr checks <N> --json name,bucket` を 20 秒ごとに見て、現 HEAD の check が
  すべて終わるまで待つ(最大 `--ci-timeout` 秒。既定 480 秒 = CI + 登録確認 5 分 + 応答待ち 15 分が外側の
  timeout 1,800 秒に収まる値)。fail / cancel が 1 つでも出たら残りを待たずに **exit 3**(何も依頼しない)。
  180 秒たっても check が 1 つも現れない時も exit 3(`CI=none`。CI が始まっていないのを green と見なさない)。
  jp4wc-rakusync PR #14 では、依頼の前の CI 待ちの until ループを 1 PR で 5 回手書きしていた
- 最後に bot ごとの状態行 `COPILOT=responded|timeout|unregistered|not-waited` /
  `CODEX=responded|timeout|request-failed|not-waited` と `CI=passed|failed|none|timeout|not-waited` を出し、成功時だけ `DONE` を出す。同時依頼で片方だけ
  応答した時は、この行で応答した bot を見分ける(終了コードだけで判断しない)

終了コード: `0` 待った bot がすべて現 HEAD に応答 / `1` TIMEOUT(依頼は登録されたが `--timeout` 内に応答が無い)/
`2` 依頼が出せなかった・登録されなかった(Copilot: 2 方法とも 5 分以内に確認できず。Codex: "@codex review" を
投稿できず)。`2` は他に待つ bot が無ければ約 5 分で返る(同時依頼で他方を待っている時は、その待ちの後に返る)。
`3`(`--wait-ci` の時だけ)CI が green にならなかった: check の失敗・取消(`CI=failed`)、check が現れない(`CI=none`)、
`--ci-timeout` 内に終わらない(`CI=timeout`)。何も依頼していないので依頼回数に数えない。`failed` は Step 5 の red の手順に、
`none` / `timeout` は「人間に確認する条件」(CI が非自明な状態)に進む。

**exit 2(Copilot 未登録)の時**は「人間に確認する条件」で次の選択肢を出す:
(a) ユーザーが PR 画面の Reviewers から Copilot を手動で依頼し、Claude は `"$R" <N> --wait-only --since <T>`
(Copilot のターンなら `--copilot-only` も)で待つ〔推奨。UI からの依頼はこれまで毎回登録された〕/
(b) この bot を待たずに進める(「未確認」として記録)/ (c) 中断。手動依頼も依頼回数に数える(同じ HEAD への
1 回の依頼)。手動依頼の後にスクリプトで依頼し直さない(二重依頼になる。待つのは `--wait-only`)。

TIMEOUT(exit 1)なら「人間に確認する条件」(`--wait-only` で待ち直す / 待たずに進める / 中断)。**TIMEOUT は
「bot が使えない/指摘を出し尽くした」ことを意味しない**(応答が Step 6 の待ち時間より遅れているだけの
可能性が高い)。3 ラウンドに達して先へ進む場合、状態ファイルと最終報告には「収束」ではなく
「未確認(bot 側は時間差で応答している可能性が高い)」と記録し、最終報告の「次にできること」で
`fix-copilot-review` による後日の再確認を必ず案内する。
依頼した事実を状態ファイルの「依頼 n 回」に加算する。

### Step 7. ゲートラウンド G<n>(ゲート: 確認ゲート)

ラウンド番号 n は Step 6 の依頼回数(両 bot 共通。`sequential` 時は通しのターン番号)。記録は `docs/reviews/<ブランチ>/G<n>.md`。

**1. 未解決スレッドと Copilot レビュー本文の取得**(REST は resolved 状態を返さないため GraphQL。
`fix-copilot-review` スキル同梱の `gate-threads.sh` が問い合わせ・返信・Resolve をまとめて持っているので
手書きしない。返信・Resolve・PR コメントの本文は必ずファイルか stdin で渡す):

```bash
S=~/.claude/skills/fix-copilot-review/scripts/gate-threads.sh

"$S" list <N> <T>             # 今回の新規指摘だけを TSV(thread_id / author / path / line / url)で
"$S" show <THREAD_ID>         # 1 件の本文を読む
"$S" status <N> <T>           # bot ごとの件数 + 現 HEAD への Copilot レビュー本文の件数(収束判定用)
"$S" bodies <N> <T>           # 現 HEAD への Copilot レビュー本文(URL / 判定見出し / Suppressed comments)
"$S" done  <N> <THREAD_ID> reply.md   # 修正した指摘: 返信してから Resolve
"$S" reply <N> <THREAD_ID> reply.md   # 保留した指摘: 返信のみ(Resolve しない)
```

- `<T>` は Step 6 で `--since` に渡した push 直前の時刻。`list` は「最初のコメントが `T` 以降
  (包含)の未解決スレッド」= 今回の新規指摘に絞り、ページングは最後まで辿る。author が bot
  (GraphQL の login は `copilot-pull-request-reviewer` / `chatgpt-codex-connector`)のものに
  `G<n>-<k>` の ID を振る(bot 名を併記)
- **Copilot はスレッドを立てずにレビュー本文だけで指摘することがある**(`### 🔵 Needs a closer look` /
  `### 🟡 Changes recommended` の見出し文と `Suppressed comments (N)`。`Comments generated: 0 new`
  でも本文に指摘が残る)。`status` の `copilot review bodies (head, since)` が `with findings` 1 件以上
  なら `bodies` で本文を読み、スレッドと同じく `G<n>-<k>` を振って仕分ける。返信先スレッドが無いので
  対応結果は PR のラウンドサマリコメントと `G<n>.md` に書く(Resolve 対象も無い)
- 前ラウンドで保留にした未解決スレッドは対象外(判断済み)。人間が ID で指示した時だけ対象に戻す
- 人間のレビュアーのコメントがあれば「人間に確認する条件」

**2. 収束判定**: 新規指摘が 0 件の bot は**収束**とし、以降その bot には依頼しない。Copilot は
「新規スレッド 0 件」だけでは収束にしない — `status` の本文件数が `with findings` 0 件(または本文を
読んで既出・対応済みの指摘しか無い)ことを合わせて確認する。

**3. 仕分け**(レビュー基準(「プロジェクト設定の読み取り」参照)の重大度で自分で再判定する。
bot の重大度を鵜呑みにしない。該当ファイルと周辺コードを読み、指摘が妥当か検証してから決める):

| 区分 | 条件 | 扱い |
|---|---|---|
| 修正 | Critical / High / Medium で妥当 | このラウンドで修正 |
| 保留 | Low、差分範囲外、誤検知、既に対応済み、`docs/review-baseline.md` の許容項目 | 修正しない。理由をスレッドに返信、未解決のまま残す、`docs/review-backlog.md` に追記 |
| 人間確認 | 「人間に確認する条件」のゲートラウンド項目に該当 | AskUserQuestion で1件ずつ(修正する / 保留 / 中断) |

**4. 修正**: 指摘の趣旨に対する最小限の変更。品質チェックを green にする(2回で無理なら停止)。
修正がコアロジック層(Domain/Services 相当、プロジェクトの構成による)に及ぶ場合、そのプロジェクトに
不変条件やアーキテクチャ規約を機械的にチェックするスキル・スクリプトがあれば commit 前に軽く流す
(レビュー指摘の修正自体が新しい規約違反を持ち込み、次のラウンドで指摘され返すことがある)。無ければ
この手順はスキップしてよい。

**5. 確認ゲート(停止)**: 作業ツリーに修正を残したまま、下記「ラウンド報告」を出して AskUserQuestion:

- 「commit & push して続行」(推奨)
- 「保留の指摘を追加で修正してから続行」→ 指定された ID を修正して 4 へ戻る
- 「ここで中断(作業ツリーに残す)」→ 状態ファイルを更新して終了。再開は `/dev-cycle resume`

ユーザーが自分でファイルを編集してから「続行」と言う場合がある。続行時は必ず `git status` と
`git diff --stat` を取り直し、品質チェックを再実行してから commit する。
`auto-commit` 指定時のみこのゲートを飛ばす(ラウンド報告は出す)。

**6. commit と push**:

```bash
git add <path>...
git commit -m "fix: <summary>" -m "<問題のシナリオ 2〜3 行。対応した指摘 ID: G1-2, G1-3>" ...
git push origin <ブランチ>
```

論理的に独立した修正はコミットを分ける。push 後に `G<n>.md`(下記フォーマット)と状態ファイルを
更新し、`docs: record dev-cycle gate round <n>` として commit・push する。

push は `git push` の代わりに `scripts/gate-round.sh push` で行うと、push 直前の UTC 時刻 `T` を取り、
push が成功した時だけ `HEAD=<sha>` と `T=<時刻>` を出力する。この `T` を次の bot の `--since` と
`gate-threads.sh list` に使う(push の後に取った `T` や前ラウンドの `T` を流用すると、指摘の取りこぼしや
重複が起きる)。記録用 `docs:` コミットの push も同じスクリプトで行い、その `T` を次の依頼に使う。
main / master の push は拒否する。PR がマージ済み・クローズ済みのブランチへの push も拒否する(マージの後に
push したコミットは base に届かない。Japanized-for-WooCommerce PR #222 では、マージの 2 分後に push した記録用
コミットが取り残され、main へ cherry-pick し直した)。拒否されたら、未マージのコミットを別の PR か(docs だけなら)
base への直接コミットで入れる。意図的な時だけ `--allow-closed-pr`。

**7. GitHub への反映**(push 後にのみ行う):

- 修正したスレッド: 何をどう直したかとコミット sha を返信し、GraphQL `resolveReviewThread` で Resolve
- 保留スレッド: 理由を返信し、**Resolve しない**
- PR にラウンドのサマリコメント(対応スレッドへのリンク `.../pull/<N>#discussion_r<databaseId>`、
  コミット sha、修正内容、テスト結果、保留とその理由)を `gh pr comment` で投稿

```bash
gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "<THREAD_ID>"}) { thread { id isResolved } } }'
```

返信・Resolve・サマリコメントは `scripts/gate-round.sh publish` で一括に行える(返信とサマリの本文は
ファイルで渡す):

```bash
G=<Base directory for this skill>/scripts/gate-round.sh
"$G" publish <N> --summary summary.md \
  --done <THREAD_ID>=reply.md \
  --hold <THREAD_ID>=reply.md \
  --since <T>
```

- `--done`(何本でも): 修正した指摘。返信してから Resolve する
- `--hold`(何本でも): 保留した指摘。返信のみで Resolve しない
- `--since`: 最後に未解決スレッドの状況を表示し、ラウンドが「未解決 0」で終わったかを目で確認できる
- 全ファイルを検証してから投稿し、ローカル HEAD が PR の head と違えば拒否する(未 push の sha を
  「修正済み」として案内しないため。意図的な時だけ `--allow-unpushed`)
- 途中で失敗した時は投稿済みの一覧を出すので、再実行は残りの指摘だけにする(全件を渡すと二重に返信する)
- `--dry-run` で実行内容だけ確認できる

**8. 次へ**: 両 bot が収束、または両 bot の依頼回数が 3 に達していれば Step 8。それ以外は Step 5 へ
戻り、CI green 後に未収束 bot へ再依頼する(Step 6)。3 回目の依頼に対する修正は push して CI を
待つが、**再依頼はしない**。`sequential` 時は、次にどの bot へ依頼するかを「順番実行」節で決める。

`G<n>.md` のフォーマット:

```markdown
# ゲートラウンド G<n>
- 対象 HEAD: <sha>(依頼時刻 <T>)
- Copilot: 新規 <k> 件 / Codex: 新規 <k> 件(または「依頼せず(収束済み)」)

## 指摘
### [G1-1][Copilot][High][src/Services/Example.php:42]
指摘の要旨(1〜3 行)/ 判定: 修正 / 保留 / 人間確認→修正
**対応:** 1 行(コミット sha または保留理由)/ スレッド: <url>

## 収束判定
| bot | 依頼回数 | 新規指摘 | 状態 |
|---|---|---|---|
修正後HEAD: <sha>
```

### Step 8. 最終報告と停止

1. `docs/reviews/<ブランチ>/final-report.md` に下記「最終報告」を書き、状態ファイルを「完了」に更新し、
   `docs: record dev-cycle final report` として commit・push する
2. 同じ内容をユーザーに報告して**停止**する。マージはしない

### `fix <ID>...`(最終報告後の人間判断による修正)

1. 状態ファイルと `G*.md` から指定 ID のスレッドを特定する(未解決であること)
2. Step 7 の 4 → 5(確認ゲート)→ 6 → 7 を実行する。bot への再依頼はしない
   (再レビューを望む場合はユーザーが判断して `gh pr edit <N> --add-reviewer @copilot` /
   `gh pr comment <N> --body "@codex review"` を指示する)
3. `final-report.md` の「修正しなかった指摘」から該当 ID を「修正した指摘」へ移し、commit・push する

保留分を1件ずつ対話的に見直したい場合は `/fix-copilot-review <N>` も使える(bot 由来の未解決スレッドを
すべて対象にし、対応不要と判断したものを AskUserQuestion で確認する)。

## 順番実行(`sequential` 指定時)

既定の同時依頼は、1 ラウンドで両 bot に依頼して両方の指摘をまとめて直す。同じ箇所を別々に指摘されて二重に
直しがちで、後から来た bot は直る前のコードを見ている。`sequential` は **1 体ずつ、前の bot の修正が入った HEAD を
次の bot に見せる**。Step 6〜8 の同時依頼をこの流れに置き換える(Step 0〜5・8 と「絶対にしないこと」「人間に確認する条件」は
そのまま有効)。

**順序**: Codex → Copilot → Codex → Copilot → Codex → Copilot(各 bot 最大 3 回、合計最大 6 ターン)。

**1 ターン** = 1 体の bot に対する「Step 5 CI 待ち → Step 6 依頼・待ち → Step 7 仕分け・修正・確認ゲート・
commit/push・GitHub への反映」。**ターンが完結してから次のターンに進み、他の bot への依頼を先に出さない。**

- **依頼はそのターンの bot だけ**:
  ```bash
  "$R" <N> --since <T> --codex-only --request-codex --wait-ci   # Codex のターン(--request-codex は Codex が push で自動レビューしないリポジトリ用)
  "$R" <N> --since <T> --copilot-only --wait-ci                 # Copilot のターン
  ```
  `--wait-ci` を付けると、前のターンの修正 push の CI 待ち(Step 5)もこの 1 回の呼び出しで済む
  Bash は Step 6 と同じく `run_in_background`・timeout 1800000ms
- **`<T>`** は、現在の HEAD を作った直近の push の直前時刻(`gate-round.sh push` が出力する)。前のターンで修正が無く push も無かったなら、前のターンの `<T>` のまま
- **対象スレッドの絞り込み**: `gate-threads.sh list` / `status` は全 bot のスレッドを返す。そのターンの bot の author
  (Codex: `chatgpt-codex-connector`、Copilot: `copilot-pull-request-reviewer`)だけを対象にする。`bodies` は Copilot のターンだけ読む。
  他の bot が前のターンで保留にして未解決のまま残したスレッドは判断済みなので対象外
- **記録**: ターン番号 n は通しの連番(G1 = 1 ターン目)。`G<n>.md` の見出しの下に `- bot: Codex(2 回目)` のように書く。
  指摘 ID は `G<n>-<k>`。状態ファイルには各 bot の依頼回数と「次のターン」を書く
- **次のターンの bot** は順序で次の bot。ただし次のいずれかなら飛ばして、その次の bot にする:
  - 収束済み(新規指摘が 0 件だった)
  - 依頼回数が 3 に達した
  - その bot が最後にレビューした HEAD から変わっていない(同じ HEAD への再依頼は同じ指摘を返すだけ)
- **終了**: 飛ばされずに残る bot がいなくなったら Step 8 へ。片方の bot だけが残った場合は、その bot が
  CI 待ちを挟みながら続けてターンを取る。最後のターンの修正は push して CI を待つが、再依頼はしない(既定と同じ)
- **確認ゲート**(Step 7-5)は既定と同じくターンごと。`auto-commit` で飛ばせる
- **TIMEOUT(exit 1)・Copilot の依頼が登録されない場合(exit 2)**の扱いは Step 6 と同じ。exit 2 でユーザーが手動で
  依頼したら `"$R" <N> --since <T> --wait-only --copilot-only` で待つ。「待たずに進める」を選んだ時は、
  その bot を「未確認」として記録し、依頼回数には数えたまま次のターンへ進む

## 報告フォーマット

### ラウンド報告(確認ゲートで提示)

```markdown
## G<n> ラウンド報告(commit 前・作業ツリーに修正あり)
- Copilot: 新規 <k> 件(修正 a / 保留 b / 人間確認 c)/ Codex: 同上 / 収束: <bot 名 or なし>
- 品質チェック: green(PHPUnit <n> 件)

### 修正した指摘(未コミット)
| ID | bot | 重大度 | 内容 | 変更ファイル |
### 修正しなかった指摘
| ID | bot | 重大度 | 理由 | スレッド |
```

### 最終報告

```markdown
# dev-cycle 最終報告: <ブランチ>
## 開発内容
- タスク / PR #<N> <url> / 承認された計画の要約 / コミット一覧(sha・メッセージ)
- 設計ドキュメントからの逸脱(あれば。要判断として残したものを含む)
## review-loop(PR 前)
| ラウンド | 指摘 | 修正 | backlog |
## Codex / Copilot ゲート
| ラウンド | bot | 新規指摘 | 修正 | 保留 | 状態 |
(状態は「収束」(新規指摘が実際に 0 件だった)と「未確認」(TIMEOUT で打ち切った。bot が指摘を
出し尽くしたわけではなく、応答が待ち時間より遅れているだけの可能性が高い)を区別する)
### 修正した指摘
| ID | bot | 重大度 | 内容 | コミット | スレッド |
### 修正しなかった指摘(PR 上で未解決のまま残してある)
| ID | bot | 重大度 | 理由 | スレッド |
## 品質ゲート
- CI: <run url> green / 品質チェック: green(PHPUnit <n> 件)
## 次にできること(人間の判断)
- 保留分の修正: `/dev-cycle fix G1-2 G2-1` または `/fix-copilot-review <N>`
- 状態が「未確認」の bot があれば: 数時間後(別セッションでもよい)に `/fix-copilot-review <N>`
  を実行し、遅れて届いた指摘が無いか確認することを推奨(「収束」した bot は再確認不要)
- マージ(GitHub 上で人間が行う)→ マージ後は `/post-merge`
```

## 注意事項

- 各ステップの開始前に状態ファイルを読み直し、完了後に更新する。長時間の待ちの後は
  `git status` / `git branch --show-current` / `gh pr view <N> --json state,headRefName` で
  前提(ブランチ・PR が変わっていないか)を再確認してから続ける
- 待ちは必ず Bash `run_in_background` の until ループで行い、前面の `sleep` や無限ループは使わない
- 実装は計画ドキュメントのフェーズ順・推奨順に従い、フェーズを跨いだ先回り実装をしない
- 修正は指摘の趣旨に対する最小限にとどめ、不要なファイル変更をしない
- `docs/review-baseline.md` / `docs/review-backlog.md` / `docs/reviews/<ブランチ>/R*.md` は
  Codex / Copilot が重複指摘を避けるために読むため、各ラウンドで最新に保つ
