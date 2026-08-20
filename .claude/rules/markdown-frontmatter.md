---
title: markdownのYAML frontmatter規約
type: rule
description: リポジトリ内markdownドキュメントに付与するOpen Knowledge Format風frontmatterのキー定義・type値一覧・例外ルール
tags: [markdown, frontmatter, rule]
keywords: [okf, frontmatter, フロントマター, キー定義, 開放知識形式, 対象外ファイル, タイプ, keywords]
---

# markdownのYAML frontmatter規約

issue #7対応。リポジトリ内の各markdownファイルに、ファイル種別・要約・タグ等を機械可読な形で
持たせることで、将来的な一覧化・検索・ツール連携をしやすくする。

## キー定義

OKF（Open Knowledge Format、https://okf.md/spec/ ）のフィールド定義に沿って各キーの意味を記載する。

| フィールド | 必須/推奨 | 説明 |
|---|---|---|
| `type` | 必須 | コンセプトのタイプを特定する短い文字列。ルーティング・フィルタリングに使う。中央登録は無く、値は本リポジトリで自由に定義する（値は下表「typeの値」参照） |
| `title` | 推奨 | 人間が読みやすい名前 |
| `description` | 推奨 | 1文でコンセプトを要約する。将来的な一覧化・インデックス生成に使う |
| `resource` | 推奨 | 実リソース（外部URL・社内配布先・BigQueryテーブルURI等）を一意に識別するURI。抽象的な概念や、対応する実リソースが無いファイルではキー自体を省略してよい（空文字列は使わない） |
| `tags` | 推奨 | 横断的カテゴリ分類用の文字列リスト（kebab-case、2〜4個程度。ディレクトリ・技術要素・工程等を表す） |
| `keywords` | 推奨 | OKF標準にはない拡張フィールド。本文中の頻出語・特徴的な語を検索用途で3〜20個（文章量に応じて増減、平均的な長さの文章なら10個前後）リスト形式で記載する。日本語で書かれたファイルでは、英語の技術用語のみに偏らず日本語の単語もバランスよく含める |
| `status` | DDRのみ・任意 | その意思決定が現在も有効かを表す（下記「DDRのstatus」参照）。省略時は有効（`active`）とみなす |
| `superseded_by` | DDRのみ・条件付き必須 | `status: superseded` のときに、置き換えた側のDDR番号を書く（例: `"0019"`） |

## DDRのstatus（後から無効になった意思決定の扱い）

DDRは**本文を一度マージしたら変更しない**運用だが、**YAML frontmatterのみは後から更新してよい**
（issue #9で決定）。後続の意思決定によって無効になったDDRに、その事実を機械可読な形で残すため。

| `status` | 意味 | 併記するキー |
|---|---|---|
| （省略） / `active` | 現在も有効。**通常はキー自体を書かない** | — |
| `superseded` | 後続のDDRによって置き換えられた | `superseded_by: "<番号>"` |
| `deprecated` | 置き換え先を持たずに廃止された（その決定自体が不要になった等） | — |

```yaml
---
title: 0009. Planモードre-entry時はgit checkout復元でなくarchiveスクリプトで対処する
type: ddr
status: superseded
superseded_by: "0019"
description: <元のまま変更しない>
---
```

**`description` は書き換えない。** `description` は「そのDDRが何を決めたか」の要約であり、
一覧・検索・`index.jsonl` から参照される。無効化の情報で上書きすると、元の決定内容が読み取れなく
なってしまう。無効化の事実は `status` / `superseded_by` という専用キーで表現し、両方の情報を残す。

値に `disabled` ではなく `superseded` / `deprecated` を使うのは、DDRの元になったADR
（Architecture Decision Record）で広く使われている語彙に合わせるため（読み手が初見でも意味を
推測でき、外部ツールとも揃う）。

`index.jsonl`（`.claude/scripts/src/extract-frontmatter.sh` が生成するfrontmatterの機械可読
インデックス）は**Git管理下に置かず、生成物として扱う**（issue #36。`.gitignore`の
`**/index.jsonl`対象）。`.claude/hooks/session-start.sh`（SessionStart hook）が**セッション開始の
たびに自動で再生成する**ため、frontmatterを更新した際に手動で `extract-frontmatter.sh` を
実行する必要はない（詳細:
[.claude/docs/ddr/0025-frontmatterのindex.jsonlをGit管理から外しSessionStart-hookで生成する.md](../docs/ddr/0025-frontmatterのindex.jsonlをGit管理から外しSessionStart-hookで生成する.md)）。

同一セッション内でfrontmatterを編集し、その場ですぐ最新の `index.jsonl` を参照したい場合や、
自動再生成を待たず手元で確認したい場合は、以下を手動実行してもよい（必須ではない）。

```bash
bash .claude/scripts/src/extract-frontmatter.sh .
```

- **通常はリポジトリルート（`.`）を指定して1回流せばよい。** mtimeが変わっていないファイルは
  前回の結果を再利用するため、差分が無ければ2秒未満で終わる（issue #11）。ディレクトリを絞る
  必要は無い。
- **`--force` は通常不要。** スクリプト自身を変更した場合はキャッシュが自動で無効化される。
  `--force` を使うのは、mtimeを保ったままファイル内容が変わった等、キャッシュを信用できない
  特殊なケースに限る。
