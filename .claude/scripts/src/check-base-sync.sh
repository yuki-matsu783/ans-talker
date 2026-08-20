#!/usr/bin/env bash
#
# 現在のブランチが、ベースブランチ（.mrworkflow.json の defaultBaseBranch）の最新を
# 取り込めているかを、作業ツリーを一切変更せずに判定する（issue #67）。
# `.claude/skills/issue-mr-flow/SKILL.md` の「作業開始・再開時のベースブランチ追従確認」節
# （`start` の既存ブランチ検出時・`resume`・`sync`）から呼び出す想定。
#
# check-base-conflicts.sh との違い（判定軸が異なるため別スクリプトにしている）:
#   - check-base-conflicts.sh ... マージ依頼の直前（flow-id 5-2）に「**衝突するか**」を見る（issue #46）
#   - 本スクリプト             ... 作業の開始・再開時に「**遅れているか**」を見る（issue #67）
#   ベースブランチ側でルール・仕様だけが追記された場合、衝突は1件も起きないため前者は検知
#   できないが、作業ブランチはその追記を知らないまま実装・レビューを進めることになる。
#
# 使い方:
#   check-base-sync.sh [--base <branch>] [--head <ref>] [--no-fetch]
#
# 出力: 判定結果のJSONをstdoutへ1つ出力する（Provider.sh の各関数と同じ規約）。
#   {
#     "base": "main", "baseRef": "origin/main", "baseSha": "...",
#     "headRef": "HEAD", "headSha": "...", "mergeBase": "...",
#     "behind": 4, "ahead": 1,
#     "changedFiles": ["..."], "changedFilesTotal": 4, "changedFilesTruncated": false,
#     "hasCommonHistory": true, "isShallow": false, "fetchOk": true, "isBehind": true
#   }
#   fetchOk ... origin/<base> のfetchに成功したか。false なら古いリモート追跡参照を見ている
#              可能性があり、behind を過小評価しうる（--no-fetch 指定時は null）。
#   behind ... ベース側にあって作業ブランチに無いコミット数。呼び出し側は isBehind を見る。
#   ahead  ... 作業ブランチ側にあってベースに無いコミット数（遅れの判定には使わない）。
#   changedFiles ... **未取り込みの**変更ファイル（merge-base から見たベース側の変更）。
#
# 終了コード: 検査が完了すれば0（遅れの有無は終了コードではなくJSONの isBehind で表す）。
#   検査自体が失敗した場合のみ非0。呼び出し側が `set -e` 配下でも、遅れの存在によって
#   スクリプト全体が止まらないようにするため。
#
# 規約: .claude/rules/shell-script-style.md（set -euo pipefail / jq前提 / ループ内で外部コマンドを呼ばない）
set -euo pipefail

# JSONへ含める変更ファイルの最大件数。ベースブランチが大きく進んでいると数百件になりうるため
# 切り詰めるが、件数そのものは changedFilesTotal で失わない（silent truncation にしない）。
readonly CBS_CHANGED_FILES_LIMIT=50

# `git rev-list --left-right --count <base>...<head>` の出力（"<behind><TAB><ahead>"）を
# 分解し、REPLY_BEHIND / REPLY_AHEAD へ返す。外部コマンドを呼ばない純粋関数。
# 数値2つとして読めない入力（空文字列・区切り無し・非数値）は終了コード1を返す。
#
# 標準出力ではなくグローバル変数へ返すのは、コマンド置換によるforkを避けるため
# （.claude/rules/shell-script-style.md「外部プロセス起動のコスト」）。
parse_left_right_to_reply() {
  local raw="${1:-}"
  # Windows版jq・CRLF混入への保険（.claude/rules/shell-script-style.md「文字コード」）
  raw="${raw//$'\r'/}"
  if [[ "$raw" =~ ^[[:blank:]]*([0-9]+)[[:blank:]]+([0-9]+)[[:blank:]]*$ ]]; then
    REPLY_BEHIND="${BASH_REMATCH[1]}"
    REPLY_AHEAD="${BASH_REMATCH[2]}"
    return 0
  fi
  REPLY_BEHIND=""
  REPLY_AHEAD=""
  return 1
}

