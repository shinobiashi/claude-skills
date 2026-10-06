---
name: wc-wp-env
description: WooCommerce 拡張プラグインのリポジトリに wp-env のローカル開発環境を「構築」するスキル。.wp-env.json を書くだけでなく、他リポジトリと衝突しないポートの割り当て、同梱プラグインの選定、依存導入、起動、店舗の初期構築（HPOS・JPY・決済・送料・サンプルデータ）、動作検証までを一気通貫で行う。「wp-env を構築して」「開発環境を作って」「ローカル環境をセットアップして」「wp-env が起動しない」「ポートが衝突する」「wp-env を作り直したい」などと言われたら使う。
compatibility: "@wordpress/env 11.15.0 / WordPress 7.1 / WooCommerce 11.1 / PHP 8.3 / Docker Desktop で構築から撤去まで実測（2026-09-19）。wp-env の版が違う場合は node_modules/@wordpress/env/README.md を正とする。"
---

# /wc-wp-env — WooCommerce 拡張向け wp-env 環境の構築

## 大前提

- **完了条件は `scripts/verify-env.sh` が FAIL 無しで通ること**。`wp-env start` の exit 0 は
  「コンテナが上がった」だけで、プラグインの有効化漏れも、`afterStart` の失敗も、load 時の Fatal も
  そこからは分からない。
- **wp-env の仕様を記憶で書かない**。設定項目・コマンドは `node_modules/@wordpress/env/README.md` と
  `npx wp-env <command> --help` で確認する。何かを自作する前に、標準機能が無いか先に調べる
  （phpMyAdmin は `phpmyadminPort` を書くだけで入る。自前の Docker スクリプトを作って捨てた過去がある）。
- **commit しない**。変更は作業ツリーに残して報告する。`.wp-env.json` や `package.json` はコード扱い
  なので、コミットは `/start-task` に渡す（main へ直接コミットしない）。
- **既存環境のデータを消す操作は承認必須**: `wp-env reset` / `cleanup` / `destroy`。作り直しは
  `destroy` ではなく `cleanup`（理由は `references/troubleshooting.md` §4）。
- **既存の設定を黙って上書きしない**。`.wp-env.json` / `bin/wp-env-setup.sh` が既にあれば差分を見せて確認する。

同梱ファイル（`<skill>` は起動時に表示される "Base directory for this skill"）:

| ファイル | 役割 |
|---|---|
| `<skill>/../dev-env/scripts/ports.js` | dev-env スキルのポート台帳。リポジトリのスロット（10 ポート）を返す・登録する |
| `<skill>/scripts/verify-env.sh` | 構築結果の検証（完了条件） |
| `<skill>/templates/wp-env-setup.sh` | 店舗の初期構築スクリプト（冪等）。リポジトリの `bin/` にコピーして使う |
| `<skill>/references/plugins.md` | 同梱プラグインの URL・並び順・採否の基準 |
| `<skill>/references/troubleshooting.md` | 実測済みのハマりどころ。**失敗したらまずここを読む** |

## 手順

### 1. 現状を把握する

```bash
git status --short && git branch --show-current
ls .wp-env.json .wp-env.override.json package.json .nvmrc composer.json bin/wp-env-setup.sh 2>/dev/null
grep -nE '^\s*\*?\s*(Plugin Name|Requires PHP|Requires at least|Requires Plugins|WC requires at least):' ./*.php
```

- メインファイル（`Plugin Name:` を持つ PHP）のヘッダーから、対応 PHP / WP / WC の最小バージョンと
  `Requires Plugins` の有無を読む。`Requires Plugins` があれば plugins の並び順が起動の成否を分ける（手順 3）。
- wp-env は `"."` を `wp-content/plugins/<リポジトリのディレクトリ名>` にマウントする。以降の
  「スラッグ」はこのディレクトリ名のこと。
- CLAUDE.md や `docs/` に開発環境の仕様（例: `docs/DEV_ENVIRONMENT.md`）があれば、それを正として従う。
  このスキルの既定と食い違う点は、勝手に合わせず手順 3 の提示で示す。
- タスクと無関係な未コミット変更があれば、進める前にユーザーへ報告する。

### 2. 前提を確認する

```bash
docker info --format '{{.ServerVersion}}'   # 失敗 = Docker が起動していない
node -v && npm -v                            # @wordpress/env 11.x は node >=18.12 / npm >=8.19
[ -f .nvmrc ] && cat .nvmrc
```

- Docker が起動していなければ、ユーザーに起動を依頼して**停止**する（自分で起動を試みない）。
- `.nvmrc` と `node -v` が食い違うときは、以降の Bash 呼び出しの先頭に
  `export PATH=~/.nvm/versions/node/v<版>/bin:$PATH` を付ける（シェル状態は呼び出し間で保持されない）。

