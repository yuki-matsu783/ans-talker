---
title: ドキュメント横断検索スクリプト（search-frontmatter.sh）
type: spec
description: frontmatterのindex.jsonlを結合してtype/tags/keywords/パス/フリーテキストで横断検索するスクリプトの仕様
tags: [search-frontmatter, doc-search, jsonl, spec]
keywords: [index.jsonl, frontmatter, 横断検索, concept_id, jq, 絞り込み, 並び替え, 出力形式, grep代替, dwidth]
---

# ドキュメント横断検索スクリプト（search-frontmatter.sh）

## 背景・目的

issue #38対応。`.claude/scripts/src/extract-frontmatter.sh` が**ディレクトリごとに**
`index.jsonl` を出力していた（仕様: [extract-frontmatter.md](extract-frontmatter.md)）が、
結合された単一のインデックスも、検索の入口となるスクリプト・スキルも存在しなかった。
`extract-frontmatter.md` は `index.jsonl` を「将来的な検索・ツール連携の基盤」と位置づけて
いたにもかかわらず、実際に検索する手段が無かったため、AIエージェントがドキュメントを探す際は
そのつど `grep` / `find` による全文探索を行っていた。

このスクリプトは、**index.jsonlの最新化 → 全index.jsonlの結合 → 絞り込み・並び替え・整形**を
1コマンドで完結させ、ドキュメント探索の第一手段を全文探索からインデックス検索へ移す
（方針の位置づけ・却下案:
[0049-ドキュメント探索はfrontmatterインデックス検索を第一手段にする.md](../ddr/0049-ドキュメント探索はfrontmatterインデックス検索を第一手段にする.md)）。

呼び出し側（AIエージェント）向けの手順・jqレシピは `.claude/skills/doc-search/SKILL.md` が持つ。
本ファイルはスクリプトの仕様のみを扱う。

## 仕様

### 実行方法

```bash
bash .claude/scripts/src/search-frontmatter.sh [オプション]
```

引数はすべて任意で、無指定なら全ドキュメントを `concept_id` 順に表形式で出力する。

### 処理の流れ

1. **index.jsonlの最新化**: `extract-frontmatter.sh <対象ディレクトリ>` を呼ぶ（`--no-refresh`
   で省略可）。`extract-frontmatter.sh` は「1件でも行の生成に失敗したら非ゼロ」という規約のため、
   **失敗しても検索自体は続行する**（stderrへ警告を出し、既存のindexで検索する）。古い
   インデックスでも、検索できないよりはよいという判断。
2. **index.jsonlの列挙**: リポジトリルート（または `--dir` の値）から `find` で `index.jsonl` を
   集める。`find` はGit管理の有無を見ないため、**`index.jsonl` がGit管理下にある場合
   （issue #36以前）と `.gitignore` 対象の生成物である場合の双方で動く**（`git ls-files` を
   使うと後者で1件も拾えない）。
3. **絞り込み・並び替え・整形**: 集めた `index.jsonl` を**jqの入力ファイルとして直接渡し**、
   1回のjq呼び出しで処理する。

### 探索から外すディレクトリ

パスの構成要素が次のいずれかに一致する `index.jsonl` は使わない（完全一致で判定するため、
`rebuild/` や `.github/` は巻き込まれない）。

| 名前 | 理由 |
|---|---|
| `.git` | Gitの内部ディレクトリ |
| `node_modules` | 依存パッケージ |
| `build` | ビルド成果物（`.gitignore` 対象） |
| `.gemini` | **配下が `.claude` 配下へのローカルリンク**（シンボリックリンク／NTFSジャンクション）であり、外さないと同じドキュメントが `.claude/...` と `.gemini/...` の2通りの `concept_id` で二重にヒットする（[0017](../ddr/0017-gemini配下はGit管理下に置かずセットアップスクリプトで生成する.md)） |

加えて、jq側で `unique_by(.concept_id)` により重複を1件へ畳む（上記のリンク以外の経路で同じ
`concept_id` が二重に現れた場合の保険）。

### 絞り込みオプション

