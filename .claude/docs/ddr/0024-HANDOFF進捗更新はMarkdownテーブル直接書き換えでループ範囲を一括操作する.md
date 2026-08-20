---
title: 0024. HANDOFF進捗更新はMarkdownテーブル直接書き換えでループ範囲を一括操作する
type: ddr
description: update-handoff-progress.shの実装方式として、構造化データへの状態移行を却下しHANDOFF.mdのMarkdownテーブルを直接書き換える方式を採用し、ループ範囲は常に一括操作する制約を採用した理由
tags: [ddr, update-handoff-progress, handoff]
keywords: [update-handoff-progress, HANDOFF, ループ範囲, Markdownテーブル, 構造化データ, mark-skip, mark-done]
---

# 0024. HANDOFF進捗更新はMarkdownテーブル直接書き換えでループ範囲を一括操作する

issue #20。仕様は
[.claude/docs/spec/update-handoff-progress.md](../spec/update-handoff-progress.md) を参照。

## 背景

`HANDOFF.md`の進捗表更新（flow-idごとの`[x]`/`[-]`マーク、ループ扱いのflow-idへの`[]`追加）が
メインエージェントの手作業に依存しており、書き間違い・更新漏れが起きやすかった。これを
`.claude/scripts/src/update-handoff-progress.sh`で機械化するにあたり、2つの設計判断を行った。

## 決定1: 進捗状態はHANDOFF.mdのMarkdownテーブルへ直接書き込む（構造化データへは移行しない）

進捗記号・ヘッダ情報を`HANDOFF.md`のMarkdownテーブル行へ正規表現で直接読み書きする方式を採用した。
進捗状態を別途JSON/YAML等の構造化データとして持ち、`HANDOFF.md`をそこから都度生成する方式は
採らなかった。

## 決定2: ループ範囲は常に一括操作とし、範囲内の一部だけの完了・スキップは許容しない

`mark-done`/`add-round`は、対象flow-idがループ範囲（例: `3-6 3-7 3-8 3-9`）に属する場合、
範囲内の全flow-id行へ同じ操作を一括適用する。範囲内の一部だけを個別に`[x]`や`[-]`にする操作は
提供しない（`mark-skip`で範囲内の一部を先に`[-]`にすると、その後の同じ範囲への`mark-done`/
`add-round`は「末尾が`[]`でない」エラーで拒否される）。

## 却下した案

### 1. 進捗状態を構造化データ（JSON/YAML）として別途保持し、HANDOFF.mdはそこから生成する

状態の読み書きが正規表現によるテキスト処理より堅牢になり、将来的な機能拡張（例: 進捗の集計・
可視化）もしやすくなる。しかし、以下の理由で却下した。

- issue #20の受け入れ条件「既存の`HANDOFF.md`の構成（見出し・表の列）を壊さない」を、生成方式では
  素直に満たせない（生成テンプレートと既存の手書きMarkdownの間で、コメント・注記等の自由記述部分の
  扱いが一致しなくなる）。
- `HANDOFF.md`は人間も直接読み書きするファイルであり（`.claude/rules/docs-workflow.md`「人間＋AI」
  対象）、状態の正が別ファイルに移ると、`HANDOFF.md`を直接手編集した場合に状態ファイルとの不整合が
  生じる。二重管理の複雑さが、機能拡張の利点に見合わない。
- 実際の運用（issue #20対応中に観測）でも、担当欄への注記（例:
  「エージェント — 実施済み（非対話的環境のためレビュー省略）」）のような自由記述を都度書き足す
  必要があり、これは構造化データでは表現しづらい。

### 2. ループ範囲内の一部flow-idだけを個別に完了・スキップできるようにする

`mark-done`/`mark-skip`の対象を常に単一のflow-idに限定し、ループ範囲への一括適用を行わない案。
実装は単純になるが、issue #20対応の実機検証で、前issue #13の`HANDOFF.md`
（`.claude/skills/issue-mr-flow/SKILL.md`の全体フロー導入後）が、まさにこの「範囲内の一部だけ
個別に`[x]`にする」手作業更新をしており、`.claude/rules/docs-workflow.md`の「同じループ範囲内の
ステップは常に同じ個数の`[]`を持つ」という既存ルールに反していたことが判明した。これは本issueが
解消しようとしている「書き間違い」そのものであり、個別操作を許容する実装ではこの種の不整合を
機械的に防げない。範囲内の一部だけ実施し残りを省略する場合（非対話的実行環境でのレビュー省略等）は、
記号を`[]`のまま残し「やったこと」セクションで補足する運用とする
（詳細: `.claude/rules/docs-workflow.md`「非対話的実行環境」節）。
