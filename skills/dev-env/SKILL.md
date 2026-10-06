---
name: dev-env
description: ローカル開発環境のポート台帳を一元管理するスキル。wp-env を使う各リポジトリに 10 ポートずつの「スロット」を割り当て、WordPress Studio（8881〜）や macOS・Xdebug などと衝突しないようにする。台帳（ports.json）と照合スクリプト（ports.js）を同梱。「ポートを割り当てて」「ポートが衝突する」「port is already allocated」「wp-env が起動しない」「Studio とぶつかる」「localhost で別のサイトが出る」「Docker Desktop のコンテナがどのリポジトリかわからない」「wp-env のポートを移行して」「ポート台帳」「開発環境のポート」などと言われたら使う。wp-env を新しく構築するときは wc-wp-env の手順 3 からこのスキルのスクリプトを使う。
compatibility: "@wordpress/env 10.39 / 11.15、WordPress Studio 1.22.0、macOS で確認（2026-10-01）。verify-ports.sh は @wordpress/env 11.16.0 でも確認（2026-10-06）。wp-env の設定の解釈は node_modules/@wordpress/env/lib/config/ を正とする。"
---

# /dev-env — ローカル開発環境のポート台帳

## 大前提

- **ポートは台帳（`ports.json`）で決め、各リポジトリでコミットする `.wp-env.json` に書く**。ポートはこの 2 か所以外に置かない。
  - `WP_ENV_PORT` / `WP_ENV_TESTS_PORT` を使ったその場しのぎはしない。どのファイルにも残らず、照合からも
    次の割り当てからも見えない（saai-knowledge が 8897/8898 で動いていたのに、どのファイルにも書かれていなかった実例がある）。
  - `.wp-env.override.json` に書くのは、自分が管理していないリポジトリ（上流のクローンなど、`.wp-env.json` を
    コミットできないもの）だけ。照合は override も読む。
- **8881〜8999 は WordPress Studio 専用**。wp-env では既定の 8888/8889 も含めて使わない。
- **台帳は元本（`~/Dev/claude-skills/skills/dev-env/ports.json`）で更新する**。`~/.claude/skills/dev-env/` は
  インストール済みのコピーで、`install.sh` の `rsync --delete` で上書きされる。`ports.js assign` はコピーへの書込みを拒否する。
- **commit しない**。台帳の変更（claude-skills）も、各リポジトリの `.wp-env.json` の変更も作業ツリーに残して報告する。
  `.wp-env.json` はコード扱いなので、各リポジトリの規約（PR 必須など）に従う。

同梱ファイル（`<skill>` は起動時に表示される "Base directory for this skill"）:

| ファイル | 役割 |
|---|---|
| `<skill>/ports.json` | 台帳。1 行 = 1 リポジトリ（`slot` と、`~/Dev` からの相対パス `repo`。任意で `note`） |
| `<skill>/scripts/ports.js` | 台帳の参照・登録、全リポジトリ・Studio・LISTEN 中のポートとの照合、起動中の wp-env とリポジトリの対応表 |
| `<skill>/scripts/verify-ports.sh` | 起動中の wp-env が台帳のスロットで応答し、ほかのプロセスが割り込んでいないかを確かめる（移行・構築の完了確認） |
| `<skill>/scripts/test-ports.sh` / `test-verify-ports.sh` | 2 つのスクリプトのシナリオテスト（Docker・ネットワーク不要）。スクリプトを直したら通す |

## ポート設計

| 範囲 | 用途 |
|---|---|
| 8881–8999 | WordPress Studio 専用 |
| 10010–10999 | wp-env。1 リポジトリ = 1 スロット = 10 ポート |

スロット NN のポートは `10000 + NN × 10 + オフセット`:

| オフセット | 用途 | `.wp-env.json` のキー |
|---|---|---|
| +0 | development の WordPress | `port`（または `env.development.port`） |
| +1 | tests の WordPress | `testsPort`（または `env.tests.port`） |
| +2 | development の phpMyAdmin | `phpmyadminPort`（または `env.development.phpmyadminPort`） |
| +3 | tests の phpMyAdmin | `env.tests.phpmyadminPort` |
| +4〜+9 | 予備（MySQL を固定する、Mailpit を足すなど） | — |

