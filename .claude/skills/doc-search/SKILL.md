---
name: doc-search
description: 'Search this repository''s markdown documents through the frontmatter index (index.jsonl) instead of scanning file contents. USE THIS FIRST — before grep, rg, find, or Glob — whenever looking for a document by what it IS or what it is ABOUT: "which DDR covers X", "list every spec", "what rules exist for shell scripts", "find docs tagged workflow", "which documents changed recently". Wraps .claude/scripts/src/search-frontmatter.sh, which refreshes index.jsonl, merges every index.jsonl in the repo, and filters by type/tag/keyword/path/free text with sorting and output-format switches. Falls back to grep/rg only when the target is a phrase in the BODY of a file rather than a document-level attribute. Also carries jq recipes for queries the options cannot express (AND across tags, grouping, counting, listing untagged files).'
title: ドキュメント横断検索
type: skill
tags: [doc-search, frontmatter, search, skill]
keywords: [index.jsonl, frontmatter, 横断検索, type, tags, keywords, jq, grep代替, ドキュメント探索, search-frontmatter]
---

# /doc-search スキル

リポジトリ内のmarkdownドキュメントを、**本文の全文探索ではなくfrontmatterのインデックス
（`index.jsonl`）経由で**検索する（issue #38。経緯・却下案:
`.claude/docs/ddr/0049-ドキュメント探索はfrontmatterインデックス検索を第一手段にする.md`）。

実処理は `.claude/scripts/src/search-frontmatter.sh` にある（仕様:
`.claude/docs/spec/search-frontmatter.md`）。

## 呼び出しタイミング

**リポジトリ内のドキュメントを探すときは、`grep` / `rg` / `find` / Globより先にこのスキルを使う。**
`.claude/` 配下だけでも70件規模のmarkdownがあり、そのすべてが `type` / `title` / `description` /
`tags` / `keywords` を持つfrontmatterを備えている（`.claude/rules/markdown-frontmatter.md`）。
「どのドキュメントか」を探す問いは、本文を1バイトも読まずにこのインデックスだけで答えられる。

| 探しているもの | 第一手段 |
|---|---|
| **ドキュメントそのもの**（「〜についてのDDRはどれか」「specの一覧」「workflowタグのルール」） | **このスキル** |
| 最近更新されたドキュメント／特定の種別の網羅的な一覧 | **このスキル**（`--sort mtime -r` / `--type`） |
| **本文中の特定の文字列**（関数名・変数名・コード片・言い回し） | `grep` / `rg` |
| ファイル名そのもの | Glob |

判断に迷ったら**まずこのスキルを使い、0件だったときに`grep`へ落とす**。frontmatterは
`description` と `keywords` に本文の要旨・特徴語を持つため、話題ベースの検索はたいてい当たる。

`grep` を第一手段にしてはいけない理由は速度だけではない。全文探索は**ヒットした行**を返すため、
「そのファイルが何のドキュメントなのか」を判断するのに結局ファイルを開くことになり、
無関係な言及（他ファイルからの参照リンク・変更履歴の記述）も同じ重みで混ざる。

## 使い方

```bash
bash .claude/scripts/src/search-frontmatter.sh [オプション]
```

初回実行時に `extract-frontmatter.sh` が走って `index.jsonl` を最新化するため、**frontmatterを
編集した直後でも結果は最新になる**（差分が無ければ2秒未満）。

### 絞り込み

同じオプションを繰り返すと **OR**、異なるオプション同士は **AND**。値の大文字小文字は無視する。

| オプション | 対象 | 一致 |
|---|---|---|
| `--type <値>` | `frontmatter.type` | 完全一致 |
| `--tag <値>` | `frontmatter.tags` の要素 | 完全一致 |
| `--keyword <値>` | `frontmatter.keywords` の要素 | 完全一致 |
| `--path <部分文字列>` | `concept_id`（リポジトリルート基準の拡張子なしパス） | 部分一致 |
| `--text <部分文字列>` | `concept_id` ＋ `mtime` ＋ frontmatter配下の**すべての値**（キー名は含まない） | 部分一致 |
| `--since <ISO8601>` | `mtime` | これ以上 |
| `--until <ISO8601>` | `mtime` | これ以下（日付のみなら当日23:59:59まで） |

### 並び替え・件数・出力

| オプション | 意味 |
|---|---|
| `--sort path\|mtime\|type\|title` | 並び替えキー（既定 `path`） |
| `--reverse` / `-r` | 逆順（`--sort mtime -r` で更新が新しい順） |
| `--limit <N>` | 先頭N件のみ |
| `--format table\|path\|json\|jsonl\|detail\|count` | 出力形式（既定 `table`） |
| `--dir <パス>` | このディレクトリ配下だけを対象にする。**相対パスはカレントではなくリポジトリルート基準** |
| `--no-refresh` | `index.jsonl` の最新化を省く（連続実行時） |
| `--quiet` / `-q` | 件数サマリ（stderr）を出さない |

