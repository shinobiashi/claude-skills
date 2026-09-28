---
name: review-loop
description: >
  重大度ベースの終了条件を持つ収束型コードレビューループを実行するスキル。
  「レビューして」「review-loop」「再レビュー」「レビューを回して」「マージ前チェック」
  など、コードレビュー・再レビュー・レビューの収束確認を求められたら必ずこのスキルを使う。
  指摘ゼロではなく「R1指摘(Critical/High/Medium)の全解消 かつ 新規Critical/Highゼロ」を
  APPROVE 条件とし、最大3ラウンドで必ず終了する。
  ラウンド管理・指摘ID採番・ベースライン除外・バックログ振り分けを自動で行う。
  リポジトリの CLAUDE.md にある「絶対に守るルール」をレビュー観点の第一級項目として扱う。
---

# review-loop — 収束型コードレビューループ

「指摘ゼロ」を目指さない。**R1 の Critical/High/Medium 指摘がすべて解消し、かつ新規の
Critical/High がゼロになったら APPROVE で終了**するレビューループを、最大3ラウンドで実行する
(R2/R3 の正確な条件は各章を参照)。

## プロジェクト設定の読み取り

起動時にリポジトリ直下の `CLAUDE.md` を読み、以下を決める。記載が無い項目は既定値を使う。

| 項目 | CLAUDE.md から読む内容 | 既定値 |
|---|---|---|
| 品質チェック | lint / 静的解析 / テスト / ビルドのコマンド一式 | `composer lint` → `composer analyze` → `composer test` → `npm run build`(`composer.json` / `package.json` の scripts に存在するものだけ) |
| 絶対ルール | 「絶対に守るルール」「設計上の不変条件」「やってはいけないこと」等の節 | CLAUDE.md の禁止事項全般 |
| レビュー基準 | `docs/review-criteria.md`(重大度定義・絶対ルール直行チェックリスト・指摘の記法) | 本スキルの「重大度定義」章 |
| 設計ドキュメント | `docs/ARCHITECTURE.md`、`docs/ADR/`、`docs/DESIGN.md` 等 | CLAUDE.md 本文 |
| ベースブランチ | PR のベースブランチ | `main` |

以下、「品質チェック」はこの表のコマンド一式を順に実行し、すべて成功することを指す。

## 前提: commit / push の扱い

グローバル CLAUDE.md の運用方針により、commit / push は**現在のセッションでユーザーが明示的に
指示した場合のみ**行う。review-loop の起動自体は commit/push の指示とはみなさない。

- **許可されている場合**(`dev-cycle` から起動されて commit が許可されている、またはユーザーが
  このセッションで「commit してよい」「push してよい」と明示した場合):
  - **各ラウンドの修正が完了し品質チェックが green になった時点で commit してよい**。
    コミットメッセージは Conventional Commits・英語、対応する指摘ID(R1-x等)を本文に含める
  - **push してよい**のは、許可の範囲内かつそのブランチの作業として妥当な範囲の場合のみ。ただし以下は
    **必ず作業前にユーザーに確認する**(判断に迷う=確認、が原則):
    - 現在のブランチが `main`(またはベースブランチ)である場合(review-loop の対象は常にコード差分
      なので、main 上では必ず確認する)
    - リモートに存在しないブランチを新規に push する(初回 push でリモートブランチを作る)場合
    - force push が必要になる状況(履歴の乖離・rebase 後など)
    - 1つの論理変更として commit すべきか、複数コミットに分割すべきか判断が割れる場合
    - 品質チェックが red のまま次のラウンドに進まざるを得ない、または
      どうしても green にできない場合(まず自力で解決を試み、それでも無理なら確認)
    - レビューで見つけた修正が絶対ルールに関わる、または main にマージ済みの DB スキーマ・
      マイグレーションの編集を含むなど、影響範囲が大きく後戻りしにくい場合
    - その他、コミット/プッシュしてよいか一般的に見て判断に迷うケース全般
  - 上記に該当しない通常の commit/push は都度確認を挟まず進めてよいが、各ラウンド完了時に
    「何を commit/push したか」を必ずユーザーに報告する
