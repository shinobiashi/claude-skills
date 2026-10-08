---
name: post-merge
description: PRがマージされた後の後始末を行う。デフォルトブランチの最新化、マージ済みローカルブランチとworktreeの片付け、今回の学びをCLAUDE.mdへ蒸留＋剪定、繰り返しパターンのコマンド化提案までを一気通貫で実施する。PR 本文に残った「マージ後に確認する項目」（PR では走らない E2E など）も拾って確認する。「マージした」「PRをマージ」「ブランチを片付けたい」「区切りがついた」「post-merge」などに言及したら、明示的に頼まれなくても積極的にこのスキルを使うこと。破壊的操作は必ず確認を取る。
argument-hint: "[マージしたブランチ名 または PR 番号(任意)]"
allowed-tools: Read, Edit, Grep, Glob, Bash(git status:*), Bash(git branch:*), Bash(git switch:*), Bash(git checkout:*), Bash(git pull:*), Bash(git fetch:*), Bash(git log:*), Bash(git diff:*), Bash(git worktree:*), Bash(git symbolic-ref:*), Bash(git remote:*), Bash(git merge --ff-only:*), Bash(git merge-base:*), Bash(git ls-remote:*)
---

# Post-Merge 後始末

PRがマージされたら「そのタスクは完了」。次のタスクにきれいな状態で入るための後始末をこの順で行う。

## 大前提

- **`/clear` はこのスキルからは実行できない**（セッション制御コマンドのため）。最後に必ずユーザーへ手動実行を促す。
- 破壊的操作（ローカルブランチ削除・worktree削除・prune）は、**実行前に必ず対象を提示して承認を取る**。承認なしに削除しない。
- 未コミットの変更が残っている場合は勝手に進めず、ユーザーに判断を仰ぐ。

## 手順

### 1. 状態を確認する
- `git status` と `git branch --show-current` で現在地を確認。
- **フォーク運用の検出**: `git remote -v` で `upstream` リモートの有無を確認する。`upstream` があれば PR のマージ先は upstream（本流）であり、以降のマージ判定はすべて **`upstream/<default>` を基準**にする（`origin/<default>` はフォークで、本流より遅れていることが多い）。`gh` コマンドはデフォルトで本流リポジトリを見るため、フォークのブランチ指定には `--repo <本流> --head <フォークowner>:<branch>` が必要な点にも注意。
- デフォルトブランチを検出する: `git symbolic-ref --short refs/remotes/origin/HEAD`。取得できなければ `main` を想定（必要なら `master`/`develop` をユーザーに確認）。
- マージ済みブランチ名は、引数 `$ARGUMENTS`（ブランチ名または PR 番号）があればそれを、無ければ現在のブランチ名を採用する。
- **対象の PR が本当にマージ済みかを確かめる**: `gh pr view <ブランチ名 or PR番号> --json number,state,mergeCommit,headRefName`。
  現在のブランチの PR が `MERGED` でないとき（別の PR をマージした直後に、次の作業ブランチにいる場合）は、
  `gh pr list --state merged --limit 5 --json number,headRefName,mergedAt` で直近にマージされた PR を見る。ローカルにブランチが
  残っているものが 1 件だけならそれを対象にし、その旨を報告する。複数あればどれの後始末かをユーザーに確認する。
  未マージの作業ブランチは片付けの対象にしない（jp4wc-pro で、PR #3 のマージ後に PR #5 のブランチ上で実行された）。

### 2. デフォルトブランチを最新化する
- 通常: `git switch <default>`（古い環境なら `git checkout <default>`）→ `git pull`。
- **現在のブランチが未マージの作業ブランチのとき**（対象の PR は別のブランチ）は、切り替えずに
  `git fetch origin <default>:<default>` で `<default>` だけを fast-forward する。作業ブランチから離れると、ブランチごとに違う
  設定ファイル（`.wp-env.json` など）がディスク上で入れ替わる。手順 5 で `<default>` に直接コミットするときだけ切り替え、
  終わったら元のブランチへ戻す。
- **フォーク運用**: `git fetch upstream` → `git switch <default>` → `git merge --ff-only upstream/<default>` → `git push origin <default>` でフォークの default も同期する。
- ここで未コミットの変更があれば停止してユーザーに確認。
- **ローカルの `<default>` に未 push のコミットがあり、origin が先へ進んでいる（squash マージなどで分岐した）場合**、`git pull` は分岐エラーか不要なマージコミットになる。次の順で扱う:
  1. `git fetch` してから `git log origin/<default>..<default> --oneline`（ローカルのみ）と `git log <default>..origin/<default> --oneline`（origin のみ）を確認する
  2. ローカルのみのコミットの内容が既に origin に入っているかを確かめる: そのコミットが触ったファイルについて `git diff <default> origin/<default> -- <ファイル>` が**空**か。次の作業ブランチを未 push の `<default>` から切っていた場合、その PR のスカッシュに内容が含まれて入っていることがある（実例: cart-bridge-jp の PR #64 に、未 push だった PR #61 の蒸留コミットが混入した）
  3. **内容が既に origin に含まれる** → `git pull --rebase`。重複コミットが「patch contents already upstream」で落ち、`<default>` が `origin/<default>` と一致する（何も失われない）。結果をユーザーに一言報告する
  4. **含まれない（本当に未 push の作業）** → 勝手に rebase/reset せず、載せ替えてよいかユーザーに確認する

