#!/usr/bin/env bash
#
# 受講者の変更ファイルと正解側のファイルを対応付ける（issue #1）。
#
# 使い方:
#   answer-talker-map.sh --diff <diff.json> --reference-root <正解ルート>
#     → {"matched":[{"submission":"…","reference":"…","by":"path"|"name"}],
#        "referenceOnly":["…"],"submissionOnly":["…"],
#        "reference":{"root":"…","files":["…"]}}
#
# 設計上の要点（reports/…answer-talker設計.md の D4）:
#   - **機械的に決まるのは「同一パス」「ファイル名一致」まで。** 対応が付かなかった要素を
#     「受講者がまだ作っていない分割単位」と見るか「別解として妥当な構成の違い」と見るかは、
#     中身を読まなければ決まらない。その判断はサブエージェントに委ねる（このスクリプトは
#     `referenceOnly` / `submissionOnly` として列挙するだけで、意味づけをしない）。
#   - パス一致だけに頼らないのは、**受講者が1ファイルに詰め込んでいる場合、正解側のどのファイルとも
#     パスが一致しない**ため。そこがまさに最も指摘したいケースにあたる。
#   - 削除された（`status: removed`）ファイルは、正解との対応付けの対象にしない。
#
# 規約: .claude/rules/shell-script-style.md（set -euo pipefail / jq前提 / ループ内で外部コマンドを
# 呼ばない）
set -euo pipefail

# 正解ルート配下のファイルを、ルートからの相対パスで列挙する（改行区切りでstdoutへ）。
# `.git` 配下は対象外。gitリポジトリでない素のディレクトリでも動くよう `find` を使う。
list_reference_files() {
  local root="$1"
  # `-print` の結果は `./` 始まりになるので取り除く。ループ内で外部コマンドを起動しないよう、
  # 変換はsedへ1回だけ通す。
  (cd "$root" && find . -type f -not -path './.git/*' -print | sed -e 's#^\./##' | sort)
}

# 受講者の変更ファイルと正解側ファイルの対応付けを組み立てる（純粋関数）。
#
#   $1 = 受講者側パスの改行区切り
#   $2 = 正解側パスの改行区切り
#
# 出力は "種別<TAB>値1[<TAB>値2]" の行を並べたもの。
#   matched<TAB>受講者パス<TAB>正解パス<TAB>path|name
#   referenceOnly<TAB>正解パス
#   submissionOnly<TAB>受講者パス
#
# 外部コマンドを呼ばない（bashの連想配列だけで突き合わせる）。
build_mapping() {
  local submission_list="$1" reference_list="$2"
  local -A ref_by_path=() ref_by_name=() ref_name_count=() ref_used=()
  local line name

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ref_by_path["$line"]=1
    name="${line##*/}"
    ref_name_count["$name"]=$(( ${ref_name_count["$name"]:-0} + 1 ))
    ref_by_name["$name"]="$line"
  done <<<"$reference_list"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -n "${ref_by_path["$line"]:-}" ]; then
      printf 'matched\t%s\t%s\tpath\n' "$line" "$line"
      ref_used["$line"]=1
      continue
    fi
    name="${line##*/}"
    # ファイル名一致は、正解側に同名が1つしかない場合だけ採る（複数あるとどれか決まらない）。
    if [ "${ref_name_count["$name"]:-0}" = "1" ]; then
      printf 'matched\t%s\t%s\tname\n' "$line" "${ref_by_name["$name"]}"
      ref_used["${ref_by_name["$name"]}"]=1
      continue
    fi
    printf 'submissionOnly\t%s\n' "$line"
  done <<<"$submission_list"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ -n "${ref_used["$line"]:-}" ] && continue
    printf 'referenceOnly\t%s\n' "$line"
  done <<<"$reference_list"
}

# build_mapping の出力（標準入力）をJSONへ変換する。
# jqの起動は1回だけ（行ごとに起動しない）。
mapping_lines_to_json() {
  local root="$1" reference_list="$2"
  jq -R -s -c --arg root "$root" --arg refs "$reference_list" '
    def rows: split("\n") | map(select(length > 0) | split("\t"));
    rows as $r
    | {
        matched: [$r[] | select(.[0] == "matched") | {submission: .[1], reference: .[2], by: .[3]}],
        referenceOnly: [$r[] | select(.[0] == "referenceOnly") | .[1]],
        submissionOnly: [$r[] | select(.[0] == "submissionOnly") | .[1]],
        reference: {
          root: $root,
          files: ($refs | split("\n") | map(select(length > 0)))
        }
      }
  ' | tr -d '\r'
}

usage() {
  printf 'usage: answer-talker-map.sh --diff <diff.json> --reference-root <正解ルート>\n' >&2
}

main() {
  local diff_file="" root=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --diff) diff_file="${2:-}"; shift 2 ;;
      --reference-root) root="${2:-}"; shift 2 ;;
      -h|--help) usage; return 2 ;;
      *) printf 'answer-talker-map: 不明な引数: %s\n' "$1" >&2; usage; return 2 ;;
    esac
  done

  if [ -z "$diff_file" ] || [ ! -f "$diff_file" ]; then
    printf 'answer-talker-map: --diff に既存のファイルを指定してください\n' >&2
    return 2
  fi
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    printf 'answer-talker-map: --reference-root に既存のディレクトリを指定してください\n' >&2
    return 2
  fi

  local submission_list reference_list
  # 削除されたファイルは正解との対応付けの対象にしない。
  submission_list="$(jq -r '.files[] | select(.status != "removed") | .path' "$diff_file" | tr -d '\r')"
  reference_list="$(list_reference_files "$root")"

  build_mapping "$submission_list" "$reference_list" \
    | mapping_lines_to_json "$root" "$reference_list"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
