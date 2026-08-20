#!/usr/bin/env bash
# .claude/scripts/src/check-base-conflicts.sh の単体テスト（issue #46）。
# 外部コマンド呼び出しを伴わない純粋関数（ddr_number_to_reply / find_duplicate_ddr_numbers）
# のみを対象とする。git操作を伴うmainは対象外（.claude/scripts/test/では実リポジトリを汚さない方針）。
# 規約: passed=N failures=N を標準出力へ出し、失敗があれば終了コード1
#       （.claude/rules/shell-script-style.md「テスト」。.claude/scripts/test/test_update_handoff_progress.sh を雛形にした）。
# 実行: bash .claude/scripts/test/test_check_base_conflicts.sh
set -euo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" == "${BASH_SOURCE[0]}" ]] && script_dir="."
repo_root="$(cd "$script_dir/../../.." && pwd)"

# shellcheck source=../../../.claude/scripts/src/check-base-conflicts.sh
source "$repo_root/.claude/scripts/src/check-base-conflicts.sh"

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

# --- ddr_number_to_reply -------------------------------------------------

REPLY=""
ddr_number_to_reply ".claude/docs/ddr/0027-プロバイダ判定はremote-URLのホスト部で.md"
assert_eq "ddr_number_to_reply: 日本語タイトルから4桁を取り出す" "0027" "$REPLY"

REPLY=""
ddr_number_to_reply "0001-first.md"
assert_eq "ddr_number_to_reply: ディレクトリ無しのパスも扱える" "0001" "$REPLY"

# 終了コードは `if` の条件式で受ける（`"$(func; echo $?)"` は set -e 配下で空文字列になりうる。
# .claude/rules/shell-script-style.md「テスト」）。
if ddr_number_to_reply ".claude/docs/ddr/index.jsonl"; then
  index_status=0
else
  index_status=1
fi
assert_eq "ddr_number_to_reply: DDR命名でなければ終了コード1" "1" "$index_status"
assert_eq "ddr_number_to_reply: DDR命名でなければREPLYは空" "" "$REPLY"

if ddr_number_to_reply ".claude/docs/ddr/027-三桁は対象外.md"; then
  three_digit_status=0
else
  three_digit_status=1
fi
assert_eq "ddr_number_to_reply: 3桁は対象外" "1" "$three_digit_status"

# --- find_duplicate_ddr_numbers -----------------------------------------

no_dup="$(find_duplicate_ddr_numbers "$(printf '%s\n' \
  '.claude/docs/ddr/0026-a.md' \
  '.claude/docs/ddr/0027-b.md' \
  '.claude/docs/ddr/0028-c.md')")"
assert_eq "find_duplicate_ddr_numbers: 重複が無ければ何も出力しない" "" "$no_dup"

# 実際にPR #52で起きた形（両ブランチが別名で同じ0027を追加した）を再現する。
# ファイル名が異なるためgit自身はコンフリクトと見なさない点が本テストの主眼。
one_dup="$(find_duplicate_ddr_numbers "$(printf '%s\n' \
  '.claude/docs/ddr/0026-a.md' \
  '.claude/docs/ddr/0027-gh_glab-CLI不在時はMCPフォールバック経路へ機構的に誘導する.md' \
  '.claude/docs/ddr/0027-プロバイダ判定はremote-URLのホスト部でgithub以外をgitlabとみなす.md')")"
assert_eq "find_duplicate_ddr_numbers: 同一番号の別名2件を検出する" \
  ".claude/docs/ddr/0027-gh_glab-CLI不在時はMCPフォールバック経路へ機構的に誘導する.md	.claude/docs/ddr/0027-プロバイダ判定はremote-URLのホスト部でgithub以外をgitlabとみなす.md" \
  "$(printf '%s' "$one_dup" | cut -f2-)"
assert_eq "find_duplicate_ddr_numbers: 出力の1列目は番号" "0027" "$(printf '%s' "$one_dup" | cut -f1)"
assert_eq "find_duplicate_ddr_numbers: 重複1件なら1行のみ" "1" "$(printf '%s\n' "$one_dup" | grep -c .)"

multi_dup="$(find_duplicate_ddr_numbers "$(printf '%s\n' \
  '.claude/docs/ddr/0024-x.md' \
  '.claude/docs/ddr/0024-y.md' \
  '.claude/docs/ddr/0025-z.md' \
  '.claude/docs/ddr/0027-p.md' \
  '.claude/docs/ddr/0027-q.md')")"
assert_eq "find_duplicate_ddr_numbers: 複数番号の重複を検出する" "2" "$(printf '%s\n' "$multi_dup" | grep -c .)"
assert_eq "find_duplicate_ddr_numbers: 検出順は入力の出現順" \
  "$(printf '0024\n0027')" "$(printf '%s\n' "$multi_dup" | cut -f1)"

same_path="$(find_duplicate_ddr_numbers "$(printf '%s\n' \
  '.claude/docs/ddr/0027-a.md' \
  '' \
  '.claude/docs/ddr/index.jsonl')")"
assert_eq "find_duplicate_ddr_numbers: 空行・非DDRファイルは無視する" "" "$same_path"

dup_path="$(find_duplicate_ddr_numbers "$(printf '%s\n' \
  '.claude/docs/ddr/0027-a.md' \
  '.claude/docs/ddr/0027-a.md')")"
assert_eq "find_duplicate_ddr_numbers: 同一パスの重複入力は重複と見なさない" "" "$dup_path"

echo "passed=$passed failures=$failures"
[[ "$failures" -eq 0 ]]
