---
title: 0012. コミットはcommitスキル経由を機構的に強制する
type: ddr
description: すべてのコミットをcommitスキル経由で行わせるため、ドキュメント記載に加えラッパースクリプトとPreToolUse hookによる技術的な強制を導入した経緯を記録したDDR
tags: [commit-skill, git-workflow, hook, ddr]
keywords: [commit, コミット, pretooluse, permissions.deny, create-commit, ラッパースクリプト, issue-39]
---

# 0012. コミットはcommitスキル経由を機構的に強制する

## 背景

issue #39「コミットSkillを利用するようにルールを記載する」。`commit`スキル
（`.claude/skills/commit/SKILL.md`）のfrontmatter descriptionは、当初
「Use ONLY when the user explicitly invoked /commit」となっていた。一方
`.claude/skills/issue-mr-flow/SKILL.md`の全体フローでは、flow-id 6/12/18/22でAIエージェントが
自律的にコミットする場面があり、この場面ではスキルの呼び出し条件に当てはまらず、直接
`git commit` を実行する余地があった。これが「スキルが使われたり使われなかったりしている」という
issue #39の現状の根本原因だった。

対応方針として、当初は`commit`スキルのdescriptionを広げ、関連ドキュメントに「コミットは常に
スキル経由」という記載を追加するだけの、ドキュメントのみの計画で合意していた。しかしこの方式は
AIエージェントの遵守にすべて依存しており、機構的な強制力を持たない。

## 決定

ドキュメント上のルール整備に加え、`.claude/settings.json`の`permissions.deny`と`PreToolUse` hookを
組み合わせ、`git commit`の直接実行を機構的にブロックする。

- **`.claude/hooks/block-direct-git-commit.sh`（新規、PreToolUse hook）**: 既存の
  `post-push-usage-report.sh`と同じ設計（`matcher: "Bash|PowerShell"`で広く受け、hookスクリプト側で
  `jq`により`tool_input.command`を取り出し、正規表現`git[[:space:]]+commit`で部分文字列チェックする）
  を踏襲した。`permissions.deny`の`if`相当のprefixマッチだけでは`cd src && git commit -m "fix"`の
  ような複合コマンドをすり抜けてしまうため、実質的な強制はhook側の文字列チェックに委ねている。
  マッチした場合はexit code 2でブロックし、`commit`スキル経由でコミットするよう促すメッセージを
  stderrへ出力する。
- **`.claude/settings.json`の`permissions.deny`にも`Bash(git commit*)` / `PowerShell(git commit*)`を
  追加**した。単純な直接実行であれば許可プロンプトの時点で弾かれる多重防御として機能する
  （複合コマンドのすり抜けはhook側でカバーする）。
- **`dev-tools/src/create-commit.sh`（新規ラッパースクリプト）**: `commit`スキルはこのスクリプト
  経由で`git add`・`git commit`を行う（`--message <メッセージ> -- <files...>`）。呼び出し文字列
  自体（Bash/PowerShellツールへ渡される文字列）に`git commit`という部分文字列を含まないため、
  上記hookの検知対象にならず、スキルの正規のコミット実行がブロックされない。ラッパー内部で
  `git commit`を実行すること自体は問題ない（hookが検査するのはツールへの呼び出し文字列のみで、
  その呼び出しが実行するスクリプトの内部処理までは見ていないため）。`issue-create`スキルが
  `dev-tools/src/create-issue.sh`を使う既存パターンを踏襲した。
- 既知のトレードオフとして、部分文字列マッチのため`git commit`という語がたまたま含まれる
  無関係なコマンド（該当文字列を検索する`grep`等）も誤ってブロックされる。悪意ある回避
  （意図的な文字列分割等）への対策も行わない。エージェントの既定動作を確実な方向へ倒すための
  仕組みであり、敵対的な安全境界を目的としたものではないため、許容することとした。

`Provider.sh`内の`add_empty_commit_for_draft_mr`（DDR 0005: Draft MR作成失敗時の空コミット
自動リトライ）は、関数内部から`git commit`を呼ぶだけであり、Bash/PowerShellツールへの
呼び出し文字列そのものに`git commit`という文字列が現れないため、このhookの影響を受けない。

## 却下した案

- **ドキュメントのみで運用する**: 当初案。`commit`スキルのdescriptionと関連ルールへの記載だけに
  留める方式。実装コストは最小だが、AIエージェントの遵守に完全に依存し、issue #39の現状
  （「スキルが使われたり使われなかったりしている」）を構造的には解決しない。ユーザーからの
  提案を受け、技術的な強制まで対応範囲を広げることにした。
- **`permissions.deny`単体で運用する**: `.claude/settings.json`の`permissions.deny`に
  `Bash(git commit*)`を追加するだけの案。`if`相当のprefixマッチはシンプルだが、
  `cd src && git commit -m "fix"`や`git add . ; git commit -m "WIP"`のような複合コマンドを
  すり抜けてしまうため、単体では不十分と判断した。
