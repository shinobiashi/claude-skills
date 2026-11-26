---
name: wc-studio-prod-copy
description: 本番の WooCommerce サイトを WordPress Studio のローカルサイトに取り込み（テーマを除く DB・uploads・plugins）、本番のふるまい（WP-Cron・Action Scheduler・SMTP 送信・外部 API への通信）を止めたうえで、顧客データを匿名化するスキル。取り込む前に置く安全策の mu-plugin、個人情報の洗い出し（pii-inventory.php）、匿名化（anonymize.php。HPOS と旧来の注文・顧客・注文メモ・レビュー・ログ・領収書 PDF。サイト固有のメタキーは設定 JSON で足す）、データベースのファイルを走査して許可していないメールアドレスが 1 件でもあれば失敗する関門（scan-pii.sh）、文字列の在りかを探す find-string.php を同梱する。「本番をローカルに取り込んで」「本番環境からテーマ以外を Studio に反映して」「ローカルでも本番と同じ見た目で確認したい」「顧客データを匿名化して」「ローカルの個人情報を消して」「本番の複製を安全にして」などと言われたら使う。
---

# wc-studio-prod-copy — 本番の複製をローカルに作り、匿名化する

本番のデータをローカルに持ってくると、見た目の確認やテストが本番と同じ条件でできる。代わりに、
**本番の設定がそのまま動く**（WP-Cron が予約ジョブを実行して実在の顧客にメールを送る、SMTP プラグインが本物のメールを送る、
連携プラグインが外部 API を叩く、バックアップが本番と同じ保存先に上がる）ことと、**顧客の個人情報が手元に残る**ことが問題になる。
このスキルは、安全策を先に置いてから取り込み、匿名化し、ファイルを走査して残りが無いことを確かめるまでを行う。

| ファイル | 役割 |
|---|---|
| `assets/local-prod-copy-safety.php` | 取り込む前に `wp-content/mu-plugins/` に置く安全策。ローカル（環境が local/development かつ localhost 等）でだけ動き、WP-Cron（`wp-cron.php` を直接叩かれた場合も）・Action Scheduler の非同期実行を止め、SMTP 系のプラグインを読み込まず（Studio がメールを手元に保存する）、外部への HTTP を止める。管理画面に「止めているもの」を出す |
| `scripts/pii-inventory.php` | 個人情報がありそうな場所の一覧（空でないテーブル、権限ごとの人数、HPOS、有効なプラグイン、規則が扱っていない個人情報らしいメタキー＝「要確認」）。`write-allow=` で管理者・店舗のアドレスを走査の許可リストに書き出す |
| `scripts/anonymize.php` | 匿名化。ローカルでなければ拒否する。`dry-run` はトランザクションで巻き戻す。SQLite なら最後に VACUUM |
| `scripts/scan-pii.sh` | **関門**。DB ファイル（-wal も）・SQL の控え・ログを走査し、許可していないメールアドレス、領収書 PDF、読めない圧縮ファイルがあれば exit 1。表示はドメインだけ |
| `scripts/find-string.php` | 文字列（`@gmail.com` など）がどのテーブル・列・行・メタキーにあるか |
| `scripts/lib.php` | WordPress 抜きで試せる関数（ローカルかどうかの判定、JSON の書き換え、既定の規則） |
| `assets/anonymize-config.example.json` | サイト固有のメタキーを足す設定 JSON の見本（cart-bridge-jp を使う店舗の例） |

`anonymize.php` が全部を消せるとは考えない。規則に無いキーに入った個人情報は残る。`scan-pii.sh` が見つけられるのは
**メールアドレス・領収書 PDF・圧縮ファイルだけ**で、規則に無いキーに入った氏名・電話番号・住所は通ってしまう。
だから「残っていない」と言うには、**4 の「要確認」のキーをすべて判断したうえで**、`scan-pii.sh` が通ることが要る。

## 手順

ローカルを上書きする操作（取り込み・匿名化）は、ユーザーの明示的な指示を受けてから行う。

### 1. 対象と取り込む範囲を決める

- `site_list` / `site_info` でローカルサイト（Studio）を、`site_connected_remote_sites` で接続先の本番を確かめる（`canPull` が true であること）
- 取り込むのは **`sqls,uploads,plugins`**。
  - **`themes` は外す**: テーマがリポジトリへのシンボリックリンクだと、取り込みでリポジトリのファイルが書き換わる
  - **`contents`（その他の wp-content ファイル）も外す**: ホスティング会社固有のキャッシュ用ファイル（`object-cache.php` など）を持ち込み、ローカルが動かなくなるおそれがある
- 今の状態を控える: `readlink <site>/wp-content/themes/<テーマ>`、リポジトリの `git status`、`ls <site>/wp-content/mu-plugins`

### 2. ローカルの DB を控え、安全策を先に置く

