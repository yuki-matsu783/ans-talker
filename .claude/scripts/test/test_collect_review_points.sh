#!/usr/bin/env bash
# .claude/scripts/src/collect-review-points.sh の単体テスト。issue #77。
#
# 純粋関数 `review_points_ancestor_dirs`（祖先ディレクトリ列の算出）に加え、
# `main` の収集・マージ動作も、mktempで作った一時的なgitリポジトリを対象に確認する
# （このリポジトリ自身を対象にすると、ルートの REVIEW-POINTS.md が常に存在するため
#  「観点表が1つも無い場合」を検証できないため）。
#
# 規約: passed=N failures=N を標準出力へ出し、失敗があれば終了コード1。
# 実行: bash .claude/scripts/test/test_collect_review_points.sh
set -euo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" == "${BASH_SOURCE[0]}" ]] && script_dir="."
repo_root="$(cd "$script_dir/../../.." && pwd)"
target="$repo_root/.claude/scripts/src/collect-review-points.sh"

# shellcheck source=../../../.claude/scripts/src/collect-review-points.sh
source "$target"

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

# --- review_points_ancestor_dirs -----------------------------------------------------

assert_eq "review_points_ancestor_dirs: ルート直下のファイルはルートのみ" \
  '.' \
  "$(review_points_ancestor_dirs 'HANDOFF.md')"

assert_eq "review_points_ancestor_dirs: 深いパスは浅い順に列挙する" \
  $'.\n.claude\n.claude/scripts\n.claude/scripts/src\n.claude/scripts/src/vcs' \
  "$(review_points_ancestor_dirs '.claude/scripts/src/vcs/Github.sh')"

assert_eq "review_points_ancestor_dirs: 先頭の./は無視する" \
  $'.\nplans' \
  "$(review_points_ancestor_dirs './plans/x.md')"

# 日本語を含むパスが壊れないこと（bashの部分文字列展開ではなくパラメータ展開で扱っている）
assert_eq "review_points_ancestor_dirs: 日本語を含むパスを壊さない" \
  $'.\nplans\nplans/【設計】' \
  "$(review_points_ancestor_dirs 'plans/【設計】/計画.md')"

assert_eq "review_points_ancestor_dirs: ..は直前の要素を打ち消す" \
  $'.\na\na/b\na/c' \
  "$(review_points_ancestor_dirs 'a/b/../c/x.sh')"

# 観点表の探索がリポジトリの外へ出ると、無関係なファイルを観点として読み込みかねない
assert_eq "review_points_ancestor_dirs: リポジトリルートより上へ出ない" \
  $'.\netc' \
  "$(review_points_ancestor_dirs '../../etc/passwd')"

assert_eq "review_points_ancestor_dirs: ルート直上の..だけならルートのみ" \
  '.' \
  "$(review_points_ancestor_dirs '../x.md')"

# --- strip_frontmatter_and_h1 --------------------------------------------------------

fixture_md="$(mktemp)"
printf '%s\n' '---' 'title: T' 'type: review-points' '---' '' '# 見出し' '' '本文1' '' '## 節' '- 項目' > "$fixture_md"

assert_eq "strip_frontmatter_and_h1: frontmatterとH1と先頭空行を取り除く" \
  $'本文1\n\n## 節\n- 項目' \
  "$(strip_frontmatter_and_h1 "$fixture_md")"

printf '%s\n' '本文だけ' '- 項目' > "$fixture_md"
assert_eq "strip_frontmatter_and_h1: frontmatterもH1も無ければそのまま" \
  $'本文だけ\n- 項目' \
  "$(strip_frontmatter_and_h1 "$fixture_md")"

# --- main（収集・マージ） -------------------------------------------------------------

fixture_repo="$(mktemp -d)"
cleanup() { rm -rf "$fixture_repo"; }
trap cleanup EXIT

(
  cd "$fixture_repo"
  git init -q .
  mkdir -p a/b c
  printf '%s\n' '---' 'title: R' '---' '' '# ルート' '' '- ルートの観点' > REVIEW-POINTS.md
  printf '%s\n' '---' 'title: A' '---' '' '# a' '' '- aの観点' > a/REVIEW-POINTS.md
  printf '%s\n' '---' 'title: AB' '---' '' '# ab' '' '- abの観点' > a/b/REVIEW-POINTS.md
  : > a/b/deep.sh
  : > c/other.sh
)

collect() { (cd "$fixture_repo" && bash "$target" "$@"); }

assert_eq "collect: 祖先チェーンの観点表を浅い順に出す" \
  $'## REVIEW-POINTS.md\n## a/REVIEW-POINTS.md\n## a/b/REVIEW-POINTS.md' \
  "$(collect a/b/deep.sh | grep '^## ')"

assert_eq "collect: 祖先でない観点表は含めない" \
  '## REVIEW-POINTS.md' \
  "$(collect c/other.sh | grep '^## ')"

# 複数ファイルを渡したときに同じ観点表が重複しないこと（和集合を取る）
assert_eq "collect: 複数ファイルでも同じ観点表は1回だけ" \
  $'## REVIEW-POINTS.md\n## a/REVIEW-POINTS.md\n## a/b/REVIEW-POINTS.md' \
  "$(collect a/b/deep.sh c/other.sh | grep '^## ')"

# 渡す順序が変わっても出力順は「浅い → 深い」で安定していること
assert_eq "collect: 渡す順序によらず浅い順で出す" \
  $'## REVIEW-POINTS.md\n## a/REVIEW-POINTS.md\n## a/b/REVIEW-POINTS.md' \
  "$(collect c/other.sh a/b/deep.sh | grep '^## ')"

assert_eq "collect: 観点表の中身が見出しの下に続く" \
  '- abの観点' \
  "$(collect a/b/deep.sh | grep -- '- abの観点')"

# 観点表が1つも無い場合は、エラーではなく「無出力・終了コード0」
empty_repo="$(mktemp -d)"
(
  cd "$empty_repo"
  git init -q .
  : > x.sh
)
if (cd "$empty_repo" && bash "$target" x.sh > "$empty_repo/out.txt" 2>/dev/null); then
  empty_status=0
else
  empty_status=1
fi
assert_eq "collect: 観点表が1つも無くても終了コード0" '0' "$empty_status"
assert_eq "collect: 観点表が1つも無ければ無出力" '0' "$(wc -c < "$empty_repo/out.txt")"
rm -rf "$empty_repo"

# 引数なしは使い方を示して失敗する
if (cd "$fixture_repo" && bash "$target" >/dev/null 2>&1); then
  noarg_status=0
else
  noarg_status=1
fi
assert_eq "collect: 引数なしは終了コード1" '1' "$noarg_status"

echo "passed=$passed failures=$failures"
[ "$failures" -eq 0 ]
