---
title: 0016. frontmatter抽出スクリプトの走査方式にgit ls-filesを採用する
type: ddr
description: extract-frontmatter.shのファイル列挙を、findベースからgit ls-filesベースへ置き換え.gitignoreに対応した経緯を記録したDDR
tags: [extract-frontmatter, gitignore, ddr]
keywords: [git ls-files, find, git check-ignore, 参考ディレクトリ, index.jsonl, タイムアウト, issue-54, issue-43]
---

# 0016. frontmatter抽出スクリプトの走査方式にgit ls-filesを採用する

## 背景

`.claude/scripts/src/extract-frontmatter.sh` は指定ディレクトリ配下を `find "$target_dir" -type f
-name '*.md'` で再帰走査していた。このfindは`.gitignore`を一切考慮しないため、`参考ディレクトリ/`
（`.claude/rules/directory-structure.md`が定める、外部OSSをローカルにcloneする場所。`.gitignore`
対象）のような大量のmarkdownファイルを含むディレクトリが存在すると、そこまで走査対象に含めて
しまう。issue #43対応時の実機確認で、リポジトリルート（`.`）に対する一括実行が2分以上かかり
タイムアウトし、書き込み中だった`index.jsonl`が末尾の行を欠いたまま壊れた状態で残ることが
判明していた。issue #54でこの問題の解消に着手した。

## 決定

**`find`ベースのファイル列挙を`git ls-files --cached --others --exclude-standard`ベースへ
置き換える（方式A）。**

```diff
-  done < <(find "$target_dir" -type f -name '*.md' -print0 | sort -z)
+  done < <(git ls-files --cached --others --exclude-standard -z -- "$target_dir" | grep -z '\.md$' | sort -z)
```

`--cached`（トラッキング済み）と`--others --exclude-standard`（未トラッキングだが`.gitignore`
非対象）を組み合わせることで、`.gitignore`にマッチするファイル・ディレクトリは列挙自体の対象に
ならない。**走査自体が発生しない**ため、issue #43で判明した「巨大な`.gitignore`対象ディレクトリに
よるタイムアウト・破損」を根本から解消できる。

### 実機検証結果の要約

スクラッチパッドに`.git`初期化済みの一時リポジトリ（`.gitignore`で`/usage/`・`/参考ディレクトリ/`
を除外）を作り、現状の`find`ベース実装と、走査部分のみ置き換えたパッチ版を比較した
（詳細な検証手順・結果は`plans/reflective-zooming-cake.md`の「調査結果」節を参照）。

- `.gitignore`対象ファイルが候補集合から完全に除外され、生成された`index.jsonl`の
  `concept_id`/`directory`/`frontmatter`/`mtime`は現状版とバイト単位で完全一致した
  （`target_dir`が`.`／サブディレクトリ／絶対パス／ignore対象ディレクトリ自身のいずれでも
  正しく動作）。
- `参考ディレクトリ/`配下に3,000件のダミーmarkdownを追加した状態で比較したところ、`find`は
  3,005件を訪問（0.94秒）したのに対し、`git ls-files`は2件のみを訪問（0.54秒）に留まった。
- `tests/test_extract_frontmatter.sh`が検証する既存関数（`frontmatter_to_json`,
  `resolve_repo_root`, concept_id/directory算出ロジック）への影響は無く、`main()`内の走査行1行の
  置き換えのみで完結した（実装後、`bash tests/test_extract_frontmatter.sh`で回帰無しを確認）。

## 却下した案

- **方式B: `find`維持＋`git check-ignore`による事後フィルタ**（`find`の出力を
  `git check-ignore --stdin -z -v`で判定し、ignore対象を除外する案）。ignore対象の除外自体は
  正しく行えることを実機確認したが、**`find`自体が`.gitignore`対象ディレクトリを含め全ファイルを
  再帰的に訪問してしまう**ため、issue #43由来の根本課題（大量ファイルによる走査コスト・
  タイムアウト・破損）を解消できない。事後フィルタは「正しさ」は満たすが「性能」を満たさないため
  不採用とした。

## 既存DDRとの関係

`.claude/scripts/docs/ddr/0008-frontmatter抽出スクリプトの設計判断.md`は「出力単位」
「concept_id基準」「YAML解析方式」の3点のみを扱っており、走査方式（ファイル列挙のロジック）は
対象外だった。DDR 0008は既にマージ済みで追記不可のため、走査方式という別トピックの決定として
本DDRを新規に追加した。
