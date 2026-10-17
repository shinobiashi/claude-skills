---
name: wporg-screenshots
description: wordpress.org の readme に載せるプラグインのスクリーンショット（`.wordpress-org/screenshot-N.png`）を、wp-env の tests サイトで Playwright（ヘッドレスの Chrome）を使って撮り直すスキル。readme の `== Screenshots ==` のキャプションと枚数を照合し、プロジェクトの `.claude/wporg-screenshots/shots.json` の順に管理画面を撮り、外部 API のモック・データの準備・片付けはプロジェクトのフック（`setup.php`・`teardown.php`・`mu-plugin.php`）に任せ、終わったら（失敗・中断でも）フックの teardown を走らせてからモックを外す。「スクリーンショットを撮り直して」「readme の画像を更新して」「wordpress.org の画像を直して」「管理画面の見た目が変わったのでスクショを撮り直して」「スクショの撮影をこのプラグインにも用意して」などで使う。モノレポ（`plugins/<slug>/`）にも対応。バナー・アイコンの作成と SVN への反映（`wp-org-release`）は扱わない。
argument-hint: "shoot [--out DIR] | status | cleanup | setup（プロジェクトに設定を作る）"
---

# /wporg-screenshots — wordpress.org 用スクリーンショットの撮影

wordpress.org のプラグインページは、readme の `== Screenshots ==` の N 番目のキャプションを `screenshot-N.(png|jpg)` に添えて見せる。
画面を変えるたびに手で撮り直すと、枚数とキャプションのずれ・古いビルドの画面・開発中のデータの写り込み・エラーの通知の写り込みが起きる。
このスキルは撮影を **wp-env の tests サイト** に限り、`shots.json` の順に毎回同じ条件（幅 1280・英語・フォーカスとホバー無し）で撮る。
描画は決定的で、画面が変わっていなければバイト単位で同じ画像になる。

Cart Bridge JP（PR #112）で作ったプロジェクトスキルから、どのプラグインでも同じ部分をここへ移した。プラグインごとに違う部分（撮る画面・
外部 API のモック・データの準備）は、各リポジトリの `.claude/wporg-screenshots/` に置く。

## 役割分担

| スキル | 担当 |
|---|---|
| **wporg-screenshots**（本スキル） | スクリーンショットの撮影と、撮影のための tests サイトの準備・片付け |
| `wp-org-release` | readme.txt の書式、SVN の `assets/`（バナー・アイコン・スクリーンショット）への反映、審査対応 |
| `release-bump` | 版数・changelog・タグ。スクリーンショットは版上げの PR とは別の PR で撮り直す |

## 前提

- wp-env が起動している（`npx wp-env start`）。tests サイトの URL は `.wp-env.json` の `testsPort`（無ければ wp-env の既定 8889）から作る。
  **dev サイトでは撮らない**（開発中のデータ・接続が写る）。
- Playwright がプロジェクトの `node_modules` にある（`@wordpress/scripts` が持ってくる。無ければ `npm install --save-dev playwright`）。
- Google Chrome がインストールされている。無ければ `npx playwright install chromium` で同梱の Chromium を入れ、`WPORG_SHOTS_CHANNEL=`（空）を付けて実行する。
- readme の `== Screenshots ==` のキャプションの数が `shots.json` の `shots` と同じ（違うと撮らずに止まる）。

## 使い方

`C=<Base directory for this skill>/scripts/capture.sh`（リポジトリのルートから実行する）。

1. **試し撮り**（リポジトリの画像はまだ変えない）: `$C shoot --out <スクラッチパッド>/shots`
2. **目視で確かめる**（Read で各画像を開く）: キャプションどおりの画面か／エラーの通知が無いか／英語の UI か／写っているのがテスト用の
   データだけか（実店舗・顧客の名前、本物のドメイン・キーが無い）／有料版・アドオンの画面が混ざっていないか（無料版の readme なら）。
   プロジェクトの `.claude/wporg-screenshots/README.md` に確かめる項目があればそれも
3. **本番**: `$C shoot`（`<plugin_dir>/.wordpress-org/` を上書きする）
4. `git diff --stat <plugin_dir>/.wordpress-org/` で変わった画像を見る。**変えていない画面に差分が出たら、管理バーの更新数や
   WooCommerce のメニューのバッジ（`Payments 1`・`Plugins 3` など）の揺れのことが多い**（WordPress・WooCommerce の状態で出たり消えたりする）。
   中身が同じなら `git checkout -- <その画像>` で戻し、意図した画面の差分だけをコミットする
5. readme とスクリーンショットの連番を照合するテストがあれば走らせる

