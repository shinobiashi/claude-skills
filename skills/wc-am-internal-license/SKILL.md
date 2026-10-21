---
name: wc-am-internal-license
description: WooCommerce API Manager のクライアント（wc-am-client.php 2.x）を同梱する自社の有料プラグインに、「社内ライセンス」の mu-plugin を生成するスキル。wp-config.php の定数に置いた社内用アカウントのユーザーライセンスキー（旧称 Master API Key）で販売サイトに自動で有効化するので、画面でライセンスキーを入れなくても、未有効化の通知や「Auto-updates unavailable.」が出ず、顧客と同じ経路で更新が届く。商品 ID・販売サイトの URL などはプラグインの `new WC_AM_Client_X_Y_Z(...)` から読み取り、wp-env での確認（販売サイトのモックで 11 の場面）までスクリプトで行う。wp-config.php を触れない・触りたくないサイト向けに、定数だけを定義する「キーのファイル」（別の mu-plugin）の雛形も出せる。「ライセンスキー無しで使えるように」「社内用ライセンスの mu-plugin」「自社・管理先のサイトでキーを入れずに更新したい」「ライセンスの警告を消したい」「wc-am-internal-license」などと言われたら使う。
---

# wc-am-internal-license — 社内ライセンスの mu-plugin を生成する

自社・管理先のサイトで自社の有料プラグインを使うとき、サイトごとにライセンスキーを入力・管理しなくても済むようにする。
生成する mu-plugin は 1 ファイルで、WC AM クライアントのコードは変えない。クライアントが読む option を差し替える。

```bash
S=~/.claude/skills/wc-am-internal-license/scripts
python3 -I "$S/generate.py" --plugin-dir . --product-id 188 --out tools/mu-plugins/jp4wc-pro-internal-license.php
python3 -I "$S/generate.py" --plugin-dir . --product-id 188 --out tools/mu-plugins/jp4wc-pro-internal-license.php --check   # テンプレートとの差
```

## なぜキーが要るのか（キー無しでは更新は取れない）

- 販売サイトの API Manager は、**有効化済みのキーと instance の組にだけ**、更新の `package`（ダウンロード URL）を返す。キーが無い・未有効化の
  instance・期限後は空文字になる（cart-bridge-jp で API Manager 3.6.0・3.8.1 を実測した。`~/Dev/cart-bridge-jp/docs/03-design-decisions.md` の R3-8c）。
  クライアント側の細工だけで「キー無しでダウンロード」はできない
- そこで、販売サイトに社内用の顧客アカウントを作って製品の 0 円の注文を入れ、そのアカウントの **ユーザーライセンスキー**を各サイトの
  `wp-config.php` の定数（またはキーのファイル）に置く。mu-plugin はそのキーでサイトを有効化し、キーを画面・DB に出さない
- ユーザーライセンスキーは、API Manager が顧客アカウントごとに 1 つ発行し、そのアカウントが購入したすべての製品の有効化に使えるキー。
  API Manager 3.8 で表示名が変わった（旧称 **Master API Key**。英語の画面では User license key、内部の名前は今も `master_api_key`）。
  注文ごとの「プロダクトライセンスキー」でもその製品には使えるが、同じ定数を販売サイトの他の製品と共有するならユーザーライセンスキーにする

## 使えるプラグインの条件

| 条件 | 外れたとき |
| --- | --- |
| WC AM クライアント 2.x（`WC_AM_Client_X_Y_Z`）を、プラグインとして（`'plugin'`）作っている | テーマは対象外。generate.py が止める |
| クライアントに渡す商品 ID が `null` か整数のリテラル | `null` なら `--product-id` が必須（顧客が設定画面で入れる値。API Manager の商品 ID） |
| 商品 ID が `null` のときは、メインファイルの中で `__FILE__` を渡してクライアントを作っている | 違えば generate.py が止める（クライアントは渡されたファイルのフォルダ名で option を作るので、下位のファイルからだと名前が変わる） |
| 販売サイトの URL が https の文字列リテラル | 定数などで渡しているなら `--api-url` |
| ソフトウェア名が英数字と ` ._()&+-` だけ | 違えば `--title` |
| `$custom_menu` を渡していない、または `menu_slug` を文字列で書いている | 読めなければ `--settings-page` にそのメニューのスラッグ |

generate.py は、メインのプラグインファイル（`Plugin Name:` のある最上位の PHP）を先に、無ければ他の PHP（`vendor/`・`tests/` などは除く）を探す。
プラグインのフォルダ名（サイトでのパス）は `--plugin-dir` のフォルダ名を使う。配布 zip のフォルダ名が違うなら `--slug`。

