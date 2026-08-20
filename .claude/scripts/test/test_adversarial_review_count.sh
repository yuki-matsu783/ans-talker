#!/usr/bin/env bash
# .claude/scripts/src/adversarial-review-count.sh の純粋ロジック（状態ファイルのパス組み立て・
# 状態JSONの正規化・上限判定・加算）の単体テスト。issue #77。
#
# `main` はgitのブランチ名取得とファイルI/Oを伴うため対象外で、
# `if [ "${BASH_SOURCE[0]}" = "${0}" ]` のガードにより source しても実行されない
# （.claude/rules/shell-script-style.md「テスト」）。
#
# 規約: passed=N failures=N を標準出力へ出し、失敗があれば終了コード1。
# 実行: bash .claude/scripts/test/test_adversarial_review_count.sh
set -euo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" == "${BASH_SOURCE[0]}" ]] && script_dir="."
repo_root="$(cd "$script_dir/../../.." && pwd)"

# shellcheck source=../../../.claude/scripts/src/adversarial-review-count.sh
source "$repo_root/.claude/scripts/src/adversarial-review-count.sh"

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

# --- adversarial_review_state_path ---------------------------------------------------

assert_eq "adversarial_review_state_path: ブランチ名をそのままファイル名に使う" \
  '.claude/state/adversarial-review/feature-77-x.json' \
  "$(adversarial_review_state_path 'feature-77-x')"

# `/` を含むブランチ名（例: claude/issue-77-abc）がディレクトリ区切りと解釈されると、
# 状態ファイルが意図しない場所へ作られる
assert_eq "adversarial_review_state_path: ブランチ名の/は__へ置き換える" \
  '.claude/state/adversarial-review/claude__issue-77-abc.json' \
  "$(adversarial_review_state_path 'claude/issue-77-abc')"

assert_eq "adversarial_review_state_path: /が複数あってもすべて置き換える" \
  '.claude/state/adversarial-review/a__b__c.json' \
  "$(adversarial_review_state_path 'a/b/c')"

# --- adversarial_review_normalize_state ----------------------------------------------

assert_eq "adversarial_review_normalize_state: 空文字列は状態なしへフォールバック" \
  '{}' \
  "$(adversarial_review_normalize_state '')"

assert_eq "adversarial_review_normalize_state: 引数省略も状態なしへフォールバック" \
  '{}' \
  "$(adversarial_review_normalize_state)"

# 壊れた状態ファイルが残ると、以降のjq呼び出しが毎回失敗して恒久的に回復不能になる
# （.claude/rules/shell-script-style.md「JSON操作」）
assert_eq "adversarial_review_normalize_state: 壊れたJSONは状態なしへフォールバック" \
  '{}' \
  "$(adversarial_review_normalize_state '{"3":')"

assert_eq "adversarial_review_normalize_state: オブジェクト以外も状態なしへフォールバック" \
  '{}' \
  "$(adversarial_review_normalize_state '[1,2,3]')"

assert_eq "adversarial_review_normalize_state: 有効なJSONはそのまま返す" \
  '{"3":2}' \
  "$(adversarial_review_normalize_state '{"3":2}')"

# --- adversarial_review_get_count ----------------------------------------------------

assert_eq "adversarial_review_get_count: 記録が無いフェーズは0" \
  '0' \
  "$(adversarial_review_get_count '{"2":1}' 3)"

assert_eq "adversarial_review_get_count: 記録があればその値" \
  '2' \
  "$(adversarial_review_get_count '{"2":1,"3":2}' 3)"

assert_eq "adversarial_review_get_count: 状態なしでも0を返す" \
  '0' \
  "$(adversarial_review_get_count '' 3)"

# --- adversarial_review_can_run ------------------------------------------------------
#
# 終了コードの検査は `$(func; echo $?)` ではなく `if` で受ける
# （set -e 配下ではサブシェルが echo に到達しないことがあるため。
#  .claude/rules/shell-script-style.md「テスト」）。

can_run_status() {
  if adversarial_review_can_run "$1" "$2"; then
    printf '0'
  else
    printf '1'
  fi
}

assert_eq "adversarial_review_can_run: 0回なら実施できる" '0' "$(can_run_status '{}' 3)"
assert_eq "adversarial_review_can_run: 2回でも実施できる" '0' "$(can_run_status '{"3":2}' 3)"
assert_eq "adversarial_review_can_run: 3回で上限に達する" '1' "$(can_run_status '{"3":3}' 3)"
assert_eq "adversarial_review_can_run: 3回を超えていても上限扱い" '1' "$(can_run_status '{"3":9}' 3)"
assert_eq "adversarial_review_can_run: フェーズごとに独立している" '0' "$(can_run_status '{"3":3}' 4)"
assert_eq "adversarial_review_can_run: 壊れた状態は実施できる側へ倒す" '0' "$(can_run_status '{"3":' 3)"

# --- adversarial_review_increment_state ----------------------------------------------

assert_eq "adversarial_review_increment_state: 記録が無ければ1になる" \
  '{"3":1}' \
  "$(adversarial_review_increment_state '{}' 3)"

assert_eq "adversarial_review_increment_state: 既存の値へ1を足す" \
  '{"3":3}' \
  "$(adversarial_review_increment_state '{"3":2}' 3)"

assert_eq "adversarial_review_increment_state: 他フェーズの値は変えない" \
  '{"2":1,"3":1}' \
  "$(adversarial_review_increment_state '{"2":1}' 3)"

assert_eq "adversarial_review_increment_state: 壊れた状態からでも1で始まる" \
  '{"4":1}' \
  "$(adversarial_review_increment_state 'not json' 4)"

# --- 上限値 --------------------------------------------------------------------------
#
# 上限は「AIエージェントの自制ではなくスクリプトで強制する」ためのものなので、
# 値が意図せず変わっていないことを固定値で確認する。
assert_eq "上限は3回" '3' "$ADVERSARIAL_REVIEW_MAX_RUNS"

echo "passed=$passed failures=$failures"
[ "$failures" -eq 0 ]
