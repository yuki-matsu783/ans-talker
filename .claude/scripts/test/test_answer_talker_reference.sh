#!/usr/bin/env bash
# .claude/scripts/src/answer-talker-reference.sh の単体テスト（issue #1）。
# 外部コマンド呼び出しを伴わない純粋関数（reference_kind_to_reply / cleanup_is_safe_dir /
# abs_path_to_reply）を対象とし、cloneを伴うmainは対象外とする。
# 規約: passed=N failures=N を標準出力へ出し、失敗があれば終了コード1
#       （.claude/rules/shell-script-style.md「テスト」）。
# 実行: bash .claude/scripts/test/test_answer_talker_reference.sh
set -euo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" == "${BASH_SOURCE[0]}" ]] && script_dir="."
repo_root="$(cd "$script_dir/../../.." && pwd)"

# shellcheck source=../../../.claude/scripts/src/answer-talker-reference.sh
source "$repo_root/.claude/scripts/src/answer-talker-reference.sh"

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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# --- reference_kind_to_reply ---------------------------------------------

REPLY=""
reference_kind_to_reply "https://github.com/owner/repo.git"
assert_eq "reference_kind_to_reply: https URLはurl" "url" "$REPLY"

REPLY=""
reference_kind_to_reply "http://localhost:8929/root/answer.git"
assert_eq "reference_kind_to_reply: ポート付きhttp URLはurl" "url" "$REPLY"

REPLY=""
reference_kind_to_reply "git@github.com:owner/repo.git"
assert_eq "reference_kind_to_reply: scp形式はurl" "url" "$REPLY"

REPLY=""
reference_kind_to_reply "ssh://git@host:2222/owner/repo.git"
assert_eq "reference_kind_to_reply: ssh URLはurl" "url" "$REPLY"

REPLY=""
reference_kind_to_reply "/c/work/answer"
assert_eq "reference_kind_to_reply: 絶対パスはlocal" "local" "$REPLY"

REPLY=""
reference_kind_to_reply "../answer"
assert_eq "reference_kind_to_reply: 相対パスはlocal" "local" "$REPLY"

REPLY=""
reference_kind_to_reply "C:/work/答え"
assert_eq "reference_kind_to_reply: 日本語を含むWindowsパスはlocal" "local" "$REPLY"

# 終了コードは `if` の条件式で受ける（`"$(func; echo $?)"` は set -e 配下で空文字列になりうる）。
if reference_kind_to_reply ""; then
  empty_status=0
else
  empty_status=1
fi
assert_eq "reference_kind_to_reply: 空文字列は終了コード1" "1" "$empty_status"
assert_eq "reference_kind_to_reply: 空文字列ならREPLYも空" "" "$REPLY"

# --- cleanup_is_safe_dir -------------------------------------------------
# 「マーカーファイルがある実在のディレクトリ」以外は削除しない、という安全弁の検査。

safe_dir="$TMP_DIR/safe"
mkdir -p "$safe_dir"
: > "$safe_dir/$ATR_MARKER"
if cleanup_is_safe_dir "$safe_dir"; then safe_status=0; else safe_status=1; fi
assert_eq "cleanup_is_safe_dir: マーカーがあれば削除可" "0" "$safe_status"

plain_dir="$TMP_DIR/plain"
mkdir -p "$plain_dir"
if cleanup_is_safe_dir "$plain_dir"; then plain_status=0; else plain_status=1; fi
assert_eq "cleanup_is_safe_dir: マーカーが無ければ削除しない" "1" "$plain_status"

if cleanup_is_safe_dir "$TMP_DIR/missing"; then missing_status=0; else missing_status=1; fi
assert_eq "cleanup_is_safe_dir: 存在しないパスは削除しない" "1" "$missing_status"

if cleanup_is_safe_dir ""; then blank_status=0; else blank_status=1; fi
assert_eq "cleanup_is_safe_dir: 空文字列は削除しない" "1" "$blank_status"

if cleanup_is_safe_dir "/"; then root_status=0; else root_status=1; fi
assert_eq "cleanup_is_safe_dir: ルートは削除しない" "1" "$root_status"

file_path="$TMP_DIR/afile"
: > "$file_path"
if cleanup_is_safe_dir "$file_path"; then file_status=0; else file_status=1; fi
assert_eq "cleanup_is_safe_dir: ディレクトリでなければ削除しない" "1" "$file_status"

# マーカーがディレクトリとして存在する場合（`-f` で弾く）
odd_dir="$TMP_DIR/odd"
mkdir -p "$odd_dir/$ATR_MARKER"
if cleanup_is_safe_dir "$odd_dir"; then odd_status=0; else odd_status=1; fi
assert_eq "cleanup_is_safe_dir: マーカーがディレクトリなら削除しない" "1" "$odd_status"

# --- abs_path_to_reply ---------------------------------------------------

REPLY=""
abs_path_to_reply "$safe_dir"
assert_eq "abs_path_to_reply: 実在ディレクトリを絶対パスにする" "$(cd "$safe_dir" && pwd)" "$REPLY"

REPLY=""
if abs_path_to_reply "$TMP_DIR/missing"; then abs_missing_status=0; else abs_missing_status=1; fi
assert_eq "abs_path_to_reply: 存在しなければ終了コード1" "1" "$abs_missing_status"
assert_eq "abs_path_to_reply: 存在しなければREPLYは空" "" "$REPLY"

REPLY=""
if abs_path_to_reply ""; then abs_blank_status=0; else abs_blank_status=1; fi
assert_eq "abs_path_to_reply: 空文字列は終了コード1" "1" "$abs_blank_status"

echo "passed=$passed failures=$failures"
[[ "$failures" -eq 0 ]]
