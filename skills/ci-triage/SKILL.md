---
name: ci-triage
description: >
  GitHub Actions の CI 失敗を「コード起因」か「インフラ起因（課金・ランナー・
  ワークフロー設定・キャッシュ）」かに切り分けるスキル。失敗ジョブの所要時間と
  ステップ実行有無から当たりを付け、`gh run view --log-failed` が空振りする
  ケース（ジョブ自体が起動していない場合）では check-runs の annotations を
  読んで原因を特定する。「CIが落ちた」「CIが真っ赤」「全部failしてる」
  「なぜ落ちたか調べて」「ci triage」「CI失敗の原因」といった依頼で使う。
  ローカルでは通るのに CI だけ落ちる場合の環境差の確認手順も含む。
  PR が触っていないファイルで落ちる（分岐元が古く main で修正済み）ケースの判定と
  ブランチ更新の手順も含む。
  引数: PR番号 または run ID（省略時は現在のブランチの PR）。
---

# CI 失敗の切り分け

CI の赤を見たとき、**まず「コードの問題か、そうでないか」を確定させる**。
ここを飛ばして修正を始めると、コードに問題が無いのに直そうとして時間を溶かす
（例: 全ジョブが課金上限で起動していないだけなのに、コードを直しにかかる）。

以下「ローカルの品質チェック」は、リポジトリの `CLAUDE.md` / `composer.json` の scripts で
定義された lint・静的解析・テストのコマンド一式を指す（既定: `composer lint` / `composer analyze` /
`composer test`。JS 側は `package.json` の `lint:js` / `build` など）。

## 手順

### 1. 全体像を見る（最初の30秒）

```sh
gh pr checks <N>          # PR 単位。run ID が分かっているなら gh run view <ID>
```

**所要時間が最大の手がかり**:

| 症状 | 最初に疑うもの |
| --- | --- |
| 全ジョブが 2〜5 秒で失敗 | ジョブが**起動していない**（課金・権限・ワークフロー構文）→ §2 へ |
| 一部ジョブだけ失敗、時間は正常 | コード起因の可能性が高い → §3 へ |
| 全ジョブが正常な時間かけて失敗 | 共通の依存・セットアップ段階の失敗 → §3 へ |
| 無関係なジョブ（例: Lint CSS）まで落ちている | インフラ起因を強く疑う → §2 へ |
| ジョブは正常に動いたが、エラー箇所が PR の触っていないファイル | 分岐元が古い（main で修正済み）→ §4 へ |

変更内容と無関係なジョブが落ちているかどうかは、`git diff --stat` で触ったファイルと
突き合わせて判断する。

### 2. ジョブが起動していない場合（ログが存在しない）

この状態では **`gh run view <ID> --log-failed` は `log not found: <job-id>` を返して
空振りする**。ログではなく **annotations** を読む:

```sh
# 失敗ジョブの ID を取得
gh run view <RUN_ID> --json jobs --jq '.jobs[] | select(.conclusion=="failure") | {name, databaseId}'

# ステップが1つも実行されていないことを確認（steps が空配列なら起動していない）
gh api repos/<OWNER>/<REPO>/actions/jobs/<JOB_ID> --jq '{name, conclusion, started_at, completed_at, steps: [.steps[] | {name, conclusion}]}'

# 原因はここに出る
gh api repos/<OWNER>/<REPO>/check-runs/<JOB_ID>/annotations
```

annotations に出る典型例:

- **課金・支出上限**: `The job was not started because recent account payments have failed
  or your spending limit needs to be increased. Please check the 'Billing & plans' section
  in your settings` → ユーザーに Settings → Billing & plans での対応を依頼する。
  コード側は無罪なので、**修正を試みない**。
- ワークフロー構文エラー / 権限不足 / ランナー枯渇も同様にここへ出る。

インフラ起因と判明したら:

1. ユーザーに原因と対応先を伝える（自分では解決できない旨も明示する）。
2. **コードが無罪であることの根拠を添える** — ローカルの品質チェックの結果、
   直前コミットで同一 CI 構成が通っていた事実など。
3. 解消後の再実行コマンドを案内する: `gh run rerun <RUN_ID>`（ワークフローが複数なら全部）。
   rerun は初回と同じコミットで走る。main 側の変更を取り込みたい場合は §4 のブランチ更新が必要。
4. **解消したかを勝手に決めつけない**。次のプッシュの CI 結果は必ず `gh pr checks` で
   実測してから語る（未解消のまま次コミットにも当てはめると、誤情報を PR に書くことになる）。

### 3. ジョブは動いたが失敗している場合

