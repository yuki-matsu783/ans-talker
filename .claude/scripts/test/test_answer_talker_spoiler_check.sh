#!/usr/bin/env bash
# .claude/scripts/src/answer-talker-spoiler-check.sh の単体テスト（issue #1）。
# 外部コマンド呼び出しを伴わない純粋関数（build_forbidden_set / find_leaked_words）を対象とする
# （grep・jqを伴うmainは対象外）。
#
# この検査は「**誤検知の側へ倒す**」方針（flow-id 3-4で合意）で設計されている。落としすぎる方向の
# ケースだけでなく、**落としてはいけないケース**（一般語のみの正当な指摘・受講者が自分で書いている
# 語・部分文字列）を必ず含めること。落とすケースだけを確かめるテストは、指摘を全滅させる実装を
# 合格させてしまう。
#
# 規約: passed=N failures=N を標準出力へ出し、失敗があれば終了コード1
#       （.claude/rules/shell-script-style.md「テスト」）。
# 実行: bash .claude/scripts/test/test_answer_talker_spoiler_check.sh
set -euo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" == "${BASH_SOURCE[0]}" ]] && script_dir="."
repo_root="$(cd "$script_dir/../../.." && pwd)"

# shellcheck source=../../../.claude/scripts/src/answer-talker-spoiler-check.sh
source "$repo_root/.claude/scripts/src/answer-talker-spoiler-check.sh"

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

declare -A ATR_FORBIDDEN=()

# 禁止語の集合を組み立て直すヘルパ（正解側の語・受講者側の語を改行区切りで渡す）。
setup_forbidden() {
  build_forbidden_set "$1" "$2"
}

# find_leaked_words の結果を「hit:<語>」「none」の形へ正規化する（終了コードも併せて検査するため）。
leaked() {
  REPLY=""
  if find_leaked_words "$1"; then
    printf 'hit:%s' "$REPLY"
  else
    printf 'none'
  fi
}

# --- 1. 正解にしかない識別子を含む本文は落とす --------------------------

setup_forbidden "$(printf '%s\n' 'UserRepository' 'format_report')" ""
assert_eq "1: 正解にしかない識別子を含む本文は落とす" \
  "hit:UserRepository" "$(leaked 'UserRepository を切り出すべき')"

# --- 2. 受講者diffにも現れる識別子は落とさない --------------------------

setup_forbidden "$(printf '%s\n' 'UserRepository' 'format_report')" \
  "$(printf '%s\n' 'UserRepository')"
assert_eq "2: 受講者が自分で書いている識別子は落とさない" \
  "none" "$(leaked 'UserRepository の責務が多すぎる')"
assert_eq "2b: 受講者側に無い識別子は落とす" \
  "hit:format_report" "$(leaked 'format_report を分けるべき')"

# --- 3. 除外語（言語キーワード・一般語）のみなら落とさない --------------

setup_forbidden "$(printf '%s\n' 'function' 'return' 'handler' 'config' 'Function')" ""
assert_eq "3: 除外語のみを含む本文は落とさない" \
  "none" "$(leaked 'この function は return が多く、handler と config が混在している')"
assert_eq "3b: 除外語は大文字始まりでも除外される" \
  "none" "$(leaked 'Function の分割を検討する')"

# --- 4. 3文字以下の語は禁止語に入れない ---------------------------------

setup_forbidden "$(printf '%s\n' 'id' 'db' 'err' 'ctx' 'repo')" ""
assert_eq "4: 3文字以下は禁止語にならない" \
  "none" "$(leaked 'id と db と err と ctx を整理する')"
assert_eq "4b: 4文字の語は禁止語になる" "hit:repo" "$(leaked 'repo の扱いを見直す')"

# --- 5. 部分文字列では一致させない（単語境界） --------------------------

setup_forbidden "$(printf '%s\n' 'repo')" ""
assert_eq "5: 禁止語が別の語の部分文字列でも落とさない" \
  "none" "$(leaked 'repository の責務を分ける')"
assert_eq "5b: アンダースコアで繋がった語も別語として扱う" \
  "none" "$(leaked 'user_repo_name を見直す')"

# --- 6. 行頭・行末・日本語に隣接していても検出する ----------------------

setup_forbidden "$(printf '%s\n' 'FilterLines')" ""
assert_eq "6: 行頭にあっても検出する" "hit:FilterLines" "$(leaked 'FilterLines が必要')"
assert_eq "6b: 行末にあっても検出する" "hit:FilterLines" "$(leaked '切り出すべきは FilterLines')"
assert_eq "6c: 日本語に直接隣接していても検出する" \
  "hit:FilterLines" "$(leaked 'ここでFilterLinesを使う')"
assert_eq "6d: 改行を挟んでも検出する" \
  "hit:FilterLines" "$(leaked "$(printf '1行目\nFilterLines\n3行目')")"

# --- 7. 大文字小文字が違えば別語として扱う ------------------------------

setup_forbidden "$(printf '%s\n' 'UserRepository')" ""
assert_eq "7: 小文字化した語は落とさない（大文字小文字を区別する）" \
  "none" "$(leaked 'userrepository の話')"

# --- 8. 空の入力 ---------------------------------------------------------

setup_forbidden "$(printf '%s\n' 'UserRepository')" ""
assert_eq "8: 空の本文は落とさない" "none" "$(leaked '')"

# --- 9. 正解ファイルが0件（禁止語が空）なら全件通す ---------------------

setup_forbidden "" ""
assert_eq "9: 禁止語が空なら何も落とさない" \
  "none" "$(leaked 'UserRepository も format_report も出てくる本文')"

# --- 10. 日本語のみの本文は落とさない -----------------------------------

setup_forbidden "$(printf '%s\n' 'UserRepository')" ""
assert_eq "10: 日本語のみの本文は落とさない" \
  "none" "$(leaked 'このファイルは責務が多いので分割を検討してほしい')"

# --- 11. 正解側に日本語の識別子があっても壊れない -----------------------

setup_forbidden "$(printf '%s\n' '設計メモ' 'UserRepository')" ""
assert_eq "11: 日本語の語は禁止語として機能しない（英数字の語だけを見る）" \
  "none" "$(leaked '設計メモ を参照する')"
assert_eq "11b: 日本語が混ざっていても英字の禁止語は検出できる" \
  "hit:UserRepository" "$(leaked '設計メモ の UserRepository を見る')"

# --- 12. 同じ本文に複数の禁止語があれば全部返す -------------------------

setup_forbidden "$(printf '%s\n' 'UserRepository' 'FilterLines')" ""
assert_eq "12: 複数の禁止語をすべて返す" \
  "hit:UserRepository FilterLines" "$(leaked 'UserRepository と FilterLines に分ける')"
assert_eq "12b: 同じ禁止語が2回出ても1回だけ返す" \
  "hit:FilterLines" "$(leaked 'FilterLines は FilterLines として切る')"

echo "passed=$passed failures=$failures"
[[ "$failures" -eq 0 ]]
