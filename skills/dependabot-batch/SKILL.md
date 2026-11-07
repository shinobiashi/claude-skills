---
name: dependabot-batch
description: Dependabot の PR をまとめて捌くスキル。棚卸し → 不安定テストと実害の切り分け → CI で走らなかったステップのローカル実行 → 有効ルールの差分確認（ツールの major が緑のまま検出力を失っていないか）→ 修正・見送り → マージ順のシミュレーション → 全部入りの確認 → 報告、までを通す。「Dependabot の PR に対応して」「PR が 12 個立ち上がっている」「依存更新の PR を片付けて」「#56〜#60 に対応して」「bump の PR をまとめて」「マージする順番を教えて」「Dependabot の PR がコンフリクトした」「major の更新は CI が緑なら入れてよいか」などと言われたら、PR が 1 本でも複数でも必ず使う。CI の失敗が Dependabot と無関係な一般の調査は ci-triage、外部コントリビューターの PR の確認は check-pr を使う。
argument-hint: "[PR番号...]（省略すると open の Dependabot PR すべて）"
---

# Dependabot PR の一括対応

Dependabot の PR は、CI の色だけでは判断できない。

- **緑は「走ったステップが通った」としか言っていない。** ツールの major は、チェックを失ったまま緑になる（`wp-scripts` 37 は `.eslintrc.js` を読まなくなり、text domain の誤りが exit 0 で通った）。
- **赤は「更新が悪い」とは限らない。** 無関係なテストが不安定なだけのことがある（Workflow しか変えていない PR で Jest が落ちた）。
- **1 本目の失敗の先は見えていない。** ジョブは最初の失敗で止まる（Prettier で止まった PR の先で、Jest が起動しなくなっていた）。
- **本数が増えると順番が効く。** 人が手を入れた PR は Dependabot がリベースしなくなるので、後に回すと手作業が増える。

このスキルは次の 4 つの問いに答えてから、マージの順番を渡す。

1. この赤は更新のせいか、実害はあるか（§2）
2. CI が見ていない部分はどこか（§3）
3. 緑のまま検出力が落ちていないか（§4）
4. どの順でマージすれば手戻りが出ないか（§7）

例はすべて saai-inventory の PR #43〜#60 の実際の対応から取っている。

## 役割分担

| スキル | 担当 |
|---|---|
| **dependabot-batch**（本スキル） | Dependabot の PR の判定、マージ順、バッチ全体の確認 |
| `ci-triage` | ジョブが起動しない（課金・権限・ランナー）など、コード以外の CI 失敗 |
| `start-task` | 不安定テストの修正など、バッチの外に立てる PR |
| `review-loop` | Dependabot の PR に足した大きな修正のレビュー |
| `fix-copilot-review` | 修正した PR についた bot のレビューの処理 |
| `post-merge` | マージ後のブランチと worktree の片付け、学びの蒸留 |

リポジトリ固有の知識（除外の理由、ツールの注意点）はスキルに持たせない。そのリポジトリの `docs/`・`CLAUDE.md`・`.github/dependabot.yml` のコメントを読み、新しく分かったことはそこへ書く。

## 確認なしで進めること、止まること

scratchpad の worktree を作ること、依存の導入、ローカルでのチェックの実行は、確認なしで進めてよい。ユーザーのチェックアウトには触らない。

次は外から見える操作なので、ユーザーの指示があるまで実行しない。

- **commit・push**: 修正は worktree に残して報告し、「この修正を push してよいか」をまとめて 1 回確認する。指示を受けたら、同じバッチで説明済みの範囲は聞き直さない。
- **マージ**: ユーザーが行う。順番を渡して待つ。
- **PR へのコメント・クローズ**（`@dependabot rebase` を含む）: 影響を説明してから。
- **`@dependabot recreate`**: 人が足したコミットを消す。使わない。
- **force push**: しない。ブランチの更新は `git merge` で行う。

## 手順

`D=<Base directory for this skill>/scripts`、`S=<スクラッチパッド>/dependabot` とする。

### 1. 棚卸し

リポジトリのルートで実行する。

```bash
python3 "$D/inventory.py" [PR番号...]    # 省略すると open の Dependabot PR すべて
```

各 PR の更新内容と区分、CI の状態に加えて、`gh pr checks` に出ない情報を表示する: 再実行で緑になった PR、走らなかったステップ、PR で起動しないワークフロー、Dependabot がリベースしない PR、レビューの有無。

