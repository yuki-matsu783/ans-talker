#!/usr/bin/env bash
# .claude/scripts/src/answer-talker-map.sh の単体テスト（issue #1）。
# 外部コマンド呼び出しを伴わない純粋関数 build_mapping を対象とする
# （ファイル列挙・jq変換を伴うmainは対象外）。
# 規約: passed=N failures=N を標準出力へ出し、失敗があれば終了コード1
#       （.claude/rules/shell-script-style.md「テスト」）。
# 実行: bash .claude/scripts/test/test_answer_talker_map.sh
set -euo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" == "${BASH_SOURCE[0]}" ]] && script_dir="."
repo_root="$(cd "$script_dir/../../.." && pwd)"

# shellcheck source=../../../.claude/scripts/src/answer-talker-map.sh
source "$repo_root/.claude/scripts/src/answer-talker-map.sh"

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

# build_mapping の出力から、指定した種別の行だけを取り出す（テスト用ヘルパ）。
rows_of() {
  local kind="$1" out="$2"
  printf '%s\n' "$out" | grep "^${kind}	" || true
}

# --- 同一パス一致 ---------------------------------------------------------

out="$(build_mapping "$(printf '%s\n' 'a.sh' 'b.sh')" "$(printf '%s\n' 'a.sh' 'b.sh')")"
assert_eq "同一パスはmatched(by=path)になる" \
  "$(printf 'matched\ta.sh\ta.sh\tpath\nmatched\tb.sh\tb.sh\tpath')" "$(rows_of matched "$out")"
assert_eq "同一パスのみならreferenceOnlyは空" "" "$(rows_of referenceOnly "$out")"
assert_eq "同一パスのみならsubmissionOnlyは空" "" "$(rows_of submissionOnly "$out")"

# --- ファイル名一致（ディレクトリが違う） --------------------------------

out="$(build_mapping "src/read.sh" "lib/read.sh")"
assert_eq "ディレクトリ違いの同名はmatched(by=name)になる" \
  "$(printf 'matched\tsrc/read.sh\tlib/read.sh\tname')" "$(rows_of matched "$out")"
assert_eq "名前一致した正解ファイルはreferenceOnlyに残らない" "" "$(rows_of referenceOnly "$out")"

# --- 同名が正解側に複数ある場合は対応付けない ----------------------------

out="$(build_mapping "src/util.sh" "$(printf '%s\n' 'a/util.sh' 'b/util.sh')")"
assert_eq "正解側に同名が2つあると対応付けない" "" "$(rows_of matched "$out")"
assert_eq "対応付かない受講者ファイルはsubmissionOnly" \
  "$(printf 'submissionOnly\tsrc/util.sh')" "$(rows_of submissionOnly "$out")"
assert_eq "同名2つは両方referenceOnlyに残る" \
  "$(printf 'referenceOnly\ta/util.sh\nreferenceOnly\tb/util.sh')" "$(rows_of referenceOnly "$out")"

# --- 分割不足（受け入れ条件の中核ケース） --------------------------------
# 受講者が1ファイルに詰め込み、正解は3ファイルに分かれている状況。
# パス一致にもファイル名一致にもかからず、正解側の3つがすべてreferenceOnlyになる。

out="$(build_mapping "main.sh" "$(printf '%s\n' 'read.sh' 'filter.sh' 'format.sh')")"
assert_eq "分割不足: 受講者側はsubmissionOnly" \
  "$(printf 'submissionOnly\tmain.sh')" "$(rows_of submissionOnly "$out")"
assert_eq "分割不足: 正解側の3ファイルがすべてreferenceOnly" \
  "$(printf 'referenceOnly\tread.sh\nreferenceOnly\tfilter.sh\nreferenceOnly\tformat.sh')" \
  "$(rows_of referenceOnly "$out")"

# --- 0件・空行の扱い -----------------------------------------------------

out="$(build_mapping "" "")"
assert_eq "両方空なら何も出力しない" "" "$out"

out="$(build_mapping "" "$(printf '%s\n' 'read.sh')")"
assert_eq "受講者側が空なら正解は全部referenceOnly" \
  "$(printf 'referenceOnly\tread.sh')" "$(rows_of referenceOnly "$out")"

out="$(build_mapping "$(printf '%s\n' 'main.sh')" "")"
assert_eq "正解側が空なら受講者は全部submissionOnly" \
  "$(printf 'submissionOnly\tmain.sh')" "$(rows_of submissionOnly "$out")"

out="$(build_mapping "$(printf '%s\n' '' 'a.sh' '')" "$(printf '%s\n' 'a.sh' '')")"
assert_eq "空行は無視する" "$(printf 'matched\ta.sh\ta.sh\tpath')" "$(rows_of matched "$out")"

# --- 日本語・空白を含むパス ----------------------------------------------

out="$(build_mapping "docs/設計 メモ.md" "docs/設計 メモ.md")"
assert_eq "日本語と空白を含むパスも同一パス一致する" \
  "$(printf 'matched\tdocs/設計 メモ.md\tdocs/設計 メモ.md\tpath')" "$(rows_of matched "$out")"

# --- パス一致がファイル名一致より優先される ------------------------------

out="$(build_mapping "src/read.sh" "$(printf '%s\n' 'src/read.sh' 'lib/read.sh')")"
assert_eq "同名が複数あっても、パス一致があればそちらを採る" \
  "$(printf 'matched\tsrc/read.sh\tsrc/read.sh\tpath')" "$(rows_of matched "$out")"
assert_eq "パス一致した場合、残りの同名ファイルはreferenceOnly" \
  "$(printf 'referenceOnly\tlib/read.sh')" "$(rows_of referenceOnly "$out")"

echo "passed=$passed failures=$failures"
[[ "$failures" -eq 0 ]]
