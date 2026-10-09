# Changelog

このリポジトリのスキルに対する変更履歴。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.0.0/)。

## [Unreleased]

### Added
- `release-bump`: 新規。タグ push で wp.org へ自動デプロイするプラグインのリリース作業を 5 つのモードに分けた司令塔:
  `start <ver>`（`release/<ver>` を切って版数ファイルを書き換え、前タグ以降の PR から changelog を起草し、本流へ push して bump PR を作る）、
  `add [<PR>...]`（bump PR を開いた後にマージされた fix PR の changelog 行を release ブランチへ追記）、`check`（版数の不一致・
  changelog の見出し・参照されていない PR・main からの遅れ・POT 再生成の要否）、`sync`（main を release ブランチへ merge。
  rebase + force push はしない）、`tag <ver>`（v 無しのタグを本流だけへ push。必ず AskUserQuestion の後）。
  `scripts/release-bump.sh` が機械的な部分を担う: 現行版数を持つ行を「書き換える行（保存先）」と「触らない行（言及）」に分類し、
  `@since` docblock と changelog 見出しは対象外、`npm version --ignore-scripts` で package.json / package-lock.json、
  `gh pr list` の `mergeCommit` を前タグとの祖先関係で絞り込んで changelog の `#<PR>` / `#<issue>` 参照と突き合わせる。
  シナリオテスト 77 件（`scripts/test-release-bump.sh`、bash 3.2 / BSD awk で動く）。
  背景: Japanized-for-WooCommerce 2.9.17 の bump PR #229 を開いた後に #228・#230 がマージされ、changelog 行を 2 回とも手で
  追記することになった（post-merge の手順 6 で提案 → ユーザー指示で実装）。2026-07-08 に提案した `/release-bump` と統合。
- `ssm-provider`: 新規。Signal Mail for WooCommerce（`saai-signal-mail`）の配信プロバイダを実装・レビューする手順。
  `ProviderInterface` の契約の写し、`SendResult` の retryable 規則、Webhook 検証と `DeliveryEvent` 正規化、`discover_settings()`
  （ADR-0009）、必須 PHPUnit 13 項目と `pre_http_request` モックの雛形、有料アドオンの骨格、`scripts/sign-webhook.php`
  （Svix / 生 HMAC / 無署名で fixture に署名し、`--url` で wp-env へ再生）。コアと Brevo 等のアドオン（別リポジトリ）の両方で使うため共有側に置く。
