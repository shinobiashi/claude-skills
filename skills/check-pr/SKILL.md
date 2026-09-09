---
name: check-pr
description: 指定した PR の head を scratchpad の worktree に取得し、PHPCS / PHPStan / PHPUnit の 3 点チェックを実行して結果を報告する。外部コントリビューターの PR など CI が走らない PR のレビュー時に使う。「PR #30 をチェックして」「/check-pr 30」等で使用する。
---

# PR ローカル検証スキル

外部コントリビューターの PR は CI が走らないため、マージ判断の前にローカルで
プロジェクト標準の 3 点チェック（PHPCS / PHPStan / PHPUnit）を実行する。
作業ツリーを汚さないよう、PR の head は scratchpad 配下の一時 worktree に取得する。

## 引数

- **PR 番号**（必須）— 省略された場合は `gh pr list --state open` で候補を提示して確認する。

## 前提

- ローカルブランチは切り替えない・汚さない（worktree 方式）。
- フォークからの PR でもブランチ名ではなく **`pull/<N>/head`** で取得できる。
- コミット・プッシュはしない（グローバル CLAUDE.md 規約）。チェック結果の報告まで。
- 実行するコマンドはリポジトリごとに異なるため、`composer.json` の `scripts` と `CLAUDE.md` から読む（手順 0）。

## 手順

### 0. チェックコマンドの確認

```bash
git rev-parse --show-toplevel          # メインリポジトリのパス（以下 <メインリポジトリ>）
jq .scripts composer.json
jq .scripts package.json 2>/dev/null
```

| チェック | 優先して使うもの（`CLAUDE.md` / `composer.json` の scripts） | 既定値（scripts に無い場合） |
|---|---|---|
| PHPCS | `composer lint` | `vendor/bin/phpcs`（`phpcs.xml(.dist)` は自動検出） |
| PHPStan | `composer analyze` | `vendor/bin/phpstan analyse --memory-limit=1G --no-progress` |
| PHPUnit | `composer test` | `vendor/bin/phpunit` |
| JS / CSS | `npm run lint:js` / `npm run lint:css` / `npm run build`（`package.json` にあるもの） | 無ければスキップ |

- `composer test` が wp-env 等のローカル環境を前提にしている場合（`CLAUDE.md` に記載）は、
  worktree からその環境で実行できるかを確認し、できなければ実行できなかった旨を報告に含める。

### 1. PR 情報の取得

```bash
gh pr view <N> --json title,author,state,headRefOid,files,baseRefName
```

- `state` が `MERGED` / `CLOSED` なら、その旨を報告して続行するか確認する。
- 変更ファイル一覧を控える（PHP 以外に composer.json / package.json / JS を触っているか確認）。

### 2. PR head を worktree に取得

```bash
git fetch origin pull/<N>/head
git worktree add <scratchpad>/pr<N> FETCH_HEAD
```

- `<scratchpad>` はセッションの scratchpad ディレクトリ（システムプロンプト参照）。
- 検証の再現性のため、`headRefOid` と `git rev-parse HEAD` が一致することを確認する。

### 3. vendor の用意

composer install は遅いので、メインリポジトリの vendor をコピーして使う:

```bash
cp -R <メインリポジトリ>/vendor <scratchpad>/pr<N>/
```

- **例外**: PR が `composer.json` / `composer.lock` を変更している場合はコピーせず、
  worktree 内で `composer install` を実行する。
- `node_modules` が必要な場合（JS / CSS チェック）も同様に、`package.json` / `package-lock.json` に
  変更が無ければコピー、あれば `npm ci` を実行する。

### 4. 3 点チェックの実行

worktree 内で順に実行する（`cd` はコマンドごとにリセットされる点に注意。
絶対パスか `cd <worktree> && ...` の複合コマンドで実行する）。以下は既定値の例で、
手順 0 で決めたコマンドに置き換える:

```bash
cd <scratchpad>/pr<N> && composer lint
cd <scratchpad>/pr<N> && composer analyze
cd <scratchpad>/pr<N> && composer test
```

- PR が JS / CSS を変更している場合は `npm run lint:js` / `npm run lint:css`（あれば）も追加する。
- PHPCS が落ちた場合、自動修正可能かは `phpcbf` の dry-run で判断できるが、
  **worktree 内のコードは修正しない**（修正は suggestion コメント等で PR 作者に返す）。

### 5. diff の目視レビュー

```bash
git diff <baseRefName>...FETCH_HEAD
```

`docs/review-checklist.md` / `docs/review-criteria.md` があればその項目、および `CLAUDE.md` の
絶対ルール（「絶対に守るルール」「設計上の不変条件」「やってはいけないこと」等の節）に照らして確認する。

### 6. 片付けと報告

```bash
git worktree remove --force <scratchpad>/pr<N>
```

報告に含めるもの:

- 3 点チェックの結果一覧（✅ / ❌ と件数）
- ❌ があれば該当ルール・ファイル・行と、修正方針の提案
- diff レビューで気づいた点（あれば）
- 検証した head の SHA（レビュー後に PR が更新されたら再実行が必要なため）

## 注意事項

- PR head が更新されたら（suggestion 適用等）、必ず再フェッチして再実行する。
  `gh pr view <N> --json headRefOid` で SHA の変化を確認できる。
- チェック結果を PR 本文のチェックリストやコメントに反映するのは、
  ユーザーに求められた場合のみ行う。