### 3. 構成を決めて提示する

**ポート** — 目視で選ばず、dev-env スキルの台帳で決める（設計と運用の詳細は dev-env の SKILL.md）:

```bash
node <skill>/../dev-env/scripts/ports.js get "$PWD"      # 登録済みなら、そのスロットのポート（未登録は exit 4）
node <skill>/../dev-env/scripts/ports.js assign "$PWD"   # 未登録なら、空いているスロットに登録する
node <skill>/../dev-env/scripts/ports.js check           # 既存のリポジトリなら、状態（ok / pending / ERROR）を確かめる
```

- 1 リポジトリに 10 ポートのスロット（10010〜10999）を割り当てる。8881〜8999 は WordPress Studio が使うので、
  wp-env の既定の 8888/8889 も使わない。
- `assign` は元本（`~/Dev/claude-skills`）の台帳に 1 行追記する。その差分も手順 8 で報告する（コミットしない）。
- 既存の `.wp-env.json` が旧ポートのまま（`check` で `pending`）なら、移行するかをユーザーに確認する
  （手順は dev-env の「既存リポジトリの移行」）。URL がブックマークや OAuth のコールバック登録に入っていることがあるため、黙って変えない。

**プラグイン** — `references/plugins.md` に従う。並び順は
「WooCommerce → 依存先 → `"."` → 開発補助」。contextual なもの（Japanized for WooCommerce など）は、
リポジトリの内容から必要と判断した理由を添えて提案し、黙って足さない。

**バージョン** — `phpVersion` は対応最小版（ヘッダーの `Requires PHP` / `composer.json` / CI マトリクスの
最小値）に固定する。上位版との差分は CI が担う。`core` は指定しない（最新の製品版）。

ここまでを 1 つの表にまとめて提示する。新規ファイルの作成だけなら、そのまま手順 4 へ進んでよい。
既存の `.wp-env.json` を変える場合と、contextual なプラグインを足す場合は、返答を待つ。

### 4. ファイルを生成する

**`.wp-env.json`**（`<port>` などは手順 3 の `ports.js` の出力。`env.tests.plugins` は WC Smooth Generator を除いたもの）:

```json
{
	"phpVersion": "8.3",
	"plugins": [
		"https://downloads.wordpress.org/plugin/woocommerce.zip",
		".",
		"https://downloads.wordpress.org/plugin/query-monitor.zip",
		"https://downloads.wordpress.org/plugin/wp-mail-logging.zip",
		"https://downloads.wordpress.org/plugin/user-switching.zip",
		"https://downloads.wordpress.org/plugin/wp-crontrol.zip",
		"https://downloads.wordpress.org/plugin/plugin-check.zip",
		"https://github.com/woocommerce/wc-smooth-generator/releases/latest/download/wc-smooth-generator.zip"
	],
	"config": {
		"WP_DEBUG": true,
		"WP_DEBUG_LOG": true,
		"WP_DEBUG_DISPLAY": false,
		"SCRIPT_DEBUG": true,
		"WP_ENVIRONMENT_TYPE": "local"
	},
	"port": <port>,
	"testsPort": <testsPort>,
	"phpmyadminPort": <phpmyadminPort>,
	"lifecycleScripts": {
		"afterStart": "bash bin/wp-env-setup.sh"
	},
	"env": {
		"tests": {
			"plugins": [ "…WC Smooth Generator 以外を同じ順で…" ],
			"phpmyadminPort": <testsPhpmyadminPort>
		}
	}
}
```

`env` / `testsPort` は wp-env 11.15 で非推奨の警告が出るが、意図して使っている
（`references/troubleshooting.md` §6）。警告を消すために勝手に新方式へ変えない。

**`bin/wp-env-setup.sh`** — テンプレートをコピーして実行権限を付ける:

```bash
mkdir -p bin && cp <skill>/templates/wp-env-setup.sh bin/wp-env-setup.sh && chmod +x bin/wp-env-setup.sh
```

development には HPOS 有効化・店舗設定（日本/JPY/小数 0 桁・パーマリンク・代引き＋銀行振込・定額送料）と
サンプルデータ（テスト顧客・商品 2 件・クーポン）を入れ、tests には HPOS 有効化だけを行う。
プラグイン固有の初期化（自作ゲートウェイの有効化など）は、ファイル末尾の目印の下に**冪等に**足す。
`bin/` が配布 zip に入らないこと（`.distignore` やビルドスクリプトの除外設定）も確認する。

**`package.json`** — 既存の内容を残して追記する。無ければ `"private": true` の最小構成で作る:

```bash
npm install --save-dev @wordpress/env@^11
npm pkg set scripts.env:start="wp-env start" scripts.env:stop="wp-env stop" scripts.env:cleanup="wp-env cleanup"
npm ci --dry-run   # CI が使う解決。ERESOLVE なら references/troubleshooting.md §10
```

