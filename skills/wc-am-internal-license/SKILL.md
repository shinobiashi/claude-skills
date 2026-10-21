---
name: wc-am-internal-license
description: WooCommerce API Manager のクライアント（wc-am-client.php 2.x）を同梱する自社の有料プラグインに、「社内ライセンス」の mu-plugin を生成するスキル。wp-config.php の定数に置いた社内用アカウントのユーザーライセンスキー（旧称 Master API Key）で販売サイトに自動で有効化するので、画面でライセンスキーを入れなくても、未有効化の通知や「Auto-updates unavailable.」が出ず、顧客と同じ経路で更新が届く。商品 ID・販売サイトの URL などはプラグインの `new WC_AM_Client_X_Y_Z(...)` から読み取り、wp-env での確認（販売サイトのモックで 5 つの場面）までスクリプトで行う。「ライセンスキー無しで使えるように」「社内用ライセンスの mu-plugin」「自社・管理先のサイトでキーを入れずに更新したい」「ライセンスの警告を消したい」「wc-am-internal-license」などと言われたら使う。
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
  `wp-config.php` の定数に置く。mu-plugin はそのキーでサイトを有効化し、キーを画面・DB に出さない
- ユーザーライセンスキーは、API Manager が顧客アカウントごとに 1 つ発行し、そのアカウントが購入したすべての製品の有効化に使えるキー。
  API Manager 3.8 で表示名が変わった（旧称 **Master API Key**。英語の画面では User license key、内部の名前は今も `master_api_key`）。
  注文ごとの「プロダクトライセンスキー」でもその製品には使えるが、同じ定数を販売サイトの他の製品と共有するならユーザーライセンスキーにする

## 使えるプラグインの条件

| 条件 | 外れたとき |
| --- | --- |
| WC AM クライアント 2.x（`WC_AM_Client_X_Y_Z`）を、プラグインとして（`'plugin'`）作っている | テーマは対象外。generate.py が止める |
| クライアントに渡す商品 ID が `null` か整数のリテラル | `null` なら `--product-id` が必須（顧客が設定画面で入れる値。API Manager の商品 ID） |
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

### 3. リポジトリに置く（コード扱い。ブランチと PR で）

- 置き場所は `tools/mu-plugins/`。`.distignore` に `/tools/` を足し、配布 zip に入れない
- `phpcs.xml` の `WordPress.Files.FileName.InvalidClassFileName` に `<exclude-pattern>tools/mu-plugins/</exclude-pattern>` を足す
  （ファイル名は製品名、クラス名はテンプレートの版なので一致しない）
- `composer phpcs`・`phpcbf` の対象と `phpstan.neon` の `paths` に `tools/` を足し、CI で崩れないようにする
- 生成したファイルは手で直さない。直すならテンプレート（下の「テンプレートを直すとき」）

### 4. wp-env で確かめる

```bash
M=$(mktemp -d)
python3 -I "$S/generate.py" --plugin-dir . [--product-id N] --out tools/mu-plugins/<slug>-internal-license.php --check --verify-mock "$M/0-mock.php"
bash "$S/verify-wp-env.sh" --mu-plugin tools/mu-plugins/<slug>-internal-license.php --mock "$M/0-mock.php"
```

- wp-env の development サイトが起動している必要がある（`npx wp-env start`）。管理者は既定で `admin` / `password`（`--user`・`--password`）
- モック（`--verify-mock`）は、ダミーのキーで定数を定義し、販売サイトへの要求をすべて `pre_http_request` で答える一時 mu-plugin。**本物の販売サイトへは出ない**
- 場面は S0（mu-plugin 無し）・S1（有効化が通る）・S2（「同じ instance で有効化済み」と断られ、状態確認で通す）・S3（キーが通らない）・
  S4（定数が無い）。判定はサイトの言語に依らない印（設定画面へのリンク・自動更新の列・更新の行の `update-link`）と、このファイルの英語の文言で見る
