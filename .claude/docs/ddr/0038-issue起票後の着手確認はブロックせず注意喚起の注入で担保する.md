---
title: 0038. issue起票後の着手確認はブロックせず注意喚起の注入で担保する
type: ddr
description: issue起票直後の自動着手を防ぐ機構として、PreToolUse hookによるブロックではなくPostToolUse hookによる注意喚起の注入を採用した理由と却下案を記録したDDR
tags: [issue-create, hook, ddr, workflow]
keywords: [着手確認, posttooluse, pretooluse, ブロック, 注意喚起, additionalContext, issue-create, issue-mr-flow, 多重防御]
---

# 0038. issue起票後の着手確認はブロックせず注意喚起の注入で担保する

## 背景

issue #39「issue起票後にissue-mr-flowへ進む際は必ず人間の確認を挟む」。AIエージェントがissueを
起票した流れのまま、人間の確認なしにブランチ・Draft MR作成（`/issue-mr-flow start`）まで
進んでしまう事故が実際に起きた（issue #38の起票直後、確認を挟まないまま `start 38` へ進み、
issue取得・既存ブランチ確認まで実行した。ユーザーの中断により、ブランチ・Draft MR作成の手前で
止まったため実害は無かった）。

**注記（issue番号の体系）**: 本DDRが参照する `issue #39` は、本リポジトリのissue #39である。
DDR 0012（コミットはcommitスキル経由を機構的に強制する）が参照する「issue #39」は移植元
リポジトリの別issue（コミットSkillの利用をルール化するもの）であり、両者は別物である
（本リポジトリのissue番号と移植元の番号は、初期のものほど一致しない）。

issue #59で `issue-create` スキル側の導線（同一セッションでそのまま着手させない・新しいセッションでの
実行を勧めるに留める）は既に整備されていたが、記載が `issue-create` スキル内に閉じており、
`issue-mr-flow` の `start` 側・共通ルール（`AGENTS.md`）からは辿れなかった。またissueは、
コミットの直接実行禁止（DDR 0012）と同様の機構的な強制が成立するかの検討も求めていた。

## 決定

**ドキュメントでの明示（`issue-create` / `issue-mr-flow` の各SKILL.md・`AGENTS.md`）を一次的な
担保とし、機構側は「ブロック」ではなく「注意喚起の注入」に留める。**

- **`.claude/hooks/post-issue-create-notice.sh`（新規、PostToolUse hook）**: issueの起票を検知して、
  「同一セッションで `/issue-mr-flow start` へ進まない」「新しいセッションでの実行を勧めるに
  留める」「AIから着手を持ちかけない」「`HANDOFF.md` は更新しない」という注意を
  `hookSpecificOutput.additionalContext` でコンテキストへ注入する
  （`post-push-compact-prompt.sh` と同じ伝達手段）。
  - 検知は2経路。CLI経路はコマンド文字列に `create-issue.sh` を含む場合、MCP経路
    （`gh`/`glab` CLI不在時。issue #34）は `mcp__github__issue_write` の `method="create"`。
    どちらも起票の**後**に発火するため、起票そのものは妨げない。CLI不在時に縮退しない点が
    既存の3つのhookと異なる。
  - 判定は純粋関数 `is_issue_create_call` に切り出し、`.claude/scripts/test/test_post_issue_create_notice.sh`
    で単体テストしている（`source` しても本体が走らないガードも含む）。
- **hookは多重防御であり、判断の根拠ではない。** 注入が無かったことを着手してよい根拠にしては
  ならない旨を、`issue-create` / `issue-mr-flow` の両SKILL.mdに明記した。

## 却下した案

- **PreToolUse hookで `start` 相当の操作をブロックする（exit code 2）**: DDR 0012と同じ形の
  機構的強制。次の2点が揃わないため採用しなかった。
  - **禁止したい操作を文字列で一意に特定できない。** コミットの直接実行（DDR 0012）と違い、
    `start` の実体は `new_issue_branch`（Bash）・`git checkout -b`・リモートへの反映・MCP経路の
    `mcp__github__create_pull_request` に分かれる。ブランチ作成・リモートへの反映は通常の開発操作でも
    日常的に使う汎用コマンドであり、文字列マッチでは取りこぼしと誤検知が同時に増える
    （既存hookの部分文字列マッチが実際に誤検知を起こしている実績がある。
    `.claude/rules/git-workflow.md`「push検知hookの誤検知」参照）。
  - **「人間が明示的に着手を指示した」という正当ケースを機構が観測できない。** ユーザーの指示は
    通常のプロンプトで与えられることが多く、hookイベントとしては届かない（`AskUserQuestion` の
    呼び出し自体は検知できるが、その質問が着手可否だったか・回答が承認だったかの判定は選択肢の
    文字列マッチに依存し脆い）。正当ケースの解除手段が「hookを黙らせる」「状態ファイルを消す」しか
    無い強制は、規範そのものを形骸化させる。コミット経路の禁止が成立するのは、
    `create-commit.sh` という**常に使える正規の代替経路**があるからで、今回はそれに相当するものが
    無い。
- **セッション単位の状態ファイルで「このセッションで起票した」ことを記録し、以降の
  `new_issue_branch` を禁止する**: 状態の持ち方としては実装可能（hook入力の `session_id` を使う）。
  ただし解除は結局「AIが自分で状態ファイルを消す」形になり、上と同じ理由で強制になっていない。
  状態ファイルの残骸が次セッション以降へ影響する運用コスト（`usage/` `.claude/state/` に続く
  3つ目のローカル状態）に対して得られるものが小さい。
- **ドキュメントのみで対応する（hookを作らない）**: issue #59の対応がまさにこれで、`issue-create`
  スキルには既に「同一セッションで `start` へ進まない」と書かれていたにもかかわらず事故は起きた。
  記載を増やすだけでは、起票直後という**流れで進んでしまう瞬間**に効きにくい。起票の直後に一度だけ
  注意を注入するのは副作用が無く、この瞬間に対して直接効くため併用することにした。
