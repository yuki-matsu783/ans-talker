#!/usr/bin/env bash
# .claude/scripts/src/update-handoff-progress.sh の単体テスト（issue #20）。
# 実ファイルI/Oを伴うため、簡略版HANDOFF.mdフィクスチャを一時ファイルへ都度作成し、
# スクリプトの関数を直接sourceして呼ぶ（外部プロセスとしての起動は行わない）。
# 規約: passed=N failures=N を標準出力へ出し、失敗があれば終了コード1
#       （.claude/rules/shell-script-style.md「テスト」。.claude/scripts/test/test_vcs_provider.sh を雛形にした）。
# 実行: bash .claude/scripts/test/test_update_handoff_progress.sh
set -euo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" == "${BASH_SOURCE[0]}" ]] && script_dir="."
repo_root="$(cd "$script_dir/../../.." && pwd)"

# shellcheck source=../../../.claude/scripts/src/update-handoff-progress.sh
source "$repo_root/.claude/scripts/src/update-handoff-progress.sh"

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

assert_success() {
  local name="$1" status="$2"
  if [[ "$status" -eq 0 ]]; then
    passed=$((passed + 1))
  else
    failures=$((failures + 1))
    echo "FAIL: $name (expected success, got exit code $status)"
  fi
}

assert_failure() {
  local name="$1" status="$2"
  if [[ "$status" -ne 0 ]]; then
    passed=$((passed + 1))
  else
    failures=$((failures + 1))
    echo "FAIL: $name (expected failure, got exit code 0)"
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# 簡略版HANDOFF.mdフィクスチャを新規作成する（ヘッダ4行＋単発ステップ・ループ範囲・
# スキップ対象を1つずつ含む最小限のテーブル）。
write_fixture() {
  local file="$1"
  cat >"$file" <<'FIXTURE'
- issue: （未着手）
- ブランチ: （未着手）
- PR: （未着手）
- push回数: 0

| 進捗 | flow-id | ステップ | 担当 |
|----|---|---|---|
| [] | 1-1 | 単発ステップ | 人間 |
| [] | 2-3 | ループ範囲1 | 人間 |
| [] | 2-4 | ループ範囲2 | エージェント |
| [] | 5-1 | スキップ対象 | エージェント |
FIXTURE
}

get_row() {
  local file="$1" flow_id="$2"
  grep -F "| $flow_id |" "$file"
}

get_header() {
  local file="$1" prefix="$2"
  # 先頭が "-" の検索パターンをgrepがオプションと誤認識しないよう "--" を挟む
  grep -F -- "- $prefix:" "$file"
}

# --- mark-done: 単発ステップ ------------------------------------------------

fixture="$TMP_DIR/handoff1.md"
write_fixture "$fixture"
cmd_mark_done "$fixture" "1-1"
assert_eq "mark-done: 単発ステップが[x]になる" \
  "| [x] | 1-1 | 単発ステップ | 人間 |" "$(get_row "$fixture" 1-1)"

# --- mark-done: ループ範囲は両方の行が更新される ----------------------------

fixture="$TMP_DIR/handoff2.md"
write_fixture "$fixture"
cmd_mark_done "$fixture" "2-3"
assert_eq "mark-done: ループ範囲2-3が[x]になる" \
  "| [x] | 2-3 | ループ範囲1 | 人間 |" "$(get_row "$fixture" 2-3)"
assert_eq "mark-done: 同じループ範囲の2-4も[x]になる" \
  "| [x] | 2-4 | ループ範囲2 | エージェント |" "$(get_row "$fixture" 2-4)"

# --- mark-done: 末尾が[]でない行に対してはエラー終了する --------------------

fixture="$TMP_DIR/handoff3.md"
write_fixture "$fixture"
cmd_mark_done "$fixture" "1-1"
set +e
cmd_mark_done "$fixture" "1-1" >/dev/null 2>&1
status=$?
set -e
assert_failure "mark-done: 完了済み行への再適用はエラー" "$status"

# --- mark-skip: 単発・複数指定 ----------------------------------------------

fixture="$TMP_DIR/handoff4.md"
write_fixture "$fixture"
cmd_mark_skip "$fixture" "5-1"
assert_eq "mark-skip: 単発ステップが[-]になる" \
  "| [-] | 5-1 | スキップ対象 | エージェント |" "$(get_row "$fixture" 5-1)"

fixture="$TMP_DIR/handoff5.md"
write_fixture "$fixture"
cmd_mark_skip "$fixture" "1-1" "5-1"
assert_eq "mark-skip: 複数指定その1(1-1)が[-]になる" \
  "| [-] | 1-1 | 単発ステップ | 人間 |" "$(get_row "$fixture" 1-1)"
assert_eq "mark-skip: 複数指定その2(5-1)が[-]になる" \
  "| [-] | 5-1 | スキップ対象 | エージェント |" "$(get_row "$fixture" 5-1)"

# --- add-round: 正常系（ループ範囲の全行が[]へ戻る。記号は連結しない） ------

fixture="$TMP_DIR/handoff6.md"
write_fixture "$fixture"
cmd_mark_done "$fixture" "2-3"
cmd_add_round "$fixture" "2-3"
assert_eq "add-round: 2-3が[]へ戻る（記号は増やさない）" \
  "| [] | 2-3 | ループ範囲1 | 人間 |" "$(get_row "$fixture" 2-3)"
assert_eq "add-round: 同じ範囲の2-4も[]へ戻る" \
  "| [] | 2-4 | ループ範囲2 | エージェント |" "$(get_row "$fixture" 2-4)"

# --- add-round: ループでないflow-idはエラー ----------------------------------

fixture="$TMP_DIR/handoff7.md"
write_fixture "$fixture"
set +e
cmd_add_round "$fixture" "1-1" >/dev/null 2>&1
status=$?
set -e
assert_failure "add-round: 単発ステップへの適用はエラー" "$status"

# --- add-round: 末尾が既に[]の行への適用はエラー ------------------------------

fixture="$TMP_DIR/handoff8.md"
write_fixture "$fixture"
set +e
cmd_add_round "$fixture" "2-3" >/dev/null 2>&1
status=$?
set -e
assert_failure "add-round: 前回往復が未完了(末尾[])な状態での適用はエラー" "$status"

# --- set-header: 指定項目のみ更新され、他は現状維持 --------------------------

fixture="$TMP_DIR/handoff9.md"
write_fixture "$fixture"
cmd_set_header "$fixture" --issue "#20 テストissue" --push-count "3"
assert_eq "set-header: issue行が更新される" \
  "- issue: #20 テストissue" "$(get_header "$fixture" issue)"
assert_eq "set-header: push回数行が更新される" \
  "- push回数: 3" "$(get_header "$fixture" push回数)"
assert_eq "set-header: 未指定のブランチ行は現状維持" \
  "- ブランチ: （未着手）" "$(get_header "$fixture" ブランチ)"
assert_eq "set-header: 未指定のPR行は現状維持" \
  "- PR: （未着手）" "$(get_header "$fixture" PR)"

# --- ヘッダ「- 現在のループ:」行が周回数を持つ（issue #58） ------------------

# "- 現在のループ:" 行そのものを取り出す（無ければ空文字列）。
get_loop_header() {
  local file="$1"
  grep -F -- "- 現在のループ:" "$file" || true
}

# "- 現在のループ:" 行の出現回数（重複挿入していないことの確認に使う）。
count_loop_header() {
  local file="$1"
  grep -c -F -- "- 現在のループ:" "$file" || true
}

# 書式組み立て・解析（ファイルI/Oを伴わない純粋関数）
format_loop_status_to_reply "3-6 3-7 3-8 3-9" "3" "進行中"
assert_eq "format_loop_status: 進行中の表記" "3-6〜3-9 の3周目（進行中）" "$REPLY"
format_loop_status_to_reply "2-3 2-4" "1" "完了"
assert_eq "format_loop_status: 完了の表記" "2-3〜2-4 の1周目（完了）" "$REPLY"

if parse_loop_header_to_reply "- 現在のループ: 3-6〜3-9 の12周目（進行中）"; then
  parse_status=0
else
  parse_status=1
fi
assert_eq "parse_loop_header: ヘッダ行を解析できる" "0" "$parse_status"
assert_eq "parse_loop_header: 先頭flow-idを取り出す" "3-6" "$REPLY_LOOP_START_ID"
assert_eq "parse_loop_header: 2桁の周回数を取り出す" "12" "$REPLY_LOOP_ROUNDS"
if parse_loop_header_to_reply "- push回数: 3"; then
  parse_status=0
else
  parse_status=1
fi
assert_eq "parse_loop_header: 別のヘッダ行にはマッチしない" "1" "$parse_status"

# 進捗表の記号は増やさず、周回数はヘッダだけが持つ（受け入れ条件の中心）
fixture="$TMP_DIR/handoff10.md"
write_fixture "$fixture"
cmd_mark_done "$fixture" "2-3"
assert_eq "mark-done(ループ): ヘッダへ1周目（完了）が書かれる" \
  "- 現在のループ: 2-3〜2-4 の1周目（完了）" "$(get_loop_header "$fixture")"
assert_eq "mark-done(ループ): ヘッダ行はpush回数の直後へ挿入される" \
  "- push回数: 0
- 現在のループ: 2-3〜2-4 の1周目（完了）" "$(sed -n '4,5p' "$fixture")"

cmd_add_round "$fixture" "2-3"
assert_eq "add-round: ヘッダの周回数が1つ進む" \
  "- 現在のループ: 2-3〜2-4 の2周目（進行中）" "$(get_loop_header "$fixture")"
assert_eq "add-round: 進捗列は[]のまま（記号を連結しない）" \
  "| [] | 2-3 | ループ範囲1 | 人間 |" "$(get_row "$fixture" 2-3)"
assert_eq "add-round: ヘッダ行は増殖せず1行のまま" "1" "$(count_loop_header "$fixture")"

cmd_mark_done "$fixture" "2-4"
assert_eq "mark-done(2周目): 周回数は据え置きで完了になる" \
  "- 現在のループ: 2-3〜2-4 の2周目（完了）" "$(get_loop_header "$fixture")"
assert_eq "mark-done(2周目): 進捗列は記号1つのまま" \
  "| [x] | 2-4 | ループ範囲2 | エージェント |" "$(get_row "$fixture" 2-4)"

# 3周目まで進めても進捗表の記号は1つのまま
cmd_add_round "$fixture" "2-3"
cmd_mark_done "$fixture" "2-3"
assert_eq "3周目まで進めてもヘッダだけが増える" \
  "- 現在のループ: 2-3〜2-4 の3周目（完了）" "$(get_loop_header "$fixture")"
assert_eq "3周目でも進捗列は記号1つ" \
  "| [x] | 2-3 | ループ範囲1 | 人間 |" "$(get_row "$fixture" 2-3)"

# 別のループ範囲へ移ったら1周目から数え直す
fixture="$TMP_DIR/handoff11.md"
cat >"$fixture" <<'FIXTURE_MULTI'
- push回数: 0
- 現在のループ: 2-3〜2-4 の3周目（完了）

| 進捗 | flow-id | ステップ | 担当 |
|----|---|---|---|
| [x] | 2-3 | ループ範囲1 | 人間 |
| [x] | 2-4 | ループ範囲2 | エージェント |
| [] | 3-3 | 別ループ1 | 人間 |
| [] | 3-4 | 別ループ2 | エージェント |
FIXTURE_MULTI
cmd_mark_done "$fixture" "3-3"
assert_eq "別のループ範囲へ移ると1周目から数え直す" \
  "- 現在のループ: 3-3〜3-4 の1周目（完了）" "$(get_loop_header "$fixture")"

# 旧 [x][x][] 表記からの移行: 周回数をヘッダへ引き継ぎ、進捗列は記号1つへ畳む
fixture="$TMP_DIR/handoff12.md"
cat >"$fixture" <<'FIXTURE_LEGACY'
- push回数: 0

| 進捗 | flow-id | ステップ | 担当 |
|----|---|---|---|
| [x][x][] | 2-3 | ループ範囲1 | 人間 |
| [x][x][] | 2-4 | ループ範囲2 | エージェント |
FIXTURE_LEGACY
cmd_mark_done "$fixture" "2-3"
assert_eq "旧表記からの移行: 記号の個数が周回数としてヘッダへ移る" \
  "- 現在のループ: 2-3〜2-4 の3周目（完了）" "$(get_loop_header "$fixture")"
assert_eq "旧表記からの移行: 進捗列は記号1つへ畳まれる" \
  "| [x] | 2-3 | ループ範囲1 | 人間 |" "$(get_row "$fixture" 2-3)"

fixture="$TMP_DIR/handoff13.md"
cat >"$fixture" <<'FIXTURE_LEGACY2'
- push回数: 0

| 進捗 | flow-id | ステップ | 担当 |
|----|---|---|---|
| [x][x] | 2-3 | ループ範囲1 | 人間 |
| [x][x] | 2-4 | ループ範囲2 | エージェント |
FIXTURE_LEGACY2
cmd_add_round "$fixture" "2-3"
assert_eq "旧表記からの移行: add-roundは個数+1をヘッダへ書く" \
  "- 現在のループ: 2-3〜2-4 の3周目（進行中）" "$(get_loop_header "$fixture")"
assert_eq "旧表記からの移行: add-roundでも進捗列は[]ひとつ" \
  "| [] | 2-4 | ループ範囲2 | エージェント |" "$(get_row "$fixture" 2-4)"

# 単発ステップのmark-done・mark-skipではヘッダ行を触らない
fixture="$TMP_DIR/handoff14.md"
write_fixture "$fixture"
cmd_mark_done "$fixture" "1-1"
assert_eq "mark-done(単発): ヘッダ行は追加されない" "0" "$(count_loop_header "$fixture")"
cmd_mark_skip "$fixture" "5-1"
assert_eq "mark-skip: ヘッダ行は追加されない" "0" "$(count_loop_header "$fixture")"

# set-header --loop: 任意の文字列をそのまま書ける／未指定なら現状維持
fixture="$TMP_DIR/handoff15.md"
write_fixture "$fixture"
cmd_set_header "$fixture" --loop "なし"
assert_eq "set-header --loop: 指定文字列がそのまま入る" \
  "- 現在のループ: なし" "$(get_loop_header "$fixture")"
cmd_set_header "$fixture" --issue "#58 テストissue"
assert_eq "set-header(--loop未指定): 既存のループ行は現状維持" \
  "- 現在のループ: なし" "$(get_loop_header "$fixture")"
cmd_set_header "$fixture" --loop "3-6〜3-9 の2周目（進行中）"
assert_eq "set-header --loop: 既存行は置換され重複しない" "1" "$(count_loop_header "$fixture")"
assert_eq "set-header --loop: 既存行が置換される" \
  "- 現在のループ: 3-6〜3-9 の2周目（進行中）" "$(get_loop_header "$fixture")"

# ヘッダ項目を持たないHANDOFF.md（flow-id 5-1直後）でも見出しの直前へ挿入できる
fixture="$TMP_DIR/handoff16.md"
cat >"$fixture" <<'FIXTURE_NOHEADER'
# HANDOFF

## フロー進捗状況

| 進捗 | flow-id | ステップ | 担当 |
|----|---|---|---|
| [] | 2-3 | ループ範囲1 | 人間 |
| [] | 2-4 | ループ範囲2 | エージェント |
FIXTURE_NOHEADER
cmd_mark_done "$fixture" "2-3"
assert_eq "ヘッダ項目が無い場合は見出しの直前へ空行付きで挿入される" \
  "- 現在のループ: 2-3〜2-4 の1周目（完了）

## フロー進捗状況" "$(sed -n '3,5p' "$fixture")"

# 挿入位置の基準が無い場合、進捗表の更新は成功させヘッダ行は警告に留める
fixture="$TMP_DIR/handoff17.md"
cat >"$fixture" <<'FIXTURE_BARE'
| 進捗 | flow-id | ステップ | 担当 |
|----|---|---|---|
| [] | 2-3 | ループ範囲1 | 人間 |
| [] | 2-4 | ループ範囲2 | エージェント |
FIXTURE_BARE
set +e
cmd_mark_done "$fixture" "2-3" 2>/dev/null
status=$?
set -e
assert_success "挿入位置が無くてもmark-done自体は成功する" "$status"
assert_eq "挿入位置が無い場合でも進捗表は更新される" \
  "| [x] | 2-3 | ループ範囲1 | 人間 |" "$(get_row "$fixture" 2-3)"
set +e
cmd_set_header "$fixture" --loop "なし" >/dev/null 2>&1
status=$?
set -e
assert_failure "set-header --loop は挿入位置が無ければエラー" "$status"

echo "passed=$passed failures=$failures"
[ "$failures" -eq 0 ]