版は `@^11` と明示する。`@wordpress/scripts` が入っているリポジトリでは、版を指定しないと 10.x が入る
（`@wordpress/scripts` 30.x が `@wordpress/env ^10` を optional peer に持つため）。`^11` にすると `npm install` は
通るのに `npm ci` だけが ERESOLVE で失敗するので、その場で `npm ci --dry-run` を通す（§10）。

`env:destroy` は足さない（共有 Docker イメージまで消しにいくため。既にあれば消さずに残す）。

**`.gitignore`** — `.wp-env.override.json` と `node_modules/` が無ければ足す。

### 5. 構築する

```bash
npx wp-env start
```

Bash の `run_in_background` で実行し、timeout は 600000ms。初回は WordPress と各プラグインの取得で
1〜2 分（実測 84 秒）、2 回目以降は 30 秒前後。前面で `sleep` して待たない。

exit 0 以外なら出力を読み、`references/troubleshooting.md` と照合する。最も多いのは §1
（`Requires Plugins` と並び順）と §5（ポート衝突）。原因を直してから再実行し、やみくもに
`cleanup` / `destroy` しない。

### 6. 検証する

```bash
bash <skill>/scripts/verify-env.sh            # development + tests
bash <skill>/scripts/verify-env.sh --dev-only
```

- **FAIL** が 1 つでもあれば未完了。原因を直して手順 5 から繰り返す。2 回直しても通らなければ、
  状況を報告してユーザーの指示を仰ぐ。
- **WARN** は構築の失敗ではなくプロジェクト側の状態（例: 開発対象が HPOS 互換を宣言していない）。
  握りつぶさず、対処方法と一緒に報告する。
- 冪等性も確かめる: `bash bin/wp-env-setup.sh` をもう一度実行し、すべて `already exists, skipping.` に
  なること。
- ポートも確かめる: `bash <skill>/../dev-env/scripts/verify-ports.sh`。台帳のスロットで応答しているか、
  `localhost` が Studio などの別サイトに繋がっていないかを見る（verify-env.sh は HTTP 200 しか見ない）。
- `package.json` / `package-lock.json` を変えたら `npm ci --dry-run` も通す。CI は `npm ci` で入れるので、ローカルの
  `npm install` が通っていても peer の衝突で落ちることがある（`references/troubleshooting.md` §10）。

### 7. 周辺との整合を取る

ポートを既定から変えたので、8888/8889 を決め打ちしている箇所を探して直す（または報告する）:

```bash
grep -rnE 'localhost:888[89]' . --include='*.ts' --include='*.js' --include='*.json' --include='*.yml' \
  --include='*.yaml' --include='*.md' --include='*.sh' --include='*.php' \
  --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git
```

Playwright の `baseURL`（`wp-e2e-playwright` スキルの既定は 8889）、CI ワークフロー、ドキュメントが
主な対象。CI も `.wp-env.json` のポートでそのまま起動するので、Playwright の既定値を `.wp-env.json` に揃えれば
足りる。`playwright test` を直接呼ぶなら `WP_BASE_URL` も設定ファイルで揃える（`@wordpress/e2e-test-utils-playwright` が
`baseURL` ではなくこれを読む。dev-env の「既存リポジトリの移行」手順 3）。`WP_ENV_PORT` / `WP_ENV_TESTS_PORT` での上書きはしない（どのファイルにも残らず、台帳との照合から見えない）。

開発環境のドキュメントが既にあれば実態に合わせて更新する。無い場合に新しく作るかどうかは
ユーザーに尋ねる（勝手にファイルを増やさない）。

### 8. 報告する

```markdown
## wp-env 構築結果: <スラッグ>
| 環境 | サイト | phpMyAdmin |
|---|---|---|
| development | http://localhost:<port> | http://localhost:<phpmyadminPort> |
| tests | http://localhost:<testsPort> | http://localhost:<tests phpmyadminPort> |

- ログイン: 管理者 `admin` / `password`、テスト顧客 `customer@example.com` / `password`、DB `root` / `password`
- ポート: dev-env 台帳のスロット <NN>（新しく登録したなら claude-skills の `ports.json` の未コミット差分も示す）
- 同梱プラグイン: <一覧。contextual で足した／見送ったものと理由>
- 検証: <verify-env.sh の INFO / WARN 行と RESULT>
- 未コミットの変更: <git status --short>
- 次の一手: `/start-task` でコミット〜PR
```

## 環境を作り直すとき

データだけ戻すなら `npx wp-env reset all` → `npx wp-env start`。コンテナごと作り直すなら
`npx wp-env cleanup` → `npx wp-env start`。どちらも既存データを消すので承認を取ってから実行し、
最後に必ず手順 6 の検証を通す。