あわせてリポジトリの事情を、main の最新で読む（手元のチェックアウトは古いことがある）。

```bash
git fetch origin
git grep -n -i -E 'dependabot|flaky|不安定' origin/main -- CLAUDE.md 'docs/*.md'
git show origin/main:.github/dependabot.yml      # コメントに除外の理由がある
```

結果を見て、各 PR の確認の深さを決める。全部を同じ深さで見ない。

| 区分 | 確認すること |
|---|---|
| 赤、または `after a retry` | §2、続けて §3 |
| 「Not proved by CI」に PR 番号付きで出た更新 | §3 |
| `major (tool)` | §4。**CI が緑でも省かない** |
| `major (test env)` | §4 の「テスト環境の更新」 |
| 実行時の依存（`runtime`）の major | §5 |
| dev の patch / minor で緑 | 変更内容の確認だけ |

major は Breaking Changes を、今の版から新しい版まで**間の major も全部**読み、リポジトリの使い方に当たるかを確かめる。PR 本文の changelog は `(truncated)` で途中で切れる（#59 では 7.0 の API 削除が本文に無かった）。`@wordpress/*` の全文は次で読める。

```bash
gh api -H 'Accept: application/vnd.github.raw' 'repos/WordPress/gutenberg/contents/packages/<パッケージ名>/CHANGELOG.md'
```

### 2. 赤と「再実行で緑」を切り分ける

「原因は更新か」と「実害はあるか」は別の問いなので、分けて判定する。

| 判定 | 見分け方 | 実例 | 対応 |
|---|---|---|---|
| 不安定（更新と無関係） | 差分が失敗箇所に届かない。同じテストが無関係な PR でも落ちる | #44（Workflow だけの変更で Jest が落ちた）・#52 | 根本原因を別 PR で直す |
| 更新が原因、実害なし | 毎回落ちるが、型や整形だけで挙動は変わらない | #53（`sprintf` の型が厳密になった）・#54 の Prettier | 追加コミットで直す |
| 更新が原因、実害あり | 実行時の挙動が変わる、ツールが動かない、検出力が落ちる | #54（Jest が起動しない）・#57（Babel 8 でプリセットが読めない） | 移行するか見送る（§6） |
| 基盤 | ジョブが起動しない、secret が無い | — | `ci-triage` |

Dependabot の PR の CI では、`GITHUB_TOKEN` は読み取り専用で、Actions secrets も読めない（Dependabot secrets だけ）。secret 不足で落ちているなら更新の問題ではない。

Playwright の `retries` は Actions の再実行とは別なので、`inventory.py` の `after a retry` には出ない。E2E の不安定さは、ジョブのログの `flaky` の行で見る。

進め方:

1. **差分が届くかを見る**: `gh pr diff <N> --name-only`。Workflow しか変えていない PR で Jest が落ちたなら、更新のせいではない。
2. **同じ失敗を探す**: `inventory.py` の「The same failure on several PRs」を見る。main でも落ちているか（`gh run list --branch main --status failure`）、backlog に既知の項目がないかも確かめる。
3. **ローカルで比べる**: 再実行で緑になっただけでは無害の証拠にならない。main と PR の両方で繰り返して比べる（worktree の作り方は §3）。

   ```bash
   bash "$D/run-steps.sh" --dir "$S/base" --repeat 5 --load -- 'npm run test:unit'
   bash "$D/run-steps.sh" --dir "$S/pr52" --repeat 5 --load -- 'npm run test:unit'
   ```

   `FLAKY` が両方に出るなら更新は無関係、PR だけ毎回 `FAIL` なら更新が原因。
4. **不安定と判定したら、原因を決定的に再現する**: タイミングに頼らず必ず落ちる形を作る（#55 では effect の完了後に探すと毎回 2 要素見つかった）。直った証拠は「落ちる形が通るようになった」こと。再実行で緑になることは証拠にならない。

不安定テストの修正は、バッチの最初に入れる価値がある。Dependabot のリベースのたびに CI が走るので、12 本のうち 2 本が落ちる確率のままだと、マージのたびに再実行が要る。修正が大きいなら、backlog に記録して再実行で進めるかをユーザーに確認する。

### 3. CI で走らなかったステップをローカルで流す

走らなかったステップは 3 種類あり、対応が違う。