**同じオプションを繰り返すとOR、異なるオプション同士はAND**。値の大文字小文字は無視する
（`ascii_downcase` による。日本語は影響を受けない）。

| オプション | 対象 | 一致の種類 |
|---|---|---|
| `--type <値>` | `frontmatter.type` | 完全一致 |
| `--tag <値>` | `frontmatter.tags` の要素 | 完全一致 |
| `--keyword <値>` | `frontmatter.keywords` の要素 | 完全一致 |
| `--path <部分文字列>` | `concept_id` | 部分一致 |
| `--text <部分文字列>` | `concept_id` ＋ `mtime` ＋ **frontmatter配下のすべての値**（キー名は含まない） | 部分一致 |
| `--since <ISO8601>` | `mtime` | 以上（文字列の辞書順比較） |
| `--until <ISO8601>` | `mtime` | 以下（同上） |

- **タグのANDはスクリプトでは表現しない。** 複数タグをすべて持つものを探す場合は
  `--format jsonl` の出力をjqへ渡す（レシピは `doc-search` スキルが持つ）。オプションの
  組み合わせ規則を「同一オプションはOR／異なるオプションはAND」の1文に保つことを優先した。
- **`--until` は日付のみ（`YYYY-MM-DD`）で与えられた場合、`T23:59:59` を補ってから比較する。**
  `mtime` は `2026-08-05T00:00:00` 形式で比較が辞書順のため、補正しないと
  `"2026-08-05T00:00:00" > "2026-08-05"` となり、**指定した当日に更新されたファイルが1件も
  残らない**（直感に反する。実装時のテストで検出した）。`--since` は日付のみでもその日の
  00:00:00 以上になるため補正しない。
- 絞り込みの値に**改行を含めることはできない**（jqへは改行区切りの1文字列として渡すため）。

### 並び替え・件数

| オプション | 意味 |
|---|---|
| `--sort path\|mtime\|type\|title` | 並び替えキー。既定は `path`（`concept_id` 順） |
| `--reverse` / `-r` | 並び順を逆にする |
| `--limit <N>` | 先頭N件のみ。0以下・未指定なら全件。**並び替えの後に効く** |

既定を `path` にしたのは、同じ条件なら常に同じ順で返る（出力の差分が取りやすい・AIが結果を
再利用しやすい）ことを優先したため。更新の新しい順は `--sort mtime -r` で得られる。

`type` / `title` で並べる場合は、値が同じレコードの順が実行ごとに変わらないよう、第2キーとして
`concept_id` を使う。`frontmatter` が無い（`null`）レコードは空文字列として扱われ、昇順では
先頭に来る。

### 出力形式

| `--format` | 内容 |
|---|---|
| `table`（既定） | `type` / `concept_id` / `title` を桁揃えして1行1件 |
| `path` | `concept_id` のみ。Readツール等へそのまま渡す用途 |
| `detail` | 1件を複数行で。type/title/description/tags/keywords/mtime |
| `json` | 全件を1つのJSON配列で（整形済み） |
| `jsonl` | 1行1JSON。さらにjqで加工する用途 |
| `count` | `matched=<絞り込み後・`--limit`打ち切り前> [shown=<実際の出力件数>] total=<重複排除後の全件>` の1行のみ。`shown=` は `--limit` で実際に打ち切られたときだけ付く |

`table` の桁揃えは、jqの `length` が**Unicodeのコードポイント数**を返すため、そのまま使うと
日本語（全角）を含む `title` / `concept_id` で列がずれる。CJK統合漢字・かな・ハングル・全角記号の
範囲にある文字を幅2として数え直す `dwidth` を定義して用いる（jqの文字列リテラル中の `\uXXXX` は
実文字へ展開されるため、そのまま文字クラスの範囲指定として使える）。

### その他のオプション

| オプション | 意味 |
|---|---|
| `--dir <パス>` | このディレクトリ配下だけを対象にする（最新化・列挙の両方が絞られる）。**相対パスはカレントディレクトリではなくリポジトリルート基準**で解決する（`main` が先に `cd "$repo_root"` するため） |
| `--no-refresh` | `extract-frontmatter.sh` の呼び出しを省く |
| `--quiet` / `-q` | 件数サマリ（stderr）を出さない |
| `-h` / `--help` | 使い方を表示して終了する |