`$C status` は、このスキルが tests サイトに置いたものが残っていないかを表示する。強制終了（SIGKILL）した後は `$C cleanup`
（フックの teardown を走らせてから、置いたものを消す）。

## 仕組み

```
capture.sh shoot
  1. shots.json を検証（config.cjs。知らないキーも誤り）→ キャプションの数を照合 → build → tests サイトの応答を確認
  2. tests サイトの mu-plugins/ に置く:
       wporg-screenshots-hooks/   フック（setup.php・teardown.php・mu-plugin.php の写し）+ .htaccess（HTTP は 403）+ 目印
       wporg-screenshots.php      目印つきの包み。hooks/mu-plugin.php を require する（mu-plugin.php があるときだけ）
  3. deactivate → activate → permalink → ユーザーの locale（既定 en_US）
  4. setup.php を `wp eval-file`（引数: tests サイトの URL、setup_args）。出力の KEY=value を {KEY} に使う
  5. ログイン Cookie（setup が COOKIES= を出さなければ capture.sh が作る。1 時間で切れる。一時ディレクトリだけに置く）
  6. shoot.cjs が一時ディレクトリに全部撮れてから出力先へ写す（失敗した回は何も写さない）
  7. 終わるとき（失敗・Ctrl-C も）: teardown.php →（成功したら）包みとフックを消す。teardown が失敗したら全部残して exit 1
```

- フックは tests サイトの中へ写して実行するので、wp-env がリポジトリのどこをマウントしているかに依存しない。
- **モック（mu-plugin）は teardown の後に外す**。setup が残したもの（キューのジョブ・偽のトークン）があるままモックを外すと、
  管理画面や WP-Cron から本物の API へ通信が出うる。teardown が失敗したら、モックもフックも残して止まる（原因を直して `cleanup`）。
- 目印の無い同名のファイル・ディレクトリは上書きも削除もしない。前回の残りがあれば `shoot` は何もせずに止まる（`cleanup` が先）。
- 撮影の前にエラーの通知（既定 `.notice-error, .components-notice.is-error`）が出ていたら、その画面は撮らずに失敗する。
- 余った番号の画像（枚数を減らした）と、形式の違う同じ番号の画像（png → jpg）は警告するだけで消さない。

## プロジェクトに設定を作る（`setup`）

`/wporg-screenshots setup` と頼まれたら（`capture.sh` のコマンドではない）、readme の `== Screenshots ==` のキャプションを読み、
管理画面のどのページか・描画し終わったと分かる英語の文言を確かめて、この節の形で書く。置き場所は `.claude/wporg-screenshots/`
（`--config DIR` で変えられる）。`.claude/` が配布 zip に入らないこと（`.distignore` など）も確かめる。最小は `shots.json` だけ:

```json
{
	"plugin_dir": ".",
	"activate": [ "woocommerce", "my-plugin" ],
	"shots": [
		{ "path": "/wp-admin/admin.php?page=my-plugin", "wait_for": "Save changes" },
		{ "path": "/wp-admin/admin.php?page=my-plugin&tab=logs", "wait_for": "Clear logs", "name": "logs" }
	]
}
```

| キー | 意味 | 既定 |
|---|---|---|
| `plugin_dir` | readme.txt と `.wordpress-org/` のあるディレクトリ（ルートからの相対。モノレポなら `plugins/<slug>`） | `.` |
| `build` | 撮る前に走らせるコマンド（argv の配列。シェルを通さない）。管理画面をビルドするプラグインは必ず指定する（古いビルドは変える前の画面を写す） | なし |
| `deactivate` / `activate` | tests サイトで無効・有効にするプラグインのスラッグ（無料版の画面にアドオンを写さないなど） | なし |
| `permalink` | `wp rewrite structure` に渡す値（REST の URL が `/wp-json/` になる） | 変えない |
| `user` / `locale` | 撮影するユーザーと、その管理画面の言語（`""` で変えない） | `1` / `en_US` |
| `setup_args` | setup.php に渡す引数（URL の後ろ） | なし |
| `local_storage` | ページを開く前に入れる localStorage（値の `{KEY}` は setup の出力） | なし |
| `format` | `png` か `jpg`（jpg は quality 90） | `png` |
| `viewport` | `{ "width", "height" }`（全体を撮るので高さはスクロールで伸びる） | 1280 × 900 |
| `error_selector` | 撮影を止めるエラーの通知の CSS セレクター | 上記 |
| `shots[]` | `path`（tests サイトからのパス。`{KEY}` 可）・`wait_for`（描画し終わったことを示す英語の文言）・任意の `uncheck`（チェックを外すチェックボックスのラベル）・任意の `name`（ログ用） | — |

