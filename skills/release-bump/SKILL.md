---
name: release-bump
description: タグ push で WordPress.org へ自動デプロイするプラグインのリリース作業。「バージョンを上げて」「bump PR を作って」「リリースの準備」「changelog に #230 を足して」「リリースブランチに追記」「リリース前チェック」「タグを打って」「2.9.17 をリリース」などで使う。`release/<ver>` ブランチを切って版数ファイルを書き換え、前タグ以降にマージされた PR から changelog を起草して bump PR を作る `start`、bump PR を開いた後にマージされた fix PR の changelog 行を追記する `add`、マージ前の `check`、main の取り込み `sync`、本流だけへの v 無しタグ push `tag` の 5 モード。wp.org の SVN 操作そのもの（`wp-org-release`）やマージ後の後始末（`post-merge`）は扱わない。
argument-hint: "start <x.y.z> [YYYY-MM-DD] | add [<PR#>...] | check | sync | tag <x.y.z>"
---

# /release-bump — bump PR から changelog 追記、タグ push まで

リリースは「bump PR を作る」「後から入った PR の changelog 行を足す」「マージ前に揃っているか見る」「タグを打つ」の
4 つの作業が日をまたいで繰り返される。それぞれで同じ取り違え（`@since` まで書き換える、PR を changelog に書き忘れる、
`v` 付きタグ、フォークへタグ push）が起きるので、機械的な部分を `scripts/release-bump.sh` に寄せ、判断の要る部分
（changelog の文、どの PR を載せるか、タグを打つ瞬間）だけを人間と相談する。

## 役割分担

| スキル | 担当 |
|---|---|
| **release-bump**（本スキル） | 版数ファイルの書き換え、changelog の起草・追記、bump PR、マージ前チェック、タグ push |
| `wp-org-release` | WordPress.org の SVN（trunk / tags / assets）、readme.txt の書式、初回提出・審査対応。タグ push で自動デプロイしないリポジトリでは `tag` の後にこちら |
| `post-merge` | bump PR がマージされた後の後始末（main の同期、ブランチ削除、CLAUDE.md への蒸留）。その後に本スキルの `tag` |
| `dev-cycle` / `start-task` | 機能・修正の PR。changelog は書かない（bump PR に集約する） |

## プロジェクト設定の読み取り

リポジトリ直下の `CLAUDE.md`（と `docs/` のリリース手順があればそれ）を読み、次を決める。記載が無い項目は既定値。

| 項目 | CLAUDE.md から読む内容 | 既定値 |
|---|---|---|
| リリースブランチ | ブランチ命名 | `release/<x.y.z>` |
| タグの形式 | `v` の有無 | **`v` 無し**（`scripts/release-bump.sh detect` が前タグの形式を報告する。デプロイ workflow が readme.txt の `= <TAG> ` 見出しから Release 本文を抜く構成では `v` を付けると本文が空になる） |
| changelog の書式 | readme.txt の既存エントリ | 直前 2 リリースのエントリから写す（例: `* **Added/Fixed/Changed/Security** - ...`、英語、末尾に `(#<issue or PR>)`） |
| 版数を持つファイル | 版数の書き換え対象 | `detect` の CARRIER 行（プラグインヘッダー `Version:`、`define( '<PREFIX>_VERSION' )`、クラス定数、readme.txt `Stable tag:`、package.json、CLAUDE.md） |
| 本流リモート | フォーク運用か | `upstream` があれば upstream、無ければ origin（`detect` の REMOTE） |
| POT 再生成 | i18n の手順 | `npm run make-pot` / `make-json`（wp-env 必須なら起動して行う） |
| タグ前の全マトリクス | タグ push の前に走らせるテスト | デプロイ workflow 自身が全マトリクスを回すなら不要。回さないなら `gh workflow run <testing.yml> -f scope=full` を main で先に回す |
| PR 本文 | PR 本文に書く項目 | 「版数 / changelog / 含まれる PR の表 / POT・Tested up to の確認 / マージ後の手順」 |

## 前提: commit / push / PR 作成の権限

グローバル CLAUDE.md の「明示的な指示があるまで commit / push しない」に対し、**このスキルの起動をもって次の操作の
指示とみなす**（`start-task` と同じ扱い）:

- `start`: リリースブランチの作成、bump コミット、本流への push、bump PR の作成 — ただし **changelog の文は
  AskUserQuestion で承認を得てから** commit する
- `add`: changelog 追記のコミットと release ブランチへの push — 追記する文を AskUserQuestion で承認を得てから
- `sync`: main を release ブランチへ merge して push — コンフリクトがあれば止まって相談

逆に、起動をもってしても許可されないもの:

- **`tag`**: タグの作成・push は wp.org へのデプロイそのもの。**必ず AskUserQuestion で「この sha にこの版数のタグを
  打って <remote> へ push する」と確認し、返答があるまで実行しない**
- PR のマージ（bump PR も人間がマージする）、`main` への直接 push、force push、push 済みブランチの rebase、
  リモートタグの削除（デプロイが失敗した時だけ、理由を示して確認のうえ行う）
- readme.txt 以外の配布物（`*.pot`、翻訳、ビルド済み JS）の変更。POT 再生成が必要と分かったら、別コミットにするか
  bump PR に含めるかを確認する

レビュー・説明・報告は日本語、コード・コミットメッセージ・changelog（既存が英語なら）は英語。

## スクリプト

```bash
R=<Base directory for this skill>/scripts/release-bump.sh

"$R" detect [--version <new>]        # 版数の所在。CARRIER=書き換える行 / MENTION=触らない行
"$R" prs [--since <tag>] [--skip 1,2] [--changelog-ref <ref>]
                                     # 前タグ以降に main へマージされた PR。kind(code|docs|ci) と changelog 参照の有無
"$R" bump <ver> [--date YYYY-MM-DD] [--entries <file>]   # 版数の書き換え + changelog 見出し + エントリ
"$R" add-entries <file> [--version <ver>]                # 既存の見出しの下に行を追記（重複は飛ばす）
"$R" check [--since <tag>] [--skip 1,2]                  # マージ前チェック。要対応なら exit 1
"$R" tag <ver> [--dry-run]                               # v 無しタグを本流へ push（前提をすべて検査）
```

- `detect` は現行版数を含む行を全部見て、**書き換えるべき行（CARRIER）とそうでない行（MENTION）に分ける**。
  `@since x.y.z` の docblock と readme.txt の changelog 見出しは履歴なので対象外（一覧にも出ない）。MENTION に
  本当は書き換えるべき行があれば報告し、スクリプトの判定を直す（手で書き換えてごまかさない）
- `prs` は `gh pr list --state merged` を前タグの日付以降で取り、**merge commit が前タグに含まれず main に含まれる**
  ものだけ残す（PR 番号の大小やマージ日時では判定しない。マージ日時がタグ後でもタグに含まれる PR がある）。
  `referenced` は changelog の最新ブロックに `#<PR>` か PR に紐づく issue の `#<n>` があるか。番号を書かずに説明した
  エントリは `no` になるので、読んで確認したうえで `--skip` に入れる。**新しく書くエントリには必ず `(#<issue or PR>)`
  を付ける**（次回以降の `check` が自動で突き合わせられる）
- `bump` と `add-entries` は readme.txt の空行の配置を保つ（見出し / エントリ / 空行 / 次の見出し）。デプロイ workflow の
  `awk "/^= ${VERSION} /..."` がこの配置を前提にしている
- `tag` は「`v` 無し」「作業ツリーがクリーン」「default ブランチ上で HEAD = 本流の先端」「プラグインヘッダー・
  `Stable tag` が <ver>」「changelog 見出しがある」「タグが未存在」をすべて検査し、**本流リモート以外への push を拒む**
  （フォークには SVN の secrets が無く、失敗 run が残るだけ）
- bash 3.2 / BSD awk で動く。`bash scripts/test-release-bump.sh` でシナリオテスト（77 件）

## モード

引数の最初の語で決める。省略時は現在の状態から推定して確認する（`release/*` ブランチの PR が open なら `check`、
default ブランチ上で bump PR がマージ済みなら `tag`、それ以外は `start` の版数を尋ねる）。

### `start <x.y.z> [<date>]` — bump PR を作る

1. **状態確認**: default ブランチ上・クリーン・本流と一致（`git fetch <remote> && git merge --ff-only <remote>/<default>`）。
   `detect --version <x.y.z>` で版数の所在と前タグを取る。`<x.y.z>` が現行より大きいこと、`release/<x.y.z>` が
   ローカル・リモートに無いことを確認。open な `release/*` PR が既にあれば **`start` ではなく `add` / `check` の対象**
   なので止まって確認する
2. **対象 PR の収集**: `prs` を実行し、`kind=code` の PR を changelog 候補にする。`docs` / `ci` は載せない。
   `code` でもリポジトリの整備（`.gitignore`、`.distignore`、phpcs 設定、テストだけの PR）は載せないと判断してよいが、
   その判断は候補一覧に「載せない理由」を添えて見せる