- スロットは 01〜99。**08 は欠番**（10080 は Chrome と Firefox が接続を拒否するポート）。
- phpMyAdmin を使わないリポジトリは +2/+3 を書かなくてよい（スロットとして確保だけしておく）。
- **ルートの `phpmyadminPort` は tests にも引き継がれる**（`port` / `testsPort` 以外のルート設定は両環境の既定になる）。
  phpMyAdmin を使うなら `env.tests.phpmyadminPort` も必ず書く。書かないと 2 つの phpMyAdmin が同じポートを取り合い、
  起動が `port is already allocated` で失敗する。
- `mysqlPort` は書かない（wp-env が毎回空いている高い番号を選ぶ）。固定が必要なら +4〜+9 を使う。

避けるポート（スロットを使えば自然に避けられる。台帳の外で何かのポートを決めるときに参照する）:

| ポート | 理由 |
|---|---|
| 8881〜8999 | Studio |
| 5000 / 7000 | macOS の AirPlay レシーバー（ControlCenter が LISTEN している） |
| 9003 | Xdebug（IDE がここで待ち受ける） |
| 10080 | ブラウザが接続を拒否する |
| 3000 / 5173 / 8080 | Node・Vite などの開発サーバーの既定 |

### WordPress Studio の挙動（Studio 1.22.0 のアプリ本体で確認）

- 新しいサイトには、8881 から順に「既存サイトが持っておらず、今 LISTEN されていない」ポートを割り当てる。
  起点は環境変数 `STUDIO_BASE_PORT` で変えられるが、GUI アプリには渡しにくい。サイトとポートの一覧は `~/.studio/cli.json`。
- Studio は wp-env の設定を知らない。wp-env が止まっている間に Studio でサイトを作ると、そのポートを取られる。
- **衝突しても起動エラーにならないことがある**。Studio のサイトが `[::1]:<port>`（IPv6）で待ち受け、wp-env（Docker）が
  同じ番号を IPv4 で持つと、両方とも起動に成功し、ブラウザの `localhost` は Studio 側へ繋がる（cart-bridge-jp R3-0j の実例）。
  見分け方は `curl -sI http://127.0.0.1:<port>/` と `lsof -nP -iTCP:<port> -sTCP:LISTEN`。
- Studio の帯域を wp-env が使わなければ、どれも起きない。

## スクリプト

```bash
node <skill>/scripts/ports.js list               # 台帳の一覧（スロットとポート）
node <skill>/scripts/ports.js get [<repo>]       # そのリポジトリのポート（JSON）。未登録なら exit 4
node <skill>/scripts/ports.js assign [<repo>]    # 空いている最小のスロットに登録（登録済みなら何もしない）
node <skill>/scripts/ports.js check [--strict]   # 全リポジトリの設定・Studio・LISTEN 中のポートを台帳と照合
node <skill>/scripts/ports.js ps [--all]         # 起動中の wp-env がどのリポジトリか（--all は停止中も）
```

- `<repo>` はディレクトリ（省略時はカレント）か台帳のキー（`~/Dev` からの相対パス。例 `cart-bridge-jp`、
  `svn-woocommerce-for-japan/trunk`）。開発用ディレクトリが `~/Dev` 以外なら `--root <dir>`（複数可）。
- 台帳は既定で元本の `~/Dev/claude-skills/skills/dev-env/ports.json` を読み、無ければスクリプトの隣のコピーを読む
  （`--ledger` / `DEV_ENV_LEDGER` / `CLAUDE_SKILLS_REPO` で変えられる）。
- `assign` は、台帳で空いているだけでなく、10 ポートのどれかを未登録リポジトリの設定・Studio のサイト・LISTEN 中の
  プロセスが使っているスロットも飛ばす。
