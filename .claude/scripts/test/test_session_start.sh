#!/usr/bin/env bash
# .claude/hooks/session-start.sh の単体テスト（issue #57で新設）。
# gh/git・ネットワークを伴わない純粋関数（context_text_bytes / append_size_warning /
# extract_handoff_next_steps）と、「sourceしても本体が実行されない」ことを検証する。
# 規約: passed=N failures=N を標準出力へ出し、失敗があれば終了コード1
#       （.claude/rules/shell-script-style.md「テスト」。.claude/scripts/test/test_update_handoff_progress.sh を雛形にした）。
# 実行: bash .claude/scripts/test/test_session_start.sh
set -euo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" == "${BASH_SOURCE[0]}" ]] && script_dir="."
repo_root="$(cd "$script_dir/../../.." && pwd)"

# source した時点で本体（stdin読み取り・コンテキスト注入）が走らないことが前提。
# 走ってしまう場合、ここでstdin待ちのままハングするか、JSONが標準出力へ漏れる。
# shellcheck source=../../../.claude/hooks/session-start.sh
source "$repo_root/.claude/hooks/session-start.sh"

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

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    passed=$((passed + 1))
  else
    failures=$((failures + 1))
    echo "FAIL: $name"
    echo "  expected to contain: $needle"
    echo "  actual            : $haystack"
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    passed=$((passed + 1))
  else
    failures=$((failures + 1))
    echo "FAIL: $name"
    echo "  expected NOT to contain: $needle"
    echo "  actual                : $haystack"
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

# 警告文に必ず含まれる特徴的な語（警告の有無の判定に使う）
WARNING_MARKER='しきい値'

# --- source時に本体が実行されない ------------------------------------------

# ここまで到達している時点で「sourceしてもstdin待ちにならない」ことは確認できている。
# 関数として定義されていることを明示的に確認する。
assert_eq "sourceしてもmainは実行されず関数として定義されるだけ" \
  "function" "$(type -t main)"
assert_eq "build_contextが関数として定義される" \
  "function" "$(type -t build_context)"

# --- context_text_bytes: 文字数ではなくバイト数を返す ------------------------

assert_eq "ASCIIのみは文字数と一致する" "5" "$(context_text_bytes 'abcde')"
assert_eq "空文字列は0バイト" "0" "$(context_text_bytes '')"
# 「あいう」は3文字だがUTF-8では9バイト。文字数で数えていればここで3が返り失敗する。
assert_eq "日本語はバイト数で数える（文字数ではない）" "9" "$(context_text_bytes 'あいう')"
# $'...' で書く（コマンド置換は末尾の改行を落とすため、末尾改行の検証に使えない）
assert_eq "改行もバイト数に含まれる" "4" "$(context_text_bytes $'a\nb\n')"

# --- append_size_warning: しきい値以下では追記されない ------------------------

short_text='短い注入テキスト'
result="$(append_size_warning "$short_text" 8000)"
assert_eq "しきい値以下なら入力がそのまま返る" "$short_text" "$result"
assert_not_contains "しきい値以下なら警告文が追記されない" "$result" "$WARNING_MARKER"

# 境界値: ちょうどしきい値ぴったり（-le 判定のため追記されない）
exact_text="$(printf 'a%.0s' $(seq 1 100))"
assert_eq "境界値テキストは100バイト" "100" "$(context_text_bytes "$exact_text")"
result="$(append_size_warning "$exact_text" 100)"
assert_eq "しきい値ちょうどなら追記されない（境界値）" "$exact_text" "$result"

# --- append_size_warning: しきい値超過で警告文が末尾へ追記される --------------

long_text="$(printf 'a%.0s' $(seq 1 101))"
result="$(append_size_warning "$long_text" 100)"
assert_contains "しきい値超過なら警告文が追記される" "$result" "$WARNING_MARKER"
assert_contains "超過時も元テキストは保持される（切り詰めない）" "$result" "$long_text"
assert_eq "超過時は元テキストが先頭にある" "$long_text" "${result:0:${#long_text}}"
assert_contains "警告文に実測バイト数が含まれる" "$result" "101 バイト"
assert_contains "警告文にしきい値が含まれる" "$result" "100 バイト"
assert_contains "警告文が整理対象のファイルを名指しする" "$result" "HANDOFF.md"

# 日本語で構成されたテキストも、文字数ではなくバイト数で判定される
# （30文字=90バイト。しきい値80なら「文字数判定なら超えない／バイト判定なら超える」）
ja_text="$(printf 'あ%.0s' $(seq 1 30))"
assert_eq "日本語テキストは90バイト" "90" "$(context_text_bytes "$ja_text")"
result="$(append_size_warning "$ja_text" 80)"
assert_contains "日本語テキストもバイト数で超過判定される" "$result" "$WARNING_MARKER"

