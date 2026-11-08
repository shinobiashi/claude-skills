# claude-skills

共有スキルの元本。`skills/<name>/` を編集し、`bash install.sh <name>` で `~/.claude/skills/` へ配置する（配置先は直接編集しない）。`bash install.sh --check` で配置先との差分を確かめる。

## 品質チェック（CI は無い）
- 変更したスキルの `scripts/test-*.sh`（偽の `gh` やスタブのツールで動くシナリオテスト。ネットワーク不要）
- `shellcheck -x skills/<name>/scripts/*.sh`
- Python は `python3 -c 'import ast; ast.parse(open("x.py").read())'` で構文だけ確かめる（`py_compile` は `__pycache__` を残す）
- テストを足したら、修正前のスクリプトで落ちることも確かめる。テストの多くは対象スクリプトのパスを引数に取る（`bash test-x.sh <旧版のパス>`）
- ミューテーション検証（review-loop の `mutate-check.sh`）は `--failure-line '^  FAIL - '` を付ける（`test-*.sh` は失敗を `  FAIL - <名前>` で出す）

## PR とレビュー
- コミットは `<type>(<skill>): ...`（例: `fix(dev-cycle): ...`）。変更は `CHANGELOG.md` の `[Unreleased]` に、新しいスキルは `README.md` の一覧にも足す
- `docs/` は無い。dev-cycle・review-loop の記録（`R*.md`・`G*.md`）は既定の `.git/dev-cycle/<ブランチ>/` に置き（コミットしない）、要約を PR 本文とラウンドのコメントに書く
- CI が無いので、dev-cycle の CI 待ち（`--wait-ci`・`--ci-only`）は使わない（`CI=none` で止まる）
- Codex は push では自動レビューしない（`request-gate-review.sh --request-codex`）。Copilot は PR を作った時点で依頼済みになる（PR #2）
