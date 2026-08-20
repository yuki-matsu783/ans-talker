---
title: 0027. gh/glab CLI不在時はMCPフォールバック経路へ機構的に誘導する
type: ddr
description: gh/glab CLIが無い実行環境で、経路判定関数とProvider関数のガードによりMCPツールでの代替へ機構的に誘導する方式を採用し、GitLabを対象外とした経緯を記録したDDR
tags: [mcp, provider, fallback, ddr]
keywords: [get_vcs_access_mode, require_vcs_cli, mcp__github, Claude Code on the web, gh, glab, DDR0020, issue-34]
---

# 0027. gh/glab CLI不在時はMCPフォールバック経路へ機構的に誘導する

## 背景

issue #34「gh/glab CLIが無い環境向けのMCPフォールバック経路をスキル・スクリプトに実装する」。

`AGENTS.md` は以前から「`gh`/`glab` CLIが実行環境に存在しない場合（例: Claude Code on the webの
リモート実行環境。issue #21対応時に実機確認）は、同等の機能を持つGitHub/GitLab公式のMCPサーバー
ツール（例: `mcp__github__*`）で代替してよい」と定めていた。しかし `.claude/skills/`・
`.claude/hooks/`・`.claude/scripts/` にMCPへの言及は1件も無く、**「どの関数をどのツールへ
読み替えるか」が定義されていない**ため、AIエージェントが毎回その場の判断でツールを選んでいた
（issue #22対応セッションで実際に発生し、`HANDOFF.md` にその旨が記録されていた）。

同じ理由で `session-start.sh` のissue/MR情報取得も機能しない。しかも失敗を握りつぶす実装
だったため、PRが存在していても「PR: なし」という**誤った情報がコンテキストへ注入されていた**。

## 決定

1. **経路判定を関数化する**: `Provider.sh` に `get_vcs_access_mode`（`cli` / `mcp` を返す）を
   追加し、`.claude/skills/issue-mr-flow/SKILL.md` の各サブコマンドは手順に入る前にこれを呼ぶ。
   判定はAIの主観ではなく `command -v gh` / `command -v glab` の結果に基づく。
2. **CLI経路の関数はCLI不在時に「代替手段を名指しして」失敗させる**: プロバイダ依存の8関数の
   先頭で `require_vcs_cli` を呼び、代替すべきMCPツール名と引数・`get_repo_slug` での
   owner/repo取得方法・SKILL.mdの該当節・WebFetch/curlを使わない旨をstderrへ出して終了コード1を
   返す。手順を読まずにCLIを呼んだ場合でも同じ案内へ収束する。
3. **対応表はSKILL.mdに一元化する**: Provider関数・サブコマンドごとのMCPツールと引数の対応は
   `.claude/skills/issue-mr-flow/SKILL.md`「`gh`/`glab` CLI不在時のMCPフォールバック」節を正とし、
   specやスクリプトのコメントには要約のみを置く（二重管理を避ける）。
4. **`get_repo_url` だけはガードの例外とする**: リモートURLの取得は `git remote get-url origin`
   というローカル操作で足りるため、MCP経路では `get_repo_slug` から組み立てて返す。これにより
   `get_mr_diff_url` / `get_mr_diff_since_url` がMCP経路でも動き、
   `post-push-compact-prompt.sh` のレビュー依頼メッセージを「MRリンクだけ欠ける」程度の縮退に
   留められる。
5. **GitLabは対象外とする**: `glab` 不在時のGitLab向けMCP代替は、このリポジトリでGitLab公式MCP
   サーバーの利用実績が無く、ツール名・引数を実機検証できないため対象外とする。判定と失敗
   メッセージの枠組みだけ共通化し、`mcp_tool_hint` はGitLabに対して「対象外」である旨を返す。
   将来実機検証できた時点でSKILL.mdへ同形式の表を追加すればよい。
   - **issue #48（DDR 0026）でGitLab CE 18.5.4を用いた実機検証が行われたが、これは `glab` CLI
     経路の検証であり、GitLab MCPサーバーの検証ではない。** 本DDRの「対象外」判断が対象と
     しているのは後者であり、issue #48の成果によって覆るものではない（`glab` があるGitLab環境は
     従来どおりCLI経路で動作する）。

DDR 0020（GitHub/GitLab情報取得は`gh`/`glab` CLIを使い、WebFetch/curlは使わない）とは矛盾しない。
DDR 0020が禁じているのは**HTMLスクレイピング・未認証アクセスという情報取得手段**であり、MCP
サーバーツールは認証済み・構造化JSONという点で `gh`/`glab` と同じ性質を持つ。本DDRは
「CLIが使えない場合の代替は**MCPのみ**であり、WebFetch・curlへは引き続きフォールバックしない」
ことを、実装（`require_vcs_cli` のメッセージ）とドキュメントの両方で明示する。

## 却下した案

- **ドキュメントに対応表を書くだけで、スクリプトは変更しない**: issue #34の受け入れ条件は
  ドキュメントだけでも形式上は満たせる。しかし、既にAGENTS.mdに「MCPで代替してよい」と
  書かれていたにもかかわらず即興判断が発生した実績があり、**「読まれなければ機能しない」対策は
  同じ失敗を繰り返す**と判断した。DDR 0012（コミットは`commit`スキル経由を機構的に強制する）と
  同じ考え方で、実行時に必ず目に入る失敗メッセージへ誘導を組み込む方式を採用した。
- **`Provider.sh` 自体がMCPを呼ぶ（CLIとMCPを完全に透過化する）**: 呼び出し側を一切変えずに
  済むのが理想だが、MCPツールはAIエージェントのツール呼び出しとしてのみ発火し、bashスクリプトの
  プロセスからは呼べない。実現するにはMCPサーバーへHTTP/JSON-RPCで直接アクセスする独自
  クライアントが必要になり、認証情報の取り回しを含めて本issueの範囲を大きく超える（かつ、
  それはDDR 0020が避けたかった「独自の生API呼び出し」に近づく）。よって却下した。
- **CLI不在時にhookも含めて完全に無効化する（何も出力しない）**: 実装は最も単純だが、
  `post-push-compact-prompt.sh` のレビュー依頼メッセージのように、CLIが無くても大部分が
  成立する機能まで失われる。`get_repo_url` のローカルフォールバックによって成立する範囲は
  残す方針とした。
- **`get_mr_for_branch` 等をCLI不在時に「空を返して成功」とする**: 既存の
  `github_get_mr_for_branch` は `gh pr view` の失敗を握りつぶして空を返す実装であり、これを
  そのままCLI不在時にも適用すると「PRが無い」と区別が付かない。実際に `session-start.sh` が
  「PR: なし」と誤表示していた原因がこれであり、**沈黙する縮退は誤情報を生む**ため採用しなかった。
