---
title: 0020. GitHub/GitLabの情報取得はgh/glab CLIを使い、WebFetch/curlは使わない
type: ddr
description: AIエージェントがGitHub/GitLabのissue・PR/MR・コメント等の情報を取得する際、WebFetchツールやcurlではなくgh/glab CLI（Provider.sh経由）を使う方針をAGENTS.mdへ明記した経緯を記録したDDR
tags: [gh, glab, webfetch, provider, ddr]
keywords: [WebFetch, curl, gh, glab, Provider.sh, 認証, 構造化JSON, issue-14]
---

# 0020. GitHub/GitLabの情報取得はgh/glab CLIを使い、WebFetch/curlは使わない

## 背景

issue #14「gitlab/githubの情報についてはwebfetchではなくgh,glabを利用して情報取得することを明記」
（目的:「web fetchやcurlをするよりコマンドを使うようにする」）。

このリポジトリは既に `.claude/scripts/src/vcs/Provider.sh`（`gh`/`glab` CLIを介してGitHub/GitLabの
issue・PR/MR・レビューコメント等を取得するVCS抽象化層）を持ち、`.claude/skills/issue-mr-flow/
SKILL.md` の各サブコマンドは一貫してこの経由で情報取得している。一方で「GitHub/GitLabの情報は
WebFetchツールやcurlではなくgh/glab CLIを使う」という方針そのものは、`AGENTS.md`・
`.claude/rules/`配下・`SKILL.md`のいずれにも明文化されていなかった（"WebFetch" "curl" の言及は
リポジトリ内に存在しないことをgrepで確認済み）。

明文化されていないことで、Provider.sh経由の既存関数が無い/気づかれない場面（単発のPRページ確認等）で
AIエージェントがWebFetchツールへ流れるリスクがあった。

## 決定

`AGENTS.md` の「## ルール」節に以下を追記し、方針を明文化する。

> GitHub/GitLabのissue・PR/MR・コメント等の情報を取得する際は、WebFetchツールやcurlではなく
> `gh`/`glab` CLI（`.claude/scripts/src/vcs/Provider.sh` 経由）を使う。

理由:

- `gh`/`glab` CLIは既にユーザーの認証情報でログイン済みであり、WebFetchのようなレート制限や
  非公開issue/PRへの未認証アクセスの問題を回避できる。
- `gh`/`glab` は構造化JSONを返し `jq` で確実に扱える。WebFetchによるHTMLページのスクレイピングは、
  GitHub/GitLab側のページ構造変更に弱く、必要な情報（レビュースレッドのthreadId等）がHTML上に
  そのまま出ていないこともある。
- 既存の`Provider.sh`抽象化・`issue-mr-flow`スキルの各サブコマンドと動作が一貫する。

技術的な強制（`.claude/hooks/block-direct-git-commit.sh`と同様のPreToolUse hookでWebFetchツールの
呼び出し自体をブロックする等）は本issueのスコープ外とし、ドキュメントでの明記に留める。

## 却下した案

- **hookによる機構的ブロック**: `block-direct-git-commit.sh`（DDR 0012）と同様に、WebFetchツールの
  使用を検知しブロックするPreToolUse hookを新設する案。`git commit`の直接実行のような不可逆・
  検知しづらい操作と異なり、WebFetch使用は実害が限定的（誤った情報取得手段を使っただけで、
  データ破壊や意図しない副作用は伴わない）で、レビュー時にも気づきやすいため、hookによる
  機構的強制は現時点では過剰と判断し却下した。将来、同種の逸脱（WebFetchでのGitHub/GitLab情報
  取得）が繰り返し発生するようであれば、DDR 0012と同じ設計方針で再検討してよい。
