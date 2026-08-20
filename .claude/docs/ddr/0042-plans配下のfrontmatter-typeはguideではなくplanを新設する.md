---
title: 0042. plans配下のfrontmatter typeはguideではなくplanを新設する
type: ddr
description: plans/*.mdのfrontmatter typeに、既存のguideを流用せず専用の値planを新設して一意に定める決定
tags: [markdown-frontmatter, docs-workflow, plans, type]
keywords: [plans, type, plan, guide, frontmatter, ライフサイクル, index.jsonl, 全体作業計画, 個別計画, 規約]
---

# 0042. `plans/` 配下のfrontmatter `type` は `guide` ではなく `plan` を新設する

## 背景

issue #95。`.claude/rules/markdown-frontmatter.md` の「typeの値」表に `plans/*.md` の行が無く、
同ファイル中に `plans` という語自体が一度も現れていなかった。「対象外・特殊対応ファイル」表にも
記載が無いため、**計画ファイルを作る側は規約から値を決められず、既存ファイルを見て推測するか
独自の値を使う**状態が続いていた。

実際の混在状況を、これまでにブランチ上へ作られた `plans/*.md` 20件で調べたところ、次のとおり
ばらついていた（値ごとのファイル数）。

| `type` の値 | 件数 |
|---|---|
| `guide` | 7 |
| `log` | 4 |
| `plan` | 4 |
| （frontmatter無し・`type`無し） | 5 |

`plans/` は `.mrworkflow.json` の `plansDir` として当初から存在するディレクトリであり、表の
「新しいディレクトリ・用途が増えた場合はこの表に追記する」という運用からの**追記漏れ**にあたる。

## 決定

**`plans/*.md`（planツールが出力する全体作業計画・`【種別】`付きの個別計画の両方）の `type` は
`plan` とする。**

- 既存値の流用ではなく、新しい値 `plan` を導入する。
- 「typeの値」表へ行を追加し、`log`（`worklog/*.md`）の直前に置く。計画→ログ→報告という
  フロー上の順序と、`plan`・`log`・`report` がいずれも**タスク単位で作られ flow-id 5-1 で
  まとめて削除される寿命の短いファイル**である点をひとまとまりで読めるようにするため。
- 表の直後に、`plan`・`log`・`report` と `guide` の区別（寿命の違い）を明記する。

## 却下した案

### 案A: 既存実態に多い `guide` をそのまま規約化する

調査時点で最多（7件）だった値をそのまま採用する案。**却下**。`guide` の対象は `README.md` /
`DEVELOPERS.md` / `.claude/docs/README.md` / `index.md`、すなわち**リポジトリを案内する永続
ドキュメント**である。計画ファイルは flow-id 5-1 で削除され main には残らない、タスク単位の
寿命を持つファイルであり、性質が異なる。同じ値にすると、`type` で絞り込んだときに「永続する
案内」と「削除される計画」が同列に並び、`type` の絞り込みそのものが用途を失う。

なお最多といっても7/20件であり、「実態が `guide` に収束していた」とは言えない（`log` 4件・
`plan` 4件・値なし5件）。多数決の根拠としても弱い。

### 案B: `log` に寄せて `worklog/` と同じ値にする

寿命が同じであることを重視し、worklogと同じ `log` にまとめる案。**却下**。両者は読む目的が
異なる。計画は**合意のスナップショット**（何をするかを事前に確定させたもの）であり、worklogは
**試行錯誤の過程**のログである。issue #87（DDR 0040）で「計画」と「実施結果」を別ファイルへ
分離したばかりであり、その直後に計画とログを同じ `type` へ畳むのは方向が逆になる。

### 案C: 全体作業計画と個別計画で値を分ける（例: `plan` と `subplan`）

2階層構造をfrontmatterでも表現する案。**却下**。両者は同じディレクトリ・同じ寿命・同じ
レビュー対象であり、値を分けても絞り込みの用途が思いつかない。区別が必要な場面では、
ファイル名（個別計画は `【種別】` で始まる）で機械的に判別できる。

### 案D: `plans/` を「対象外・特殊対応ファイル」としてfrontmatter自体を付けない

**却下**。`plans/` は `.gitlab/issue_templates/Default.md` のように**frontmatterを置くと機能上の
実害が出る**ファイルではない。また、計画ファイルはレビュー対象であり `description` による要約が
役に立つ。規約から外すと、値がばらつく現状が「無規定」から「対象外」へ名前を変えるだけで、
新規作成時に何も書かなくてよいのか付けてよいのかが依然として読み取れない。

## 影響

- `.claude/rules/markdown-frontmatter.md`（「typeの値」表へ `plan` を追加し、`guide` との
  区別を注記）
- 既存ファイルの移行は**不要**。`plans/` は flow-id 5-1 で削除されるため、main のワーキング
  ツリーに `plans/*.md` は1件も存在しない（値がばらついていたのは、いずれもマージ済み
  ブランチ上の履歴である）。
- **`type` を条件分岐に使っているコードは無い**ため、新しい値を追加してもスクリプトの変更は
  不要である。`.claude/scripts/src/extract-frontmatter.sh` はfrontmatterのキーを値によらず
  そのままJSON化するだけで、`index.jsonl` にも `type` の値がそのまま入る（`type` によって
  出力を変える処理は無い）。`.claude/hooks/` 配下で `.type` を参照している箇所は
  `UsageTracking.sh` のみだが、これはtranscriptのJSONエントリ種別（`assistant` / `user` /
  `tool_use`）であり、markdownのfrontmatterとは無関係である。