- 終わると（失敗・中断も）2 つのファイルと触った option・transient を消し、クライアントの option が前と同じかを確かめる。失敗したときは取得した HTML を残してパスを出す
- 実際の zip のダウンロードと更新はしない（package の URL はモックの偽物）。本物の更新は、本番サイトに置いた後に次の版で確かめる

### 5. サイトに置く

- `wp-content/mu-plugins/` にファイルを写し、`wp-config.php` に `define( '<定数>', '<ユーザーライセンスキー>' );` を足す
- 管理画面を 1 回開くと有効化される。プラグイン一覧の行に「Licensed with the internal key (mu-plugin)」が出ればよい
  （失敗するとプラグイン一覧と更新の画面にだけ理由を出し、1 時間おきに再試行する）

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
| 有効化 | `admin_init`（優先度 20。クライアントが instance を作った後）で、キー・商品 ID・instance・サイトのアドレスの HMAC が前回の成功と違えば、販売サイトに `activate` を POST の本文で送る（転送しない・15 秒）。断られたら `status` で有効か確かめる。成功したら `update_plugins` を捨てる |
| 失敗 | 理由（タグを除き 300 字まで）を記録し、1 時間の transient で再試行を止める。プラグイン一覧と更新の画面にだけ出す（`manage_options`） |
| 設定画面を閉じる | メニューから外し、直接開いたらプラグイン一覧へ転送する（入力欄に差し替えたキーが出るため） |
| 置いてあると分かるように | プラグイン一覧の行に「Licensed with the internal key (mu-plugin)」 |
| 何もしない条件 | 定数が無い・形が違う（`[A-Za-z0-9_-]{1,190}`）・販売サイトが https でない |

`<data_key>` は `wc_am_client_` ＋（クライアントに渡す商品 ID、`null` ならプラグインのフォルダ名）を、クライアントと同じく小文字にして ` _&?-` を `_` にしたもの。

## 限界・注意

- **クライアント自身の要求（`update`・`status`・`plugininformation`）はキーを URL のクエリ文字列で送る**（wc-am-client.php 2.12.2 の作り）。
  販売サイトのアクセスログにキーが残る。顧客のキーも同じ扱いで、mu-plugin では変えられない
- 有効化したサイトでは、クライアントが `auto_update_plugin` で自動更新を強制する（プラグイン一覧の列は「Auto-updates enabled」のラベル）。キーを有効化した顧客のサイトと同じ
- DB を複製したサイト（本番から作ったステージングなど）は instance が同じなので、同じ有効化を共有する（アドレスが違うので有効化を送り直すが、「有効化済み」→状態確認で通る）
- マルチサイトは対象外（記録がサイトごとの option、更新の情報がネットワークで 1 つ）
- 顧客のキーで有効化済みのサイトに置くと、こちらのキーが優先される。顧客の有効化は販売サイトに残るので、先に無効化してもらう
- クライアントの版を上げたら（`WC_AM_Client_2_12_2` → 次の版）、`--check` と wp-env の確認をやり直す。option の名前は 2.x で同じだが、作りが変わりうる

## テンプレートを直すとき

1. `templates/internal-license.php`（と、必要なら `templates/verify-mock.php`）を直し、`scripts/generate.py` の `TEMPLATE_VERSION` を上げる
   （クラス名 `AW_WC_AM_Internal_License_<版>` が変わり、版の違うファイルが同じサイトで並んでも衝突しない）
2. `bash scripts/test-generate.sh`（生成のシナリオテスト）
3. 使っているリポジトリで `generate.py ... --check` が差を出すので、生成し直して `verify-wp-env.sh` を流し、PR にする

## 使っているリポジトリ

| リポジトリ | ファイル | 商品 ID | 定数 |
| --- | --- | --- | --- |
| jp4wc-pro | `tools/mu-plugins/jp4wc-pro-internal-license.php` | 188（クライアントには `null`） | `WC4JP_PRO_INTERNAL_API_KEY` |