# 改行区切りのファイル一覧を先頭 <limit> 件へ切り詰め、REPLY_FILES（切り詰め後の一覧）と
# REPLY_TOTAL（切り詰め前の全件数）へ返す。空行は数えない。外部コマンドを呼ばない純粋関数。
truncate_file_list() {
  local list="${1:-}" limit="${2:-0}"
  local -a kept=()
  local line count=0

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    count=$((count + 1))
    if [ "$count" -le "$limit" ]; then
      kept+=("$line")
    fi
  done <<<"$list"

  REPLY_TOTAL="$count"
  if [ "${#kept[@]}" -gt 0 ]; then
    printf -v REPLY_FILES '%s\n' "${kept[@]}"
    REPLY_FILES="${REPLY_FILES%$'\n'}"
  else
    REPLY_FILES=""
  fi
}

main() {
  local base="" head_ref="HEAD" do_fetch=1

  while [ $# -gt 0 ]; do
    case "$1" in
      --base)
        # $# を先に確認する（$2 を直接参照すると set -u 配下で
        # 「$2: unbound variable」という原因の分からないエラーになる）
        [ $# -ge 2 ] && [ -n "$2" ] || { echo "--base には値が必要です" >&2; return 1; }
        base="$2"; shift 2 ;;
      --head)
        [ $# -ge 2 ] && [ -n "$2" ] || { echo "--head には値が必要です" >&2; return 1; }
        head_ref="$2"; shift 2 ;;
      --no-fetch) do_fetch=0; shift ;;
      -h|--help)
        sed -n '2,35p' "${BASH_SOURCE[0]}"
        return 0
        ;;
      *)
        echo "不明な引数です: $1" >&2
        return 1
        ;;
    esac
  done

  local repo_root config
  repo_root="$(git rev-parse --show-toplevel)"
  if [ -f "$repo_root/.mrworkflow.json" ]; then
    config="$(<"$repo_root/.mrworkflow.json")"
  else
    config='{"defaultBaseBranch":"main"}'
  fi
  [ -n "$base" ] || base="$(printf '%s' "$config" | jq -r '.defaultBaseBranch // "main"' | tr -d '\r')"

  # fetchはrefspecを明示する。single-branch clone（`git clone --branch <b>` 等）では
  # `git fetch origin <base>` を実行しても remotes/origin/<base> が作られないが、
  # refspec形なら作られることを実機で確認している（issue #67）。先頭の `+` は
  # ベースブランチがforce-pushで巻き戻ったときに non-fast-forward で拒否されないため
  # （既定のcloneのrefspec `+refs/heads/*:refs/remotes/origin/*` と同じ扱い）。
  #
  # **失敗を握りつぶさない。** `|| true` で捨てると、ネットワーク不通・認証切れのときに
  # 古い origin/<base> を読んで `isBehind: false` を返し、呼び出し側からは「遅れていない」と
  # 区別がつかなくなる（このスクリプトは検知そのものが目的であり、見逃しが後段で拾われない）。
  # 終了コードは fetchOk としてJSONへ出し、判定の信頼性を呼び出し側が識別できるようにする。
  # `--no-fetch` でfetchを行わなかった場合は false ではなく null にする
  # （「失敗した」と「そもそも試していない」を呼び出し側が区別できるようにするため）。
  local fetch_ok="null"
  if [ "$do_fetch" -eq 1 ]; then
    if git fetch origin "+${base}:refs/remotes/origin/${base}" >/dev/null 2>&1; then
      fetch_ok="true"
    else
      fetch_ok="false"
    fi
  fi

  local base_ref="origin/$base"
  if ! git rev-parse --verify --quiet "$base_ref" >/dev/null; then
    printf 'エラー: ベースブランチ %s が見つかりません。次で作成できます:\n' "$base_ref" >&2
    printf "  git fetch origin '+%s:refs/remotes/origin/%s'\n" "$base" "$base" >&2
    return 1
  fi

  local base_sha head_sha is_shallow
  base_sha="$(git rev-parse "$base_ref")"
  head_sha="$(git rev-parse "$head_ref")"
  is_shallow="$(git rev-parse --is-shallow-repository | tr -d '\r')"

  # behind と ahead は1回の起動で両方取る（左が base 側のみ＝behind、右が head 側のみ＝ahead）
  local counts
  counts="$(git rev-list --left-right --count "${base_ref}...${head_ref}")"
  if ! parse_left_right_to_reply "$counts"; then
    printf 'エラー: git rev-list --left-right --count の出力を解釈できません: %s\n' "$counts" >&2
    return 1
  fi
  local behind="$REPLY_BEHIND" ahead="$REPLY_AHEAD"

  # merge-base の有無を**先に**判定する。無い状態で3ドット記法（`A...B`）のdiffを実行すると
  # `fatal: <head>...<base>: no merge base` で終了コード128になり、`set -e` 配下では
  # スクリプトごと落ちる（rev-list の方は成功してしまうため、ここを分けないと気づけない）。
  local merge_base="" has_common="false" changed=""
  if merge_base="$(git merge-base "$head_ref" "$base_ref" 2>/dev/null)"; then
    has_common="true"
    # 未取り込みの変更は3ドット記法（`${head}...${base}`）で取る。2点だと作業ブランチ自身の変更が混ざり、
    # 「自分が今書いたファイルを取り込め」と表示してしまう（issue #67 の調査で実測）。
    # core.quotepath=false は日本語を含むパスが8進エスケープされるのを防ぐ。
    changed="$(git -c core.quotepath=false diff --name-only "${head_ref}...${base_ref}")"
  else
    merge_base=""
  fi

  truncate_file_list "$changed" "$CBS_CHANGED_FILES_LIMIT"

  # JSONの組み立てはjq 1回。可変長のファイル一覧は --arg ではなく標準入力から読ませる
  # （.claude/rules/shell-script-style.md「大きなJSONを--argjson/--arg等の引数で渡さない」）。
  printf '%s\n' "$REPLY_FILES" | jq -R -n \
    --arg base "$base" --arg baseRef "$base_ref" --arg baseSha "$base_sha" \
    --arg headRef "$head_ref" --arg headSha "$head_sha" \
    --arg mergeBase "$merge_base" \
    --argjson behind "$behind" --argjson ahead "$ahead" \
    --argjson total "$REPLY_TOTAL" --argjson limit "$CBS_CHANGED_FILES_LIMIT" \
    --argjson hasCommonHistory "$has_common" \
    --argjson isShallow "$is_shallow" \
    --argjson fetchOk "$fetch_ok" '
      ([inputs] | map(select(length > 0))) as $files
      | {
          base: $base, baseRef: $baseRef, baseSha: $baseSha,
          headRef: $headRef, headSha: $headSha,
          mergeBase: (if $mergeBase == "" then null else $mergeBase end),
          behind: $behind, ahead: $ahead,
          changedFiles: $files,
          changedFilesTotal: $total,
          changedFilesTruncated: ($total > $limit),
          hasCommonHistory: $hasCommonHistory,
          isShallow: $isShallow,
          fetchOk: $fetchOk,
          isBehind: ($behind > 0)
        }' | tr -d '\r'
}

# 単体テスト（.claude/scripts/test/test_check_base_sync.sh）からsourceして純粋関数のみ再利用できるよう、
# 直接実行された場合のみ main を呼ぶ（check-base-conflicts.sh と同じガードパターン）。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