### 出力先と終了コード

- **stdout**: 検索結果のみ。
- **stderr**: 件数サマリ `matched=N total=N indexes=N`（`--quiet` で抑止）と、最新化失敗・
  index.jsonl不在の警告。
- **終了コード**: 検索できれば0（**該当0件でも0**）。引数不正・gitリポジトリ外・`--dir` の
  ディレクトリ不在のみ1。0件を非ゼロにしないのは、`set -e` 配下の呼び出し側が0件で止まらない
  ようにするため（`check-base-conflicts.sh` が「コンフリクトの有無」を終了コードで表さないのと
  同じ方針）。

## 実装上の判断

### jqプログラムは固定文字列にし、条件はすべて `--arg` で渡す

利用者の入力でjqプログラムを組み立てると、`--text '"'` のような値でフィルタ自体が壊れる。
条件は改行区切りの1文字列にまとめて `--arg` で渡し、jq側で `split("\n")` する。

`--arg` を使うのは `--args`（位置引数）を避けるためでもある。`--args` の場合、`-A` のように
**ハイフンで始まる値**をjqがオプションとして解釈しないよう、フィルタ直後に `--` を置く必要が
ある（`.claude/rules/shell-script-style.md`「JSON操作」。issue #69で実際に踏んだ）。`--arg` は
値を必ず次の引数として読むため、この問題が起きない。

また、`--args` を使うと残りの引数がすべて位置引数になり、**`index.jsonl` をjqのファイル
オペランドとして渡せなくなる**。データをjq自身にファイルから読ませる形（`.claude/rules/
shell-script-style.md`「大きなJSONを`--argjson`等でjqへ渡さない」）を保つうえでも `--arg` が適する。

### 外部プロセスの起動回数

検索1回あたりのjq起動は**2回**（結果の出力用と件数サマリ用）で、`index.jsonl` の数・ドキュメント
数に比例しない。`index.jsonl` の列挙は `find` 1回で、除外判定（`sf_is_excluded_path`）は
`case` のグロブのみで行うためforkしない（`.claude/rules/shell-script-style.md`
「外部プロセス起動のコスト」）。

件数サマリは `--format count` と**同じjqプログラム**を使い回すため、集計ロジックは1箇所しかない。

### jqの `any(gen; cond)` の中では `.` がgeneratorの値を指さないことがある

部分一致の判定を当初 `any($needles[]; $h | contains(.))` と書いていたが、`$h |` の右側では
`.` が `$h` へ差し替わるため `contains($h)` と等価になり、**部分一致の条件が常に真（＝全件
ヒット）**になっていた。generatorの値は先に `. as $n` で束縛してから使う。

```jq
# 悪い例（常に真になる）
any($needles[]; $h | contains(.))
# 良い例
any($needles[]; . as $n | $h | contains($n))
```

この不具合は「絞り込みが効かず全件返る」という形で出るため、**条件を1つだけ指定した状態では
一見それらしい件数が返り**、気づきにくい。単体テストでは「部分一致で全件ヒットしないこと」を
明示的に検証している。

### 引数の検証を省くと、誤りが「該当0件」に化ける

値を取るオプションを `--type) types+=("${2-}"); shift 2 ;;` とだけ書くと、2通りの形で**無言の
誤動作**になる。

| 誤り | 検証が無い場合の挙動 |
|---|---|
| 値の省略（`--type` で終端） | `shift 2` が失敗し `set -e` でシェルごと終了。バリデーションにも `usage` にも到達せず、**何も出力しないまま exit 1** |
| 値の位置に別のオプション（`--type --quiet`） | `--quiet` が値として食われ、`matched=0` の**正常終了**になる |

本スクリプトは「該当0件」を正常終了（exit 0）としているため、後者は**タイプミスと「該当なし」が
区別できない**。呼び出し側（AIエージェント）は「ドキュメントが無い」と解釈して `grep` へ
フォールバックしてしまう。`sf_validate_option_value` で両方を弾く。