3. **changelog の起草**: 候補 PR ごとに `gh pr view <N> --json title,body` を読み、**既存エントリの書式**（カテゴリ・
   言語・文体・末尾の `(#n)`）で 1 行ずつ書く。利用者から見た変化を書く（内部名・ファイル名ではなく、何がどう
   直ったか）。`Tested up to` / `WC tested up to` のヘッダーが上がるなら `**Changed** - Tested up to ...` を足す
   （ヘッダー自体を上げるかはユーザー判断。上げるならその行も bump コミットに含める）。日付は引数、無ければ今日
   （公開予定日が決まっていればそれを使う）
4. **承認（停止）**: 版数・日付・エントリ全文・載せない PR とその理由を提示し、AskUserQuestion で
   「この内容で bump PR を作る」「文を直す（指示をもらって 3 へ）」「中断」
5. **ブランチと書き換え**: `git switch -c release/<x.y.z>` → エントリを scratchpad のファイルに書き →
   `bump <x.y.z> --date <date> --entries <file>` → `git diff` を見て、**版数の行と changelog 以外が変わっていない**
   ことを確認（`@since` が変わっていたら即座に直してスクリプトのバグとして報告）
6. **commit / push / PR**: `git add` は変わったファイルを明示（`-A` は使わない）。
   `chore: bump version to <x.y.z> and add changelog`。本流へ push し、
   `gh pr create --repo <owner/repo> --base <default> --head <release-branch>`（フォーク運用で本流へ push しているので
   `owner:` 接頭辞は不要）。本文は「プロジェクト設定の読み取り」の項目。末尾にシステムプロンプト指定の署名
7. **報告**: PR の URL、載せた PR と載せなかった PR、`check` の結果（`BEHIND 0` のはず）、「マージ後は `/post-merge` →
   `/release-bump tag <x.y.z>`」。POT 再生成が要りそうなら（`check` の WARN）その旨

### `add [<PR#>...]` — 後から入った PR の changelog 行を足す

bump PR を開いた後に fix PR がマージされた時の作業。`post-merge` の最終報告で「bump PR に changelog 行を追記」と
出たらこれを使う。

1. **release ブランチの特定**: 本流の `release/*` ブランチで PR が open なもの。複数あれば確認。見つからなければ
   「bump PR が無いので `start` から」と案内して止まる
2. **worktree**: 今のチェックアウトを汚さないよう、scratchpad に worktree を作って作業する:
   `git fetch <remote> && git worktree add <scratchpad>/release-bump/<ver> <release-branch>`
   （ローカルブランチが無ければ `-b release/<ver> <remote>/release/<ver>` で作り、追跡を付ける）。
   終わったら `git worktree remove`
3. **対象 PR**: 引数があればその番号、無ければ `prs` で `kind=code` かつ `referenced=no` のもの。番号を書かずに
   既に書かれているエントリがあれば、それは対象から外す（`--skip` に入れて `check` が通るようにする）
4. **起草と承認（停止）**: `start` の 3 と同じ書式で 1 行ずつ書き、AskUserQuestion で承認を得る
5. **追記と push**: `add-entries <file>`（見出しは最新のもの）→ `git diff` が readme.txt の追記行だけであることを確認 →
   `chore: add the <ver> changelog entry for #<N>`（複数なら `entries for #<N>, #<M>`）→ release ブランチへ push
6. **確認**: `check` を実行。`BEHIND` が出ていれば `sync` を提案する（追記と同じターンで続けてよい）
7. 報告: 追記した行、コミット sha、PR の URL、`check` の結果

### `check` — マージ前チェック

release ブランチの worktree（または release ブランチ上）で `check` を実行し、結果をそのまま表にして報告する。

| 行 | 意味 | 次の手 |
|---|---|---|
| `MISSING carriers / Stable tag / package.json` | 版数の不一致 | `detect` で所在を見て直す |
| `MISSING heading` | changelog の見出しが無い | `bump` をやり直すか見出しを手で足す |
| `MISSING code PRs without a changelog reference` | 載っていない PR | 読んで、本当に無ければ `add`、番号無しで載っていれば `--skip` |
| `BEHIND n` | main が先に進んでいる | `sync` |
| `WARN translation calls` | 前タグ以降に翻訳文字列が増えた | `.pot` の最終変更がそれより後か確認。前なら POT 再生成（別コミット） |
| `WARN heading` | 見出しが `= x.y.z - YYYY-MM-DD =` の形でない | デプロイ workflow の抽出に合わせて直す |

`DONE` で exit 0 なら「マージできる状態」。マージは人間が行う（`gh pr merge` を代行しない）。

### `sync` — main を release ブランチへ取り込む