`--format` の使い分け: `table`（既定・一覧を眺める）／`path`（結果をReadツール等へ渡す）／
`detail`（description・keywordsまで見て当たりを付ける）／`json` `jsonl`（jqでさらに加工する）／
`count`（件数だけ知りたい）。

### よく使う形

```bash
# 「コンフリクト」に関係するドキュメントを、要約付きで見る
bash .claude/scripts/src/search-frontmatter.sh --text コンフリクト --format detail

# DDRを新しい順に10件（何が最近決まったかを掴む）
bash .claude/scripts/src/search-frontmatter.sh --type ddr --sort mtime -r --limit 10

# specの一覧をパスだけで受け取り、そのままReadツールへ渡す
bash .claude/scripts/src/search-frontmatter.sh --type spec --format path -q

# シェルスクリプト関連のルール
bash .claude/scripts/src/search-frontmatter.sh --type rule --keyword bash

# 今日更新されたドキュメント
bash .claude/scripts/src/search-frontmatter.sh --since 2026-08-19 --sort mtime -r
```

## jqレシピ（オプションで表現できないケース）

`--format jsonl` の出力を `jq` へ渡す。**`--no-refresh` を付ければ `extract-frontmatter.sh` の
再実行を省ける**（直前に1度実行していれば十分）。

```bash
# 以降の例で使う共通部分
SF() { bash .claude/scripts/src/search-frontmatter.sh --format jsonl -q "$@"; }
```

**タグのAND（複数タグをすべて持つもの）** — スクリプトの `--tag` はORのため、jq側で絞る。

```bash
SF | jq -r 'select((.frontmatter.tags // []) | (index("workflow") and index("skill"))) | .concept_id'
```

**typeごとの件数を数える**

```bash
SF | jq -s -r 'group_by(.frontmatter.type // "(なし)") | map({type: .[0].frontmatter.type, n: length})
             | sort_by(-.n) | .[] | "\(.n)\t\(.type // "(なし)")"'
```

**frontmatterが無い／必須キーが欠けているファイルを洗い出す**（規約違反の検出）

**`.claude/rules/markdown-frontmatter.md`「対象外・特殊対応ファイル」の表に載っているファイルを
除いてから読むこと。** issueテンプレート（`.github/ISSUE_TEMPLATE/` `.gitlab/issue_templates/`）は
**frontmatterを追加してはいけない**と規約が定めており、これを違反として扱うと
「追加してはいけないfrontmatterを追加する」方向へ動いてしまう。

```bash
# 規約上の対象外（issueテンプレート）を除いたうえで、frontmatter そのものが無いものを探す
SF | jq -r 'select(.concept_id | test("ISSUE_TEMPLATE|issue_templates") | not)
          | select(.frontmatter == null) | .concept_id'
# 推奨キーが欠けているもの（同じく対象外を除く）
SF | jq -r 'select(.concept_id | test("ISSUE_TEMPLATE|issue_templates") | not)
          | select((.frontmatter // {}) | has("keywords") | not) | .concept_id'
```

`.claude/agents/*.md` と `.claude/skills/*/SKILL.md` は `description` を**追加しない**規約
（既存のキーをそのまま使う）なので、`has("description")` での洗い出しにも同じ注意が要る。

**タグの一覧と出現回数**（既存のタグ語彙に合わせたいとき）

```bash
SF | jq -s -r '[.[].frontmatter.tags // []] | flatten | group_by(.)
             | map({tag: .[0], n: length}) | sort_by(-.n) | .[] | "\(.n)\t\(.tag)"'
```

**superseded になったDDRと、その置き換え先**

```bash
SF --type ddr | jq -r 'select(.frontmatter.status == "superseded")
                     | "\(.concept_id) -> \(.frontmatter.superseded_by)"'
```

**description を使って一覧をmarkdownの表にする**（reportsへ貼るとき）

```bash
SF --type spec | jq -r '"| \(.frontmatter.title) | \(.frontmatter.description) |"'
```

## 注意

- **`index.jsonl` はGit管理外の生成物**（`.gitignore` の `**/index.jsonl`）。SessionStart hookが
  セッション開始のたびに再生成するが、このスクリプトも実行のたびに最新化するため、
  手動で `extract-frontmatter.sh` を叩く必要はない
  （`.claude/docs/ddr/0025-frontmatterのindex.jsonlをGit管理から外しSessionStart-hookで生成する.md`）。
- **検索できるのはfrontmatterの内容だけで、本文は対象外**。本文中の語を探すときは `grep` / `rg`
  を使う。逆に言えば、frontmatterの `description` / `keywords` の質がそのまま検索の質になる
  （新規markdown作成時は `.claude/rules/markdown-frontmatter.md` に従って必ず付与する）。
- **`plans/` `worklog/` `reports/` 配下のファイルもヒットする**。これらはタスク単位で
  flow-id 5-1 に削除される寿命の短いファイルのため、恒久的な参照先として扱わない
  （`.claude/rules/docs-workflow.md`）。除外したいときは `--dir .claude` で対象を絞る。
