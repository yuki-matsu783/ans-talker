#!/usr/bin/env bash
#
# Claude Code / Gemini CLI 共通 PostToolUse・AfterTool hook（issue起票の検知、同一セッションで
# issue-mr-flow へ進まないよう注意を促すメッセージ注入）。
# 設計: issue #39 →
#       .claude/docs/spec/issue-mr-workflow.md「issue起票後の着手確認（issue #39）」,
#       .claude/docs/ddr/0038-issue起票後の着手確認はブロックせず注意喚起の注入で担保する.md
#
# 目的: AIエージェントがissueを起票した流れのまま、人間の確認なしにブランチ・Draft MR作成
# （`/issue-mr-flow start`）まで進んでしまうのを防ぐ。どのissueにいつ着手するかの判断を
# 人間が握れるようにするための、ドキュメント（issue-create / issue-mr-flow の各SKILL.md）に
# 対する多重防御。
#
# **ブロック（PreToolUse + exit 2）は行わない。** 「人間が明示的に着手を指示した」という正当な
# ケースをhookからは観測できず、ブロックするとその解除手段が「hookを黙らせる」ことになって
# しまうため。判断はエージェントに委ね、hookは起票の直後に一度だけ注意を注入する役割に留める
# （却下案を含む詳細はDDR 0038参照）。
#
# 検知対象は2経路ある（`.claude/settings.json` の matcher で両方を受ける）。
#   - CLI経路: Bash/PowerShell/run_shell_command のコマンド文字列に `create-issue.sh` を含む
#   - MCP経路: `mcp__github__issue_write` の `method` が `create`（`gh`/`glab` CLI不在時。issue #34）
# いずれもツール実行「後」に発火するため、起票そのものは妨げない。
#
# 既知のトレードオフ: 既存の push/commit 検知hookと同じく部分文字列マッチのため、
# `create-issue.sh` という語をたまたま含むコマンド（該当ファイルを開く・検索する等）でも
# 発火する。注入されるのは注意文だけで処理は妨げないため、実害は小さいものとして許容する。
#
# 注意（エラー方針）: 本体処理は `main` にまとめ、`( main )` の実サブシェルで呼ぶ
# （.claude/rules/shell-script-style.md「bashでのtry/catch相当の書き方」）。失敗はすべて
# 握りつぶし、元のツール実行はブロックしない。

set -uo pipefail

NOTICE_TEXT='issueの起票を検知しました（issue #39）。このまま同一セッションで `/issue-mr-flow start` へ進まないでください。

- 起票結果（issue番号・URL）をユーザーへ提示し、着手する際は**新しいセッション**で `/issue-mr-flow start <issue番号>` を実行することを勧めるに留めること（起票と実装が同じセッションに同居すると、進行中の別issueのブランチ・MRと作業コンテキストが混ざるため）。
- 着手するかどうかをAIから持ちかけないこと。着手してよいのは、ユーザーからの明示的な指示があったときのみ。
- この時点ではまだissueに対応するブランチが無いため、`HANDOFF.md` は更新しないこと（更新はflow-id 1-6の担当）。

詳細: `.claude/skills/issue-create/SKILL.md`「してはいけないこと」。'

write_additional_context() {
  local text="$1"
  jq -nc --arg text "$text" \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $text}}'
}

# issue起票の呼び出しかどうかを判定する純粋関数（外部コマンド呼び出し無し）。
# $1=tool_name $2=コマンド文字列（CLI経路） $3=method（MCP経路）
# 起票と判定した場合のみ 0 を返す。
is_issue_create_call() {
  local tool_name="$1" command="${2:-}" method="${3:-}"
  case "$tool_name" in
    run_shell_command | Bash | PowerShell)
      [[ "$command" == *create-issue.sh* ]]
      ;;
    mcp__github__issue_write)
      [[ "$method" == "create" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

main() {
  set -euo pipefail

  local raw
  raw="$(cat)"
  [ -n "$raw" ] || exit 0

  local hook_input
  hook_input="$(printf '%s' "$raw" | jq -c '.' 2>/dev/null)" || exit 0
  [ -n "$hook_input" ] || exit 0

  local agent_id
  agent_id="$(printf '%s' "$hook_input" | jq -r '.agent_id // empty')"
  # サブエージェント内実行では何もしない（post-push-usage-report.shと同じガード）
  [ -z "$agent_id" ] || exit 0

  local tool_name command method
  tool_name="$(printf '%s' "$hook_input" | jq -r '.tool_name // empty')"
  command="$(printf '%s' "$hook_input" | jq -r '.tool_input.command // empty')"
  method="$(printf '%s' "$hook_input" | jq -r '.tool_input.method // empty')"

  is_issue_create_call "$tool_name" "$command" "$method" || exit 0

  write_additional_context "$NOTICE_TEXT"
}

# source 時に本体（stdin読み取り）が走らないようにする
# （.claude/rules/shell-script-style.md「テスト」）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  ( main ) || true
  exit 0
fi
