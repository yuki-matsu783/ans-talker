---
title: AIエージェント共通ルール
type: rule
description: 複数のAIコーディングエージェント（Claude Code, Gemini CLI等）が共通で従うルール・プロジェクト概要・開発実行方法
tags: [agents, rule]
keywords: [issue-mr-flow, 計画, claude-code, gemini-cli, gh, glab, webfetch, 着手確認, doc-search, index.jsonl, ドキュメント探索]
---

## ルール

- ユーザへの応答・対話はすべて日本語で行う
- 開発フロー全体（issueの起票〜マージ）は `.claude/skills/issue-mr-flow/SKILL.md` を参照する
  （唯一の実装フロー定義）。**誤字修正・軽微なドキュメント修正等、フロー自体を省略してよい
  ごく小さな変更を除き、全タスクはissueを起点に進める**（除外時はmainへの直接コミットも
  許容する。ブランチ運用の詳細は `.claude/rules/git-workflow.md`「適用範囲」参照）。
- **issueを起票したこと自体は、そのissueに着手してよいという指示ではない**。issue起票
  （`.claude/skills/issue-create/SKILL.md`）の直後に、同じセッションで
  `/issue-mr-flow start <issue番号>` へ進んでよいのは、ユーザーから明示的な着手の指示があった
  ときだけである。AIから着手を持ちかけず、新しいセッションでの実行を勧めるに留める
  （どのissueにいつ着手するかの判断を人間が握るため。issue #39。詳細は
  `.claude/skills/issue-create/SKILL.md`「してはいけないこと」・
  `.claude/skills/issue-mr-flow/SKILL.md`「`start`」節、
  `.claude/docs/ddr/0038-issue起票後の着手確認はブロックせず注意喚起の注入で担保する.md`）。
- 特別なコンテキストなしで回答可能な簡易タスクを除き、いかなるタスク（調査、設計、コード作成、テスト、リファクタリングなど）も、**実作業を開始する前に必ず「計画（Plan）」を立ててユーザーに提示**する
- 計画はplansディレクトリ配下に保存する。計画は2階層に分ける（詳細は
  `.claude/skills/issue-mr-flow/SKILL.md`「計画の2階層構造」）
  - **全体作業計画**: planツール（Planモード）で作成。**issue（ブランチ）につき1回**だけ作り、
    既にあれば新規作成しない
  - **個別作業計画**: `plans/【種別】タスク内容.md` として**planツールを使わず**作成する
- 計画がユーザーに承認（Approve）されるまで、ファイルの書き換えやコマンドの実行を行ってはいけない
- コーディング規約・ディレクトリ構成・ドキュメント運用などの詳細ルールは `.claude/rules/` 配下を参照する
- GitHub/GitLabのissue・PR/MR・コメント等の情報を取得する際は、WebFetchツールやcurlではなく
  `gh`/`glab` CLI（`.claude/scripts/src/vcs/Provider.sh` 経由）を使う。認証済みで構造化JSONが
  得られ、`.claude/skills/issue-mr-flow/SKILL.md` の各サブコマンドとも一貫するため（詳細・却下案は
  `.claude/docs/ddr/0020-GitHub_GitLab情報取得はgh_glab-CLIを使いWebFetchは使わない.md` 参照）。
  **`gh`/`glab` CLIが実行環境に存在しない場合**（例: Claude Code on the webのリモート実行環境。
  issue #21対応時に実機確認）は、`Provider.sh`が動作しないため、同等の機能を持つGitHub/GitLab
  公式のMCPサーバーツール（例: `mcp__github__*`）で代替してよい。WebFetchツールやcurlへは
  フォールバックしない（この場合もDDR 0020の理由は変わらないため）。**経路の判定方法
  （`get_vcs_access_mode`）と、Provider関数・サブコマンドごとのMCPツール対応表は
  `.claude/skills/issue-mr-flow/SKILL.md`「`gh`/`glab` CLI不在時のMCPフォールバック」節が正**
  （issue #34。GitLabは対象外）。
- **リポジトリ内のドキュメントを探すときは、`grep`/`rg`/`find`/Globによる全文探索より先に、
  frontmatterインデックス（`index.jsonl`）の横断検索を使う**（`doc-search` スキル、実体は
  `bash .claude/scripts/src/search-frontmatter.sh`）。「〜についてのDDRはどれか」「specの一覧」
  「workflowタグのルール」のように**ドキュメントそのもの**を探す問いは、`type`/`title`/
  `description`/`tags`/`keywords` を持つインデックスだけで答えられ、本文を開く必要が無い。
  全文探索はヒット行しか返さないため、そのファイルが何のドキュメントかを判断するのに結局
  ファイルを開くことになり、他ファイルからの参照リンクや変更履歴中の言及も同じ重みで混ざる。
  **`grep`/`rg` を使うのは、本文中の特定の文字列（関数名・コード片・言い回し）を探すとき**、
  またはインデックス検索が0件だったときに限る。使い方・jqレシピは
  `.claude/skills/doc-search/SKILL.md`、仕様は `.claude/docs/spec/search-frontmatter.md`
  （issue #38。理由・却下案は
  `.claude/docs/ddr/0049-ドキュメント探索はfrontmatterインデックス検索を第一手段にする.md`）。

## プロジェクト概要

<!-- TODO: このリポジトリで開発するプロダクト・アプリの概要をここに記載する -->

このリポジトリは、issue駆動MRワークフロー機構（`.claude/` 一式・`.mrworkflow.json`・issue
テンプレート等）のテンプレートです。アプリ本体を追加する際は、このセクションをプロジェクト概要
（何を実装するリポジトリか）で置き換えてください。

## 開発・実行

<!-- TODO: このプロジェクトの実行方法・推奨開発環境を記載する -->
