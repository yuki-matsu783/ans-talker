#!/usr/bin/env bash
# .claude/scripts/src/answer-talker-submission.sh の単体テスト（issue #6）。
#
# API呼び出しを伴わない範囲を対象とする（`is_excluded_path` / `list_submission_files` /
# `prune_submission_tree` / `emit_degraded` / `cleanup_main`）。段の判断そのものは
# ネットワークに依存するため、実機検証（`【テスト】`）で確かめる。
#
# 規約: passed=N failures=N を標準出力へ出し、失敗があれば終了コード1
#       （.claude/rules/shell-script-style.md「テスト」）。
# 実行: bash .claude/scripts/test/test_answer_talker_submission.sh
set -euo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" == "${BASH_SOURCE[0]}" ]] && script_dir="."
repo_root="$(cd "$script_dir/../../.." && pwd)"

# `source` してもmainが走らないこと（stdin待ちでハングしないこと）を前提にしている
# （.claude/rules/shell-script-style.md「テスト」のガード）。
# shellcheck source=../../../.claude/scripts/src/answer-talker-submission.sh
source "$repo_root/.claude/scripts/src/answer-talker-submission.sh"

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

assert_true() {
  local name="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
  else
    failures=$((failures + 1))
    echo "FAIL: $name（真を期待したが偽）"
  fi
}

assert_false() {
  local name="$1"
  shift
  if "$@"; then
    failures=$((failures + 1))
    echo "FAIL: $name（偽を期待したが真）"
  else
    passed=$((passed + 1))
  fi
}

# --- is_excluded_path -----------------------------------------------------

assert_true  'node_modules直下を除外する'        is_excluded_path 'node_modules/pkg/index.js'
assert_true  '途中のnode_modulesも除外する'      is_excluded_path 'a/b/node_modules/x.js'
assert_true  'vendorを除外する'                  is_excluded_path 'a/vendor/b.go'
assert_true  'distを除外する'                    is_excluded_path 'dist/out.js'
assert_true  '.gitを除外する'                    is_excluded_path '.git/config'
assert_true  '__pycache__を除外する'             is_excluded_path 'pkg/__pycache__/m.pyc'
assert_false '通常のファイルは除外しない'        is_excluded_path 'main.sh'
assert_false 'ネストした通常ファイルも残す'      is_excluded_path 'src/lib/io.sh'

# **前方一致・部分一致で誤爆しないこと。** ディレクトリ名として現れた場合だけ除外する。
assert_false 'dist を含むファイル名は除外しない' is_excluded_path 'src/dist.txt'
assert_false 'buildで始まる名前は除外しない'     is_excluded_path 'build.sh'
assert_false 'targetを含むパスの一部は除外しない' is_excluded_path 'src/targets/a.sh'

# --- prune_submission_tree / list_submission_files ------------------------
#
# 一時ディレクトリを作って実際に削除・列挙する（ファイルI/Oのみで、API呼び出しは伴わない）。

tmp="$(mktemp -d)"
mkdir -p "$tmp/node_modules/pkg" "$tmp/src" "$tmp/dist" "$tmp/lib"
printf 'readme\n'            > "$tmp/README.md"
printf '#!/bin/sh\necho x\n' > "$tmp/src/main.sh"
printf 'export const a = 1\n' > "$tmp/node_modules/pkg/index.js"
printf 'built\n'             > "$tmp/dist/out.js"
printf 'lib\n'               > "$tmp/lib/io.sh"
printf 'bin\x00\x01\x02data\n' > "$tmp/image.png"

prune_submission_tree "$tmp"

remaining="$( (cd "$tmp" && find . -type f | sed 's|^\./||' | sort) | tr '\n' ' ')"
assert_eq '生成物ディレクトリとバイナリが削除される' 'README.md lib/io.sh src/main.sh ' "$remaining"

listed="$(list_submission_files "$tmp" | tr '\n' ' ')"
assert_eq '一覧はルートからの相対パスで返る' 'README.md lib/io.sh src/main.sh ' "$listed"

rm -rf "$tmp"

# **削除対象が1つも無いツリーでも失敗しないこと**（`comm`/`find` の空入力で落ちない）。
tmp2="$(mktemp -d)"
printf 'only\n' > "$tmp2/a.txt"
prune_submission_tree "$tmp2"
assert_eq '除外対象が無くても残る' 'a.txt ' "$( (cd "$tmp2" && find . -type f | sed 's|^\./||') | tr '\n' ' ')"
rm -rf "$tmp2"

# --- emit_degraded --------------------------------------------------------
#
# **段3は「失敗」ではない。** 終了コード0で、`degraded:true` / `root:null` を返す。

out="$(emit_degraded 'fetch-failed')"
assert_eq '段3のstageは3'          '3'             "$(printf '%s' "$out" | jq -r '.stage')"
assert_eq '段3のrootはnull'        'null'          "$(printf '%s' "$out" | jq -r '.root')"
assert_eq '段3のtmpdirはnull'      'null'          "$(printf '%s' "$out" | jq -r '.tmpdir')"
assert_eq '段3のdegradedはtrue'    'true'          "$(printf '%s' "$out" | jq -r '.degraded')"
assert_eq '段3のreasonが入る'      'fetch-failed'  "$(printf '%s' "$out" | jq -r '.reason')"
assert_eq '段3のfilesは空配列'     '0'             "$(printf '%s' "$out" | jq -r '.files | length')"
assert_eq '段3のtruncatedはfalse'  'false'         "$(printf '%s' "$out" | jq -r '.truncated')"

# 終了コードを検査する。`"$(func; echo $?)"` の形は `set -e` 配下で空文字を返しうるため使わない
# （.claude/rules/shell-script-style.md「テスト」）。
if emit_degraded 'x' >/dev/null; then
  degraded_status=0
else
  degraded_status=1
fi
assert_eq '段3は終了コード0で返る' '0' "$degraded_status"

# --- cleanup_main ---------------------------------------------------------
#
# マーカーが無いディレクトリは**絶対に削除しない**（誤って別のディレクトリを消さないため）。

no_marker="$(mktemp -d)"
out="$(cleanup_main --tmpdir "$no_marker")"
assert_eq 'マーカー無しは削除しない'   'false'      "$(printf '%s' "$out" | jq -r '.removed')"
assert_eq 'マーカー無しの理由'         'no-marker'  "$(printf '%s' "$out" | jq -r '.reason')"
assert_true 'マーカー無しは実体が残る' test -d "$no_marker"
rmdir "$no_marker"

with_marker="$(mktemp -d)"
printf 'answer-talker submission\n' > "$with_marker/$ATR_SUBMISSION_MARKER"
mkdir -p "$with_marker/source"
printf 'x\n' > "$with_marker/source/a.txt"
out="$(cleanup_main --tmpdir "$with_marker")"
assert_eq 'マーカー有りは削除する'     'true'       "$(printf '%s' "$out" | jq -r '.removed')"
assert_false 'マーカー有りは実体が消える' test -d "$with_marker"

# 2回目（冪等）
out="$(cleanup_main --tmpdir "$with_marker")"
assert_eq '2回目は削除しない'          'false'      "$(printf '%s' "$out" | jq -r '.removed')"
assert_eq '2回目の理由'                'not-found'  "$(printf '%s' "$out" | jq -r '.reason')"

out="$(cleanup_main --tmpdir '')"
assert_eq '空パスは削除しない'         'false'      "$(printf '%s' "$out" | jq -r '.removed')"

echo "passed=$passed failures=$failures"
[ "$failures" -eq 0 ]