- 仕様の詳細は
  [.claude/docs/spec/extract-frontmatter.md](../docs/spec/extract-frontmatter.md) を参照。
あわせて `.claude/docs/README.md` のDDR一覧にも、置き換え先が分かる注記を添えるとよい。

**生成された `index.jsonl` は、ドキュメントを探すための検索インデックスとして使う**（issue #38）。
`type` / `tags` / `keywords` / パス / フリーテキストでの絞り込みと、mtime等での並び替えが
`bash .claude/scripts/src/search-frontmatter.sh` で行える（最新化も兼ねるため、上記の
`extract-frontmatter.sh` を先に実行する必要はない）。**リポジトリ内のドキュメントを探すときは、
`grep`/`find`による全文探索より先にこちらを使う**（`AGENTS.md`のルール。使い方・jqレシピは
[.claude/skills/doc-search/SKILL.md](../skills/doc-search/SKILL.md)、仕様は
[.claude/docs/spec/search-frontmatter.md](../docs/spec/search-frontmatter.md)）。
ここで定める `description` / `keywords` の質が、そのまま検索の当たりやすさになる。

新規markdown作成時は原則このfrontmatterを付与する。既存のfrontmatterを持つファイル（後述）は
既存キーを変更せず、不足しているキーのみを追記する。

## typeの値

| type | 対象 |
|---|---|
| `ddr` | `.claude/docs/ddr/*.md` |
| `rule` | `.claude/rules/*.md`, `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` |
| `agent` | `.claude/agents/*.md` |
| `skill` | `.claude/skills/*/SKILL.md` |
| `plan` | `plans/*.md`（planツールが出力する全体作業計画・`【種別】`付きの個別計画の両方。issue #95） |
| `log` | `worklog/*.md` |
| `report` | `reports/*.md`（調査結果・作業結果・反映結果の正文。issue #87。同ディレクトリの`*.html`はfrontmatterを持たないため対象外） |
| `guide` | `README.md`, `DEVELOPERS.md`, `.claude/docs/README.md`, `index.md` |
| `handoff` | `HANDOFF.md` |
| `spec` | `.claude/docs/spec/*.md` |
| `review-points` | `**/REVIEW-POINTS.md`（各ディレクトリ直下のレビュー観点表。issue #77） |

アプリ本体を追加し、専用の`docs/spec/`・`docs/ddr/`・`docs/README.md`（必要なら`dev-tools/docs/`
配下も）を新設した場合は、上表に対象パスを追記する。

`type`の値は自動判定せず、ファイルごとに内容を見て個別に決定する。上表は現時点の割り当て例であり、
新しいディレクトリ・用途が増えた場合はこの表に追記する。

`plan`・`log`・`report` は、いずれもタスク（issue／ブランチ）単位で作られ flow-id 5-1 でまとめて
削除される寿命の短いファイルに与える値であり、永続する案内ドキュメントの `guide` とは区別する
（`.claude/rules/docs-workflow.md` のライフサイクル表と対応する）。issue #95以前は `plans/*.md`
についての規定が無く、実際には `guide` / `log` / `plan` / frontmatter無しが混在していたため、
専用の値 `plan` を新設して一意に定めた（経緯・却下案:
[.claude/docs/ddr/0042-plans配下のfrontmatter-typeはguideではなくplanを新設する.md](../docs/ddr/0042-plans配下のfrontmatter-typeはguideではなくplanを新設する.md)）。

## 対象外・特殊対応ファイル

以下は既に別スキーマのfrontmatterを持つか、機能上frontmatterの追加が適さないため、通常の
4〜6キーをそのまま追加しない。

| ファイル | 扱い | 理由 |
|---|---|---|
| `.gitlab/issue_templates/Default.md` | **対象外**（frontmatter追加しない） | GitLabはissueテンプレートのfrontmatterを特別扱いしないため、追加すると issue作成のたびに本文へYAMLがそのまま挿入されてしまう |
| `.github/ISSUE_TEMPLATE/task.md` | **対象外**（frontmatter追加しない） | GitHub仕様の`title`等の既存frontmatterと衝突・干渉するため。issueテンプレートにOKF frontmatterは不要と判断した |
| `.claude/agents/*.md` | `title`/`type`/`tags`/`keywords`/（該当すれば`resource`）のみ追加。`description`は追加しない | 既存の`description`はClaude Codeがサブエージェント選択に使う実キーのため、重複させず流用する |
| `.claude/skills/*/SKILL.md` | 同上 | 同上（skill選択に使う`description`を保持） |
| `.claude/rules/*.md`のうち`alwaysApply: true`を持つファイル | 既存キーの下に新キーを追記する | `alwaysApply`はClaude Codeのルール常時適用設定として実際に使われるため、値・位置を変更しない |

いずれも既存のfrontmatterブロックは1つのまま、新キーを既存キーの下に追記する形にし、既存キーの
値・順序は変更しない。

## 新規ファイル作成時のフォーマット例

```yaml
---
title: <ファイルの題名>
type: <上表のtype値>
description: <1行要約>
resource: <対応する実リソースがあれば記載。無ければキー自体を省略>
tags: [<kebab-caseのキーワード, 2〜4個>]
keywords: [<本文の頻出語・特徴語, 3〜20個（目安10個）>]
---
```
