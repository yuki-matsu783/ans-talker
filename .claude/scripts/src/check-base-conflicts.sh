#!/usr/bin/env bash
#
# 現在のブランチとdefaultブランチ（.mrworkflow.json の defaultBaseBranch）の間に
# コンフリクトがあるかを、作業ツリーを一切変更せずに判定する（issue #46）。
# `.claude/skills/issue-mr-flow/SKILL.md` の flow-id 5-2（マージ依頼前のコンフリクト検知）と
# `.claude/skills/resolve-conflict/SKILL.md` のStep 1から呼び出す想定。
#
# 検知する2種類:
#   1. テキストコンフリクト  ... `git merge-tree --write-tree` が報告する通常のコンフリクト。
#   2. DDR番号の重複（semantic conflict）
#      ... 両ブランチが「別々のファイル名で同じ連番のDDR」を追加した場合、ファイル名が
#          異なるためgitはコンフリクトと見なさず、無言でマージが成功してしまう。結果として
#          同じ番号のDDRが2つ並ぶ。過去4回（PR #29 / #37 / #49 / #52）すべてこの形で、
#          いずれも人手で気づいて改番していた。gitに任せていては検知できないため、
#          このスクリプトが番号の重複を直接調べる。
#
# 使い方:
#   check-base-conflicts.sh [--base <branch>] [--head <ref>] [--no-fetch]
#
# 出力: 判定結果のJSONをstdoutへ1つ出力する（Provider.sh の各関数と同じ規約）。
#   {
#     "base": "main", "baseRef": "origin/main", "baseSha": "...",
#     "headRef": "HEAD", "headSha": "...", "ddrDirs": ["..."],
#     "textualConflictFiles": ["..."],
#     "duplicateDdrNumbers": [{"number":"0027","files":["...","..."]}],
#     "hasTextualConflict": true, "hasDuplicateDdrNumber": true, "hasConflict": true
#   }
#
# 終了コード: 検査が完了すれば0（コンフリクトの有無は終了コードではなくJSONの hasConflict で表す）。
#   検査自体が失敗した場合のみ非0。呼び出し側が `set -e` 配下でも、コンフリクトの存在によって
#   スクリプト全体が止まらないようにするため。
#
# 規約: .claude/rules/shell-script-style.md（set -euo pipefail / jq前提 / ループ内で外部コマンドを呼ばない）
set -euo pipefail

# JSON組み立て時に、2種類の結果リストを1本の標準入力へ連結するための区切り行。
# 制御文字を使うとシェルのコマンド文字列に混ざったとき目視できないため、通常の文字列にする。
readonly CBC_SPLIT_MARK='@@CBC-SPLIT@@'

# パスからDDRの連番（先頭4桁）をREPLYへ返す。DDRの命名（NNNN-タイトル.md）でなければ
# REPLYを空にして終了コード1を返す。外部コマンドを呼ばない純粋関数。
ddr_number_to_reply() {
  local path="$1"
  local name="${path##*/}"
  if [[ "$name" =~ ^([0-9]{4})- ]]; then
    REPLY="${BASH_REMATCH[1]}"
    return 0
  fi
  REPLY=""
  return 1
}

# DDRファイルパスの改行区切り文字列を受け取り、同じ連番を持つ相異なるパスが2つ以上ある番号を
# "番号<TAB>パス1<TAB>パス2..." の形式で1行ずつstdoutへ出力する（重複が無ければ何も出力しない）。
# 外部コマンドを呼ばない純粋関数（ループ内でjq等を起動しないための分離。
# .claude/rules/shell-script-style.md「外部プロセス起動のコスト」）。
find_duplicate_ddr_numbers() {
  local list="$1"
  local -A seen=()
  local -a numbers=()
  local path number

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    ddr_number_to_reply "$path" || continue
    number="$REPLY"
    if [ -z "${seen[$number]+x}" ]; then
      seen[$number]="$path"
      numbers+=("$number")
    elif [[ $'\t'"${seen[$number]}"$'\t' != *$'\t'"$path"$'\t'* ]]; then
      # 同じパスが2度渡された場合を重複と誤判定しないよう、タブ区切りの完全一致で判定する
      seen[$number]="${seen[$number]}"$'\t'"$path"
    fi
  done <<<"$list"

  for number in "${numbers[@]}"; do
    [[ "${seen[$number]}" == *$'\t'* ]] || continue
    printf '%s\t%s\n' "$number" "${seen[$number]}"
  done
}

# <ref> のツリーから、ddrDirs配下のmarkdownパスを改行区切りで返す。
list_ddr_paths() {
  local ref="$1"
  shift
  [ "$#" -gt 0 ] || return 0
  git -c core.quotepath=false ls-tree -r --name-only "$ref" -- "$@" | grep -E '\.md$' || true
}

