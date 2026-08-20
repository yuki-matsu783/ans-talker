#!/usr/bin/env bash
#
# Claude Code PreToolUse hook（`git commit`の直接実行をブロック、issue #39）。
# 設計: issue #39 →
#       .claude/docs/ddr/0012-コミットはcommitスキル経由を機構的に強制する.md
#
# 目的: すべてのコミットを `.claude/skills/commit/SKILL.md`（`commit`スキル）経由で行わせる
# （issue #39の受け入れ条件）。ドキュメント上のルールだけではエージェントの遵守に依存するため、
# Bash/PowerShellツールのコマンド文字列に "git commit" が含まれる場合を機構的にブロックする。
#
# .claude/settings.json 側で matcher: "Bash|PowerShell" として広く受け、本スクリプト側で
# command 文字列を正規表現でチェックする（既存の post-push-usage-report.sh と同じ設計。
# `permissions.deny` の prefix マッチだけでは `cd src && git commit -m "fix"` のような
# 複合コマンドをすり抜けてしまうため、hook側でも実文字列を検査する）。
#
# commitスキル自身は `.claude/scripts/src/create-commit.sh` というラッパー経由でコミットするため、
# 呼び出し文字列に "git commit" という部分文字列を含まず、本hookには引っかからない
# （ラッパー内部で `git commit` を実行すること自体は問題ない。本hookが検査するのは
# Bash/PowerShellツールへの「呼び出し文字列」のみで、その呼び出しが実行するスクリプトの
# 内部処理までは見ていないため）。
#
# 既知のトレードオフ: 部分文字列マッチのため、"git commit" という語がコマンド文字列に
# たまたま含まれる場合（該当文字列を検索する grep 等）も誤ってブロックする。悪意ある回避
# （意図的な文字列分割等）への対策は行わない（安全境界ではなく、既定動作を確実な方向へ
# 倒すための仕組み）。

set -uo pipefail

main() {
  set -euo pipefail

  local raw
  raw="$(cat)"
  [ -n "$raw" ] || exit 0

  local hook_input
  hook_input="$(printf '%s' "$raw" | jq -c '.' 2>/dev/null)" || exit 0
  [ -n "$hook_input" ] || exit 0

  local tool_name
  tool_name="$(printf '%s' "$hook_input" | jq -r '.tool_name // empty')"
  if [ "$tool_name" != "Bash" ] && [ "$tool_name" != "PowerShell" ]; then
    exit 0
  fi

  local command
  command="$(printf '%s' "$hook_input" | jq -r '.tool_input.command // empty')"
  [ -n "$command" ] || exit 0

  if printf '%s' "$command" | grep -qiE 'git[[:space:]]+commit'; then
    echo "git commit の直接実行はブロックされています。commit スキル（.claude/skills/commit/SKILL.md）経由で、.claude/scripts/src/create-commit.sh を使ってコミットしてください。" >&2
    exit 2
  fi

  exit 0
}

main