### 3. マージ後に確認する項目を拾う
PR の本文に残った未チェックの項目（`- [ ]`）は、「マージ後に確認する」と約束したもの（`/start-task` の PR 本文は、実施済みを
`[x]`、レビュアー・マージ後に確認する項目を `[ ]` で書く）。後始末のときに拾わないと、誰も確認しないまま残る。

- 対象の PR の本文から未チェックの項目を抜き出す。1 件も無ければ「未チェックの項目なし」と報告して次へ進む:
  ```bash
  gh pr view <PR> --json body --jq .body | grep -nE '^\s*[-*] \[ \]'
  ```
- 項目を 3 つに分ける:
  1. **マージコミットの CI で確かめられるもの**（PR では走らず `<default>` への push でだけ走る E2E など）→ 下の方法で run を見る
  2. **手元で確かめられるもの**（コマンドの実行、生成物の確認など）→ 実行して結果を見る。環境やデータを変える操作は承認を取る
  3. **自分では確かめられないもの**（本番環境、外部サービスの設定、目視の確認）→ 確認したことにせず、残っている項目としてユーザーに渡す
- マージコミットの CI は **sha で引く**（ブランチ先端の sha ではなく `mergeCommit.oid`。`<default>` への push で走る run はマージコミットに付く）:
  ```bash
  SHA=$(gh pr view <PR> --json mergeCommit --jq .mergeCommit.oid)
  gh api "repos/<OWNER>/<REPO>/actions/runs?head_sha=$SHA" \
    --jq '.workflow_runs[] | "\(.id) \(.name) \(.status)/\(.conclusion // "-")"'
  ```
  `gh run list --branch <default>` は、新しい run を返さず古い run だけを並べたことがある（jp4wc-pro、2026-10-06）。
- run が実行中なら**前面で待たない**。`gh run watch <ID> --exit-status` をバックグラウンドで走らせて手順 4 以降を先に進め、
  完了したらジョブごとの結果を報告する。
- **失敗していたら「完了」と報告しない**。ジョブが 1 ステップも実行せずに終わっていればインフラ起因のことが多い（`/ci-triage`）。
  コード起因なら、マージ済みの変更が `<default>` を壊しているので、最終報告の先頭で伝える。
- 結果は最終報告に、項目ごとに「確認済み / 失敗 / 未確認（理由）」で書く。PR に記録を残すかどうかはユーザーに尋ねる
  （残すなら `gh pr comment <PR> --body-file <ファイル>` で 1 件。マージ済み PR の本文のチェックボックスは書き換えない）。

### 4. マージ済みブランチとworktreeを片付ける（承認必須）
- `git branch --merged <default>` で対象がマージ済みか確認する（フォーク運用では `--merged upstream/<default>`）。
- マージ済みなら削除を提案 → 承認後に `git branch -d <branch>`。マージ済みでなければ削除せず、その旨を報告。
- **squash / rebase マージのブランチは `--merged` に出ず、`-d` が「not fully merged」で拒否される**（コミットが本流に別のハッシュで入るため）。
  この場合は次の**3点をすべて確認**してから、承認を取って `git branch -D` を提案する（1つでも欠けたら削除しない）:
  1. `gh pr view <PR> --json state,mergeCommit` が `MERGED`（マージコミットの sha を控える）
  2. **ブランチ先端と本流のツリーが同一**: `git diff --stat <branch> <default>` が空、または `git rev-parse <branch>^{tree} <default>^{tree}` が一致
     （マージ後に本流へ別のコミットが入っていて差分が出る場合は、差分が「後から本流に入った変更だけ」であることを `git log <branch>..<default>` で確認）
  3. **未 push のコミットが無い**: `git log origin/<branch>..<branch>` が空（リモートを既に消していると失敗するので、その場合は
     `git log <default>..<branch>` で本流に無いコミットが無いことを確認）
- `git worktree list` を確認し、対象ブランチに紐づく worktree があれば削除を提案 → 承認後に `git worktree remove <path>`。（`claude -w` を使っていた場合に該当）
- 追跡ブランチの掃除として `git fetch --prune` を提案。
- **リモートブランチは GitHub の「マージ時にブランチを自動削除」で既に消えていることが多い**。`git push origin --delete` の前に
  `git ls-remote --heads origin <branch>` で存在を確認し、無ければ削除を試みない（試すと "remote ref does not exist" で失敗する。無害だが紛らわしい）。
  `git fetch --prune` で追跡ブランチだけ掃除すればよい。