main() {
  local base="" head_ref="HEAD" do_fetch=1

  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      --head) head_ref="$2"; shift 2 ;;
      --no-fetch) do_fetch=0; shift ;;
      -h|--help)
        sed -n '2,30p' "${BASH_SOURCE[0]}"
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
    config='{"defaultBaseBranch":"main","ddrDirs":[".claude/docs/ddr"]}'
  fi

  # jq起動は1回にまとめる（base名とddrDirsを同時にTSVで取り出す）
  local meta
  meta="$(printf '%s' "$config" | jq -r '[(.defaultBaseBranch // "main")] + (.ddrDirs // [".claude/docs/ddr"]) | @tsv')"
  meta="${meta//$'\r'/}"
  local -a meta_fields=()
  IFS=$'\t' read -r -a meta_fields <<<"$meta"
  [ -n "$base" ] || base="${meta_fields[0]}"
  local -a ddr_dirs=("${meta_fields[@]:1}")

  if [ "$do_fetch" -eq 1 ]; then
    git fetch origin "$base" >/dev/null 2>&1 || true
  fi

  local base_ref="origin/$base"
  if ! git rev-parse --verify --quiet "$base_ref" >/dev/null; then
    echo "エラー: ベースブランチ ${base_ref} が見つかりません（git fetch origin ${base} を確認してください）" >&2
    return 1
  fi

  local base_sha head_sha
  base_sha="$(git rev-parse "$base_ref")"
  head_sha="$(git rev-parse "$head_ref")"

  # 1. テキストコンフリクト（作業ツリーを変更しない）
  local merge_out="" merge_status=0
  # `if ! cmd; then` の中で `$?` を読むと、bashは `!` で反転済みの値（0）を返すため終了コードを
  # 取り違える。`cmd || status=$?` の形で受けること（issue #46で実際に踏んだ）。
  merge_out="$(git -c core.quotepath=false merge-tree --write-tree --name-only --no-messages "$head_ref" "$base_ref")" || merge_status=$?
  if [ "$merge_status" -gt 1 ]; then
    echo "エラー: git merge-tree が失敗しました（終了コード ${merge_status}）" >&2
    return 1
  fi
  # 1行目は書き出されたツリーのOIDなので落とす
  local conflict_files=""
  if [ "$merge_status" -eq 1 ]; then
    conflict_files="$(printf '%s\n' "$merge_out" | tail -n +2 | sed '/^$/d')"
  fi

  # 2. DDR番号の重複（両ブランチのDDR一覧を合わせて番号ごとに数える）
  local ddr_paths duplicates
  ddr_paths="$(printf '%s\n%s\n' \
    "$(list_ddr_paths "$head_ref" "${ddr_dirs[@]}")" \
    "$(list_ddr_paths "$base_ref" "${ddr_dirs[@]}")" | sed '/^$/d' | sort -u)"
  duplicates="$(find_duplicate_ddr_numbers "$ddr_paths")"

  # JSONの組み立てはjq 1回で行う。可変長データは --args ではなく標準入力から読ませる
  # （.claude/rules/shell-script-style.md「大きなJSONを--argjson/--arg等の引数で渡さない」）。
  printf '%s\n%s\n%s\n' "$conflict_files" "$CBC_SPLIT_MARK" "$duplicates" | jq -R -n \
    --arg base "$base" --arg baseRef "$base_ref" --arg baseSha "$base_sha" \
    --arg headRef "$head_ref" --arg headSha "$head_sha" \
    --arg splitMark "$CBC_SPLIT_MARK" \
    --arg ddrDirs "${ddr_dirs[*]}" '
      ([inputs] | map(select(. != null))) as $lines
      | ($lines | index($splitMark)) as $i
      | ($lines[0:$i] | map(select(length > 0))) as $conflicts
      | ($lines[($i + 1):] | map(select(length > 0))
         | map(split("\t") | {number: .[0], files: .[1:]})) as $dups
      | {
          base: $base, baseRef: $baseRef, baseSha: $baseSha,
          headRef: $headRef, headSha: $headSha,
          ddrDirs: ($ddrDirs | split(" ") | map(select(length > 0))),
          textualConflictFiles: $conflicts,
          duplicateDdrNumbers: $dups,
          hasTextualConflict: ($conflicts | length > 0),
          hasDuplicateDdrNumber: ($dups | length > 0),
          hasConflict: (($conflicts | length > 0) or ($dups | length > 0))
        }' | tr -d '\r'
}

# 単体テスト（.claude/scripts/test/test_check_base_conflicts.sh）からsourceして純粋関数のみ再利用できるよう、
# 直接実行された場合のみ main を呼ぶ（update-handoff-progress.shと同じガードパターン）。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