`git merge <remote>/<default>` を release ブランチの worktree で行い、push する。**rebase はしない**（push 済み
ブランチの履歴を書き換え、force push が要る）。コンフリクトは readme.txt の `Stable tag` と changelog 見出し、
`CLAUDE.md` の版数行に出やすい。release 側（新しい版数）を採って解消し、解消した内容を報告する。それ以外のファイルで
コンフリクトしたら止まって相談する。merge 後に `check` を再実行する。

### `tag <x.y.z>` — タグを打つ（bump PR のマージ後）

1. `/post-merge` が済んでいる前提で、default ブランチ上・クリーン・`git fetch` 後に本流と一致していることを確認する。
   `tag <x.y.z> --dry-run` で前提検査だけ走らせ、拒まれたらその理由を解消する（拒否は設計どおり）
2. **タグ前の全マトリクス**（「プロジェクト設定の読み取り」参照）: デプロイ workflow 自身が全マトリクスを回すなら
   そのまま進む。回さないなら `gh workflow run <testing.yml> --ref <default> -f scope=full` を実行して green を待つ
   （Bash `run_in_background` で `gh run watch`）
3. **確認（停止）**: 「`<sha>` に `<x.y.z>` のタグを作って `<remote>`（`<owner/repo>`）へ push する。これで wp.org への
   デプロイと GitHub Release の作成が走る」と AskUserQuestion。選択肢は「push する」「中断」
4. `tag <x.y.z>` を実行し、`gh run list --repo <owner/repo> --branch <x.y.z>` で run を見つけて `gh run watch <id>
   --exit-status` を背景で待つ
5. **結果**:
   - 成功: `gh release view <x.y.z> --repo <owner/repo>` で本文（changelog）と ZIP を確認し、
     wp.org 側は `svn ls https://plugins.svn.wordpress.org/<slug>/tags/ | grep <x.y.z>`（svn があれば）。
     plugins API の表示は数分〜最大 24 時間遅れるので、遅いだけで失敗扱いにしない
   - 失敗: 何もデプロイされていない（workflow の設計上）。`gh run view <id> --log-failed` で原因を見て報告し、
     **タグの削除（`git push <remote> :refs/tags/<x.y.z>` と `git tag -d`）は理由を示して確認のうえ**行う。
     修正は main への PR で行い、マージ後にもう一度 `tag`
6. 報告: run の URL、Release の URL、wp.org の確認結果、残っている作業（翻訳の反映、告知など）

## 最終報告の形

```markdown
## release-bump <モード>: <x.y.z>
- PR / Release: <URL>
- commit: <sha> <メッセージ>
- changelog: 追加 n 行（#..., #...）/ 載せなかった PR: #... (理由)
- check: DONE | MISSING ... | BEHIND n | WARN ...
- 次: （マージは人間が行う → /post-merge → /release-bump tag <x.y.z>）または（タグ push 済み → run <URL> を確認）
```

## 注意事項・ハマりどころ

- **`@since` を巻き込まない**: 版数の一括置換は `@since x.y.z` docblock（その機能が出た版）も書き換えてしまう。
  必ず `bump` を使い、`git diff` で `@since` 行が変わっていないことを見る
- **PR の選別はタグとの祖先関係で**: マージ日時がタグより後でも、タグに含まれる PR がある（タグを打つ直前に
  マージした PR）。`prs` はこれを除外する。`git log --merges` の件数や PR 番号の大小で数えない
- **番号無しのエントリは `check` に見えない**: 既存の changelog には番号を書かない行がある。`--skip` で明示する。
  これから書く行には `(#n)` を付ける
- **タグは `v` 無し・本流だけ**: `v2.9.14` は Release 本文が空になった実績。フォークへ push すると secrets が無く
  失敗 run だけが残る。`tag` が両方を拒む
- **POT 再生成は別コミット**: 翻訳文字列を足した PR が bump PR の後に入ったら `.pot` が古い。`check` の WARN を見て、
  必要なら wp-env を起動して `make-pot` / `make-json` を回し、`chore: regenerate the POT file` として bump PR に足す
  （差分の大半が行番号の変化なら正常）
- **merge であって rebase ではない**: release ブランチは本流に push 済み。履歴を書き換えない
- **bump PR はマージしない**: `check` が DONE でも、マージは人間が GitHub 上で行う（`dev-cycle` / `post-merge` と同じ）
- **readme.txt は配布物**: グローバル CLAUDE.md の「ドキュメントのみなら main へ直接」の対象外。changelog の追記も
  必ず release ブランチの PR 経由
- **`Tested up to` は別判断**: 版数と一緒に上げるかどうかは、そのバージョンで実際にテストしたかによる。上げる時は
  readme.txt とプラグインヘッダー（`WC tested up to` も）の両方
