---
title: 0011. issue作成は独立スキルとして新設し、issue-mr-flowのサブコマンドにはしない
type: ddr
description: AIエージェントによるissue起票代行の実装方式として、issue-mr-flowへのサブコマンド追加ではなく独立スキル（issue-create）を新設した経緯を記録したDDR
tags: [issue-create, skill, ddr]
keywords: [issue-mr-flow, サブコマンド, 独立スキル, create-issue.sh, issue-25]
---

# 0011. issue作成は独立スキルとして新設し、issue-mr-flowのサブコマンドにはしない

## 背景

issue #25「issueを作成するスクリプト、スキルを作成する」への対応で、AIエージェントがissueを
起票できるようにする実装方式を検討した。`.claude/skills/issue-mr-flow/SKILL.md`は「issue起票から
マージまでの唯一の実装フロー定義」であり、その`start`/`comments`/`reply`/`describe`/`sync`/`resume`
という既存サブコマンド群と同じ構造（`Provider.sh`のディスパッチ関数を呼び出す手順書の1節）として
`create`のようなサブコマンドを追加する案と、`.claude/skills/issue-create/`という完全に独立した
新規スキルとして切り出す案の、大きく2案があった。

## 決定

**独立スキル（`.claude/skills/issue-create/SKILL.md`）として新設する。**

- `dev-tools/src/vcs/Provider.sh`側の実装（`build_issue_body`/`new_issue`ディスパッチ）は、
  他の`get_issue`等と同じ構造でそのまま追加する（スキル配置の議論とは独立した判断）。
- `issue-mr-flow/SKILL.md`のflow-id 1（issueを起票する、本来は人間の担当）の担当セルに、
  「AIが代行する場合は`issue-create`スキル」という一言の導線のみを追加し、`issue-mr-flow`本体の
  サブコマンド一覧・全体フロー構造には手を入れない。

## 理由

- **「唯一の実装フロー定義」の性質が異なる**: `issue-mr-flow`のサブコマンド群はいずれも「既に
  起票されたissueに対して、ブランチ・MRを介した往復作業を進める」ためのものであり、全体フロー
  （flow-id 2〜23）の一部として密結合している。issue作成（flow-id 1相当）はその**手前**の工程で、
  ブランチ・MR・レビュー往復といった状態を一切持たない独立した操作であるため、密結合させる
  必然性が無い。
- **利用契機が異なる**: `issue-mr-flow`の各サブコマンドは「今どのflow-idにいるか」という文脈に
  依存して呼ばれるのに対し、issue起票はブランチをチェックアウトする前、開発フローに入る前の
  純粋な「思いついたことをissue化したい」という単発の要望から呼ばれる。既存サブコマンドの
  多くが前提とする`resume`による現在地確認（ブランチ・issue番号の特定）とも噛み合わない。
- **今後の再利用性**: 独立スキルにしておくことで、`issue-mr-flow`のフロー定義を変更せずに
  issue作成の手順単体を改善できる。将来的に他の起票元（例: 定型的な不具合報告テンプレートからの
  一括作成等）が増えても、`issue-mr-flow`本体の複雑化を避けられる。

## 却下した案

- **`issue-mr-flow`へ`create`サブコマンドとして追加する**: 既存の6サブコマンドと同じ書式で
  ドキュメントが1箇所にまとまる利点はあるが、上記の理由により却下した。「唯一の実装フロー定義」
  という`issue-mr-flow`の性質上、無関係な関心事（起票前の単発操作）を混在させるとフローの見通しが
  悪くなる懸念もあった。
