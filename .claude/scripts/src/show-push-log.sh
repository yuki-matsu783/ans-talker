#!/usr/bin/env bash
#
# push断面のセッションログを表示するCLIスクリプト（issue #23）。
# 設計: issue #23 → .claude/docs/spec/issue-mr-workflow.md
#
# 以前は post-push-save-logs.sh が push のたびにtranscript全文を logs/push-<N>/ へコピーして
# いたが、transcriptが追記専用であること（各push断面が現物の先頭N行とバイト単位で一致し、
# `/compact` を挟んでもこの性質が保たれること）が実データで確認されたため、全文コピーを廃止し
# 「1本のミラー（usage/session-logs/<sessionId>/main.jsonl）＋行範囲の記録
# （usage/state/push-index.jsonl）」へ置き換えた。本スクリプトはその行範囲を使って、
# 従来 logs/push-<N>/ を開いて見ていたのと同じ情報を取り出すためのもの。
#
# 使い方:
#   show-push-log.sh                  # push一覧（push番号・日時・ブランチ・行範囲）を表示
#   show-push-log.sh <push番号>       # そのpushで新たに記録されたメインログの範囲を出力
#   show-push-log.sh <push番号> --agents  # 同じpushのサブエージェント分もあわせて出力

set -euo pipefail

usage() {
  cat <<'EOF'
使い方:
  show-push-log.sh                      push一覧を表示する
  show-push-log.sh <push番号>           そのpushで記録されたメインログの範囲を出力する
  show-push-log.sh <push番号> --agents  サブエージェント分もあわせて出力する
EOF
}

# リポジトリルートを求める（Provider.sh の get_repo_root と同じ考え方だが、本スクリプトは
# VCS操作を一切行わないため Provider.sh をsourceせず自前で解決する）。
resolve_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# 指定ファイルの from〜to 行（1始まり・両端含む）を出力する。
#
# 重要: push-index.jsonl の行番号は、集計側（UsageTracking.sh の _usage_aggregate_new_lines /
# _usage_aggregate_transcript）と同じ「**空行を除いた**行数」を基準にしている
# （jqの `select(length > 0)` 相当）。そのため物理行番号で切り出す素の `sed -n 'N,Mp'` は使えず、
# 先に空行を落としてから範囲を取る必要がある。実データのtranscriptに空行は観測されていないため
# 通常は一致するが、基準を揃えておかないと空行が1つ入った瞬間にズレる。
extract_range() {
  local file="$1" from="$2" to="$3"
  grep -v '^[[:space:]]*$' "$file" | sed -n "${from},${to}p"
}

repo_root="$(resolve_repo_root)"
index_file="${repo_root}/usage/state/push-index.jsonl"

if [ ! -f "$index_file" ]; then
  echo "push-index が見つかりません: ${index_file}" >&2
  echo "（git push が一度も検知されていないか、usage/ が削除されています）" >&2
  exit 1
fi

show_agents=false
push_num=""
while [ $# -gt 0 ]; do
  case "$1" in
    --agents) show_agents=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [ -z "$push_num" ]; then
        push_num="$1"; shift
      else
        echo "不明な引数です: $1" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

# 引数なし: push一覧を表示する
if [ -z "$push_num" ]; then
  printf 'push  日時                  行範囲        ブランチ / セッション\n'
  printf '%s\n' "----------------------------------------------------------------------"
  jq -r '
    [(.push|tostring), .at, "\(.main.from)-\(.main.to)", .branch, .sessionId] | @tsv
  ' "$index_file" 2>/dev/null | tr -d '\r' | while IFS=$'\t' read -r p at range branch session; do
    printf '%-5s %-21s %-13s %s (%s)\n' "$p" "$at" "$range" "$branch" "$session"
  done
  exit 0
fi

if ! printf '%s' "$push_num" | grep -qE '^[0-9]+$'; then
  echo "push番号は整数で指定してください: ${push_num}" >&2
  exit 1
fi

entry="$(jq -c --argjson n "$push_num" 'select(.push == $n)' "$index_file" | tr -d '\r' | head -n 1)"
if [ -z "$entry" ]; then
  echo "push ${push_num} は push-index に存在しません（一覧: show-push-log.sh）" >&2
  exit 1
fi

session_id="$(printf '%s' "$entry" | jq -r '.sessionId' | tr -d '\r')"
main_from="$(printf '%s' "$entry" | jq -r '.main.from' | tr -d '\r')"
main_to="$(printf '%s' "$entry" | jq -r '.main.to' | tr -d '\r')"
log_dir="${repo_root}/usage/session-logs/${session_id}"
main_log="${log_dir}/main.jsonl"

if [ ! -f "$main_log" ]; then
  echo "ミラーが見つかりません: ${main_log}" >&2
  echo "（usage/session-logs/ が削除されたか、別マシンで記録されたpushです）" >&2
  exit 1
fi

echo "# push ${push_num} / main (${main_from}-${main_to}) / session ${session_id}" >&2
extract_range "$main_log" "$main_from" "$main_to"

if [ "$show_agents" = true ]; then
  # `tr -d '\r'`: WindowsネイティブjqはコマンドAND置換の出力にもCRを付与するため、
  # forに渡す前に除去する（.claude/rules/shell-script-style.md「文字コード」節）。
  for agent_id in $(printf '%s' "$entry" | jq -r '.agents // {} | keys[]' | tr -d '\r'); do
    a_from="$(printf '%s' "$entry" | jq -r --arg id "$agent_id" '.agents[$id].from' | tr -d '\r')"
    a_to="$(printf '%s' "$entry" | jq -r --arg id "$agent_id" '.agents[$id].to' | tr -d '\r')"
    agent_log="${log_dir}/subagents/agent-${agent_id}.jsonl"
    if [ ! -f "$agent_log" ]; then
      echo "# agent ${agent_id}: ログが見つかりません（${agent_log}）" >&2
      continue
    fi
    echo "# push ${push_num} / agent ${agent_id} (${a_from}-${a_to})" >&2
    extract_range "$agent_log" "$a_from" "$a_to"
  done
fi