弾くのは `--` で始まる値だけにする。`--text -A` のように**ハイフン1つで始まる値**は実在の
検索語（`keywords: [git add, -A, pathspec]` 等）のため通す。裏返しとして、`--` で始まる文字列
そのものは `--text` の検索語にできない。

### 規約違反のレコードが混ざっていても落ちない

`tags: workflow` のようにリストで書かれていないfrontmatterは、`extract-frontmatter.sh` の
パーサ上は文字列としてそのまま `index.jsonl` へ入る。本スクリプトは**規約違反の洗い出し**も
用途に掲げている（`doc-search` スキルのjqレシピ）ため、**規約違反のレコードが混ざった状態で
使われることが想定内**である。配列キーへのアクセサ（`arr_raw`）でスカラーを配列へ包み、
どの出力形式でも落ちないようにする。

jqはストリーミング出力するため、この種の型エラーは**途中まで出力したうえで落ちる**（部分的な
結果とエラーが同時に出る）ことに注意する。

## 影響範囲

- 新規: `.claude/scripts/src/search-frontmatter.sh`、`.claude/skills/doc-search/SKILL.md`、
  `.claude/scripts/test/test_search_frontmatter.sh`、本ファイル、
  [DDR 0049](../ddr/0049-ドキュメント探索はfrontmatterインデックス検索を第一手段にする.md)。
- 変更: `AGENTS.md`（ドキュメント探索の第一手段を定めるルールを追加）、
  `.claude/rules/markdown-frontmatter.md`（`index.jsonl` を検索インデックスとして使う旨を追記）、
  `.claude/docs/README.md`（spec一覧へ本ファイル、DDR一覧へ0048を追加）、
  `index.md`（スキル一覧へ `/doc-search` を追加）、
  `.claude/skills/apply-mr-workflow-to-project/SKILL.md`（展開されるAI資産の一覧へ追記）、
  `HANDOFF.md`。
- `extract-frontmatter.sh` および `index.jsonl` の形式は**変更していない**（読み取り専用で利用する）。

## 設定項目

固有の設定ファイルは持たない。対象ディレクトリはリポジトリルート（`git rev-parse --show-toplevel`）
から決まり、`--dir` で絞れる。探索から外すディレクトリはスクリプト冒頭の `SF_EXCLUDED_DIRS`
（`.git node_modules build .gemini`）で定める。`find` の `-prune` 条件はこの変数から組み立てる
ため、**追加するときに書き換える場所は1箇所だけ**である（走査打ち切りと除外判定でリストが
二重管理になっていると、片方にだけ追記したときに「除外は効くが走査は続く」または
「specに書いていないディレクトリが黙って探索対象から外れる」のどちらかになる）。

## 未決定事項・懸念点

- **本文は検索対象にできない。** `index.jsonl` はfrontmatterしか持たないため、本文中の語を探す
  用途は引き続き `grep` / `rg` が担う。frontmatterの `description` / `keywords` の質がそのまま
  検索の質になるため、規約（`.claude/rules/markdown-frontmatter.md`）に沿った付与が前提になる。
- **タグの語彙は統制されていない。** `tags` は各ファイルの作成時に自由に決めており、同義語
  （`doc` / `docs`）や表記ゆれが混ざりうる。現状は `doc-search` スキルのjqレシピ（タグの一覧と
  出現回数）で既存語彙を確認する運用に留め、統制語彙リストの導入は行っていない。
- **ディレクトリ名に改行を含むリポジトリは対象外。** `index.jsonl` の列挙は `find -print`
  （改行区切り）で受けている。`git ls-files` と違い `find` はパスをクォート・8進エスケープ
  しないため、`-print0` の利点は「改行を含むパスを区別できる」ことだけだが、その区別は行単位で
  受ける時点で失われる。該当する場合はjqが開けないパスとして**失敗する**ため、無言で誤った
  結果になることはない。
- **`plans/` `worklog/` `reports/` 配下もヒットする。** これらはタスク単位で削除される寿命の
  短いファイルだが、検索対象からの一律除外はしていない（作業中はむしろ探したいため）。除外が
  必要な場合は `--dir .claude` で対象を絞る。