## 手順

### 1. 販売サイトで準備する（リポジトリの外。ユーザーが行う）

- 社内用の顧客アカウントを作り、対象の製品の 0 円の注文を作る
- その注文の有効化数と期限を、使うサイトの数と期間に足りるようにする（**サイトごとに有効化を 1 つ使う**）
- ユーザーライセンスキーを控える。キーはリポジトリ・チャット・issue に書かない。販売サイトで見られる場所（API Manager 3.8.1 のソースで確認）:

  | 場所 | 表示 |
  | --- | --- |
  | 管理画面のユーザー → 社内用アカウントを編集 | 「ライセンスキー」欄の「ユーザーライセンスキー：」。生成・置き換え・無効化もここ |
  | 管理画面の WooCommerce → 注文 → 社内用の 0 円の注文 | 「ライセンス管理」ボックスの上の「ユーザーライセンスキー：」 |
  | 社内用アカウントでログインしたマイアカウント（`/my-account/api-keys/`） | いちばん上の表 |

  「APIマネージャー → 構成 → ライセンスキー → 有効なタイプ」が「プロダクトライセンスキー」だけだと、注文画面とマイアカウントには出ない
  （既定は「ユーザライセンスキー」）。ソースではこの設定は表示の切り替えで、API の照合では読んでいないが、実測はしていない。
  3.8 より前の API Manager では表示名が「Master API Key」のことがある

### 2. 生成する

```bash
python3 -I "$S/generate.py" --plugin-dir . [--product-id N] --out tools/mu-plugins/<slug>-internal-license.php
```

出力の要約（client・plugin file・product ID・API URL・key constant・settings page）を見て、商品 ID と定数の名前をユーザーに確かめる。
定数の名前は既定で販売サイトのホストから作る（`wc4jp-pro.work` → `WC4JP_PRO_INTERNAL_API_KEY`。同じ販売サイトの製品は同じ定数を共有する）。
生成したファイルは `php -l` を通してから書く。

wp-config.php を編集しないサイトがあるなら、`--key-file FILE` でキーのファイルも出す（`--check` と一緒でもよい）。

```bash
python3 -I "$S/generate.py" --plugin-dir . [--product-id N] --out tools/mu-plugins/<slug>-internal-license.php --check --key-file <リポジトリの外>/<slug>-internal-license-key.php
```

- 中身は `if ( ! defined( '<定数>' ) ) { define( '<定数>', '' ); }` だけの mu-plugin。キーは空で出すので、ユーザーがエディタで貼る。
  スクリプトにもチャットにもキーを渡さない
- 書き先は**リポジトリの外の新しいファイル**だけ。`--plugin-dir` の中と、既にあるファイル（キーを貼った後かもしれない）は止める（exit 2）
- キーが空のままなら、本体の mu-plugin は定数が無いのと同じく何もしない。`wp-config.php` に定数があれば、そちらが勝つ

### 3. リポジトリに置く（コード扱い。ブランチと PR で）

- 置き場所は `tools/mu-plugins/`。`.distignore` に `/tools/` を足し、配布 zip に入れない
- `phpcs.xml` の `WordPress.Files.FileName.InvalidClassFileName` に `<exclude-pattern>tools/mu-plugins/</exclude-pattern>` を足す
  （ファイル名は製品名、クラス名はテンプレートの版なので一致しない）
- `composer phpcs`・`phpcbf` の対象と `phpstan.neon` の `paths` に `tools/` を足し、CI で崩れないようにする
- 生成したファイルは手で直さない。直すならテンプレート（下の「テンプレートを直すとき」）

### 4. wp-env で確かめる

```bash
M=$(mktemp -d)
python3 -I "$S/generate.py" --plugin-dir . [--product-id N] --out tools/mu-plugins/<slug>-internal-license.php --check --verify-mock "$M/0-mock.php" --key-file "$M/key.php"
bash "$S/verify-wp-env.sh" --mu-plugin tools/mu-plugins/<slug>-internal-license.php --mock "$M/0-mock.php" --key-file "$M/key.php"
```