- `check` の状態:

| 状態 | 意味 | 対応 |
|---|---|---|
| `ok` | スロットどおり | なし |
| `pending` | 登録済みだが旧ポートのまま（既定の 8888/8889 など） | そのリポジトリで次に起動するときに移行する（下記） |
| `ERROR` | 台帳に無い／自分のスロット以外の 10000 番台を使っている（テンプレートからのコピーなど）／他リポジトリと重複／phpMyAdmin などを両環境で共有／JSON が壊れている | 直す。1 件でもあれば exit 1 |
| `missing` | 台帳にあるが、このマシンに `.wp-env.json` が無い | なし（clone していないだけ） |

  ほかに、Studio のサイトが 10000 番台に入っていれば ERROR、スロットのポートを Docker 以外のプロセスが
  LISTEN していれば WARN を出す。`--strict` は WARN と `pending` も exit 1 にする。

`ps` は、Docker Desktop のコンテナ一覧に出るグループ名（wp-env のインスタンス名）とリポジトリ・スロット・
公開ポートの対応を出す。

- インスタンス名は `~/.wp-env/`（`WP_ENV_HOME`）の下のディレクトリ名で、Docker Compose のプロジェクト名になる。
  旧形式は設定ファイルのパスの MD5（32 桁）、@wordpress/env 11 系（11.15 で確認。10.39 は旧形式）で新しく作った
  環境は `wp-env-<リポジトリのディレクトリ名>-<MD5 の先頭 8 桁>`。`ps` は各リポジトリの両方の名前を計算して照合し、
  一致しなければ WordPress コンテナのマウント元で探す（`matched by its mounts`）。
- スロットと違うポートで動いていれば `not on slot NN`。`--all` は停止中のインスタンスも並べ、リポジトリが見つからない
  ディレクトリ（削除・移動したチェックアウトの名残）は `no repository found` と出る。
- 旧形式のまま 11 系に上げても名前は変わらない（ディレクトリがあれば旧形式を使い続ける）。新形式にするには
  `npx wp-env cleanup` で作り直す必要があり、DB は空になる（ボリュームもプロジェクト名ごと）。残すなら先に
  `wp db export` する。`AUTH_KEY` / `AUTH_SALT` も作り直しで変わるので、それを鍵にした暗号化データ
  （cart-bridge-jp の `TokenStore` など）は復号できなくなる。急がない: ポートはスロットで固定済みなので、
  Docker Desktop の Port(s) 列と `ps` で見分けられる。

起動中の環境を確かめるのは `verify-ports.sh`（リポジトリのルートで、環境を起動した状態で実行する）:

```bash
bash <skill>/scripts/verify-ports.sh             # development + tests
bash <skill>/scripts/verify-ports.sh --dev-only  # tests 環境を見ない
```

| 確認すること | 失敗の意味 |
|---|---|
| コンテナが公開しているポートがスロットと一致する（WordPress・tests・phpMyAdmin があれば） | `.wp-env.json` が未移行、または移行後に再起動していない |
| `127.0.0.1` と `localhost` の両方でログイン画面・tests サイトに届く | `localhost`（ブラウザは `::1` を先に試す）だけ別のサーバーに繋がっている |
| `/wp-admin/` が同じポートのログイン画面へ転送される | Studio などのサイトが `[::1]` で同じ番号を待ち受けている（lsof に映らない場合も、ここで分かる） |
| `siteurl` が development・tests ともそのポート | 再起動していない |
| REST API が `/wp-json/` で応答する | `?rest_route=` だけ応答するなら WARN（パーマリンクが「基本」。`/wp-json/` 形式で登録した OAuth の callback と食い違う） |
| そのポートを待ち受けているのがコンテナランタイムだけ | ほかのプロセスが同じ番号を持っている |

  FAIL が 1 つでもあれば exit 1。台帳に無いリポジトリ・起動していない環境も FAIL。

## 手順

### 新しいリポジトリ（wc-wp-env の手順 3 から呼ばれる）

