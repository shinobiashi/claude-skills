# ハマりどころ（すべて実測済み）

確認環境: `@wordpress/env` 11.15.0 / WordPress 7.1.1 / WooCommerce 11.1.1 / PHP 8.3 / Docker Desktop（2026-09-19）。
§10 と、§9 の `install-path`・EBADENGINE の項は `@wordpress/env` 11.16.0 / Node 20.19 / npm 11.5（2026-10-06）。
wp-env の版が変わったら、ここを信じる前に `node_modules/@wordpress/env/README.md` を読む。

## 1. `wp-env start` が「プラグインを有効化できない」で失敗する

```
Warning: Failed to activate plugin. <Plugin> requires 1 plugin to be installed and activated: WooCommerce.
Error: No plugins activated.
```

`wp-env start` は exit 1 になり、**サイトも phpMyAdmin も立ち上がらない**（HTTP 応答なし）。

原因: wp-env は `plugins` を**書かれた順に** `wp plugin activate <dir>` し、全体を `&&` で連結する
（`lib/runtime/docker/wordpress.js`）。開発対象が `Requires Plugins: woocommerce` を宣言していて、
`"."` が WooCommerce より前にあると、依存未充足で最初の有効化が失敗し、後続もすべて実行されない。

対処: `plugins` を「WooCommerce → 依存先 → `"."` → 開発補助」の順にする（`references/plugins.md`）。
`Requires Plugins` を宣言していないプラグインでは `"."` が先頭でも動くため、**ヘッダーを足した途端に
壊れる**。最初から正しい順で書く。

## 2. `wp-env start` が成功しても、構築できたとは限らない

- `lifecycleScripts.afterStart` の標準出力は、成功時には**表示されない**。スクリプト内の WARNING は
  起動ログからは見えない
- exit 0 は「コンテナが上がった」ことしか意味しない

→ 完了判定は必ず `scripts/verify-env.sh`。プロビジョニングの成否（通貨 JPY・商品数）、同梱プラグインの
有効化漏れ、`debug.log` の PHP Fatal、HPOS の状態まで見る。

## 3. HPOS が有効にならない／環境ごとに違う

`wp plugin activate woocommerce` だけで作られた店舗は **HPOS=no（旧 posts ストレージ）** で上がる。
実店舗の新規インストールは HPOS が既定なので、放置すると本番と違うストレージで開発することになる。
テンプレートの `bin/wp-env-setup.sh` が development / tests の両方で有効化する。

| コマンド | 結果 |
|---|---|
| `wp wc hpos enable` | 注文テーブルを作成して有効化、exit 0。再実行は `Warning: HPOS is already enabled.` で exit 0（冪等） |
| `wp wc hpos enable --for-new-shop` | データが 1 件でもあると `Error: [Failed] This is not a new shop, but --for-new-shop flag was passed.` プロビジョニング後は必ず失敗するので**使わない** |
| `wp wc hpos status` | 有効/無効、互換モード、未同期注文数 |
| `wp wc hpos compatibility-info` | 互換／非互換／未宣言のプラグイン一覧 |

`custom_order_tables` に**非互換を宣言した**プラグインが有効だと、`enable` は pre-enable checks で
exit 1 になる。開発対象が犯人なら `before_woocommerce_init` での
`FeaturesUtil::declare_compatibility( 'custom_order_tables', __FILE__, true )` を確認する。
テンプレートはこの失敗で起動を止めない（WARNING を出して続行）。`verify-env.sh` が WARN で知らせる。

## 4. `destroy` / `cleanup` / `reset` の違い

| コマンド | 消えるもの | 使いどころ |
|---|---|---|
| `wp-env reset [development\|tests\|all]` | DB のみ（既定は development） | データだけ初期化。次の `start` で再プロビジョニング |
| `wp-env cleanup` | コンテナ・ボリューム・ネットワーク・ローカルファイル。**Docker イメージは残す** | 環境を作り直す。次の `start` が速い |
| `wp-env destroy` | 上記 + **Docker イメージ**（`docker compose down --volumes --remove-orphans --rmi all`） | ディスクを空けたいときだけ |