1. `site_export`（`mode: "db"`）で今の DB を控える。ローカルが以前にも本番から取り込んだものなら、**控えにも個人情報が入っている**（7 で削除を提案する）
2. `assets/local-prod-copy-safety.php` を `<site>/wp-content/mu-plugins/` にコピーする。**取り込む前に置く**:
   取り込みの直後、まだ何も止めていないうちに WP-Cron が起動した実例がある（`doing_cron` が取り込みの 1 分後に立っていた）
3. 外部連携・バックアップのプラグイン（例: cart-bridge-jp、UpdraftPlus）も止めるなら、`wp-config.php` に
   `define( 'LOCAL_PROD_COPY_UNLOAD_PLUGINS', 'updraftplus,cart-bridge-jp' );` を足す（ディレクトリ名。本番のプラグイン一覧は取り込み後の 4 で分かるので、そこで決めてもよい）

### 3. 取り込む

`site_pull`（`options: "sqls,uploads,plugins"`）。2 分を超えるとバックグラウンドに回るので、完了の通知を待つ。終わったら次を確かめる:

- テーマのシンボリックリンクとリポジトリの `git status` が 1 と同じ
- `mu-plugins` に安全策が残っている（`wp eval 'echo has_filter( "pre_get_ready_cron_jobs" ) ? "on" : "off";'`）
- 管理画面のお知らせ「本番の複製（ローカル）: 止めているもの」

続けて、**決済をテストモードにする**（取り込んだ DB は本番の決済設定のままで、安全策は WordPress の HTTP API を通らない SDK の通信を止められない）:

1. 有効な決済を一覧にする: `wp eval 'foreach ( WC()->payment_gateways()->payment_gateways() as $id => $g ) echo $id, " ", $g->enabled, " ", $g->get_option_key(), "\n";'`
2. 外部の決済サービスを呼ぶもの（カード・PayPay・後払いなど）ごとに、テストモードの設定を探す。決済ごとの設定（`woocommerce_<id>_settings`）に無ければ、
   プラグイン共通の設定にある（例: PAY.JP は `payjp_settings` の `test_mode`。真偽値で、真ならテスト用のキーを使う）。
   保存時のフックが外部 API を呼ばないことをコードで確かめてから、ローカルの DB だけを書き換える。キーの値は表示しない
3. 実際に使われるキーがテスト用に変わったことを、プラグインの関数で確かめる（PAY.JP なら `Payjp_Settings::get_secret_key()` の先頭が `sk_test_`）。
   テスト用のキーが入っていなければ、その決済を無効にする

### 4. 洗い出す

Studio の WP-CLI はサイトのディレクトリの中しか読めないので、`scripts/` の PHP と設定 JSON を `<site>/.prod-copy-tmp/` にコピーしてから実行する。
引数は **`config=…`・`dry-run`・`write-allow=…` のように `--` を付けない**（WP-CLI が `--` 付きを自分のオプションと見なし「unknown --config parameter」で止まる）。

```
wp eval-file <site>/.prod-copy-tmp/pii-inventory.php config=<site>/.prod-copy-tmp/site-config.json write-allow=<site>/.prod-copy-tmp/allow.txt
```

- **「要確認」のキーは 1 つずつ必ず判断する**（省略しない。走査は氏名・電話・住所を見つけられないので、ここが唯一の確認になる）。
  中身を `wp eval 'echo get_metadata(...)'` などで数件見て、個人情報ならサイトの設定 JSON に足し（見本: `assets/anonymize-config.example.json`。
  規則の意味は `scripts/lib.php` の `wcspc_default_config()`）、そうでなければ判断を報告に書く。キー名だけの推測なので、個人情報らしくない名前のキー
  （例: `x_custom_contact`）は出てこない。メールアドレスが入っていれば 6 の走査で見つかる
- 有効なプラグインを見て、2-3 の `LOCAL_PROD_COPY_UNLOAD_PLUGINS` に足すものをユーザーと決める
- 設定 JSON には個人情報が入らないので、次に取り込み直すときのために残しておく場所をユーザーと決める（例: プロジェクトの `docs/local-prod-copy/`。
  店舗・管理者のドメインの許可リストも同じ場所に置ける。テーマの CLAUDE.md からそこを指しておく）

### 5. 匿名化する

```
wp eval-file <site>/.prod-copy-tmp/anonymize.php config=<site>/.prod-copy-tmp/site-config.json dry-run
wp eval-file <site>/.prod-copy-tmp/anonymize.php config=<site>/.prod-copy-tmp/site-config.json
```

`dry-run` の件数（顧客・注文・住所の数）が 4 の洗い出しと合っているかを見てから本番どおりに実行する。管理者（既定は administrator・shop_manager）は残る。
WooCommerce や WordPress の API で保存し直すと連携のフックが動くので、スクリプトは直接クエリで書き換える。

### 6. 関門: ファイルを走査する