`shots[i]` が `screenshot-(i+1)` になる。順番と数は readme の `== Screenshots ==` に合わせる（キャプションを先に直す）。
ハッシュだけが違う URL（`#/import` など）への移動は SPA を読み直さないので、各ショットは移動の後に読み込み直す。

### フック（任意）

| ファイル | いつ・どう動くか | 書くこと |
|---|---|---|
| `mu-plugin.php` | 撮影の間だけ、包みの mu-plugin から読み込まれる（tests サイトの全要求と WP-CLI） | 外部 API を `pre_http_request` でフィクスチャへ向ける、撮影向けの値の差し替え、邪魔な通知の抑止。**致命的エラーを出さない**（tests サイトの全要求が落ちる）。モックが読み込まれた印に定数を define し、setup で確かめる |
| `setup.php` | `wp eval-file <container>/setup.php <tests URL> <setup_args…>`。`$args[0]` が URL | 最初に `home_url() === $args[0]`（＝ tests サイト）とモックの定数を**肯定形で**確かめ、違えば何も変えずに `exit( 1 )`。サイト名など写る値、偽の接続、画面に出すデータを用意する。後で使う値は `KEY=value`（KEY は大文字）で出す。途中で止まるときは自分が始めたもの（ジョブなど）を止めてから終わる |
| `teardown.php` | 撮影の終わり（失敗・中断も）と `cleanup` で、**モックがまだある間に** `wp eval-file … <tests URL>` | setup が作った偽の接続・開いたジョブを片付ける。自分の作ったものだけ（他人のトークンは持ち主を確かめて触らない）。何も残っていなければ何もしない。片付けられなければ `exit( 1 )`（capture.sh はモックを残す） |

setup.php を置いたら teardown.php も置く（無いと警告する）。データを何も用意しない画面（設定画面だけなど）なら、フックは要らない。

## してはいけないこと

- dev サイトで撮らない。モックを外して撮らない（setup がモックの定数を確かめる）。
- 撮影中・`cleanup` 前に tests サイトで PHPUnit を走らせない（tests サイトの mu-plugin は PHPUnit にも読み込まれ、HTTP のモックを横取りする）。
- 包みの mu-plugin・フックのディレクトリを `rm` で手で消さない。`cleanup` を使う（teardown を先に走らせる）。
- ログイン Cookie をリポジトリに置かない（capture.sh は一時ディレクトリに書き、終了時に消す。setup の `COOKIES=` も画面に出さない）。
- 実店舗・顧客のデータを写さない。フィクスチャは匿名化したものだけを使う。

## うまくいかないとき

- `has N shots but … has M screenshot captions`: `shots.json` と readme のキャプションの数をそろえる。
- `unknown key "…"`: `shots.json` の綴り。知らないキーは黙って無視せず止める。
- `something of this skill is already installed`: 前回が強制終了した。`$C cleanup`。
- `the teardown hook failed; keeping …`: teardown の失敗の原因を直して `$C cleanup`（モックは残っているので本物の API へは出ない）。
- `waitFor` のタイムアウト: `wait_for` の文言が UI と違う、または画面が開けていない（Cookie が通らない・PHP のエラー）。tests サイトに管理者でログインして同じ画面を開いて確かめる。
- `… shows an error notice`: その画面の API 呼び出しが失敗している（モックにフィクスチャが無い API を呼んでいないか）。
- `uses {KEY}, but the setup hook did not print KEY=`: setup の出力と `shots.json` の `{KEY}` が合っていない。
- `Unsupported chromium channel` / Chrome が無い: `npx playwright install chromium` の後に `WPORG_SHOTS_CHANNEL= $C shoot`。

## 同梱ファイル

| ファイル | 役割 |
|---|---|
| `scripts/capture.sh` | 撮影の流れ・tests サイトへの設置と片付け（`shoot` / `status` / `cleanup`）。bash 3.2 で動く |
| `scripts/config.cjs` | `shots.json` の検証（シェルが読める `KEY=value` の行に直す）と、setup の出力の `KEY=value` を JSON にする |
| `scripts/shoot.cjs` | Playwright で撮る（Cookie でログイン → localStorage → 各ショット: 移動・再読み込み・`wait_for`・`uncheck`・エラーの通知の確認・全体の撮影） |
| `scripts/test-capture.sh` | シナリオテスト（偽の `npx`〔wp-env〕・`curl`・撮影で、順序・片付け・拒否を確かめる。wp-env もブラウザも要らない）。`bash scripts/test-capture.sh` |

使用例: Cart Bridge JP（`artisanworkshop/cart-bridge-jp` の `.claude/wporg-screenshots/`）。モノレポの無料版を、Pro を無効にし、
Color Me Shop API をフィクスチャへ向けるモック・偽のトークン・dry-run の結果を用意して 5 画面撮る。