- **許可されていない場合**: 各ラウンドの修正は作業ツリーに残したまま、ラウンドの結果を報告して
  AskUserQuestion で「commit する / commit せずに次ラウンドへ / ここで中断」を確認する。
  commit せずに進む場合、次ラウンドの差分対象は `git diff <前ラウンドのレビュー対象HEAD>`
  (作業ツリー差分を含む)とし、R<n>.md の `修正後HEAD` には `<sha>(+ 未コミット差分)` と記す
- レビュー・説明は日本語、コード・コミットメッセージは英語
- 不要なファイル変更をしない(レビューで見つけた指摘の修正範囲を超えて触らない)

## 全体フロー

```
R1: フルレビュー → Critical/High/Medium を修正 → 品質チェック green → commit(許可時。必要なら push)
R2: R1修正差分のみ再レビュー(検証モード) → R1指摘の解消判定
    → 未解消のR1指摘・新規Critical/Highを修正(新規Mediumは可能なら修正) → commit(許可時。必要なら push)
R3: (R2でR1指摘が未解消 or 新規Critical/Highが残った場合のみ) 修正 → 最終判定 → commit(許可時。必要なら push)
その後: PR作成は start-task スキル(または dev-cycle)に委譲
       → Copilot / Codex を独立最終ゲートとして実行(本スキルの範囲外、fix-copilot-review スキル)
```

- Low・差分範囲外の指摘は**修正せず** `docs/review-backlog.md` へ追記する
- `docs/review-baseline.md` に記載済みの許容項目は**指摘しない**
- R3 終了時点で Critical/High が残る場合のみ、ユーザーに判断を委ねる(無限ループ禁止)

## ラウンドの自動判定

レビュー結果は `docs/reviews/<ブランチ名>/R<n>.md` に保存する。
スキル起動時に以下でラウンドを決定する:

1. `git branch --show-current` でブランチ名を取得(`main` 上で呼ばれた場合は
   対象ブランチをユーザーに確認する)
2. `docs/reviews/<ブランチ名>/` 内の既存 `R*.md` を確認
   - 無ければ **R1**
   - `R1.md` のみあれば **R2**
   - `R2.md` があれば、その**判定**を読んで分岐する:
     - 判定が **APPROVE** → ループは R2 で完了済み。R3 として再実行せず、ユーザーに
       「ループは完了しています(R2でAPPROVE済み)。新規ループを始めるなら reset を
       指示してください」と伝える
     - 判定が **CHANGES REQUESTED** → **R3**
   - `R3.md` まで存在する場合はループ完了済み。再実行せず、ユーザーに
     「ループは完了しています。新規ループを始めるなら reset を指示してください」と伝える
3. ユーザーが「reset」「最初から」と言った場合はディレクトリ内の `R*.md` を
   アーカイブ(`archive/` へ移動)して R1 から開始

各ラウンド開始時に `git rev-parse HEAD` を記録し、R<n>.md の冒頭にレビュー対象
コミット範囲を明記する。R2 以降の差分起点は**前ラウンドのレビュー対象HEAD**とする。

## 重大度定義(全ラウンド共通・全ツール共通)

`docs/review-criteria.md` がある場合は、重大度定義・絶対ルール直行チェックリスト・指摘の記法を
そこに一本化している(Claude Code / Codex / GitHub Copilot 共通)ので、**このスキルでレビューする
前に必ず読み、そちらを優先する**。無い場合は以下の定義を使う:

| 重大度 | 定義 |
|---|---|
| **Critical** | セキュリティ脆弱性(SQLi / XSS / CSRF / nonce欠落 / capability チェック漏れ / エスケープ漏れ)、データ破壊・損失、認証バイパス |
| **High** | 明確なバグ、仕様違反、CLAUDE.md の絶対ルール違反、WordPress/WooCommerce のフック契約違反、HPOS 非互換、後方互換の破壊、致命的な型エラー |
| **Medium** | パフォーマンス懸念(N+1、無限 autoload、キャッシュ欠落)、エラーハンドリング不足、テスト欠落 |
| **Low** | 命名、コメント、リファクタ提案、スタイル、WPCS の軽微な逸脱 |

