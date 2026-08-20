---
title: 0052. 対応工数レポートのトークン列はengineではなくデータで決める
type: ddr
description: 対応工数レポートのトークンテーブルの列構成を実行中のengineではなくtokensByModelの中身で決め、両エンジン由来のモデルが混在する場合は列の和集合を出す判断
tags: [usage-report, gemini-cli, ddr, report]
keywords: [トークン列, Cache Write, Thoughts, Tool, tokensByModel, 混在, sinceLastPush, 繰り越し, 空テーブル, build_usage_report_body]
---

# 0052. 対応工数レポートのトークン列はengineではなくデータで決める

## 背景

Claude Code のトークンは `{input, output, cacheCreate, cacheRead}` の4項目で、レポートは
`Input / Output / Cache Write / Cache Read` の4列で表示している。

一方 Gemini CLI のトークンは `{input, output, cached, thoughts, tool, total}` で、
**Cache Write に相当するものが無く、代わりに Thoughts・Tool がある**（issue #97 フェーズ2の調査）。
`total` は内訳の合計なので加算しない。

issue #97 の当初計画では「実行中の engine で列構成を切り替える」としていた。

## 決定

**列構成は engine ではなく、`sinceLastPush.tokensByModel` の中身で決める。**
判別は「そのモデルのバケットが `thoughts` キーを持つか」で行う。

| 状態 | 列構成 |
|---|---|
| 全バケットが `thoughts` を持たない | `Input / Output / Cache Write / Cache Read`（**現行のまま**） |
| 全バケットが `thoughts` を持つ | `Input / Output / Cache Read / Thoughts / Tool` |
| **混在** | **和集合** `Input / Output / Cache Write / Cache Read / Thoughts / Tool`（欠けている列は0） |

あわせて次の2つを決めた。

- **モデル行のスキップ判定を「そのバケットが持つ数値項目がすべて0か」へ一般化する。**
- **表示するモデル行が0件のときは、ヘッダ行・区切り行を含めてテーブルごと出力しない。**

## 理由

### engine で決めると、両エンジンを使ったブランチで数値が無言で消える

状態ファイルはブランチ単位（`usage/state/<safeBranch>.json`）で、`sinceLastPush` は
**投稿に成功するまで繰り越される**（`gh`/`glab` CLI が無い環境では投稿がスキップされて繰り越す
経路が実在する。issue #34）。このリポジトリは `.gemini/` を `.claude/` へのリンクとして両エンジン
から使う前提なので、**同じブランチの `tokensByModel` に両エンジン由来のモデルが同居しうる**。

この状態で「今回の engine」だけで列を決めると、最後が Claude Code なら Gemini分の
`thoughts`/`tool` が、最後が Gemini なら Claude分の Cache Write が、いずれも表から消える。
しかも**エラーにならず、数値が静かに欠ける**ため気づけない。

### 4項目固定のスキップ判定は Gemini のモデル行を消す

既存の判定は `input`/`output`/`cacheCreate`/`cacheRead` の4項目だけを見ている。Gemini では
`tool` トークンだけが正の値を持つ行がありうるが、4項目はすべて0なので「全項目0」と判定されて
消える。判定を「そのバケットが持つ数値項目すべて」へ一般化すると、**Claude Code のバケットは
キーがちょうど4つなので現行式と同値**であり、既存の出力は変わらない。

### 空テーブルは受け入れ条件に反する

ヘッダ行と区切り行は無条件に出力されていたため、モデル行が1つも残らないと**ヘッダ2行だけの
空テーブル**になる。issue #97 の受け入れ条件は「トークン情報が取得できない場合に、レポートが
空のトークンテーブルや『0』の羅列にならないこと」であり、これに正面から反する。

なお **Claude Code 経路でこの抑止が発火することはない**。投稿ガード（トークン合計 > 0）を先に
通るため、モデル行が0件になる状態ではそもそも投稿されない。

## 却下した案

| 案 | 却下理由 |
|---|---|
| 実行中の engine で列構成を切り替える | 混在時にどちらかの数値が無言で消える（上記） |
| 常に6列（和集合）を出す | 純粋な Claude Code のレポートに常に空の Thoughts/Tool 列が付き、既存の出力が変わる。「Claude Code 側のレポート内容は変えない」という issue #97 の受け入れ条件に反する |
| engine ごとに状態ファイルを分ける（`<branch>-gemini.json` 等） | 混在は避けられるが、同じブランチの工数が2つのレポートに割れる。読み手にとっては1本の作業なので、分けるのは実装の都合を利用者へ押し付けることになる |
| モデル名から engine を推定する（`gemini-` で始まるか等） | モデル名は外部の命名に依存し、将来変わりうる。データの形（キーの有無）で判別するほうが壊れにくい |
| 空テーブルのときヘッダだけ残して「データなし」と書く | 行が無いテーブルを見せる意味が無い。使用モデルは別途 `- 使用モデル:` 行で出す |

## 影響

- `post-push-usage-report.sh` のレポート本文を `build_usage_report_body` へ切り出し、
  列構成の決定・スキップ判定・空テーブル抑止を jq 側で行う。
- 切り出しによって Claude Code 経路の出力が変わっていないことは、旧実装をラップして
  `diff` を取る形で確認した（バイト一致）。回帰は
  `.claude/scripts/test/test_usage_tracking.sh` のレポート本文ケースが持つ。
- 仕様: `.claude/docs/spec/issue-mr-workflow.md`「対応工数レポート」節。
