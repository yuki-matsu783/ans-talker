#!/usr/bin/env bash
#
# 標準4見出し（目的・現状・期待する動作・受け入れ条件）に沿ってissueを作成するCLIスクリプト
# （issue #25）。`.claude/skills/issue-create/SKILL.md` からAIエージェントが呼び出すほか、
# 人間が直接実行してもよい。
#
# 使い方:
#   .claude/scripts/src/create-issue.sh --title "<タイトル>" --purpose "<目的>" \
#     --current "<現状>" --expected "<期待する動作>" --acceptance "<受け入れ条件>"
#
# 標準出力に、作成したissueのJSON（number/title/body/url/slug）を出力する。
#
# 前提: `gh`（GitHubの場合）/ `glab`（GitLabの場合）CLI。CLIが無い実行環境では内部の `new_issue` が
# `require_vcs_cli` により失敗し、代替すべきMCPツール名（`mcp__github__issue_write`）を提示する
# （issue #34。手順: .claude/skills/issue-create/SKILL.md 手順3の読み替え）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./vcs/Provider.sh
source "${SCRIPT_DIR}/vcs/Provider.sh"

usage() {
  cat <<'EOF'
使い方: create-issue.sh --title <タイトル> --purpose <目的> --current <現状> --expected <期待する動作> --acceptance <受け入れ条件>

すべてのオプションが必須です。
EOF
}

title="" purpose="" current="" expected="" acceptance=""
while [ $# -gt 0 ]; do
  case "$1" in
    --title) title="$2"; shift 2 ;;
    --purpose) purpose="$2"; shift 2 ;;
    --current) current="$2"; shift 2 ;;
    --expected) expected="$2"; shift 2 ;;
    --acceptance) acceptance="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "不明な引数です: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "$title" ] || [ -z "$purpose" ] || [ -z "$current" ] || [ -z "$expected" ] || [ -z "$acceptance" ]; then
  echo "エラー: --title --purpose --current --expected --acceptance はすべて必須です" >&2
  usage >&2
  exit 1
fi

body="$(build_issue_body "$purpose" "$current" "$expected" "$acceptance")"

missing="$(test_issue_sections "$body")"
if [ -n "$missing" ]; then
  echo "エラー: issue本文に以下の見出しがありません: $missing" >&2
  exit 1
fi

new_issue "$title" "$body"