```bash
bash scan-pii.sh --allow-file <site>/.prod-copy-tmp/allow.txt [--allow-domain <店舗のドメイン>] \
  <site>/wp-content/database/.ht.sqlite <site>/wp-content/uploads
```

- 失敗したら、出たドメインごとに `wp eval-file <site>/.prod-copy-tmp/find-string.php '@<ドメイン>'` で場所を探す
  - 顧客のデータ → そのキーをサイトの設定 JSON に足して 5 をやり直す
  - 管理者・店舗・開発者のアドレス → `--allow-address`（アドレス単位）か、店舗の独自ドメインなら `--allow-domain`
  - **顧客が使うフリーメールのドメイン（gmail.com など）は許可しない**。管理者の個人アドレスが gmail なら `--allow-address` でアドレスだけを許可する
- 通るまで 5 と 6 を繰り返す。通ったら完了

### 7. 片付けと報告

- `<site>/.prod-copy-tmp/` を消す（`allow.txt` には管理者のアドレスが入っている）
- 2-1 の控えに個人情報が入っていれば（`scan-pii.sh <控え>.sql` で分かる）、削除してよいかユーザーに確認する
- 報告に必ず書くこと:
  - 匿名化したもの（件数）と、残したもの（管理者、店舗の設定、商品）
  - **残っているもの**: 本番の API キー（決済・連携・バックアップ先・AI など）は DB に残る。決済は 3 でテストモードにしたこと（使われるキーがテスト用であること）を書く
  - **このローカルを Studio から本番へ push しない**（匿名化したデータで本番を上書きする）。本番から取り込み直したら、2〜6 をやり直す

## 落とし穴

- **安全策を後から入れると間に合わない**: 取り込み直後に WP-Cron が起動していた。`DISABLE_WP_CRON` は自動起動を止めるだけで、`wp-cron.php` を直接叩かれると動くので、
  安全策の mu-plugin は `pre_get_ready_cron_jobs` で実行するジョブも空にしている
- **管理画面を開くと、WP-Cron を止めていても Action Scheduler が動く**（非同期実行）。安全策の mu-plugin が止める
- **最初の匿名化で漏れたキーを見つけたのは走査だけだった**: `_wc_email_verified_wp`（メール確認済みのアドレス）。いまは既定の規則に入れてある。
  同じように、規則に無いキーは走査で見つけて設定に足す
- **`strings` は隣の列のバイトをアドレスの前後にくっつける**（`customer1@example.comz`、`…Qx7vadmin@localhost.localdomain`）。`scan-pii.sh` は許可したドメイン・アドレスに文字がくっついたものも通す
- **安全策で読み込まないプラグインは、管理画面では「無効」に見える**。その状態で別のプラグインを有効にすると、DB 上も無効として保存される（ローカルの複製なので実害は無い）
- **Studio の DB は `sqlite3` で開けないことがあった**（`unable to open database file (14)`）。VACUUM は WordPress の SQLite 接続（PDO）経由で行う。`anonymize.php` が自分で行う
- **注文メモは消す**: 自由記述（氏名・メール・送り状番号が入る）で、置き換えでは消し切れない

## 検証の範囲

- 安全策の mu-plugin は、本番の複製のローカルに一時的に置いて確かめた: 外部への `wp_remote_get()` が `local_prod_copy_blocked` になり自分のサイトへは届くこと、
  予約済みのイベントがあっても実行対象が 0 件になること、`LOCAL_PROD_COPY_UNLOAD_PLUGINS` に書いたプラグインが読み込まれないこと、ページの見た目が変わらないこと。
  **ただし「安全策を置いてから `site_pull` する」流れは、通しでは試していない**（取り込みで mu-plugins が変わらないことは、安全策なしの取り込みで確かめた）
- 決済のテストモード化は PAY.JP（payjp-for-wc）で行い、使われるキーが `pk_test_`・`sk_test_` に変わることを確かめた。ほかの決済プラグインは未確認
- 匿名化を実行して確かめたのは、WordPress Studio（SQLite）上の本番の複製（WooCommerce 11・HPOS）だけ。合成のマーカー行（顧客・HPOS の注文と住所・
  cart-bridge-jp の配送 JSON・旧来の注文〔posts テーブル〕・注文メモ・レビュー・規則に無いメタキー）を直接入れ、`dry-run` が巻き戻すこと、
  匿名化で規則にあるものが消えること、規則に無いキーを走査が見つけ `find-string.php` が場所を示すこと、設定に足すと走査が通ることを確かめた
- **MySQL（wp-env など）では未検証**（SQL は標準的なものだけを使っている）
- シナリオテスト（WordPress もネットワークも不要）:

```bash
bash scripts/test-lib.sh "$PWD/scripts/lib.php"
bash scripts/test-scan-pii.sh "$PWD/scripts/scan-pii.sh"
bash scripts/test-safety-plugin.sh "$PWD/assets/local-prod-copy-safety.php"
```