```sh
gh run view <RUN_ID> --log-failed | head -60
```

失敗ステップ名で切り分ける:

まず、エラーが出ているファイルが PR の差分（`gh pr view <N> --json files`）に含まれるかを見る。
含まれなければ §4（分岐元が古い）を先に疑う。

- **PHPCS / PHPStan / PHPUnit** → ローカルの品質チェックを実行し再現するか確認。
  再現すれば素直にコード修正。再現しなければ §5（環境差）へ。
- **Lint JS / Build** → ローカルの `npm run lint:js` / `npm run build`（スクリプト名は
  `package.json` に合わせる）。macOS では `unrs-resolver` のネイティブバインディング欠落で
  lint:js が**コード起因でなく**落ちることがあるため、判定は Docker で行う（§5）。
- **依存インストール（`npm ci` / `composer install`）** → §5 の環境差が濃厚。

### 4. PR が触っていないファイルで落ちている（分岐元が古い）

PR の変更と無関係な箇所でエラーが出ている場合、**PR が古い main から分岐していて、
その後 main で直ったエラーをまだ抱えているだけ**のことが多い。PR 自体は無罪なので、コードは直さない。

```sh
git fetch origin
git merge-base origin/<default> origin/<head-branch>         # 分岐元
git log --oneline <merge-base>..origin/<default>              # 分岐後に main へ入ったコミット（fix: を探す）
gh run list --branch <default> --limit 3 --workflow <CI 名>   # main の CI が通っているか
```

分岐後の main にそのファイルの修正が入っていて、main の CI がグリーンなら確定。

- **`gh run rerun` では直らない**。再実行は初回の run と同じマージコミット（`GITHUB_SHA`）で走るため、
  その後 main に入った修正は取り込まれない。`gh run view <RUN_ID> --json attempt` で attempt が
  2 以上なのに同じエラーなら、この状態。
- 対処は PR ブランチを最新の main に更新すること: `gh pr update-branch <N> --rebase`
  （マージコミットで更新するなら `--rebase` を付けない）。リモートブランチの書き換えになるので、
  **ユーザーの承認を取ってから**実行する。
- 更新前に `git merge-tree --write-tree origin/<default> origin/<head-branch>` でコンフリクトが
  無いことを確認しておく。PR の差分がドキュメントや設定だけなら、更新後のコードは main と同じになる。
  その main の CI が通っていることを根拠として添える。
- 更新直後は `gh pr view` が古い head SHA を返すことがある（`gh pr checks` も PR の head を基準に
  するので、古い結果を返しうる）。CI を待つ（§6）ときは、
  `git rev-parse origin/<head-branch>` で新しい SHA を取り、
  `gh api repos/<OWNER>/<REPO>/commits/<SHA>/check-runs` で SHA を指定して見る。

### 5. ローカルでは通るのに CI だけ落ちる（環境差）

よくある原因:

- **`npm ci` が Linux だけ失敗**: `fsevents`（macOS専用のオプション依存）の OS 別解決
  エントリが、ローカルの `npm install` のたびに `package-lock.json` から落ちる。
  再発しやすい既知の罠（リポジトリの CLAUDE.md に対処法の記載があれば参照）。
- **`npm run lint:js` が macOS だけ失敗**: `unrs-resolver` のネイティブバインディング欠落。
  環境問題でありコードは無罪。

いずれも **CI と同じ Linux / Node 版で実測して判定する**（Node 版はワークフローの
`node-version` または `.nvmrc` に合わせる）:

```sh
docker run --rm -v "$(pwd)":/work -w /work node:<CI と同じ版> bash -c "npm ci && npm run lint:js"
```

PHP 側は CI ワークフロー（`.github/workflows/*.yml`）の PHP / WordPress バージョンマトリクスと
ローカル wp-env の版がずれている可能性を疑う。特定バージョンでだけ落ちているなら、
そのバージョン固有の挙動（新しい PHP の deprecation 等）を確認する。

### 6. 修正後の確認

修正をプッシュしたら、CI の完走を **Monitor で待つ**（自分でポーリングしない）:

```
Monitor: 各チェックが pending でなくなったら結果を1行ずつ emit し、全部出たら exit
```

全チェックがグリーンになるまで「直った」と報告しない。

## 出力スタイル

- 最初に「コード起因 / インフラ起因 / 分岐元が古い」の判定を1行で述べる。ここが読み手の最大の関心。
- インフラ起因なら、ユーザーが取るべきアクション（課金設定の確認等）と再実行コマンドを示す。
- コード起因なら、失敗ログの要点を引用してから修正に入る。
- 推測で語らない。annotations やログの実際の出力を根拠として示す。