- **フォーク運用**: origin（フォーク）に残っているマージ済みリモートブランチの削除も提案してよい。削除前に必ず `git ls-remote` + `git merge-base --is-ancestor <sha> upstream/<default>` で**1本ずつ**マージ済みを確認し、未マージのブランチは残して報告する。削除は `git push origin --delete <branch>`（承認必須・権限プロンプトが出るのは意図どおり）。

### 5. 学びを CLAUDE.md に蒸留し、同時に剪定する
- 今回のマージ内容を把握する: `git log --oneline <default>@{1}..<default>` や該当範囲の `git diff`。
- 「**毎セッション効く規約・ハマりどころ**」だけを抽出する。この開発スタックでは特に次を意識する:
  - **WordPressプラグイン(PHP)**: フック登録のタイミング、HPOS対応のデータアクセス方法、nonce/権限(`current_user_can`)/サニタイズ・エスケープの方針、i18nロードの作法、名前空間・命名規約。
  - **Laravel(PHP)**: FormRequest/Policy の置き場所、Service/Action の分割方針、マイグレーション・命名規約、キュー/イベントの約束事。
  - **TypeScript / React**: 型の配置、コンポーネント分割方針、状態管理・データ取得フックの約束事、strictルール。
- 既存の CLAUDE.md を読み、(a) 追記すべき新規約 と (b) 今回のマージで**古くなった・矛盾する記述** の両方を洗い出す。
  **リポジトリに `.claude/rules/*.md`（パス指定ルール）がある場合は、それも読み、領域固有の落とし穴は該当するルールファイルへ追記する**
  （どの領域にも効く汎用規約・アーキテクチャ原則だけ CLAUDE.md へ。分割済みの CLAUDE.md を再び肥大化させない）。差分の提示では追記先ファイルを明示する。
- 追加と削除を**差分としてユーザーに提示** → 承認後に Edit で反映する。
- 反映を `<default>` へ**直接コミットする場合（ドキュメントのみ）は、次の作業ブランチを切る前に push する**（承認の質問に「push もする」の選択肢を入れる）。未 push のまま `<default>` から作業ブランチを切ると、次の PR にこの蒸留コミットの変更が混入する（手順 2 の実例）。
- 原則: CLAUDE.md は毎セッションの冒頭で読み込まれ context を消費する。**簡潔第一（目安200行以内）**。手順ものや特定ディレクトリだけに効く規則は CLAUDE.md に足さず、別スキル / スラッシュコマンド / `.claude/rules/` へ逃がすことを提案する。

### 6. 繰り返しパターンをコマンド化する（提案のみ）
- 今回の作業で2回以上踏んだ手順や、定型化したレビュー観点があれば、新しいスキル / スラッシュコマンド / サブエージェントへの切り出しを**提案**する。
- ここでは自動作成しない。ユーザーが望めば別途作成に進む。

### 7. 締め（ユーザーへの案内）
- 実施した後始末を1〜3行で簡潔に報告する。手順 3 の確認結果（確認済み / 失敗 / 未確認）もここに含める。
- 「次のタスクに移る前に `/clear` を手動で実行してください」と促す（`/compact` ではなく `/clear`。タスク完了時は履歴を引き継がない）。
  手順 3 でバックグラウンドの確認がまだ走っているなら、結果を報告してから `/clear` するよう伝える。
- 厄介な問題を解いたセッションなら、`/clear` の前に `/rename` で命名、または `/export` で保存を提案する。
  - これらは**ユーザー個人の参照用**（セッション一覧での発見しやすさ／生トランスクリプトの手元保存）であり、手順5のリポジトリへの知見蒸留とは目的が異なる。`/export` はローカル環境の情報（鍵ファイル名・パス等）を含みうる生ログのため、内容を選別せずリポジトリへ自動保存することはしない。あくまで人力で判断して使う機能であり、それ自体が不要というわけではない。
  - `/rename` はスラッシュコマンドのためスキルから直接実行できない（実行自体はユーザーが行う）が、**名付け自体はスキルが代行してよい**。リポジトリ名・タスク概要・PR番号・主な成果からその場で具体的な名前案を1つ組み立て、`/rename <名前案>` の形でそのまま貼り付けられるように提示する（例: `/rename jp4wc-rakusync Phase0基盤構築+RMS実店舗確認(PR#1)`）。「命名してください」とだけ促すのではなく、ユーザーがコピペするだけで済む状態にする。

## 出力スタイル
- 各ステップの前に「何をしようとしているか」を1行で述べ、破壊的操作は承認を待つ。
- 最終報告は箇条書きで短く。冗長な説明は避ける。
