#!/usr/bin/env bash
# .claude/hooks/post-issue-create-notice.sh の単体テスト（issue #39で新設）。
# ネットワーク・git操作を伴わない純粋関数（is_issue_create_call / write_additional_context）と、
# 「sourceしても本体が実行されない」ことを検証する。
# 規約: passed=N failures=N を標準出力へ出し、失敗があれば終了コード1
#       （.claude/rules/shell-script-style.md「テスト」。test_session_start.sh を雛形にした）。
# 実行: bash .claude/scripts/test/test_post_issue_create_notice.sh
set -euo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" == "${BASH_SOURCE[0]}" ]] && script_dir="."
repo_root="$(cd "$script_dir/../../.." && pwd)"

# source した時点で本体（stdin読み取り・コンテキスト注入）が走らないことが前提。
# 走ってしまう場合、ここでstdin待ちのままハングするか、JSONが標準出力へ漏れる。
# shellcheck source=../../../.claude/hooks/post-issue-create-notice.sh
source "$repo_root/.claude/hooks/post-issue-create-notice.sh"

passed=0
failures=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    passed=$((passed + 1))
  else
    failures=$((failures + 1))
    echo "FAIL: $name"
    echo "  expected: $expected"
    echo "  actual  : $actual"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    passed=$((passed + 1))
  else
    failures=$((failures + 1))
    echo "FAIL: $name"
    echo "  expected to contain: $needle"
    echo "  actual            : $haystack"
  fi
}

# is_issue_create_call の判定結果を 0/1 で受け取る。
# set -e 配下でコマンド置換に頼ると終了コードが取れないため if で受ける
# （.claude/rules/shell-script-style.md「テスト」）。
detect() {
  if is_issue_create_call "$1" "${2:-}" "${3:-}"; then
    printf '0'
  else
    printf '1'
  fi
}

# --- CLI経路（create-issue.sh の実行） ---
assert_eq "Bashでcreate-issue.shを実行したら起票と判定する" "0" \
  "$(detect 'Bash' '.claude/scripts/src/create-issue.sh --title "x" --purpose "y"' '')"
assert_eq "パスの前に別コマンドが連結されていても判定する" "0" \
  "$(detect 'Bash' 'cd /repo && bash .claude/scripts/src/create-issue.sh --title "x"' '')"
assert_eq "Gemini CLIのrun_shell_commandでも判定する" "0" \
  "$(detect 'run_shell_command' '.claude/scripts/src/create-issue.sh --title "x"' '')"
assert_eq "PowerShellでも判定する" "0" \
  "$(detect 'PowerShell' '.claude/scripts/src/create-issue.sh --title "x"' '')"
assert_eq "無関係なコマンドは対象外" "1" "$(detect 'Bash' 'git status' '')"
assert_eq "コマンドが空なら対象外" "1" "$(detect 'Bash' '' '')"

# --- MCP経路（gh/glab CLI不在時。issue #34） ---
assert_eq "issue_writeのmethod=createは起票と判定する" "0" \
  "$(detect 'mcp__github__issue_write' '' 'create')"
assert_eq "issue_writeでもmethod=updateは対象外" "1" \
  "$(detect 'mcp__github__issue_write' '' 'update')"
assert_eq "issue_write以外のMCPツールは対象外" "1" \
  "$(detect 'mcp__github__create_pull_request' '' 'create')"

# --- 注意文の内容 ---
assert_contains "注意文が同一セッションでのstart抑止に言及する" "$NOTICE_TEXT" '/issue-mr-flow start'
assert_contains "注意文が新しいセッションでの実行を勧める" "$NOTICE_TEXT" '新しいセッション'
assert_contains "注意文がHANDOFF.mdを更新しない旨に言及する" "$NOTICE_TEXT" 'HANDOFF.md'

# --- 出力JSONの形 ---
context_json="$(write_additional_context "$NOTICE_TEXT")"
assert_eq "hookEventNameがPostToolUse" "PostToolUse" \
  "$(printf '%s' "$context_json" | jq -r '.hookSpecificOutput.hookEventName')"
assert_eq "additionalContextへ注意文がそのまま入る" "$NOTICE_TEXT" \
  "$(printf '%s' "$context_json" | jq -r '.hookSpecificOutput.additionalContext')"

echo "passed=$passed failures=$failures"
[[ "$failures" -eq 0 ]]
