# わざと誤りを入れて検出力を確かめる

`rules-diff.py` は設定を比べるが、設定が正しくても実際に検出するとは限らない（対象のパスから外れている、プラグインが読めていない）。
ツールの major では、**PR の worktree に誤りを置いて、プロジェクトの実際のコマンドが落ちることを確かめる**。

#54 の生のコミットでは、次の 1 行が exit 0 で通った。設定の差分と同じ問題を、別の角度から確かめられる。

```ts
export const x = __( 'Hello', 'wrong-domain' );
```

## 手順

1. worktree の、**lint の対象に入るディレクトリ**にファイルを置く。ignore されたパスに置くと、検出されなくて当然なので確認にならない。
2. `npm run lint:js` のように CI と同じコマンドを実行する。ファイル名を渡せるなら絞ってよい（`npx wp-scripts lint-js <path>`）。
3. **終了コードが 0 以外で、かつ狙ったルール名が出る**ことを確かめる。別の理由で落ちているなら確認になっていない。
4. 置いたファイルを消す（`rm -f "${S:?}/pr54/<置いたファイル>"`。`$S` を裸で書くと、Claude Code の安全チェックに止められる）。worktree は使い捨てなので、ユーザーのチェックアウトには残らない。

main の worktree でも同じ誤りを試して、そちらで検出されるなら、PR で失われた検出力だと確定する。

## 置くもの

プロジェクトの text domain・ディレクトリに読み替える。使っているツールだけでよい。

| ツール | 置くもの | 期待する結果 |
|---|---|---|
| ESLint（i18n） | `__( 'Hello', 'wrong-domain' )` | `@wordpress/i18n-text-domain` |
| ESLint（テスト） | `*.test.tsx` に `it.only( 'a', () => {} )` | `jest/no-focused-tests` または `vitest/no-focused-tests` |
| TypeScript | `const n: number = 'x';` | `TS2322` |
| Stylelint | `a { color: #ggg; }` | `color-no-invalid-hex` |
| PHPCS（エスケープ） | `echo $_GET['x'];` | `WordPress.Security.EscapeOutput`・`WordPress.Security.ValidatedSanitizedInput` |
| PHPCS（国際化） | `__( 'x', 'wrong-domain' );` | `WordPress.WP.I18n.TextDomainMismatch` |
| PHPStan | 存在しないメソッドの呼び出し | `method.notFound` |
| Jest / Vitest | `expect( 1 ).toBe( 2 );` | テストが 1 件失敗する。`Tests: 0 total` なら起動していない |
| PHPUnit | `$this->assertTrue( false );` | テストが 1 件失敗する |
| E2E ヘルパー（型チェックの対象なら） | `tests/e2e` に、ヘルパーの存在しないメソッドの呼び出し | `check-types` が `TS2339` で落ちる |

テストの実装を変えたときは、`review-loop` の `mutate-check.sh` で「ガードを壊すとテストが落ちる」ことも確かめられる（#54 では jsdom の変更に合わせて書き換えたテストをこの形で確かめた）。

## 差分の読み方の例

#54 の修正後（`rules-diff.py` の `eslint`）に残った項目:

| 項目 | 読み方 |
|---|---|
| `LOST: no-with, jsx-a11y/heading-has-content` | 上流の共有設定から外れた。意図的なら報告に書いて通す |
| `gained: @wordpress/no-unsafe-render-order` など | 新しいルール。CI が緑なら現状は違反なし |
| `OPTIONS changed: no-console` など | 共有設定の形式の変化が多い。件数が多いときは `--json` で中身を見る |

逆に、#54 の修正前の出力は `CONFIG SOURCE` が先頭に出た。これが出ている間は、ルールの増減を見ても意味がない。比べている設定がプロジェクトのものではないからだ。