| 種類 | 実例 | 対応 |
|---|---|---|
| 失敗で止まって届かなかった | #54 は ESLint で止まり、Stylelint・TypeScript・Jest・Build に届かなかった | ローカルで全部流す |
| 条件で飛ばされた（`if: failure()` など） | #47 の `upload-artifact` は E2E が失敗したときしか動かない | リリースノートで、使っている入力への影響を確かめる |
| PR で起動しない（タグ・リリース・`paths` の絞り込み） | リリース用ワークフローの Action の更新 | 同上。次のリリースが初回の実行になることを報告する |

後の 2 つは緑の PR にも当てはまる。`inventory.py` の「Not proved by CI」に PR 番号付きで出たものが該当する。「for information」の行は、このバッチの更新に関係しないステップなので確認しなくてよい。

全ステップが緑の PR は、ここでは流し直さなくてよい。CI が同じことをもう確かめている。

worktree は §2・§4・§5 でも使うので、作り方はここにまとめる。1 本で 1GB を超えるので、作るのは main と実際に確認する PR だけにして、終わったら消す。

```bash
git fetch origin
git worktree add --detach "$S/base" origin/main
git fetch origin refs/pull/54/head && git worktree add --detach "$S/pr54" FETCH_HEAD
```

依存は CI の Install のステップと同じコマンドで入れる（多くは `npm ci`・`composer install`）。npm だけの更新なら Composer 側は要らない。

実行するコマンドは記憶で書かず、`.github/workflows/*.yml` の `run:` から写す。準備のステップ（Strauss など）も同じ順で流す。飛ばすと、後のステップが的外れな理由で落ちる。

```bash
bash "$D/run-steps.sh" --dir "$S/pr54" --log-dir "$S/logs/pr54" -- \
  'npm run lint:js' 'npm run lint:css' 'npm run check-types' 'npm run test:unit' 'npm run build'
```

失敗しても最後まで流れるので、CI を何周もせずに全部の問題が一度に見える（#54 では `lint:js` に加えて、CI が届かなかった `test:unit` の失敗も見えた）。

先頭に出る Node と PHP の版を CI と比べる。`.nvmrc` があれば nvm で切り替えるが、PHP は手元の版のままなので報告に書く。wp-env や E2E のようにローカルで流せなかったものは、「未実行」として報告する。

緑でも、CI のログに増えた非推奨の警告は見ておく。#58 の wp-env 12 は緑のまま警告を出していた。今は動くが次の major で壊れるものは、backlog に記録するよう提案する。

```bash
warnings() { gh run view "$1" --log | cut -f3- | cut -d' ' -f2- | grep -i deprecat | sort -u; }
diff <(warnings <main の run ID>) <(warnings <PR の run ID>)
```

run ID は `gh run list --branch <ブランチ> --limit 1 --json databaseId --jq '.[0].databaseId'` で取る。時刻を落としているので、増えた行だけが差分に出る。

### 4. ツールの major: 有効ルールの差分

lint・静的解析・テスト・ビルドのツールの major が対象。CI が緑でも省かない。比べる 2 つの worktree で、依存の導入と CI の準備ステップ（Strauss など）を済ませてから実行する。

```bash
# ツールは Node の版で挙動が変わるので、同じコマンドの中で CI の版に合わせる
source ~/.nvm/nvm.sh && nvm use "$(cat "$S/pr54/.nvmrc")" >/dev/null
python3 "$D/rules-diff.py" --base "$S/base" --head "$S/pr54" --only eslint,stylelint,tsc,jest,playwright
```

`--only` には更新した側のツールを渡す。npm の更新なら上のとおり、Composer の更新なら `phpcs,phpstan,phpunit`。関係のない側を入れると、依存の導入に時間を使うだけになる。

ESLint・Stylelint は実際に効いている設定、PHPCS は sniff の一覧、PHPStan はパラメータ、TypeScript は設定とファイル数、Jest はテストファイルの一覧、Playwright・PHPUnit はテストの一覧を比べる。