1. `node <skill>/scripts/ports.js assign "$PWD"` を実行する。元本の台帳に 1 行追記され、ポートが JSON で出力される。
2. 出力されたポートを `.wp-env.json` に書く。
3. `bash ~/Dev/claude-skills/install.sh dev-env` で配置し、claude-skills の差分（`ports.json` の 1 行）を報告する。
4. 起動したら `bash <skill>/scripts/verify-ports.sh` が FAIL 無しで通ることを確かめる。

テンプレートから作ったリポジトリは、テンプレートのスロットのポートを `.wp-env.json` ごと引き継いでいる。
`check` が ERROR にするので、`assign` で新しいスロットを取り、書き換える。

### 既存リポジトリの移行（`check` で `pending`）

1. `node <skill>/scripts/ports.js get "$PWD"` でポートを確認する。
2. `.wp-env.json` のポートを書き換える。既存の書き方（ルートの `port` / `testsPort` か、`env.development` / `env.tests` か）に
   合わせる。`.wp-env.override.json` にポートがあれば消す（中身がポートだけならファイルごと消してよい。gitignore 済み）。
   ほかのマシン・クローンにも同じ override が残っていると、そちらが優先されて旧ポートのまま起動する。プロジェクトの
   環境手順（開発サイクルのスキルの Step 0 など）に「override が残っていれば消す」確認を書く（cart-bridge-jp PR #94 で
   Copilot が指摘）。
3. 旧ポートを決め打ちしている箇所を探して直す:

   ```bash
   grep -rnIE 'localhost:(<旧dev>|<旧tests>)|\b(<旧dev>|<旧tests>|<旧pma>)\b|WP_ENV_(TESTS_)?PORT' . \
     --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git
   ```

   主な対象は、Playwright の `baseURL` や `WP_BASE_URL` の既定値、README・CLAUDE.md・AGENTS.md・開発環境のドキュメント、
   プロジェクト固有のスキル。CI は `.wp-env.json` のポートでそのまま起動するので、Playwright の既定値（下記の
   `WP_BASE_URL` を含む）を揃えれば足りる。
   **Playwright は `baseURL` だけでは足りない**。`@wordpress/e2e-test-utils-playwright` は `WP_BASE_URL` を読み込み時に
   一度だけ読み、`requestUtils.setupRest()` は `RequestUtils.setup()` に渡した `baseURL` ではなくそこから REST のルートを
   引く（未設定なら 8889）。`wp-scripts test-playwright` で起動しているなら `.wp-env.json` の tests ポートを自動で設定する
   ので不要だが、`playwright test` を直接呼ぶリポジトリでは、設定ファイルの先頭（そのパッケージを読み込む前）で
   `process.env.WP_BASE_URL` を設定する（saai-knowledge PR #66 で E2E が `ECONNREFUSED ::1:8889` になった）。
   **過去の記録（レビュー記録・完了済みの計画ログ・ADR など）は書き換えない**。
4. OAuth のコールバック URL など、外部サービスにポート入りの URL を登録しているなら、登録し直しが必要なことを
   ユーザーに伝える（自分では登録しない）。
5. 起動中なら `npx wp-env stop` → `npx wp-env start` で新しいポートに切り替わる（`WP_HOME` / `WP_SITEURL` は
   wp-env が起動時にポートから設定する）。記事本文などに保存済みの旧ポートの URL は残る。直すなら承認を得てから
   `wp search-replace`。
6. `check` でそのリポジトリが `ok` になり、起動した環境で `verify-ports.sh` が FAIL 無しで通ることを確かめる
   （Docker が止まっていて起動できないときは、その旨を報告する）。E2E のワークフローが PR では走らない（夜間・手動実行のみの）
   リポジトリなら、マージ後に `gh workflow run <ワークフロー> --ref main` で一度流し、新しいポートで通ることを確かめる。

### 台帳からリポジトリを外す

元本の `ports.json` から該当行を消す。スロット番号は詰めない（空いたスロットは次の `assign` が再利用する）。