`destroy` は他の wp-env と共有しているベースイメージ（MariaDB・phpMyAdmin など）も消そうとする。
他の環境が稼働中なら Docker が拒否するだけで実害は無いが、停止中なら消えて次回に再ダウンロードになる。
**作り直しは `cleanup`**。いずれも `--force` で確認プロンプトを省ける。どれも既存データを消すので、
ユーザーの承認なしに実行しない。

## 5. ポートの衝突

wp-env の既定は 8888（development）/ 8889（tests）。ポートを指定していないリポジトリはすべてこの 2 つを
使うので、そうしたリポジトリ同士は同時に起動できない。しかも 8881〜8999 は WordPress Studio が自動で割り当てる
範囲で、8888/8889 も Studio のサイトと重なる。

- 割り当ては dev-env スキルの台帳（`../dev-env/scripts/ports.js`）。1 リポジトリに 10 ポートのスロット
  （10010〜10999）を割り当て、`check` で全リポジトリの `.wp-env.json`（override を含む）・Studio のサイト・
  LISTEN 中のポートと照合する
- 目視で選ばない。このスキルの作成時、7 リポジトリを見て「空いている」と判断した 8894/8895/9004 は、
  見ていなかった 1 リポジトリが既に使っていた。その後の照合でも、gitignore 済みの override や環境変数で
  決めたポートが他リポジトリと重なっていた（2026-10-01）
- `WP_ENV_PORT` / `WP_ENV_TESTS_PORT` での一時的な変更はしない。どのファイルにも残らず、次の割り当てで
  同じポートが他のリポジトリに渡る
- 起動が `port is already allocated` で失敗しなくても衝突していることがある。Studio のサイトが IPv6 の
  `[::1]` で同じ番号を待ち受けると、ブラウザの `localhost` が Studio 側へ繋がる（dev-env の SKILL.md 参照）
- ポートを既定から変えたら、8888/8889 を決め打ちしている箇所（Playwright の `baseURL`、CI、
  ドキュメント）を直す。`wp-e2e-playwright` スキルの既定は `http://localhost:8889`（`WP_BASE_URL` で上書き可）

## 6. `env.tests` / `testsPort` は非推奨（11.15.0 時点では動作する）

起動のたびに次の警告が出る:

```
⚠ Warning: wp-env starts both development and tests environments by default.
This behavior is deprecated and will be removed in a future version.
The "env", "testsPort", and "testsEnvironment" options are also deprecated.
Use the --config option with a separate config file for test environments instead.
```

このスキルは**あえて従来方式（`env.tests`）のまま**にしている。`wp-phpunit` / `wp-e2e-playwright` /
`woo-marketplace-qit` の各スキルと既存リポジトリのテストランナーが、`tests-cli` コンテナと 8889 番を
前提にしているため。`@wordpress/env` は `^11.x` 指定なので、メジャーを意図的に上げない限り壊れない。

メジャーを上げるときに移行する: テスト用を別ファイル（例 `.wp-env.tests.json`）に分けて
`wp-env start --config=.wp-env.tests.json` で起動する。設定ファイルごとにコンテナとデータが分離され、
override は `.wp-env.tests.override.json`。そのとき上記 3 スキルの `tests-cli` 前提も同時に直す。

## 7. phpMyAdmin に自前の Docker スクリプトは不要

`.wp-env.json` に `"phpmyadminPort": <port>` を書くだけで phpMyAdmin コンテナが組み込まれ、
`start` / `stop` / `cleanup` に追従する（ユーザー `root` / パスワード `password`）。tests 側にも
別のポートを `env.tests.phpmyadminPort` で与えると、両方を同時に使える。

過去に `lifecycleScripts.afterStart` から独立コンテナを起動するスクリプトを自作し、この標準機能に
気づいて捨てた経緯がある。**wp-env に何か足したくなったら、まず README の設定項目表を読む。**

## 8. スクリプトを足すときの注意