- `wc-email-editor`: 新規。`woocommerce/email-editor`（PHP 2.18.0）と `@woocommerce/email-editor`（JS 2.5.0）を自前プラグインに
  同梱する手順。3 フィルター（`woocommerce_email_editor_post_types` / `woocommerce_is_email_editor_page` / `replace_editor`）と
  `Assets_Manager` → `initializeEditor()` の統合レシピ、`Renderer::render()` と差し込みタグ、webpack（`@wordpress/ui` と
  `@wordpress/global-styles-engine` は同梱、`__i18n_text_domain__`）と Strauss（`EmailEditor\` と `EmailEditorVendor\` の両方を接頭辞化）、
  WC 本体のブロックメールエディタが有効なときに同梱版を起動しない共存ルール。2026-10-07 に WooCommerce monorepo trunk と
  Packagist / npm で確認。背景: saai-signal-mail ROADMAP U4（SPIKE-1 / PR-17 / PR-18）。
- `wc-block-development`: `references/checkout-payment-method-totals.md` を追加（1.0.0 → 1.1.0）。支払い方法に依存する
  手数料・割引を Checkout Block で扱うときの手引き。WooCommerce 9.8 以降はブロック自身が支払い方法の変更を約 1.5 秒後に
  `PUT /wc/store/v1/checkout?__experimental_calc_totals=true` で送り、`chosen_payment_method` を保存して再計算した
  カートを返す。独自のセッションキーを `extensionCartUpdate` で更新する旧来の方式は、合計の再計算に 1.2 秒以上かかる
  サーバーでこのリクエストと競合する（互いに保存前の値で計算し、セッションは 1 行まとめて上書きされる）。推奨パターン
  （`chosen_payment_method` を読む、注文確定 POST はリクエストの `payment_method` を `rest_request_before_callbacks` で
  先に捕まえる）、版ごとの挙動（9.8 / 10.9 / 11.1.2 のタグで確認）、遅いサーバーの再現方法、Playwright での確かめ方を載せた。
  SKILL.md の用途・参照先・Failure modes にも反映。
  背景: jp4wc-pro #6 の調査で、Checkout Block の代引き手数料が支払い方法の切替に追従しない原因が無料版の独自キー
  `jp4wc_gateway_id` だと分かった（Japanized-for-WooCommerce #215）。
- `wp-playground`: `references/cli.md` の Failure modes に、日本語など英語以外のサイトで REST リクエストが本文 `Internal Server Error` だけの 500 になる件を追加。`WP_DEBUG` 有効時にコアが REST の応答へ付ける
  `X-WP-DeprecatedFunction` / `X-WP-DeprecatedParam` / `X-WP-DoingItWrong` の値が `__()` で翻訳されて非 ASCII になり、
  Node の HTTP サーバーが `ERR_INVALID_CHAR` で拒否する（PHP の error log には何も出ず、CLI の標準出力にだけ出る）。
  テスト用 mu-plugin で `rest_api_init`（優先度 999）に `rest_handle_*` を外す回避策を載せた。
  背景: okatora-shop PR #2 の検証で、PDF Invoices の `wcpdf_get_invoice()`（非推奨）を REST から呼んだら 500 になった。
- `dev-env`: `ports.js ps [--all]`。Docker Desktop がコンテナをまとめて表示するグループ名（wp-env のインスタンス名 =
  `~/.wp-env/` の下のディレクトリ名。旧形式の MD5、または @wordpress/env 11 系の `wp-env-<dir>-<hash8>`）から、
  リポジトリ・スロット・公開ポートを引く。両方の名前を設定ファイルのパスから計算して照合し、合わなければ
  WordPress コンテナのマウント元（`/host_mnt` を除く）で探す。スロット外のポートは `not on slot NN`、`--all` は
  停止中と持ち主の無いディレクトリも出す。シナリオテストを 64 → 75 件に（`DEV_ENV_DOCKER` で docker を差し替え）。
- `dev-env`: `scripts/verify-ports.sh`。起動中の wp-env が台帳のスロットで応答し、ほかのプロセスが割り込んでいないかを
  確かめる: コンテナの公開ポートとスロットの一致、`127.0.0.1` と `localhost` の両方での到達、`/wp-admin/` の転送先、
  `siteurl`、REST（`?rest_route=` だけなら WARN）、待ち受けプロセス（`lsof +c 0`）。4 リポジトリの移行で手書きした
  確認を 4 回繰り返したため切り出した。docker / curl / npx を `DEV_ENV_*` で差し替えるシナリオテスト
  `test-verify-ports.sh`（40 件）。SKILL.md の新規・移行手順と wc-wp-env の手順 6 から呼ぶ。
- `dev-env`: ローカル開発環境のポート台帳を一元管理する新スキル。wp-env を使う各リポジトリに 10 ポートの「スロット」
  （`10000 + NN×10`。+0/+1 が development/tests の WordPress、+2/+3 が phpMyAdmin、+4〜+9 は予備。08 は 10080 が
  ブラウザに拒否されるため欠番）を割り当て、8881〜8999 を WordPress Studio 専用として wp-env から外す。
  - 台帳 `ports.json` に `~/Dev` の 32 リポジトリを登録（現役の cart-bridge-jp / saai-points-wallet / saai-knowledge /
    saai-inventory を 01〜04、残りは名前順に 05〜33）。各リポジトリの `.wp-env.json` は次の起動時に順次移行する。
  - `scripts/ports.js`: `list` / `get` / `assign`（空きスロットへ登録。台帳の空きに加え、未登録リポジトリの設定・
    Studio のサイト・LISTEN 中のプロセスが使うスロットも飛ばす。インストール済みコピーへの書込みは拒否）/
    `check`（全リポジトリの `.wp-env.json` と `.wp-env.override.json` を wp-env と同じ優先順位で解釈し、
    `ok` / `pending` / `ERROR` / `missing` を判定。Studio の `~/.studio/cli.json` と `lsof` も照合）。
    シナリオテスト `scripts/test-ports.sh`（59 件）。
  - 背景（2026-10-01 の調査）: Studio が 16 サイトで 8881〜8896 を使い、wp-env の 8888〜8896 とほぼ全部重なっていた。
    25 リポジトリがポート未指定（8888/8889）、gitignore 済みの override や環境変数で決めたポートは
    `find-free-ports.js` から見えず、cart-bridge-jp（8895）と saai-ten4wc（testsPort 8895）が重複。
    jp4wc-pro / payjp-for-wc の phpMyAdmin が Xdebug の 9003 を、saai-blocks-for-wc は development と tests で
    同じ 9001 を使っていた（起動が失敗する設定）。Studio のサイトが IPv6 の `[::1]` で待ち受けると、
    wp-env は起動に成功したままブラウザの `localhost` が Studio 側へ繋がる（cart-bridge-jp R3-0j）。
- `review-loop`: `mutate-check.sh --allow-dirty`。未コミットの変更があるファイルでも変異検証できる（「前提」章で commit が
  許可されていない R2 や、dev-cycle の確認ゲート前の修正）。
  - 復元の検証は、実行前の控えとの 1 バイト単位の比較（`cmp`）だけになり、未コミットの変更はそのまま残る。
  - no-op の検出も控えとの比較で行い、dry-run の差分は変異の分だけを出す。
  - 強制終了されると `git checkout` では戻せないため、控えの場所を最初に stderr へ出す。
  - 既定（付けない時）は従来どおり clean なファイルに限り、`git diff` でも検証する。拒否時のメッセージで `--allow-dirty` を案内する。
  - 背景: omotegae-project PR #81 で、確認ゲート前の修正を試すために退避→変異→復元を 2 回手書きし、
    控えの置き場所を取り違えて復元に一度失敗した。
  - `--help` はファイル冒頭のコメント全体を出すようにした（行番号の固定をやめた）。シナリオテストを 38 → 55 件に。
- `review-loop`: `mutate-check.sh` が、変異がガードではなくコードを壊した実行（PHP の Parse error・
  `Class "…" not found`・`Call to undefined function`、JS の SyntaxError・ReferenceError）を BROKEN（exit 1）にする。
  `--expect` のテストが落ちていても捕捉と数えない（jp4wc-rakusync P1-S12 で、`use` の無いクラスへの差し替えが全テストを
  落として CAUGHT と読んだ）。`--allow-errors` で解除。`--expect` 以外のテストも落ちたら WARNING と件数を出し、
  `--only` でそれを失敗（NOT CAUGHT CLEANLY）にする。シナリオテストを 27 → 38 件に
- `review-loop`: 配置側（`~/.claude/skills/`）にだけあった `scripts/mutate-check.sh` / `test-mutate-check.sh` と
  SKILL.md の「ミューテーション検証」節を元本に取り込んだ（`install.sh` の `rsync --delete` で消えないように）
- `dev-cycle`: `request-gate-review.sh --wait-ci [--ci-timeout SECONDS]`。依頼の前に PR の現 HEAD の check が
  すべて終わるのを待ち（`gh pr checks --json name,bucket` を 20 秒ごと。既定 480 秒）、green の時だけ依頼する。
  fail / cancel は残りを待たずに、check が 180 秒現れない時・時間切れの時も、何も依頼せず exit 3（`CI=failed|none|timeout`）。
  状態行に `CI=` を追加。jp4wc-rakusync PR #14 で 1 PR に 5 回手書きした「CI 待ち → 依頼」のループを置き換える。
  `--wait-ci` を付けなければ従来どおりで、他プロジェクトへの影響なし
- `dev-cycle`: 引数 `sequential`（任意）を追加。Codex と Copilot を同じラウンドで同時に依頼する既定の流れに対し、
  Codex → Copilot → Codex → … と 1 体ずつ順番に回し、前の bot の修正が入った HEAD を次の bot にレビューさせる
  （各 bot 最大 3 回。収束済み・上限到達・HEAD 不変の bot は飛ばす）。既定は従来どおり同時依頼で、他プロジェクトへの影響なし。
  `request-gate-review.sh` の既存の `--codex-only` / `--copilot-only` を使うのでスクリプトの変更は無い。
- `wc-wp-env`: WooCommerce 拡張のリポジトリに wp-env 環境を「構築」する新スキル（jp4wc-rakusync の
  Phase 0 と saai-points-wallet の `bin/wp-env-setup.sh` を汎用化）。`scripts/find-free-ports.js` が
  兄弟リポジトリの `.wp-env.json` と LISTEN 中のポートから衝突しない組を割り当て、
  `templates/wp-env-setup.sh` が店舗を冪等に初期構築し（HPOS・日本/JPY・決済・送料・サンプルデータ。
  ホストから呼ばれたら自身をコンテナ内で 1 回だけ再実行する）、`scripts/verify-env.sh` が完了条件
  （HTTP 応答・プラグイン有効化・`debug.log` の Fatal・プロビジョニング・HPOS）を判定する。
  使い捨てプラグインで構築→検証→撤去まで実測（@wordpress/env 11.15.0 / WP 7.1.1 / WC 11.1.1）。
  実測で確定した事項を `references/troubleshooting.md` に記録: `Requires Plugins` を宣言したプラグインを
  WooCommerce より前に並べると `wp-env start` が exit 1 で環境ごと立ち上がらない／`wp plugin activate`
  だけで作った店舗は HPOS=no／`wp wc hpos enable --for-new-shop` はデータがあると失敗する／
  `wp-env destroy` は共有 Docker イメージまで消すので作り直しは `cleanup`／`env.tests` は 11.15 で
  非推奨だが `wp-phpunit`・`wp-e2e-playwright`・`woo-marketplace-qit` が `tests-cli` と 8889 を
  前提にしているため当面維持
- `dev-cycle`: `scripts/request-gate-review.sh`（saai-points-wallet の `spw-dev-cycle` で 3 ラウンドの
  bot ゲートを経て検証した版を汎用化）。Copilot の依頼登録を 3 系統の証拠（`requested_reviewers` の
  不在→出現、timeline の `review_requested`、現 HEAD へのレビュー到着）で最大 5 分確認し、両 bot の
  応答を提出時刻ではなく review の `commit_id` で判定する。`--request-codex` で "@codex review" も
  投稿できる。Step 6 の手書き `gh` ループを置き換え、外側 timeout を 1,800,000ms に変更
- `fix-copilot-review`: `gate-threads.sh bodies <PR> [SINCE]`（現 HEAD への Copilot レビュー本文を
  URL / 判定見出し / Suppressed comments 付きで表示）と `status` の本文件数行。Copilot がスレッドを
  立てず本文だけで指摘したレビューを、スレッドと同じ扱いで数えられる。`dev-cycle` の Step 7 も
  この 2 コマンドを使い、Copilot の収束判定に「本文の指摘 0 件」を加えた
- `fix-copilot-review` / `dev-cycle`（Fixed 相当）: `gh api --paginate` の出力を `jq -s` で結合してから
  集計（ページごとの JSON になる場合に `0\n1` のような値を数値比較して誤判定していた）。オブジェクトを
  返す端点（`requested_reviewers`）は平坦化しない。`SINCE` は包含比較（push と同一秒の応答を落とさない）、
  `body: null` のレビューで一覧が失敗しない、jq 欠如時は即終了
- `fix-copilot-review`: `scripts/gate-threads.sh`（`dev-cycle` で実績のあるスレッド一覧・返信・
  Resolve ヘルパーを移植）。返信本文を必ずファイル/stdin から渡すため `gh pr comment --body "..."`
  のシェルエスケープ事故を防ぎ、`done`/`reply` がスレッド ID 1 つから返信先と Resolve 先の両方を
  解決するため取り違えも防ぐ。50 件超のスレッドも自動でページングする
- `wp-phpunit`: `references/wp-testcase-patterns.md` に「不確実なコア挙動を使い捨てテストで実測する」
  手法の節を追加（実例: `WC_Product_Variable::get_price()` が親商品では `''` を返す、
  `DateTimeImmutable::getLastErrors()` が PHP 8.2+ で「報告なし」を空配列ではなく `false` で返す）
- `dev-cycle`: `scripts/gate-round.sh`（`push` / `publish`）を追加。
  ゲートラウンドの手入力だった末尾作業（push 直前の `T` の記録 → push → スレッドごとの返信と Resolve → サマリコメント → 未解決数の確認）
  を 1 本にまとめ、1 つの PR で 5 ラウンド続けて手で回した時に起きやすいずれを防ぐ。
  `push` は push が成功した時だけ `T=` を出力し、main / master の push を拒否する。
  `publish` は返信・サマリのファイルを全部検証してから投稿し、ローカル HEAD が PR の head と違えば（未 push の sha を「修正済み」と案内しないため）
  拒否、途中で失敗したら投稿済みの一覧を出す。`--dry-run` あり。bash 3.2（macOS 標準）
  で動くよう空配列を避け、偽の `gh` / `gate-threads.sh` で 32 ケースを確認する `scripts/test-gate-round.sh` を同梱。
  既存のスクリプトと手順（`gate-threads.sh`、`request-gate-review.sh`、手書きの `git push`）はそのまま使える（追加のみ）

### Fixed
- `dev-cycle`: `gate-round.sh push` が、PR がマージ済み・クローズ済みのブランチにもそのまま push していた。マージの後に
  push したコミットは base に届かず取り残される（Japanized-for-WooCommerce PR #222 で、マージの 2 分後に push した記録用
  コミットを main へ cherry-pick し直した）。push の前に `gh pr list --head <branch> --state all` で PR を引き、PR があって
  開いているものが 1 つも無ければ拒否する（`--allow-closed-pr` で上書き）。PR がまだ無い初回 push は通し、`gh` が答えられない
  時は警告して続行する。あわせて `help` の表示を、行番号の決め打ちからヘッダーコメントの終わりまでに変えた。
  シナリオテストを 32 → 46 件に（マージ済み・クローズ済みで拒否、dry-run でも拒否、同名ブランチの新しい PR が開いていれば通す、
  `gh` の失敗で続行、`--allow-closed-pr`、help の範囲）。
- `dev-cycle`: `request-gate-review.sh` が Codex の「Codex Review Summary」コメント（`<!-- codex-pull-request-review-summary -->`）を
  応答と数え、PR で最初の依頼のときに Codex が実行中（🔄 Running）のまま `CODEX=responded` を返していた。要約コメントは PR ごとに
  1 件の状態表示で、本当の応答（レビュー・「指摘なし」のコメント）の数秒後に ✅ Completed へ書き換えられる。応答の数から外し、
  待ちの各行に `codex-summary=<状態>@<sha>` を出し、時間切れの時は「まだ実行中なので `--wait-only` で待ち直す」か「Completed なのに
  応答が見つからない」かを伝える。あわせて、Codex が説明している「指摘なし」の印である PR 本文への 👍（`T` 以降）を応答に数える。
  シナリオテストを 94 → 107 件に（Running のまま時間切れ、Running の後にレビュー、Completed だけ、別コミットの要約、👍 の新旧）。
  saai-pi4t の PR #5・#6 で発生（要約コメントの編集履歴で Running の実際の文面を確認）。
- `dev-env`: `verify-ports.sh` が @wordpress/env 11.16.0 の環境で必ず「no running WordPress container … (instance '?')」で
  FAIL していた。11.16.0 には `wp-env install-path` が無く（何も出力せず exit 0）、インスタンス名を引けなかったため。
  `install-path` が空なら `wp-env status --json` の `installPath` から引く。シナリオテストを 40 → 47 件に（status からの解決、
  どちらも空、JSON でない出力）。jp4wc-pro の wp-env 再構築（PR #5）で発見し、実機の 11.16.0 で FAIL 無しを確認。
- `dev-env`: `test-ports.sh` の assign のシナリオが、実機で待ち受け中のポートに左右されていた（スロット 11 の wp-env を
  起動していると「10110 is used by squatter」ではなく「listening now (com.docker.backend)」になり 1 件失敗する）。
  assign の 3 回の実行に空の `DEV_ENV_LSOF_OUTPUT` を渡して、実機の状態から切り離した。
- `dev-env`: `ports.js check` が Docker Desktop の待ち受け（`com.docker.backend`）を「コンテナ以外のプロセス」と誤って
  WARN にしていた。`lsof` は既定でコマンド名を 9 文字（`com.docke`）に切り詰めるため、`docker` の一致判定に掛からなかった。
  `lsof +c 0` で全体を取り、判定も `docke` で行う。4 リポジトリを同時に起動した実機の照合で発見。
  テスト用に `DEV_ENV_LSOF_OUTPUT`（lsof 出力のファイル）で実コマンドを差し替えられるようにし、シナリオを 59 → 64 件に。
- `review-loop`: `mutate-check.sh` が Jest のファイル単位の要約行 `FAIL <パス>` を失敗したテストの見出しとして数えていたため、
  狙ったテストだけが落ちても `--only` が「NOT CAUGHT CLEANLY」と誤判定していた。`FAIL` の行はテスト名を含む Vitest 形式
  （`FAIL  file > suite > name`）だけを数える。シナリオテストに実際の Jest の出力形式と Vitest の他テスト失敗を追加（55 → 60 件）。
  背景: cart-bridge-jp PR #87 の Jest 導入時に、`--only` を外して失敗一覧を目で確かめる回避をしていた。
- 配置側（`~/.claude/skills/`）にだけあった 2026-09-24 の編集を元本に取り込んだ（`install.sh` の `rsync --delete` で消えないように）:
  - `dev-cycle`: 初回 push も `gate-round.sh push` で行い、出力の `T` を `--since` に使う。`git log --date=format:` で `T` を作ると
    コミットのタイムゾーンのまま `Z` が付き、JST では 9 時間先になって `gate-threads.sh list/status` が 0 件を返すため
  - `fix-copilot-review`: Copilot の新形式の本文（`<!-- ccr-overview-v2 -->`）に対応。スレッドの無い新規指摘の
    `Previously missed (N)` を本文指摘として評価し、`gate-threads.sh` の `has_findings` に数える。承認系の見出しの下でも入りうる。
    `bodies` はパスに混ざるゼロ幅スペース（U+200B）を除く
  - `post-merge`: ローカルの default に未 push のコミットがあり origin が先へ進んだ時の扱い（内容が origin に含まれていれば
    `git pull --rebase`、含まれなければ確認）と、蒸留を default へ直接コミットしたら次の作業ブランチを切る前に push すること
- `review-loop`: `mutate-check.sh --expect` が Vitest / Jest の失敗見出し（`× name`・`FAIL  file > … > name`・
  `✕ name`・`● Suite › name`）を読めず、捕捉できていても「NOT CAUGHT BY THE NAMED TEST」になっていた（既定は PHPUnit の
  `1) Name` だけだった）。既定の `--failure-line` に加え、シナリオテストを 22 → 27 件に（ロケール C でも通る）。
  jp4wc-rakusync P1-S11（PR #23）で 3 回手で確かめ直した。あわせてテストの `cd` に `|| exit 2`（shellcheck SC2164）
- `dev-cycle`: `scripts/request-gate-review.sh` の Copilot 依頼が登録されない問題。REST の `reviewers[]=Copilot`
  （GitHub が文書化していない値）が 2026-09-21 頃から 201 を返しながら 6 回に 1 回程度しか登録されず
  （jp4wc-rakusync PR #4〜#11。timeline に `review_requested` が出ず、pending にもならず、レビューも来ない。
  同じ PR への Web UI からの依頼は毎回登録された）、未登録のまま 15 分待って exit 2 になっていた。依頼を文書化された
  `gh pr edit <N> --add-reviewer @copilot`（gh 2.88+。Web UI と同じ GraphQL mutation）→ REST
  `copilot-pull-request-reviewer[bot]` の順に改め、登録確認（GraphQL `reviewRequests` と REST `requested_reviewers` の
  pending 一覧・timeline イベント・現 HEAD へのレビュー）を方法ごとに 90 秒、最初の依頼から合計 5 分まで行ってから
  exit 2 にする。2026-09-23 に installed 側で「登録確認は診断のみで待ちを止めない」に変えた版は omotegae-project の
  記録（登録確認が通らないのにレビューが届く）を根拠にしていたが、その PR の timeline には依頼イベントがあり、
  遅かったのは確認手段（60 秒の pending 一覧・数分遅れる timeline）だった。`--wait-only`（UI からの手動依頼の後や
  TIMEOUT 後に待つだけ）、bot ごとの状態行 `COPILOT=` / `CODEX=`（同時依頼で片方だけ応答した時に見分ける）、
  `@codex review` の投稿失敗時の再試行 1 回と「投稿できなければ待たない」を追加。偽の `gh` / `sleep` で
  64 ケースを確認する `scripts/test-request-gate-review.sh` を同梱。SKILL.md の Step 6・順番実行・
  「人間に確認する条件」を更新（exit 2 の選択肢の先頭は「ユーザーが UI から依頼 → `--wait-only` で待つ」）。
  使い捨ての jp4wc-rakusync PR #12 で検証: `gh pr edit` の依頼が 0 秒で pending 一覧に現れ、timeline にも即時に
  `review_requested` が残り、2 分後にレビューが届いて exit 0
- drift の再同期: 2026-09-22〜24 に installed 側（`~/.claude/skills/`）だけを直接編集していた 3 スキルをソースへ
  取り込んだ（`install.sh --check` で検出。`review-loop`・`post-merge` に続く同じ事故）。`dev-cycle`（SKILL.md・
  request-gate-review.sh。上の修正の土台）、`fix-copilot-review`（`gate-threads.sh bodies` が File summaries 表の
  セルに `**Moderate (1 vote):**` 等の重大度付きで書かれた指摘を落とさない。表セルにしか指摘が無い回があった）、
  `wp-org-release`（1.1.0: 審査への応答手順 Step 2b と、提出フォームの説明の無い "Additional Information" 欄の正体
  〔`class-upload-handler.php` で監査ログに残る Upload Comment。通知は飛ばない〕）
- `review-loop`: ソース側に反映されていなかった「R1/R2 で独立サブエージェントを併用する」手順を
  取り込み、`~/.claude/skills/review-loop/SKILL.md`（installed）と再同期。installed 側が
  2026-09-12 頃に直接手編集されソースより進んでいたため、`install.sh` を実行すると
  この手順が失われる drift 状態になっていた（`install.sh --check` で検出）
- `woo-marketplace-extension`: 「メニュー配置」節が「WooCommerce サブメニュー」と「WooCommerce
  Settings タブ」のどちらも単に "OK" とだけ示しており、**設定画面は Settings タブに置かなければ
  ならず、サブメニューは設定を伴わないデータ管理画面専用**という公式 UX Guidelines の区別を
  読み手に伝えられていなかった（実プラグインの実装で見落とし、審査前に手動で発覚）。設定画面用の
  例を `WC_Settings_Page` + `woocommerce_get_settings_pages`（現行 API。旧来の
  `woocommerce_settings_tabs_array` だけの例はタブ表示のみで保存処理が無いため非推奨として残した）
  に差し替え、NG 例と「やってはいけないこと」の1行を追加。あわせて、`WC_Settings_Page` は
  WooCommerce が `WC_Admin_Settings::get_settings_pages()` の中（呼ばれるのは `admin_init` /
  `rest_api_init` / 設定画面の `load-*` フックなど、いずれも `plugins_loaded` より後。WC 11.1 のソースで
  確認）でしか `include_once` しないため `plugins_loaded` 等の早い
  タイミングで直接 `new` すると本番でも fatal する落とし穴（DI コンテナのシングルトン解決で踏みやすい）
  と、その回避策（`woocommerce_get_settings_pages` フィルタのコールバック本体の中で初めて `new` する）
  を明記した

### Changed
- `review-loop`: 各ラウンドの対象を作業ツリーのスナップショットとして記録する `scripts/snapshot.sh` を追加し、R1〜R3 の差分の
  取り方を HEAD 起点からスナップショット起点に変えた。`save R<n>` は未コミット差分と未追跡ファイルを含む作業ツリーを、HEAD を親にした
  コミットとして `refs/review-loop/<branch>/R<n>` に記録する（HEAD・index・ブランチ・ファイルは変えない）。R1 は
  `git diff <base>...refs/review-loop/<branch>/R1`、R2 は `snapshot.sh diff R1 R2` で取る。commit せずに次ラウンドへ進んでも
  前ラウンドの修正だけが取れ、未追跡の新規ファイルも漏れない。シナリオテスト 32 件（`scripts/test-snapshot.sh`）。
  背景: paidy-wc PR #40 で R1 を未コミット差分 + 未追跡の新規スクリプトで始め、R1 の修正も同じ作業ツリーに入ったため、
  R2 の「R1 の修正差分」を保存しておいた patch から作り直すことになった（`git archive` は `export-ignore` の `.claude/`・`docs/` を
  黙って落とした。post-merge の手順 6 で提案 → ユーザー指示で実装）。`dev-cycle` の「review-loop は `git diff main...HEAD` を
  対象にする」という理由の記述も合わせて直した。
- `dev-cycle`: Step 7 の収束判定と終了条件を明記。新規指摘をすべて保留にして修正が無かったラウンドでも、新規指摘があった bot は
  未収束なので、依頼回数が 3 未満なら再依頼する（同じ HEAD を飛ばすのは `sequential` 専用の規則）。再依頼せずに終える時は
  AskUserQuestion で確認し、最終報告の状態に「未収束（ユーザー判断で終了）」と書く。状態の区別に「上限」（3 回目の依頼でも
  新規指摘があった）も追加。背景: Japanized-for-WooCommerce PR #222 で修正なしの G2 の後にゲートを終えたが、ユーザーの指示で
  依頼した G3 で Copilot が同じコードに新規 2 件（「Previously missed」）を出し、Codex はそこで初めて収束した。
- `wc-block-development` / `wc-development`: 確認済みバージョンを WooCommerce 11.1.2（2026-09-22）・WordPress 7.1.2 に
  更新（確認日 2026-10-06。11.2.0 は RC）。`wc-development` の `references/blocks-integration.md` に「支払い方法に依存する
  合計」の節を追加し、`extensionCartUpdate` で独自の支払い方法キーを持たないよう注意書きを入れた。
- `post-merge`: 手順 3「マージ後に確認する項目を拾う」を追加（以降の手順は 4〜7 に繰り下げ）。PR 本文の未チェックの項目
  （`- [ ]`）を抜き出し、マージコミットの CI・手元・確認不能の 3 つに分けて扱う。CI は `mergeCommit.oid` の sha で引き
  （`gh run list --branch <default>` が古い run だけを返したことがある）、実行中ならバックグラウンドで待つ。
  あわせて手順 1・2 に、現在のブランチの PR が未マージだった場合の扱い（直近にマージされた PR を対象にし、作業ブランチから
  離れずに `git fetch origin <default>:<default>` で最新化する）を追記。引数に PR 番号も取れるようにした。
  背景: jp4wc-pro の PR #5 で「PR では走らない E2E をマージ後に確認する」を後始末で拾う必要があり、PR #3 の後始末は
  PR #5 のブランチ上で実行された。
- `wc-wp-env`: `@wordpress/scripts` と `@wordpress/env` 11.x の peer 衝突を手順とハマりどころに追記（troubleshooting §10）。
  `@wordpress/scripts` 30.x は `@wordpress/env ^10` を optional peer に持ち、`^11` を足すと `npm install` は通るのに
  `npm ci` だけが ERESOLVE で落ちる（jp4wc-pro PR #5 の CI で発覚）。手順 4 は `@wordpress/env@^11` と版を明示して
  `npm ci --dry-run` を通し、手順 6 の検証にも加えた。回避は `package.json` の `overrides`。§9 に、11.16.0 では
  `wp-env install-path` が無いことと、`@php-wasm/*` の EBADENGINE 警告（Node 20）を追記。
- `dev-env` / `wc-wp-env`: 4 リポジトリの移行（PR マージ後）で踏んだ点を移行手順に追記。(1) 他のマシン・クローンに残る
  `.wp-env.override.json` が新しいポートを上書きするので、プロジェクトの環境手順に確認を書く（cart-bridge-jp PR #94）。
  (2) `@wordpress/e2e-test-utils-playwright` は `baseURL` ではなく `WP_BASE_URL`（既定 8889）から REST のルートを引くため、
  `playwright test` を直接呼ぶリポジトリでは設定ファイルで設定する（saai-knowledge PR #66）。(3) PR で走らない E2E は
  マージ後に `gh workflow run` で確かめる。
- `wc-wp-env`: ポートの割り当てを dev-env の台帳（`../dev-env/scripts/ports.js`）に切り替え、
  `scripts/find-free-ports.js` を削除。`.wp-env.json` のテンプレートのポートはプレースホルダーに。
  `WP_ENV_PORT` / `WP_ENV_TESTS_PORT` での上書きを案内しないように（CI も `.wp-env.json` のポートで起動する）。
  `references/troubleshooting.md` §5 を Studio との衝突（IPv6 で黙って繋がる件を含む）に合わせて更新。
- `post-merge`: 手順 6 の `/rename`・`/export` の提案に補足を追加。(1) どちらもユーザー個人の参照用で
  あり、手順 4 のリポジトリへの知見蒸留とは目的が違うこと、`/export` の生ログはローカル環境の情報
  （鍵ファイル名・パス等）を含みうるためリポジトリへ自動保存しないこと、(2) `/rename` はスキルから
  実行できないが名付けは代行し、`/rename <名前案>` をそのまま貼れる形で提示すること。
  なお当初 installed 側（`~/.claude/skills/post-merge/`）へ直接編集してしまい drift を作ったため、
  同じ内容をソースへ移植して再同期した（`review-loop` の 2026-09-12 の件と同じ事故。
  スキル実行時に表示される "Base directory" が installed 側を指すので編集先を誤認しやすい）
- `post-merge`: 手順 3・4 に 3 点を追記。(1) squash / rebase マージのブランチは `--merged` に出ず
  `git branch -d` が "not fully merged" で拒否されるため、PR が `MERGED`・ブランチ先端と本流のツリーが同一・
  未 push のコミットが無い、の 3 点をすべて確認してから承認を取って `-D` を提案する、(2) リモートブランチは
  GitHub の自動削除で既に無いことが多いので、`git push origin --delete` の前に `git ls-remote --heads` で
  存在を確認する、(3) リポジトリに `.claude/rules/*.md` がある場合は領域固有の落とし穴をそちらへ追記し、
  CLAUDE.md を再び肥大化させない。なおこれも installed 側へ直接編集して drift を作った後にソースへ移植した
  （直前の項目と同じ事故の再発）
- `fix-copilot-review`: スレッドの Resolve と PR への対応サマリコメント投稿を上記
  `gate-threads.sh` 経由に統一（手順 6・7）。従来は Resolve の GraphQL mutation だけが例示され、
  スレッドへの返信手段そのものが明文化されていなかった
- `dev-cycle`: ゲートラウンドの TIMEOUT を「bot が指摘を出し尽くした」ではなく「応答が待ち時間より
  遅れているだけの可能性が高い」と明記（Codex・Copilot とも push から数時間かかった応答実績あり）。
  3 ラウンドで打ち切って先へ進む場合、状態は「収束」ではなく「未確認」と記録し、最終報告で
  `fix-copilot-review` による後日の再確認を案内するよう変更。修正がコアロジック層に及ぶ場合、
  プロジェクト固有の機械的な不変条件チェックを commit 前に流す手順も追加（レビュー指摘の修正自体が
  新しい規約違反を持ち込み、次のラウンドで指摘され返す事例があったため）
- `fix-copilot-review`: 同様に、修正がコアロジック層に及ぶ場合はプロジェクト固有の機械的チェックを
  commit 前に流す手順を追加
- `fix-copilot-review`: Copilot の review 本文も指摘の取得元に追加。判定見出しが `Needs a closer look` のとき Copilot はインラインコメントを投稿せず（`Comments generated: 0 new`）、指摘を本文の `Suppressed comments`（`Previously missed` 含む）に畳むため、従来の `reviewThreads` だけの取得では取り逃がしていた。手順 2 を「2a スレッド / 2b レビュー本文 / 2c 早期終了判定」に分け、終了条件を「未解決スレッド 0 件 かつ 本文指摘 0 件」に変更。本文指摘は `B<k>` の連番で扱い、Resolve 対象が無いため対応サマリコメントに処理結果を必ず残す（再レビュー時の重複判断防止）。判定が `Needs a closer look` で指摘も無い場合は「人間の確認を求めている」として総評文を提示する
- バージョン表記を 2026-09-09 時点に更新（WP 7.1 / WC 11.1.0、WPCS 3.4.1 + PHPCS 3.13.5、Playwright 1.63 / e2e-utils 1.54、`Tested up to: 7.1`、GitHub Actions を checkout@v7 / setup-node@v7 / cache@v6 / upload-artifact@v7 に）: `wp-github-actions`、`wp-phpcs`、`wp-e2e-playwright`、`wp-phpunit`、`wp-phpstan`、`wp-rest-api`、`wp-plugin-development`、`wp-wpcli-and-ops`、`wp-block-development`、`wp-abilities-api`、`wc-block-development`、`wp-org-release`、`payjp-v2-woocommerce`、`woo-marketplace-qit`（CI 例）
- `wp-abilities-api`: WordPress/agent-skills trunk（d87ee69）の更新を取り込み。`references/php-registration.md` を新 API 形（`execute_callback`、必須 `permission_callback`、`meta.annotations`、`meta.mcp.public`、ID は `plugin/verb-noun`）に置換し、参照 7 本（domain-vs-projection、grouping-heuristic、shared-core-service、plugin-family-patterns、error-code-vocabulary、input-schema-gotchas、delegate-helper-pattern）を追加。ローカル加筆（6.9 でコア入り、JS パッケージ 2 種）は維持

## 2026-09-09 — 初回統合

### Added
- リポジトリ新設。`~/.claude/skills/` に散在していた 37 スキルを `skills/` に集約し、`install.sh`（`--check` で差分検出）を追加
- 新規: `adr`（ADR 起票・Supersede）、`wc-action-scheduler`（Action Scheduler 4.1 の API・チャンク処理・PHPUnit）、`saai-admin-react`（SAAI 流 React 管理画面）
- 汎用化して追加: `dev-cycle`、`check-pr`、`ci-triage`（各プロジェクト固有版から固有名を除去し、コマンドは CLAUDE.md / composer.json から読む）
- WordPress/agent-skills（trunk d87ee69, 2026-08-16）から `wp-plugin-directory-guidelines`、`wp-playground`、`blueprint` を取り込み

### Changed
- `wc-development`、`woo-marketplace-extension` / `-submission` / `-qit` / `-content` / `-pricing`、`wp-security-check`: 各プロジェクトに分岐していた版を日本語系（saai-knowledge / saai-ten4wc）をベースに統合し、payjp-for-wc 系の事実（QIT 自動テスト、価格ルール、商標、SaaS Billing API、HPOS sync-on-read、Fulfillments API、PCI DSS 4.0.1）を移植。公式ドキュメントで再確認し、WP 7.1 / WC 11.1.0 / qit-cli 1.3.1 / Plugin Check 2.1.0 / WPCS 3.4.1 に更新
- `woo-marketplace-qit`: Plugin Check を「任意」、PHPStan を「推奨」に（公式の提出時必須リストに基づく）。CLI フラグを `--plugin` / `--test-package` に修正
- `woo-marketplace-pricing`: 価格表を公開 API で再検証。「マーケットプレイスを安くする」戦略は公式ルール（シングルサイト価格と揃える）と矛盾するため削除。`scripts/analyze_competitors.sh` を API ベースに置換
- `review-loop`: APPROVE 条件を「R1 の Critical/High/Medium 全解消 かつ 新規 Critical/High ゼロ」に強化。CLAUDE.md の絶対ルールを第一級のレビュー観点に

### Removed
- `~/.claude/commands/wp-security-check.md`（9 行の旧コマンド）は同名スキルに統合

## 2026-05-22 — saai-blocks-for-wc バンドル（前身）

- `wc-block-development`、`wp-i18n`、`wp-org-release`、`wp-phpcs`、`wp-phpunit`、`wp-github-actions`、`wp-e2e-playwright` 1.0.0 を `saai-blocks-for-wc/.claude/skills/` に `install.sh` 付きで配置（本リポジトリの前身）