| 出力 | 意味 | 対応 |
|---|---|---|
| `CONFIG SOURCE` / `NOT READ` | プロジェクトの設定が読まれていない | **最優先で直す**。ルールの増減はこの後で見直す |
| `OPTIONS DROPPED` | プロジェクトが設定したオプションが消えた | 直す（text domain の指定はここに出る） |
| `LOST` | 効いていたルールが消えた | 上流の意図的な削除なら記録して通す。リリースノートや変更履歴で確かめる |
| `WEAKENED` | error が warn になった | CI は warn で落ちないので、意図した変更かを確かめる |
| `FAILED` | ツールが設定を出せない、または入っていない | **差分なしと読まない**。ツールが動かない場合と、準備のステップが足りない場合がある |
| `CHANGED` | オプションの変化やルールの追加だけ | 内容を見る。止める必要はない |
| `SAME` | 比べた範囲は同じ | 下の「`SAME` の読み方」を見る |
| `SKIPPED` | プロジェクトがそのツールを使っていない | 対応なし |

`LOST` が出ても、それだけで壊れているとは限らない。逆に `SAME` も実際に動く保証にはならない。**lint・解析ツール本体の major では、全部 `SAME` でも誤りを 1 つ入れて検出を確かめる**。`CONFIG SOURCE`・`OPTIONS DROPPED` が出たものは、直した後に必ず確かめる。手順は `references/detection-checks.md` を読む。

**`SAME` の読み方**: 比べたツールが、更新したパッケージを見ていないなら、`SAME` は何も言っていない。Jest の一覧はファイル単位なので、テストだけ減っても `SAME` になる。件数は CI のログの `Tests:` の行を main と比べる。

**テスト環境の更新**（`major (test env)`: `@wordpress/env`・`@wordpress/e2e-test-utils-playwright`・Playwright）: lint の比較は関係しない。代わりに次を確かめる。

- `rules-diff.py --only playwright` でテストの一覧が減っていないか
- CI の E2E の件数と `flaky` の行が main と同じか
- Breaking Changes で削除された API を使っていないか（`git grep`）
- E2E が型チェックの対象なら、`tests/e2e` に型の誤りを入れて検出されるか

### 5. 実行時の依存の major

ユーザーの手元に届くものが変わるかを確かめる。ビルドを両方の worktree で実行してから、まず出力を丸ごと比べる。

```bash
diff -rq "$S/base/assets/build" "$S/pr59/assets/build"    # ビルドの出力先はリポジトリに合わせる
```

**差が無ければ出荷物は変わらないので、下の 3 つは省いてよい**（#59 はバイト単位で同じだった）。差があれば次を見る。

- `rules-diff.py --only assets`: `*.asset.php` の依存が同じなら、WordPress に要求するスクリプトは変わっていない。
- `make-pot` の結果の件数（プロジェクトの手順で実行する。wp-env が要るなら「未実行」と報告する）。
- 新しい設定ファイルが増えたら、`.distignore` と `.gitattributes` に入っているか（配布 ZIP に混ざる）。

**テストが見ている版と、本番で動く版の違いに注意する。** `@wordpress/*` の多くは本番では WordPress 同梱の版が読み込まれるが、Jest は npm の版で動く。テストの緑はこの差を証明しない。Breaking Changes が React の版に触れているときは、`npm ls react@<新しい版>` で版のずれを確かめる（`npm ls react` は出力が長すぎて読めない）。バンドルが変わっていて影響も読めないなら、要判断として報告する。

### 6. 修正する、または見送る

**修正する**: worktree で直して確認し、push の指示を待つ。コミットを足した PR は Dependabot がリベースしなくなる。

**スタックする**: 2 本の PR が同じファイルに手を入れるなら、片方の上に積む（#54 は #53 と #55 の上に積んだ）。積んだ PR は merge commit でマージする。

**見送る**: 上流が追いつくまで入れられない更新は、次を提案する。

1. `.github/dependabot.yml` の `ignore` に、**理由をコメントで**足す（解除の条件も書く）。理由が残らないと、次の担当者がまた同じ調査をする。
2. PR を閉じるコメントに同じ理由を書く（#57）。`@dependabot ignore` のコメントだけで済ませると、理由がリポジトリに残らない。

**修正を別 PR にする**: 不安定テストの修正のように更新と関係しないものは、`start-task` で別の PR にする。

### 7. マージ順をシミュレートする

見送る PR を除いて、残りをすべて渡す。修正の push の後に実行する。

```bash
bash "$D/merge-sim.sh" --plan 43 44 45 46 47 48 49 50 51 52 53 54 55
```

ワーキングツリーも ref も変えずに、衝突する組、推奨順、番号順を表示する（推奨順と番号順が同じなら 1 つにまとめる）。

順番の考え方:

1. **Dependabot がリベースしない PR を先に入れる**（人がコミットを足した PR と、人が立てた PR）。後に回すと、main の取り込みとロックファイルの解決を手でやることになる。
2. スタックは下から順に入れる。
3. 残りの PR は、衝突しても Dependabot がリベースするので、その CI を待ってからマージする。

**番号順の結果も必ず報告する。** 実際の対応では推奨順を伝えたのに、番号順にマージされて #49・#53・#54 が衝突した。人は一覧の上から押す。推奨順を守らないと何が起きるかを書いておくと、守る理由が伝わる。

リポジトリが squash を使うなら `--method squash` でも試す。merge commit なら通るスタックが、squash だと衝突する（#53 と #54）。どちらを使うかは、`git log --oneline origin/main -30 | grep -c 'Merge pull request'` が 0 かどうかで分かる。

`merge-sim.sh` の前提:

- 衝突しなかった PR の組み合わせでも、ロックファイルの整合は保証されない。§8 で確かめる。
- リベースが止まるのは、人のコミットが入ったときと、作られてから 30 日経ったとき。`inventory.py` が後者も表示する。

ロックファイルの衝突を解くときは `references/lockfile-conflicts.md` を読む。

### 8. 全部入りを確かめる

各 PR の CI は単体の結果なので、組み合わせは誰も確かめていない。`merge-sim.sh` の**推奨順の** `tip` で実体を作って流す。

```bash
git worktree add --detach "$S/tip" <推奨順の tip>
```

衝突した PR は `tip` に入っていない。全部入りにする手順は `references/lockfile-conflicts.md` にある。

`npm ci` と `composer validate` が通ることを先に確かめ（ロックファイルの整合）、§3 と同じステップを `run-steps.sh` で流す。Composer の PR が複数あるときは PHPCS・PHPStan・PHPUnit も組み合わせで流す。

全部入りで流せなかったものは「全マージ後の main の CI が初回の実行」として報告する。

### 9. 報告する

push した PR があれば、その CI の完了を待ち、`inventory.py` をもう一度実行して、全部が緑で merge state が `CLEAN` であることを確かめてから報告する。bot のレビューがついていたら `fix-copilot-review` で処理する。

この形で報告し、マージを待つ。

```markdown
**N 本のうち M 本をマージできます。** （見送り・要判断があればここに一文）

## マージ順
1. **#55**
2. **#53**
3. **#54**: #53・#55 の上に積んであります
4. **#43・#44・#45・#47**: 順不同
5. **#46、#48、#49**: #48 の後に #49 が `composer.lock` で衝突します。Dependabot のリベースと CI を待ってください
（merge commit でマージしてください。理由: …）

番号順にマージすると、#53・#54 が衝突して手作業が要ります。

## 各 PR の対応
| PR | 内容 | 判定 | 対応 |
|---|---|---|---|

## 確認してほしい点
- 判断が要ること（見送り、上流の削除として通したルール、移行の方針）
- CI で実行されていないもの（条件付きのステップ、PR で起動しないワークフロー）
- 全部入りで未実行のもの、手元の環境が CI と違う点（Node・PHP の版）

## 確認済み
- 実際に確かめたことと、その結果
```

先頭の一文で結論を言う。緑にできなかったことを省かない。「未実行」と「確認済み」を混ぜない。

### 10. マージの後

ユーザーから「マージした」と聞いたら:

1. **main の最後の CI を確かめる**: 続けてマージすると `cancel-in-progress` で途中の実行は取り消されるので、`cancelled` が並ぶのは正常。**最後の実行が success であること**を確かめる。これが全部入りの初回の実行になる。
2. **次の PR を確かめる**: 同時に開ける本数に上限があるので、閉じると次の PR が開く（#50〜#54 の後に #56〜#60 が開いた）。`inventory.py` をもう一度実行する。
3. **片付ける**: `post-merge` に任せる。worktree は `git worktree remove` で消す（バッチが大きいと数 GB になる）。Dependabot のブランチが自動で消えるとは限らないので、残っていたら報告する。
4. **学びを残す**: リポジトリ固有のことは `docs/`、どのリポジトリにも効くことはこのスキルへ。

## 関連ファイル

- `references/detection-checks.md`: わざと誤りを入れて検出力を確かめる手順
- `references/lockfile-conflicts.md`: 人のコミットが入った PR の更新、ロックファイルの衝突の解き方、全部入りの作り方
- `scripts/test-*.sh`: 各スクリプトのシナリオテスト（ネットワーク不要）
