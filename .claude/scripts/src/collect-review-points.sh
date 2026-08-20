#!/usr/bin/env bash
#
# レビュー観点表（REVIEW-POINTS.md）の収集・マージ（issue #77）。
#
# 各ディレクトリ直下に置かれた `REVIEW-POINTS.md` は、**そのディレクトリ配下すべて**
# （孫以下を含む）のファイルに適用される。レビュー対象ファイルのあるディレクトリから
# リポジトリルートまで祖先を遡って観点表を集め、1つへマージして標準出力へ出す。
#
# 使い方:
#   bash .claude/scripts/src/collect-review-points.sh <ファイルパス...>
#
# 複数ファイルを渡した場合は各祖先チェーンの和集合を取り、同じ観点表は1回だけ出力する。
# 出力順は「浅い → 深い」（一般 → 具体）で、由来が分かるよう
# `## <観点表のパス>` の見出しを挟んで連結する。
# 観点表が1つも見つからなければ何も出力せず終了コード0で終わる
# （観点表が無くてもレビュー自体は一般的な観点で行えるため、エラーにしない）。

set -euo pipefail

# ファイルパスから、リポジトリルート（`.`）を先頭とする祖先ディレクトリ列を
# 「浅い → 深い」の順で出力する（純粋関数）。
#
#   review_points_ancestor_dirs '.claude/scripts/src/vcs/Github.sh'
#     → . / .claude / .claude/scripts / .claude/scripts/src / .claude/scripts/src/vcs
#
# 引数はリポジトリルートからの相対パスであることを前提とする。`..` は直前の要素を打ち消し、
# 打ち消す要素が無ければ無視する（**リポジトリルートより上へは決して出ない**）。
# ループ内で外部コマンドを起動しない（.claude/rules/shell-script-style.md）。
review_points_ancestor_dirs() {
  local path="$1"
  local dir acc="" part
  local -a parts=()

  if [[ "$path" == */* ]]; then
    dir="${path%/*}"
  else
    dir="."
  fi

  printf '.\n'

  IFS='/' read -r -a parts <<<"$dir"
  for part in "${parts[@]}"; do
    case "$part" in
      "" | ".") continue ;;
      "..")
        # 直前の要素を打ち消す。打ち消す要素が無ければルートに留まる
        if [[ "$acc" == */* ]]; then
          acc="${acc%/*}"
        else
          acc=""
        fi
        continue
        ;;
    esac
    acc="${acc:+$acc/}$part"
    printf '%s\n' "$acc"
  done
}

# 観点表からYAML frontmatterと先頭のH1見出しを取り除いて出力する。
# マージ後の出力では `## <パス>` を各観点表の見出しとして使うため、frontmatter（機械可読の
# メタデータ）とH1（frontmatterのtitleと重複する）はそのまま連結すると読みにくいため除く。
strip_frontmatter_and_h1() {
  awk '
    BEGIN { fm = 0; h1 = 0; started = 0 }
    NR == 1 && $0 == "---" { fm = 1; next }
    fm == 1 && $0 == "---" { fm = 0; next }
    fm == 1 { next }
    h1 == 0 && /^# / { h1 = 1; next }
    started == 0 && /^[ \t]*$/ { next }
    { started = 1; print }
  ' "$1"
}

main() {
  local repo_root rel dir found=0 file
  local -a dirs=()
  local -A seen=()

  if [ "$#" -eq 0 ]; then
    printf '使い方: %s <ファイルパス...>\n' "$0" >&2
    return 1
  fi

  repo_root="$(git rev-parse --show-toplevel)"
  cd "$repo_root"

  for file in "$@"; do
    rel="${file#"$repo_root"/}"
    rel="${rel#./}"
    while IFS= read -r dir; do
      if [ -z "${seen[$dir]:-}" ]; then
        seen[$dir]=1
        dirs+=("$dir")
      fi
    done < <(review_points_ancestor_dirs "$rel")
  done

  # 浅い順（`/` の個数順）に並べ替える。ファイルを渡した順序に依存せず、常に
  # 「一般 → 具体」の順で出力するため。
  while IFS= read -r dir; do
    if [ "$dir" = "." ]; then
      rel="REVIEW-POINTS.md"
    else
      rel="$dir/REVIEW-POINTS.md"
    fi
    [ -f "$rel" ] || continue
    found=1
    printf '## %s\n\n' "$rel"
    strip_frontmatter_and_h1 "$rel"
    printf '\n'
  done < <(printf '%s\n' "${dirs[@]}" | awk '{print gsub("/", "/") "\t" $0}' | sort -k1,1n -k2,2 | cut -f2-)

  [ "$found" -eq 1 ] || return 0
}

# テストから関数だけを読み込めるようにガードする（.claude/rules/shell-script-style.md「テスト」）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