- wp-env の development サイトが起動している必要がある（`npx wp-env start`）。管理者は既定で `admin` / `password`（`--user`・`--password`）
- モック（`--verify-mock`）は、ダミーのキーで定数を定義し、販売サイトへの要求をすべて `pre_http_request` で答える一時 mu-plugin。**本物の販売サイトへは出ない**
- 場面は S0（mu-plugin 無し）・S1（有効化が通る）・S2（「同じ instance で有効化済み」と断られ、状態確認で通す）・S3（キーが通らない）・
  S9（S3 の直後にキーを変える → 1 時間待たずに有効化する）・S10（有効化の要求がメッセージの無い `WP_Error` で失敗 → 成功と取り違えない）・
  S5（販売サイトが有効化を消して 1 日たった → 状態確認で気付いて有効化し直す）・S11（日次の状態確認が HTTP 503 → 有効化を残し、
  有効化し直さず、1 時間は聞き直さない）・S6（ログインしていない `admin-post.php` への要求では有効化しない）・
  S7（定数を後から読まれる mu-plugin で定義しても効く）・S4（定数が無い）。`--key-file` を渡すと、S7 はキーのファイルにダミーのキーを入れた写しで
  確かめ、S8（キーのファイルを空のまま置く → 何もしない）が増える。`--key-file` はキーが空のままのファイルだけを受け付ける
  （キーを貼ったファイルは exit 2。本物のキーを開発サイトへ写さない）。判定はサイトの言語に依らない印（設定画面へのリンク・自動更新の列・
  更新の行の `update-link`）と、このファイルの英語の文言で見る。mu-plugin 自身の要求は、キーが本文にあることでクライアントの要求と見分ける
- 終わると（失敗・中断も）写したファイルと触った option・transient を消し、クライアントの option が前と同じかを確かめる。失敗したときは取得した HTML を残してパスを出す
- 実際の zip のダウンロードと更新はしない（package の URL はモックの偽物）。本物の更新は、本番サイトに置いた後に次の版で確かめる

### 5. サイトに置く

- `wp-content/mu-plugins/` にファイルを写し、`wp-config.php` に `define( '<定数>', '<ユーザーライセンスキー>' );` を足す
  （`/* That's all, stop editing! */`〔日本語版は「編集が必要なのはここまでです」〕の行より上）
- `wp-config.php` を編集できない・したくないサイトでは、手順 2 の `--key-file` で出したキーのファイルに、エディタでキーを貼って
  `wp-content/mu-plugins/` に置く（`wp-config.php` は触らない）。定数は `muplugins_loaded` で読むので、ファイル名の順は問わない。
  キーを貼ったファイルは、リポジトリにも配布物にも入れない。`wp-content` を git やデプロイツールで管理しているサイトでは、その管理対象から外す
  （入れるとキーがリポジトリに残る。外さないとデプロイでファイルが消える）。止めるときはこのファイルを消す
- 管理者が管理画面を 1 回開くと有効化される。プラグイン一覧の行に「Licensed with the internal key (mu-plugin)」が出ればよい
  （失敗するとプラグイン一覧と更新の画面にだけ理由を出し、1 時間おきに再試行する。キーを直したなら待たずに試す）
- 定期購入の製品なら、キーが効くのは定期購入が「有効」か「キャンセル待ち」の間だけ。「保留」になると API Manager は有効化を消す
  （`wc-am-subscription.php`。期限切れや My Account からの削除も同じ）。mu-plugin は 1 日 1 回の状態確認で気付き、有効化し直す。
  定期購入が戻っていなければ失敗の理由がプラグイン一覧に出る

### 6. 外すとき

- ファイルを消すと、通常のライセンスの動作（未有効化の通知など）に戻る。キーは DB に無いので残らない
- **販売サイト側の有効化は残る**。My Account の API Keys からそのサイトの有効化を外す
- このファイルの記録（option `<data_key>_internal_license`）は残っても害は無い。消すなら `wp option delete`

## 生成されるファイルの動き