- `wp-env run <container> ...` の進捗表示（`ℹ Starting…` `✔ Ran…`）は stderr に出る。値を取るときは
  stdout だけを読み、`tr -d '\r'` で CR を落とす
- `grep -c PATTERN file || echo 0` は 0 件のとき `0` を**2 回**出力する（`grep -c` は 0 を出力した上で
  exit 1 になる）。`|| true` にする
- `afterStart` は **`start` のたびに**走る。冪等かつ短時間で終わらせる。`npx wp-env run cli wp …` を
  何度も呼ぶと毎回 docker exec の往復がかかるので、テンプレートのように「ホストから呼ばれたら自分自身を
  コンテナ内で 1 回だけ再実行する」形にする（全項目 skip の再実行で約 13 秒・実測）
- コンテナ内のカレントは `/var/www/html`、開発対象は `wp-content/plugins/<リポジトリのディレクトリ名>`
- `wp wc …` 系コマンドは `--user=1` が要る

## 9. その他

- **Docker が起動していない**: `docker info` が失敗する。ユーザーに Docker Desktop の起動を依頼して待つ
- **`.nvmrc` と `node -v` の不一致**: `npm install` が optionalDependencies を黙ってスキップすることがある。
  以降の Bash 呼び出しの先頭で `export PATH=~/.nvm/versions/node/v<版>/bin:$PATH`（シェル状態は呼び出し間で
  保持されない）。`@wordpress/env` 11.x 自体の要件は node >=18.12 / npm >=8.19
- **Japanized for WooCommerce** の wordpress.org スラッグは `woocommerce-for-japan`
- **WC Smooth Generator** は wordpress.org に無い。GitHub Releases の zip を指定し、tests には入れない
- マシン固有の上書きは `.wp-env.override.json`（`.gitignore` に入れる）。共有したい設定は `.wp-env.json`
- **`wp-env install-path` は 11.16.0 に無い**: 何も出力せず exit 0 で終わる。インスタンスのディレクトリは
  `npx wp-env status --json` の `installPath`（`~/.wp-env/wp-env-<ディレクトリ名>-<hash8>`）
- **`npm install` の EBADENGINE 警告**: 11.16.0 が依存する `@php-wasm/*` が node >=24.18 / npm >=11.16 を要求する。
  Node 20 では警告だけで、Docker ランタイムの `start` と `verify-env.sh` は通る

## 10. `npm ci` が ERESOLVE で失敗する（`@wordpress/scripts` と `@wordpress/env` の peer 衝突）

```
npm error code ERESOLVE
npm error While resolving: @wordpress/scripts@30.27.0
npm error Found: @wordpress/env@11.16.0
npm error Could not resolve dependency:
npm error peerOptional @wordpress/env@"^10.0.0" from @wordpress/scripts@30.27.0
```

原因: `@wordpress/scripts` 30.x（31.0.0 も同じ）は `@wordpress/env ^10.0.0` を optional peer に持つ。ルートで `^11` を
要求すると衝突するが、**`npm install` は通り、`npm ci` だけが失敗する**。ローカルでは気づかず、CI の `npm ci`
（lint・Jest・E2E のジョブ）で初めて落ちる（jp4wc-pro PR #5）。版を指定せずに `npm install --save-dev @wordpress/env`
すると、npm はこの peer に合わせて 10.x を入れる。

対処: `package.json` の `overrides` で、その peer をルートの版に合わせる。

```json
"overrides": {
	"@wordpress/scripts": {
		"@wordpress/env": "$@wordpress/env"
	}
}
```

`npm install` → `npm ci --dry-run` で ERESOLVE が消えることを確かめる（jp4wc-pro では `package-lock.json` は変わらず、
`npm ci`・lint・Jest が通った）。wp-env や Playwright を `wp-scripts` 経由（`wp-scripts test-playwright` など）で呼ぶ
リポジトリでは、overrides の前に 11.x で動くかを確かめる。`@wordpress/scripts` 36.0.0 の peer は `>=10.0.0` なので、
そこまで上げれば overrides は要らない。