判定に迷ったら低い方に倒す(重大度インフレを防ぐ)。

**絶対ルール直行チェックリスト**: CLAUDE.md の絶対ルール(「プロジェクト設定の読み取り」参照)を
レビュー観点の第一級項目として扱う。R1 の最初に、各ルールを差分に照らして1件ずつ確認する
(`docs/review-criteria.md` にチェックリストがあればそれを使う)。絶対ルールに反する差分は、
理由を問わず **High 以上**として扱う。

## R1: フルレビュー

対象: `git diff main...HEAD`(ベースブランチが異なる場合はユーザーに確認)。

手順:
1. `docs/review-baseline.md` を読む(無ければ後述のテンプレートで作成)
2. 絶対ルール直行チェックリストを差分に照らして確認する
3. 差分をレビューし、以下のフォーマットで `docs/reviews/<ブランチ>/R1.md` に出力する
   - **独立サブエージェントを併用する**: 自分（実装者）のレビューは自分の設計判断の盲点を再現しやすい。
     `git diff <base>...HEAD` をファイルに書き出し、フレッシュコンテキストのサブエージェント
     (`general-purpose`。可能なら上位モデル)に CLAUDE.md・baseline・backlog を読ませたうえで
     敵対的レビューをさせ、その結果を自分の指摘とマージしてから R1.md に書く(実績: 自己レビューが
     High 2 件のところ、サブエージェントが別の High 2 件・Medium 2 件を検出)。サブエージェントの
     重大度も鵜呑みにせず、実ソースや実測で裏取りしてから採用する
4. 差分範囲**外**の既存コードへの指摘は「対象外指摘」セクションに分離する
5. Critical/High が1件も無ければ冒頭に **APPROVE** と明記する

出力フォーマット:

```markdown
# R1 レビュー結果
- 対象: <base>...<HEAD sha>
- 判定: APPROVE / CHANGES REQUESTED

## 指摘
### [R1-1][Critical][src/Services/Example.php:42]
内容の説明(1〜3行)
**修正方針:** 1行で

### [R1-2][High][src/js/Example.tsx:118]
...

## 対象外指摘(差分範囲外)
- [R1-X1][Medium][...] ...

## Low(backlogへ)
- [R1-L1][Low][...] ...
```

6. レビュー後、**Critical/High/Medium をすべて修正**する
7. Low と対象外指摘は `docs/review-backlog.md` に追記する(修正しない)
8. 修正完了後、品質チェックを実行する(green にならない場合は
   Critical/High 相当として扱い追加修正し、それでも green にできなければユーザーに確認する)
9. green になったら「前提」章に従って commit する(対応した指摘ID R1-x をメッセージ本文に含める、
   Conventional Commits・英語)。push するかどうかも「前提」章の確認基準に従う
10. R1.md 末尾に `修正後HEAD: <sha>` として追記する

## R2: 検証再レビュー

対象: `git diff <R1のレビュー対象HEAD>...HEAD`(= R1 の修正で変更された差分のみ)。

これは**自由探索ではなく検証タスク**である:

1. R1.md を読み、Critical/High/Medium の各指摘IDについて
   **解消 / 未解消** を1件ずつ判定する(R1 と同様に独立サブエージェントへ「R1.md + 修正差分」を渡して
   検証させ、自分の判定と突き合わせる)
   - **解消がテストの追加・書き換えに依存する指摘**(「テストが無い」「テストがトートロジー」等)は、コードを
     読むだけで「解消」と判定しない。**対象の分岐・ガードを一時的に壊し、そのテストが落ちること**(ミューテーション)を
     実測する。確認後は必ず元に戻し、`git diff --stat` が空(または実測前と一致)であることを確認する
     (`git stash`/`checkout` で戻さない。未コミット差分を巻き込むため)。テストコマンドは CLAUDE.md の品質チェックに従う
     (実績: PR #61 で R1-1「トートロジーのテスト」の解消を、分岐に 1 行足して当該テストが失敗することで確認できた)。
     独立サブエージェントに検証を渡す場合は、この手順と「実測後に元へ戻す」ことをプロンプトで明示する
   - **この手順は手書きせず、同梱の `scripts/mutate-check.sh` を使う**(次節)
2. R1 の修正によって**新たに混入した**問題のみ、新規指摘として [R2-連番] で報告する
   (新規 Medium が見つかった場合、その場で簡単に直せるなら修正してよい。無理に修正せず
   backlog へ送ってもよい。いずれも収束判定には影響しない — 影響するのは新規 Critical/High のみ)
3. 禁止事項:
   - R1 で指摘済み・許容済み・backlog 送りにした項目を別の表現で再指摘しない
   - 差分起点より前から存在するコードへの新規指摘をしない(見つけたら backlog へ)
4. **APPROVE 条件(両方を満たす場合のみ)**:
   a. R1 の Critical/High/Medium が**すべて解消**している(1件でも未解消なら
      APPROVE 不可。未解消のものは新しい ID を振らず、元の R1-x のまま修正する
      — 「新規指摘ではないので新規Critical/Highのみ修正」というR2の制約の対象外)
   b. 新規に混入した Critical/High が**ゼロ**である
   両方満たせば冒頭に **APPROVE** → **ループ終了**(この回に修正があれば「前提」章に従って commit する)
5. a・bのいずれかが未達なら、未解消のR1指摘の修正 および/または 新規 Critical/High の
   修正を行い、品質チェックを再実行、green なら「前提」章に従って commit して
   (push は確認基準に従う)R3 へ

出力は R1 と同フォーマットで `R2.md` に保存。冒頭に R1 指摘の解消判定表を付ける:

```markdown
## R1 指摘の解消判定
| ID | 重大度 | 判定 |
|---|---|---|
| R1-1 | Critical | 解消 |
| R1-2 | High | 未解消 → 下記 R2-1 参照 |
```

## ミューテーション検証（`scripts/mutate-check.sh`）

ガードを1つ壊し、それを固定しているはずのテストを走らせ、**どう終わってもファイルを元に戻す**。
答えるのは「テストは気づいたか」の一点だけ。

```bash
M=<Base directory for this skill>/scripts/mutate-check.sh

# 行を消す（最頻出）
"$M" --file includes/class-foo.php \
     --delete-matching "search_columns.*post_title" \
     --expect 'test_search_matches_titles_only' \
     --test-cmd 'composer test -- --filter Test_Foo'

# 文字列を差し替える / 複数行のブロックを差し替える
"$M" --file includes/class-foo.php --replace "'read_post'" "'exist'" ...
"$M" --file includes/class-foo.php --replace-file old.txt new.txt ...

# JS（Vitest / Jest）: --expect はテスト名（describe を除いた it の文言）の一部でよい
"$M" --file assets/src/Foo.tsx --replace "keyCode !== 229" "true" \
     --expect 'IME conversion' \
     --test-cmd 'npx vitest run assets/src/Foo.test.tsx'

# 変異の内容だけ確認して戻す（テストは走らせない）
"$M" --file includes/class-foo.php --delete-matching '...' --dry-run

# 厳密モード: 落ちたテストがすべて --expect に一致した時だけ CAUGHT
"$M" --file includes/class-foo.php --delete-matching '...' --only \
     --expect 'test_a|test_b' --test-cmd '...'

# まだコミットしていない修正を試す（「前提」章で commit が許可されていない R2、dev-cycle の確認ゲート前）
"$M" --file includes/class-foo.php --allow-dirty --delete-matching '...' --expect '...' --test-cmd '...'
```

`--expect` が照合する「失敗の見出し」は、既定で PHPUnit（`1) Class::test`）・Vitest（`× name` /
`FAIL  file > suite > name`）・Jest（`✕ name` / `● Suite › name`）。それ以外のランナーは `--failure-line <ERE>` で渡す。

終了コード: `0` 捕捉できた（ガードは本当にテストされている） / `1` 捕捉できなかった
（テストが通ってしまった、`--expect` と違うテストが落ちた、変異がコードを壊した〔BROKEN〕、
`--only` で他のテストも落ちた） / `2` セットアップ失敗（何も判定していない）。

**変異がガードではなくコードを壊した時は BROKEN（exit 1）**: 出力に読み込みレベルの破損
（PHP の Parse error・`Class "…" not found`・`Call to undefined function`、JS の SyntaxError・ReferenceError）が
あれば、`--expect` のテストが落ちていても捕捉とは数えない。全テストが同じ理由で落ちるので何も証明しないため
（実績: jp4wc-rakusync P1-S12 で、`use` の無いクラス名に差し替えた変異が 4 件すべてを落とし、CAUGHT と読んだ）。
null の参照や型エラーは、ガードを外して正当に起きるので対象にしない。意図した時だけ `--allow-errors`。
`--expect` 以外のテストも落ちた時は、判定は変えずに WARNING と件数を出す。関連テストが一緒に落ちるのは
普通なので既定では失敗にしないが、`--only` を付けると失敗（NOT CAUGHT CLEANLY）にする。

手書きのループに戻さない理由 — スクリプトが面倒を見る4点:

- **必ず復元する**（`trap` で EXIT/INT/TERM を捕捉）。共有ワーキングツリーに変異を残す事故を防ぐ
- **復元を検証する**（実行前に取った控えと 1 バイトも違わないこと、既定ではさらに `git diff` が空であることを確認し、
  違えば exit 2 で大きく報告）。そのため既定では開始時にそのファイルが clean であることも要求する。
  未コミットの修正を試す時は `--allow-dirty` を付ける: 検証は控えとの比較だけになり、未コミットの変更はそのまま残る。
  強制終了（SIGKILL）されると `git checkout` では戻せないので、控えの場所を最初に stderr へ出す
  （実績: omotegae-project PR #81 の確認ゲート前に、この手順を手書きして控えの置き場所を取り違え、復元に一度失敗した）
- **no-op の変異を拒否する**。マッチしなかった変異はファイルを変えないままテストを通し、
  「ガードは覆われている」と誤読させる。実績: `perm => 'editable'` を足しただけの修正が
  `post_status => 'any'` のせいで実際には無効だった件は、この種の取り違えと紙一重だった
- **判定を言語化する**（CAUGHT / NOT CAUGHT / NOT CAUGHT BY THE NAMED TEST / BROKEN / NOT CAUGHT CLEANLY）。
  `--test-cmd` は対象テストに絞って渡す（判定は終了ステータスを見る）

`bash scripts/test-mutate-check.sh "$PWD/scripts/mutate-check.sh"` で本体のシナリオテスト（55件）が走る
（引数は絶対パス。テストは作業用リポジトリへ `cd` するので、相対パスだと全件が落ちる）。

## R3: 最終ラウンド(R2 で APPROVE 条件[R1指摘の全解消 かつ 新規Critical/Highゼロ]を満たせなかった場合のみ)

R2 と同じ検証モードで実行し、対象は R2 修正差分のみ。R2 と同じ2条件(R1指摘の全解消・
新規Critical/Highゼロ)で判定する。

- 両条件を満たす → **APPROVE、ループ終了**
- 満たさない場合 → **修正せずに停止**し、ユーザーに報告:
  「3ラウンドで収束しませんでした。設計レベルの問題の可能性があります。
  該当指摘: [一覧]。設計ドキュメントとの整合を含め個別に相談してください」

R3 を超えてループを続けてはならない。

## ループ終了後

APPROVE が出たら以下をユーザーに提示する:

1. 全ラウンドのサマリ(指摘数・修正数・backlog送り数)
2. 品質チェックの最終結果
3. 各ラウンドで実際に行った commit の一覧(sha・メッセージ)と、push 済みかどうか。
   commit が許可されていなかった場合は、作業ツリーに残っている修正の一覧(`git diff --stat`)
4. まだ commit / push していない変更がある場合は、ここで commit / push してよいか確認する
   (「前提」章の確認基準に該当しない限り、確認した上でそのまま進めてよい)
5. 次のステップの提案: PR作成は `start-task` スキル(または `dev-cycle`)に委譲できる旨、
   PR作成後は `fix-copilot-review` スキルで Copilot/Codex の指摘に対応する旨。
   その際「最終ゲートで出た指摘は Critical/High のみ修正、他は backlog」
   というルールを添える

## docs/review-baseline.md / docs/review-backlog.md(無ければ初回に作成)

`docs/review-criteria.md` にテンプレートがある場合はそれを使う(Codex/Copilot も同じテンプレートを
参照するため、独自フォーマットを作らない)。無い場合は以下のテンプレートで作成する。

`docs/review-baseline.md`:

```markdown
# レビューベースライン(許容済み指摘リスト)
レビュー時、ここに記載された項目は指摘しないこと。

## 形式
- [カテゴリ] 対象範囲 — 許容理由

## 許容項目
- [WPCS] (例)Yoda condition 非適用 — チーム規約で不採用
- [DB] (例)$wpdb 直接クエリは Repository クラス内に限り許容 — 抽象化済みのため
```

`docs/review-backlog.md`:

```markdown
# レビューバックログ(今回対応しない指摘)
| 追記日 | ID | 重大度 | 場所 | 内容 | 起票状況 |
|---|---|---|---|---|---|
```

初回作成時は例をコメントとして残し、実プロジェクトの許容項目はユーザーに確認して追記する。
backlog はラウンドごとに追記し、GitHub Issue 化するかはユーザーに確認する。

## Codex / Copilot との役割分担

- 本スキル(review-loop)が実装直後・PR作成前のフルレビューを担当し、
  Critical/High/Medium を収束させてから PR を作る
- PR作成後の Codex / Copilot によるレビューは**独立した最終ゲート**であり、本スキルの
  範囲外。`docs/review-criteria.md` を共通基準として使うリポジトリでは、それらのレビューも
  `docs/review-criteria.md`・`docs/review-baseline.md`・`docs/reviews/<branch>/R*.md` を踏まえて
  行われる前提のため、本スキルの各ラウンドでそれらのファイルを最新に保つこと(特に R1.md〜R3.md は
  Codex/Copilot が重複指摘を避けるために読む)
- 最終ゲートで出たコメントへの対応は `fix-copilot-review` スキル(または `dev-cycle` のゲート
  ラウンド)に委譲する

## 注意事項

- レビューと修正は同一セッションで行う(コンテキスト維持が収束の前提)。
  セッションを跨ぐ場合は `--resume` で再開してからこのスキルを使う
- レビューは PHPCS / PHPStan / PHPUnit / ESLint 等の機械的な指摘をなぞるのではなく、
  品質チェックの結果を土台にしつつ、CLAUDE.md およびレビュー基準に照らして判断する
- 対象プロジェクトが WordPress プラグインの場合、`wporg-plugin-check` や
  `wc-*` 系スキルが利用可能ならレビュー観点の参照として併用してよい。
  ただし指摘の重大度判定は本スキル(または `docs/review-criteria.md`)の定義を優先する
- レビュー範囲の拡大(「ついでに全体も見て」等)を求められた場合は、
  本ループとは別タスクとして扱い、ループの差分スコープを崩さない
- main にマージ済みの DB スキーマ・マイグレーションの編集を差分が含む場合、および CLAUDE.md の
  絶対ルールに反する差分は、理由を問わず High 以上として扱う
