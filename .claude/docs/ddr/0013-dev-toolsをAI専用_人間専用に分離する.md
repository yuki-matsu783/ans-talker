---
title: 0013. dev-toolsをAI専用/人間専用に分離する
type: ddr
description: AI専用スクリプト・設計書をdev-tools/から.claude/scripts/へ分離し、人間専用のビルド・配布ツールのみdev-tools/に残した経緯を記録したDDR
tags: [dev-tools, directory-structure, plugin-distribution, ddr]
keywords: [dev-tools, claude-scripts, plugin配布, git-mv, 歴史的記録, issue-mr-resume, issue-24]
---

# 0013. dev-toolsをAI専用/人間専用に分離する

## 背景

issue #24「dev-toolsをAI・人間が利用するものと人間のみが利用するもので分ける」。
`dev-tools/`配下には、AIエージェント（Claude Code）が`.claude/skills/*`経由で能動的に実行する
スクリプト（`vcs/Provider.sh`, `create-commit.sh`等）と、人間が手動実行する開発補助スクリプト
（`build.sh`）が混在していた。Claude Codeのplugin配布は`.claude/`配下一式をパッケージ化する想定
のため、AI専用スクリプト・設計書が`.claude/`の外（`dev-tools/`）に置かれていると、配布物に含まれ
ない、または配布の境界が曖昧になるという問題があった。

## 決定

利用者（誰が実行するか）を軸に、`dev-tools/`配下を物理的に分離する。

- **AI専用スクリプト・設計書** → `.claude/scripts/`（`src/`にスクリプト本体、`docs/{spec,ddr}/`に
  設計ドキュメント）へ`git mv`で移動する。対象: `vcs/Provider.sh` `Github.sh` `Gitlab.sh`,
  `create-commit.sh`, `create-issue.sh`, `archive-reentrant-plan.sh`, `extract-frontmatter.sh`、
  設計書`issue-mr-workflow.md` `shell-scripts.md` `extract-frontmatter.md`、DDR `0002`〜`0012`。
- **人間専用ツール**（`build.sh`, `distribution.md`, DDR `0001`。いずれもexe配布ビルド専用）は
  `dev-tools/`に残す。
- **実行主体が人間のままでも「AIが読む設計書と対になっている」スクリプトは移動対象に含める**:
  `extract-frontmatter.sh`は人間が手動実行する運用のままだが、`.claude/scripts/src/`へ移動した
  （レビューでの指摘を受けて決定。判断基準は「誰が実行するか」よりも「AI専用スクリプト群と
  設計・運用が一体かどうか」を優先した）。同様の理由で、`build.sh`の規約も一部含む
  `shell-scripts.md`も`.claude/scripts/docs/spec/`へ移動し、`dev-tools/docs/spec/distribution.md`
  側から新しい参照パスへリンクする形にした（規約文書自体を分割はしない）。
- **既にマージ済みのDDR・spec内の「影響範囲」changelogは、ファイルの移動先パスへ書き換えない**:
  DDR（`.claude/scripts/docs/ddr/*.md`）は`git mv`のみを行い本文は一切変更しない。spec
  （`issue-mr-workflow.md`, `shell-scripts.md`, `extract-frontmatter.md`）の「## 影響範囲」節
  （過去issueごとのchangelog）も同様に、過去のエントリはそのpoint-in-timeでの正しいパス表記の
  まま残し、当時存在しなかった`.claude/scripts/...`パスを遡って書き込まない。今回の移動自体は
  「変更（issue #24 ...）」という新規エントリとして追記する。「## 仕様」等、現在の状態を説明する
  節のみを新パスへ更新する。
- **`.claude/agents/issue-mr-resume.md`は全面書き直す**: 調査段階では「移行対象パスの書き換えの
  み」で足りると想定していたが、精読の結果、同ファイル全体が旧PowerShell版`Provider.ps1`・
  PascalCase関数（`Get-IssueNumberFromBranch`等）を前提とした記述であり、現行bash版
  `Provider.sh`（snake_case関数）とは単純なパス書き換えでは済まないと判明した。当初は
  「dev-tools分離とは独立した既存バグ」として本issueのスコープ外とする方針だったが、レビューで
  「スコープ外としたものも今回対応してほしい」との指示を受け、全面書き直しを実施した。

## 却下した案

- **`dev-tools/src/`にAI専用スクリプトを残し、`.claude/scripts/`側にシンボリックリンクまたは
  ラッパーを置く**: Windows環境でのシンボリックリンク作成には管理者権限や開発者モードの有効化が
  必要になることがあり、開発機ごとのセットアップ負担が増える。またplugin配布の観点では、配布物に
  実体ファイルが含まれる必要があるため、リンクだけでは解決しない。物理的な移動（`git mv`）を採用。
- **AI専用/人間専用の区別をせず、`dev-tools/`配下を丸ごと`.claude/scripts/`へ改名する**:
  `build.sh`・`distribution.md`はAIエージェントの実行フローに一切登場せず、plugin配布に含める
  必要がない。全部を`.claude/`配下に集約すると、issue #24の目的（AI専用と人間専用の分離）を
  達成できない。
- **ファイル移動に合わせて、移動したDDR・spec内の全ての過去パス参照も新パスへ機械的に置換する**:
  実装中に一度この方式で`sed`による一括置換を行い、spec文書の「## 影響範囲」節（過去issueごとの
  changelog）まで新パスへ書き換えてしまい、当時存在しなかったパスが過去のエントリに紛れ込む形で
  歴史的記録を破壊しかけた。`git checkout --`で復旧し、「現在の状態を説明する節のみ更新し、過去の
  changelog・DDRは書き換えない」方針に切り替えた（上記「決定」参照）。
