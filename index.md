---
title: Repository Map
type: guide
description: プロジェクトルートから各ディレクトリへの相対パスと役割をまとめたリポジトリマップ
tags: [index, repository-map, guide]
keywords: [directory, repository-map, リポジトリマップ, ディレクトリ, claude, gemini, plans, worklog]
---

# Repository Map

このリポジトリの主要ディレクトリの一覧。**各ディレクトリの役割説明は本ファイルを正とし**、
ファイル単位の詳細は記載しない（重複を避けるため）。ディレクトリツリー構造・配置ルールは
[.claude/rules/directory-structure.md](.claude/rules/directory-structure.md)を、ドキュメントの
置き場所・ライフサイクルは [.claude/rules/docs-workflow.md](.claude/rules/docs-workflow.md) を参照。

## Directory Structure

- [./.claude/](./.claude/) Claude Code向けのルール・スキル・エージェント・hook・スクリプト定義一式。
  - [./.claude/docs/](./.claude/docs/) issue駆動MRワークフロー機構自体の設計ドキュメント。
    - [./.claude/docs/spec/](./.claude/docs/spec/) 機能ごとの正史仕様（最新の仕様を上書き更新）。
    - [./.claude/docs/ddr/](./.claude/docs/ddr/) 意思決定ログ（DDR: Design Decision Record。追記のみ）。
  - [./.claude/rules/](./.claude/rules/) AI向け詳細ルール（コーディング規約・ディレクトリ構成・ドキュメント運用等）。
  - [./.claude/skills/](./.claude/skills/) `/issue-mr-flow`（唯一の実装フロー定義）・`/commit`
    ・`/issue-create`・`/resolve-conflict`・`/canvas-report`・`/doc-search` のスキル定義。
  - [./.claude/agents/](./.claude/agents/) サブエージェント定義（issue-mr-flow途中引き継ぎ用）。
  - [./.claude/scripts/](./.claude/scripts/) AIエージェントが`.claude/skills/*`経由で能動的に実行するスクリプト一式。
    - [./.claude/scripts/src/](./.claude/scripts/src/) issue駆動MRワークフロー支援スクリプト等（bash）。
      - [./.claude/scripts/src/vcs/](./.claude/scripts/src/vcs/) GitHub/GitLabの差異を吸収するVCS抽象化層（`Provider.sh`）。
    - [./.claude/scripts/test/](./.claude/scripts/test/) 副作用の無い純粋ロジックの単体テスト（`test_<対象>.sh`）。
      `passed=N failures=N`を出力し失敗時は終了コード1。
  - [./.claude/hooks/](./.claude/hooks/) SessionStart/PostToolUse等のClaude Code hookスクリプト。
    - [./.claude/hooks/lib/](./.claude/hooks/lib/) 複数hookスクリプトで使い回す共通ロジック。
- [./.gemini/](./.gemini/) Gemini CLI向け設定。`settings.json`のみGit管理。`docs/`・`hooks/`・
  `rules/`・`scripts/`・`skills/`は`.claude/`配下の同名ディレクトリへのローカルリンクで、
  `.gitignore`対象（Git管理外。理由は`.claude/rules/directory-structure.md`参照）。
  clone後は`bash .claude/scripts/src/setup-gemini-links.sh`を1回実行してリンクを作成する。
- `./plans/` 計画ファイル。全体作業計画（planツールが出力する`<自動命名>.md`、issueにつき1つ）と個別作業計画（`【種別】タスク内容.md`、planツールを使わずWrite/Editで作成）の2階層。タスクごとに新規生成しそのままコミットして履歴として残す。**flow-id 5-1で削除するためディレクトリが存在しない期間があり、リンクにしていない**。
- [./worklog/](./worklog/) 実装中の詳細な試行錯誤ログ（`日付_<全体計画名>_<個別計画名>_push<N>.md`）。内容は設計反映（flow-id 4-6）でspec/ddrへ反映し、ファイル自体はflow-id 5-1で`plans/` `reports/`とまとめて削除する。
- [./.github/ISSUE_TEMPLATE/](./.github/ISSUE_TEMPLATE/) GitHub用issueテンプレート（目的・現状・期待する動作・受け入れ条件）。
- [./.gitlab/issue_templates/](./.gitlab/issue_templates/) GitLab用issueテンプレート（同上）。
- `./build/` ビルド成果物の出力先。`.gitignore` 対象でコミットしない（通常は空）。**Git管理下に実体を持たないためリンクにしていない**（`.gitignore`の`/build/`対象で、ビルド時に動的に作成される）。

`reports/`（`日付_<全体計画名>_<内容を簡潔に>.md` が調査結果・作業結果・反映結果の正文で、個別計画へ
結果を書かないための分離先。同名の `.html` はその内容を視覚的にまとめた報告用の自己完結HTML）・
`usage/`（対応工数レポートのローカル作業状態）は、いずれもワークフロー実行中に動的に作成される
ディレクトリのため上記には含まれない（詳細: `.claude/rules/docs-workflow.md`）。

このリポジトリはissue駆動MRワークフロー機構そのものを配布するテンプレートであり、現時点では
`src/` 等のアプリ本体コードを持たない。アプリ本体を追加する場合は、そのアプリ専用の
`docs/spec/` `docs/ddr/`（必要なら人間専用ツール用の `dev-tools/`）を新設し、`.mrworkflow.json`
の `specDirs`/`ddrDirs` に追記することを検討する（詳細: `.claude/rules/directory-structure.md`
「配置の指針」）。
