# ロックファイルの衝突と全部入りの作り方

## まず誰が解くかを決める

| PR | 解く人 |
|---|---|
| Dependabot のコミットだけ | **Dependabot**。衝突すると自動でリベースする。CI の完了を待ってマージする |
| Dependabot のコミットだけで、作られてから 30 日超 | `@dependabot rebase` のコメントで頼む（コメントなので確認してから） |
| 人のコミットが入っている | **手で解く**。下の手順 |

`@dependabot recreate` は人のコミットを上書きするので使わない。人のコミットが入った PR で手が要るのは、Dependabot がその PR をリベースしなくなっているからだ（コミットメッセージに `[dependabot skip]` を入れた場合を除く）。

## 人のコミットが入った PR に main を取り込む

force push を避けるため、`git merge` で取り込む。ロックファイルは手で直さず、片方を土台にして作り直す。

```bash
cd "$S/pr53"
git fetch origin
git merge --no-commit origin/main

git diff --name-only --diff-filter=U    # 衝突したファイル
```

`package.json` は隣接行が衝突しているだけのことが多い（#53 の `@wordpress/i18n` と #52 の `@wordpress/url`）。両方の更新を残して解く。

### npm

`package-lock.json` は変更が大きい側を土台にして、解決した `package.json` に合わせて作り直す。

```bash
git checkout --theirs -- package-lock.json    # main を土台にする場合
npm install --package-lock-only --no-audit --no-fund
npm ci --no-audit --no-fund                   # 作り直した結果が本当に入るか
```

`--theirs` は merge の相手側（ここでは main）を指す。#53 に main を取り込むときは main が土台（`--theirs`）だった。#53 を #54 に取り込むときは、ロックの変更が大きい #54 が土台（`--ours`）だった。

### Composer

`composer.json` を触る PR 同士は、`composer.lock` の `content-hash` が必ず衝突する。

```bash
git checkout --ours -- composer.lock
composer update <変えたパッケージ> --no-install --no-interaction --no-scripts
composer validate --no-check-publish          # lock が composer.json と合っているか
```

### 解いた後

`run-steps.sh` で CI と同じステップを流してから、コミットして push の指示を待つ。マージコミットの本文には、どちらを土台にしたかを書く。

## 全部入りを作る

`merge-sim.sh` の `tip` には、衝突した PR が入っていない。残りを足して全部入りにする。

1. `git worktree add --detach "$S/tip" <tip>`
2. 衝突した PR の `package.json`・`composer.json` の版の変更を反映する（§7 で表示された PR の分だけ）
3. ロックファイルを作り直す

   ```bash
   npm install --package-lock-only --no-audit --no-fund
   composer update --lock --no-install --no-interaction --no-scripts
   ```

4. `npm ci`・`composer install` が通ることを確かめ、CI と同じステップを流す

この worktree は確認用で、push しない。手順 2 の結果は Dependabot のリベースの結果とは少し違うことがある（解決の順番が違う）ので、最終の確認は全マージ後の main の CI になる。報告にはそう書く。