| 目的 | 仕組み |
| --- | --- |
| キーを渡す | `pre_option_<data_key>` で `<data_key>_api_key` を返す。`pre_update_option_` で DB に書かせない |
| 未有効化の通知を出さない | `pre_option_<data_key>_activated` を `Activated` にする |
| 商品 ID を渡す（クライアントが `null` のとき） | `pre_option_wc_am_product_id_<slug>` で返し、書かせない |
| 定数を読む時点 | `muplugins_loaded`（すべての mu-plugin の後、クライアントを作る `init` の前）。`wp-config.php` でも別の mu-plugin でも定義できる |
| 有効化 | 管理者（`manage_options`）の `admin_init`（優先度 20。クライアントが instance を作った後。ログインしていない `admin-post.php` でも `admin_init` は走るので権限で絞る）で、キー・商品 ID・instance・サイトのアドレスの HMAC が前回の成功と違えば、販売サイトに `activate` を POST の本文で送る（転送しない・15 秒）。断られたら `status` で有効か確かめる。成功したら `update_plugins` を捨てる |
| 有効化の確認 | 前回の成功と同じでも、1 日たったら `status` で確かめる。販売サイトが有効化を消していれば（期限・定期購入の保留・My Account からの削除）有効化し直す。`status` が取れない（通信の失敗・200 以外・JSON でない）ときは消えたと見なさず、有効化を残して 1 時間後に確かめ直す |
| 失敗 | 理由（タグを除き 300 字まで。空になったら「The request failed without a reason.」。空文字は成功の印なので使わない）を記録し、記録の「有効化済み」を消して、1 時間の transient で再試行を止める。transient は失敗した設定の HMAC を持つので、キー・商品 ID・instance・アドレスが変われば待たずに試す。プラグイン一覧と更新の画面にだけ出す（`manage_options`） |
| 設定画面を閉じる | メニューから外し、直接開いたらプラグイン一覧へ転送する（入力欄に差し替えたキーが出るため） |
| 置いてあると分かるように | プラグイン一覧の行に「Licensed with the internal key (mu-plugin)」 |
| 何もしない条件 | 定数が無い・形が違う（`[A-Za-z0-9_-]{1,190}`）・販売サイトが https でない・マルチサイト |

`<data_key>` は `wc_am_client_` ＋（クライアントに渡す商品 ID、`null` ならプラグインのフォルダ名）を、クライアントと同じく小文字にして ` _&?-` を `_` にしたもの。

## 限界・注意

- **クライアント自身の要求（`update`・`status`・`plugininformation`）はキーを URL のクエリ文字列で送る**（wc-am-client.php 2.12.2 の作り）。
  販売サイトのアクセスログにキーが残る。顧客のキーも同じ扱いで、mu-plugin では変えられない
- 有効化したサイトでは、プラグイン一覧の自動更新の列が「Auto-updates enabled」のラベルになる（クライアントの `auto_update_plugin` が true を返すため）。
  ただしクライアントはこのフィルターと更新の確認を `is_admin()` のときだけ登録し、バックグラウンドの自動更新は cron で動くので、
  実際に自動で更新される可能性は低い（コードを読んだ判断。実測していない）。キーを有効化した顧客のサイトと同じ
- `<data_key>_activated` には書き込みを止めていない（クライアントが `Deactivated` などを書く）。秘密の値ではなく、mu-plugin を外した後の本当の状態になる
- DB を複製したサイト（本番から作ったステージングなど）は instance が同じなので、同じ有効化を共有する（アドレスが違うので有効化を送り直すが、「有効化済み」→状態確認で通る）
- マルチサイトは対象外で、置いても何もしない（記録がサイトごとの option、更新の情報がネットワークで 1 つ。wp-env では確かめられないので、
  `is_multisite()` のガードは test-generate.sh が文字列で見るだけ）
- 通知と行の文言は翻訳しない（英語のまま）。社内用で配布物に入らず、テンプレートは製品をまたいで共通なので、製品の `.po` に入れると
  配布しないファイルの文字列を配ることになる。verify-wp-env.sh もこの英語の文言を判定に使う（jp4wc-pro PR #19 の Copilot 指摘で判断）
- 顧客のキーで有効化済みのサイトに置くと、こちらのキーが優先される。顧客の有効化は販売サイトに残るので、先に無効化してもらう
- クライアントの版を上げたら（`WC_AM_Client_2_12_2` → 次の版）、`--check` と wp-env の確認をやり直す。option の名前は 2.x で同じだが、作りが変わりうる

## テンプレートを直すとき

1. `templates/internal-license.php`（と、必要なら `templates/verify-mock.php`）を直し、`scripts/generate.py` の `TEMPLATE_VERSION` を上げる
   （クラス名 `AW_WC_AM_Internal_License_<版>` が変わり、版の違うファイルが同じサイトで並んでも衝突しない）。
   キーのファイル（`templates/internal-license-key.php`）はクラスを持たず、リポジトリにも置かないので、直しても版は上げなくてよい。
   ただし `define( '<定数>', '' );` の行の形は `verify-wp-env.sh` と `test-generate.sh` が探すので変えない
2. `bash scripts/test-generate.sh`（生成のシナリオテスト）
3. 使っているリポジトリで `generate.py ... --check` が差を出すので、生成し直して `verify-wp-env.sh` を流し、PR にする

## 使っているリポジトリ

| リポジトリ | ファイル | 商品 ID | 定数 |
| --- | --- | --- | --- |
| jp4wc-pro | `tools/mu-plugins/jp4wc-pro-internal-license.php` | 188（クライアントには `null`） | `WC4JP_PRO_INTERNAL_API_KEY` |