# 第2引数を省略した場合は既定値 CONTEXT_SIZE_WARN_BYTES が使われる
saved_limit="$CONTEXT_SIZE_WARN_BYTES"
CONTEXT_SIZE_WARN_BYTES=10
result="$(append_size_warning 'abcdefghijk')"
assert_contains "引数省略時は既定値のしきい値が使われる（超過側）" "$result" "$WARNING_MARKER"
CONTEXT_SIZE_WARN_BYTES=8000
result="$(append_size_warning 'abcdefghijk')"
assert_not_contains "引数省略時は既定値のしきい値が使われる（非超過側）" "$result" "$WARNING_MARKER"
CONTEXT_SIZE_WARN_BYTES="$saved_limit"

# --- extract_handoff_next_steps: 「次にやること」節のみを抜き出す --------------

write_handoff_fixture() {
  cat >"$1" <<'FIXTURE'
# HANDOFF

## フロー進捗状況

| 進捗 | flow-id |
|----|---|
| [x] | 1-1 |

## やったこと

- これは抜き出されてはいけない

## 次にやること

- 個別作業計画のレビュー
- 設計反映

## 判断を迷った内容

- これも抜き出されてはいけない
FIXTURE
}

fixture="$TMP_DIR/handoff.md"
write_handoff_fixture "$fixture"
section="$(extract_handoff_next_steps "$fixture")"
assert_contains "見出し行を含めて抜き出す" "$section" "## 次にやること"
assert_contains "節の中身が含まれる" "$section" "- 個別作業計画のレビュー"
assert_contains "節の中身が最後まで含まれる" "$section" "- 設計反映"
assert_not_contains "前の節（やったこと）は混ざらない" "$section" "## やったこと"
assert_not_contains "前の節の中身は混ざらない" "$section" "これは抜き出されてはいけない"
assert_not_contains "次の節（判断を迷った内容）は混ざらない" "$section" "## 判断を迷った内容"
assert_not_contains "次の節の中身は混ざらない" "$section" "これも抜き出されてはいけない"
assert_not_contains "フロー進捗状況の表は混ざらない" "$section" "flow-id"

# 最終節（後続の ## が無い）でも末尾まで抜き出せる
fixture="$TMP_DIR/handoff_last.md"
cat >"$fixture" <<'FIXTURE'
## やったこと

- 済み

## 次にやること

- 最終行まで読むこと
FIXTURE
section="$(extract_handoff_next_steps "$fixture")"
assert_contains "最終節でも中身を抜き出せる" "$section" "- 最終行まで読むこと"
assert_not_contains "最終節でも前の節は混ざらない" "$section" "## やったこと"

# 「次にやること」節が無いファイル
fixture="$TMP_DIR/handoff_none.md"
cat >"$fixture" <<'FIXTURE'
## やったこと

- 済み
FIXTURE
if extract_handoff_next_steps "$fixture" >/dev/null 2>&1; then
  status=0
else
  status=1
fi
assert_failure "節が無いファイルでは失敗を返す" "$status"

# 見出しだけで中身が空の場合も「無い」とみなす
fixture="$TMP_DIR/handoff_empty.md"
cat >"$fixture" <<'FIXTURE'
## 次にやること

## 判断を迷った内容

- あり
FIXTURE
if extract_handoff_next_steps "$fixture" >/dev/null 2>&1; then
  status=0
else
  status=1
fi
assert_failure "見出しだけで中身が空なら失敗を返す" "$status"

# 存在しないファイル
if extract_handoff_next_steps "$TMP_DIR/not_exist.md" >/dev/null 2>&1; then
  status=0
else
  status=1
fi
assert_failure "存在しないファイルでは失敗を返す" "$status"

# 実物の HANDOFF.md でも抜き出せる（合成フィクスチャのみで完了としない。
# .claude/rules/shell-script-style.md「テスト」の実データ確認）
if [ -f "$repo_root/HANDOFF.md" ]; then
  if section="$(extract_handoff_next_steps "$repo_root/HANDOFF.md")"; then
    status=0
  else
    status=1
  fi
  assert_success "実物のHANDOFF.mdから抜き出せる" "$status"
  assert_eq "実物からの抜粋は見出し行で始まる" \
    "## 次にやること" "$(printf '%s' "$section" | head -1)"
fi

echo "passed=$passed failures=$failures"
[ "$failures" -eq 0 ]
