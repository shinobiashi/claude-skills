---
name: adr
description: >
  ADR（Architecture Decision Record）を起票・更新・Supersede するスキル。
  「ADR を起票して」「ADR-000X を書いて」「この設計判断を記録して」「ADR にして」
  「ADR を Superseded にして」「既存 ADR と矛盾しないか確認して」などと言われたら使う。
  リポジトリ既存の ADR 規約（docs/ADR か docs/decisions か、見出し構成、Status 行の書式、
  言語）を自動検出して踏襲し、README の一覧表も更新する。設計変更を伴う実装の前に
  「先に ADR を」と判断したときにも積極的に使う。
compatibility: "リポジトリに docs/ADR/ または docs/decisions/ があることを想定。無ければ docs/ADR/ を新設する。git commit は行わない。"
---

# adr — 設計判断の記録

「なぜそう決めたか」を後から再現できる形で残す。コードコメントや PR 本文は代替にならない。

## いつ ADR を書くか

次のいずれかに該当したら、実装より先に ADR を起票する。

- 外部依存（ライブラリ、サービス、API）の追加・置換
- データモデル・テーブル・メタキーの形の変更
- 公開契約の変更（フック、REST エンドポイント、インターフェース、設定キー）
- セキュリティ・暗号・認証方式の決定
- ライセンス・課金・ティア挙動の決定
- **既存の Accepted な ADR と矛盾する実装**（この場合は必ず Supersede）
- REQUIREMENTS や CLAUDE.md の「決定:」と書かれた未確定事項を確定するとき

## 手順

### 0) 規約の検出（毎回）

1. `docs/ADR/`、`docs/adr/`、`docs/decisions/` の順に探す。見つかった場所を採用する。
2. その中の `README.md`（一覧表）と最新の ADR を読み、次を控える:
   - ファイル名規則（例: `0007-prepaid-product-type.md`。番号 4 桁、slug は英語 kebab-case）
   - 見出し構成（例: `Context / Decision / Options Considered / Consequences`、または MADR の
     `Status / Context / Decision / Consequences / Alternatives / References`）
   - Status 行の書式（例: `**Status:** Accepted　**Date:** YYYY-MM-DD　**Deciders:** 名前`）
   - 本文の言語（日本語 / 英語）
3. 次の番号 = 既存の最大番号 + 1。
4. `CLAUDE.md` に ADR に関する規則（「既存 ADR と矛盾する実装をしない」など）があれば従う。

### 1) 材料を集める

ユーザーの依頼と、関連ドキュメント（REQUIREMENTS / ARCHITECTURE / DATA-MODEL / Issue / PR）から:

- **Context**: なぜ今決める必要があるか。制約（互換性、法規制、性能、既存 ADR）。
- **Options**: 最低 2 案。各案の複雑さ・リスク・影響範囲を表にする。
- **Decision**: 採用案を 1〜3 文で。実装上の要点（キー名、クラス名、フック名）を含める。
- **Consequences**: 良い点・悪い点・追随して更新が必要な文書（設定キー一覧、公開フック一覧、
  データモデル、readme の注意書き）と、フォローアップ作業。
- **Status**: ユーザーが承認するまで `Proposed`。承認後 `Accepted`。

不足があれば推測で埋めず、ユーザーに 1 回でまとめて質問する。

### 2) 矛盾チェック

既存 ADR の Decision をすべて読み、今回の決定と衝突するものを列挙する。

- 衝突あり → 新 ADR の Context に「ADR-XXXX を Supersede する理由」を書き、旧 ADR の
  Status を `Superseded by ADR-NNNN` に書き換え、双方向にリンクする。
- 衝突なし → その旨を報告に 1 行書く。

### 3) ファイルを書く

- `NNNN-slug.md` を検出した規約どおりに作成する（見出し構成・言語・Status 行を踏襲）。
- 設定キー・公開フック・テーブル定義に影響する場合、該当ドキュメント（例: REQUIREMENTS §4、
  ARCHITECTURE §5、DATA-MODEL）の更新箇所を Consequences に列挙する。ADR と同じ PR で
  更新するのが原則。
- `README.md` の一覧表に行を追加する（番号・タイトル・Status）。Supersede した場合は
  旧行の Status も更新する。

### 4) 報告と承認

- 作成・変更したファイルのパスと、矛盾チェックの結果を報告する。
- **git commit / push はしない**。ユーザーが承認したら Status を `Accepted` に変え、
  コミットはユーザーの指示を待つ。

## テンプレート（規約が検出できない場合の既定）

```markdown
# ADR-NNNN: タイトル（決定内容が分かる 1 文）

**Status:** Proposed　**Date:** YYYY-MM-DD　**Deciders:** 名前

## Context
（背景、制約、関連する要件・ADR）

## Decision
（採用した案と要点）

## Options Considered
| | A: 採用案 | B: 代替案 | C: 代替案 |
|---|---|---|---|
| 複雑さ | | | |
| リスク | | | |
| 影響範囲 | | | |

## Consequences
- 良い点:
- 悪い点 / 引き受けるリスク:
- 追随して更新する文書:
- フォローアップ:
```

## やってはいけないこと

- 既存 ADR を黙って書き換える（Supersede 以外で Decision を変えない）。
- 1 つの ADR に複数の独立した決定を詰め込む。
- 選択肢を 1 つしか書かない（「他に無かった」なら、その理由を Options に書く）。
- ADR の番号を飛ばす、既存番号を再利用する。
