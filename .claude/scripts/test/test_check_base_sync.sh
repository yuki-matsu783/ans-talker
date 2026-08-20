#!/usr/bin/env bash
# .claude/scripts/src/check-base-sync.sh の単体テスト（issue #67）。
# 純粋関数（parse_left_right_to_reply / truncate_file_list）と、main の結合テストを対象とする。
# main の検証は mktemp -d で作った使い捨てgitリポジトリに対して行い、実リポジトリは汚さない。
# 規約: passed=N failures=N を標準出力へ出し、失敗があれば終了コード1
#       （.claude/rules/shell-script-style.md「テスト」。test_check_base_conflicts.sh を雛形にした）。
# 実行: bash .claude/scripts/test/test_check_base_sync.sh
set -euo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" == "${BASH_SOURCE[0]}" ]] && script_dir="."
repo_root="$(cd "$script_dir/../../.." && pwd)"

# shellcheck source=../../../.claude/scripts/src/check-base-sync.sh
source "$repo_root/.claude/scripts/src/check-base-sync.sh"

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

# --- parse_left_right_to_reply -------------------------------------------

# 終了コードは `if` の条件式で受ける（`"$(func; echo $?)"` は set -e 配下で空文字列になりうる。
# .claude/rules/shell-script-style.md「テスト」）。
REPLY_BEHIND=""; REPLY_AHEAD=""
parse_left_right_to_reply "$(printf '4\t1')"
assert_eq "parse: behindを取り出す" "4" "$REPLY_BEHIND"
assert_eq "parse: aheadを取り出す" "1" "$REPLY_AHEAD"

REPLY_BEHIND=""; REPLY_AHEAD=""
parse_left_right_to_reply "$(printf '0\t0')"
assert_eq "parse: 両方0（追従済み）" "0" "$REPLY_BEHIND"
assert_eq "parse: 両方0（aheadも0）" "0" "$REPLY_AHEAD"

REPLY_BEHIND=""; REPLY_AHEAD=""
parse_left_right_to_reply "$(printf '1234\t5678')"
assert_eq "parse: 桁数が多くても扱える" "1234" "$REPLY_BEHIND"
assert_eq "parse: 桁数が多くても扱える（ahead）" "5678" "$REPLY_AHEAD"

# WindowsネイティブjqのCR付与や、CRLFで受け取った場合の保険
REPLY_BEHIND=""; REPLY_AHEAD=""
parse_left_right_to_reply "$(printf '3\t2\r')"
assert_eq "parse: 末尾のCRを取り除く" "2" "$REPLY_AHEAD"

# 区切りがスペースでも読める（gitはTABを出すが、区切りの種類に依存しない）
REPLY_BEHIND=""; REPLY_AHEAD=""
parse_left_right_to_reply "7 8"
assert_eq "parse: スペース区切りでも読める" "7" "$REPLY_BEHIND"

if parse_left_right_to_reply ""; then empty_status=0; else empty_status=1; fi
assert_eq "parse: 空文字列は終了コード1" "1" "$empty_status"
assert_eq "parse: 空文字列ならREPLY_BEHINDは空" "" "$REPLY_BEHIND"
assert_eq "parse: 空文字列ならREPLY_AHEADは空" "" "$REPLY_AHEAD"

if parse_left_right_to_reply "4"; then single_status=0; else single_status=1; fi
assert_eq "parse: 数値が1つだけなら終了コード1" "1" "$single_status"

if parse_left_right_to_reply "$(printf 'a\tb')"; then nonnum_status=0; else nonnum_status=1; fi
assert_eq "parse: 数値でなければ終了コード1" "1" "$nonnum_status"

if parse_left_right_to_reply "$(printf -- '-1\t2')"; then neg_status=0; else neg_status=1; fi
assert_eq "parse: 負数は受け付けない" "1" "$neg_status"

if parse_left_right_to_reply "$(printf '1\t2\t3')"; then three_status=0; else three_status=1; fi
assert_eq "parse: 3つ以上は受け付けない" "1" "$three_status"

# --- truncate_file_list --------------------------------------------------

REPLY_FILES="x"; REPLY_TOTAL="x"
truncate_file_list "" 50
assert_eq "truncate: 空入力は0件" "0" "$REPLY_TOTAL"
assert_eq "truncate: 空入力の一覧は空文字列" "" "$REPLY_FILES"

REPLY_FILES=""; REPLY_TOTAL=""
truncate_file_list "a.md" 50
assert_eq "truncate: 1件" "1" "$REPLY_TOTAL"
assert_eq "truncate: 1件の一覧" "a.md" "$REPLY_FILES"

REPLY_FILES=""; REPLY_TOTAL=""
truncate_file_list "$(printf 'a\nb\nc')" 3
assert_eq "truncate: 上限ちょうどなら全件" "3" "$REPLY_TOTAL"
assert_eq "truncate: 上限ちょうどの一覧" "$(printf 'a\nb\nc')" "$REPLY_FILES"

REPLY_FILES=""; REPLY_TOTAL=""
truncate_file_list "$(printf 'a\nb\nc\nd')" 3
assert_eq "truncate: 上限+1件でも全件数は失わない" "4" "$REPLY_TOTAL"
assert_eq "truncate: 上限+1件なら先頭3件へ切り詰める" "$(printf 'a\nb\nc')" "$REPLY_FILES"

REPLY_FILES=""; REPLY_TOTAL=""
truncate_file_list "$(printf 'a\n\nb\n')" 50
assert_eq "truncate: 空行は数えない" "2" "$REPLY_TOTAL"
assert_eq "truncate: 空行を除いた一覧" "$(printf 'a\nb')" "$REPLY_FILES"

# 日本語を含むパス（このリポジトリの plans/【調査】〜.md 等）が壊れないこと。
# 先頭を ${var:0:N} で切り出す比較は使わない（バイト単位で切られマルチバイト文字が壊れる。
# .claude/rules/shell-script-style.md「テスト」）。
REPLY_FILES=""; REPLY_TOTAL=""
truncate_file_list "$(printf 'plans/【調査】ベースブランチ.md\n.claude/rules/shell-script-style.md')" 50
assert_eq "truncate: 日本語を含むパスの件数" "2" "$REPLY_TOTAL"
assert_eq "truncate: 日本語を含むパスが壊れない" \
  "plans/【調査】ベースブランチ.md" "$(printf '%s' "$REPLY_FILES" | head -1)"

REPLY_FILES=""; REPLY_TOTAL=""
truncate_file_list "$(printf 'a\nb')" 0
assert_eq "truncate: 上限0なら一覧は空だが件数は残る" "2" "$REPLY_TOTAL"
assert_eq "truncate: 上限0の一覧" "" "$REPLY_FILES"

# ---------------------------------------------------------------------------
# main の結合テスト（issue #67 のフェーズ3の敵対的レビュー指摘への対応）
#
# 純粋関数のテストだけでは、「壊れても静かに間違った値を返す」経路を守れない。
# 特に merge-base 不在の分岐は、ソース側のコメントが「ここを分けないと fatal で
# 終了コード128になる」と書いているとおり、消えても気づけない形の退行になる。
#
# 実リポジトリは汚さない。mktemp -d で使い捨てのgitリポジトリを作り、
# `git update-ref refs/remotes/origin/<base>` でリモート追跡参照だけを用意して
# `--no-fetch` で main を呼ぶ（ネットワークもリモートも要らない）。
# ---------------------------------------------------------------------------

cbs_script="$repo_root/.claude/scripts/src/check-base-sync.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

# 使い捨てリポジトリを作る。$1=リポジトリ名。作成したパスを REPLY_REPO へ返す。
make_repo() {
  local dir="$tmp_root/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email 'test@example.com'
  git -C "$dir" config user.name 'test'
  git -C "$dir" config commit.gpgsign false
  REPLY_REPO="$dir"
}

# $1=リポジトリ, $2=メッセージ, $3...=作成するファイル
commit_files() {
  local dir="$1" msg="$2"; shift 2
  local f
  for f in "$@"; do
    # ${f%/*} はスラッシュを含まないとファイル名自身を返すため、ディレクトリ付きのときだけ作る
    if [[ "$f" == */* ]]; then mkdir -p "$dir/${f%/*}"; fi
    printf '%s\n' "$msg" > "$dir/$f"
    git -C "$dir" add -- "$f"
  done
  git -C "$dir" -c core.hooksPath=/dev/null commit -q -m "$msg"
}

run_cbs() { # $1=リポジトリ, 残り=引数。stdoutを返し、終了コードは呼び出し側で見る
  ( cd "$1" && bash "$cbs_script" "${@:2}" )
}

# --- ケース1: ベースが2コミット進んでいる（通常のケース） ---
make_repo behind; repo_behind="$REPLY_REPO"
commit_files "$repo_behind" 'base1' 'README.md'
git -C "$repo_behind" checkout -q -b feature
commit_files "$repo_behind" 'feature1' 'feature.txt'
git -C "$repo_behind" checkout -q main
commit_files "$repo_behind" 'base2' '.claude/rules/added.md'
commit_files "$repo_behind" 'base3' 'plans/【調査】日本語パス.md'
git -C "$repo_behind" update-ref refs/remotes/origin/main "$(git -C "$repo_behind" rev-parse main)"
git -C "$repo_behind" checkout -q feature

out="$(run_cbs "$repo_behind" --no-fetch --base main)"
assert_eq "main: behind=2" "2" "$(printf '%s' "$out" | jq -r '.behind')"
assert_eq "main: ahead=1" "1" "$(printf '%s' "$out" | jq -r '.ahead')"
assert_eq "main: isBehind=true" "true" "$(printf '%s' "$out" | jq -r '.isBehind')"
assert_eq "main: hasCommonHistory=true" "true" "$(printf '%s' "$out" | jq -r '.hasCommonHistory')"
assert_eq "main: changedFilesTotal=2" "2" "$(printf '%s' "$out" | jq -r '.changedFilesTotal')"
assert_eq "main: changedFilesTruncated=false" "false" "$(printf '%s' "$out" | jq -r '.changedFilesTruncated')"
# 作業ブランチ自身の変更（feature.txt）が「未取り込み」に混ざらないこと（3ドット記法の効果）
assert_eq "main: 自分の変更は含まない" "false" \
  "$(printf '%s' "$out" | jq -r '.changedFiles | any(. == "feature.txt")')"
# 日本語を含むパスが8進エスケープされないこと（core.quotepath=false の効果）
assert_eq "main: 日本語パスがそのまま出る" "true" \
  "$(printf '%s' "$out" | jq -r '.changedFiles | any(. == "plans/【調査】日本語パス.md")')"
# --no-fetch のときは false ではなく null（「試していない」と「失敗した」の区別）
assert_eq "main: --no-fetch なら fetchOk=null" "null" "$(printf '%s' "$out" | jq -r '.fetchOk')"

# --- ケース2: 追従済み（behind=0） ---
git -C "$repo_behind" checkout -q main
out="$(run_cbs "$repo_behind" --no-fetch --base main)"
assert_eq "main: 追従済みなら behind=0" "0" "$(printf '%s' "$out" | jq -r '.behind')"
assert_eq "main: 追従済みなら isBehind=false" "false" "$(printf '%s' "$out" | jq -r '.isBehind')"
assert_eq "main: 追従済みなら changedFiles は空" "0" \
  "$(printf '%s' "$out" | jq -r '.changedFiles | length')"

# --- ケース3: 共通祖先が無い（orphanブランチ） ---
# rev-list --left-right --count は失敗せずベース側の全コミット数を返す一方、
# 3ドット記法のdiffは fatal で落ちる。merge-base 判定を先に置いていないとここで死ぬ。
make_repo orphan; repo_orphan="$REPLY_REPO"
commit_files "$repo_orphan" 'base1' 'a.txt'
commit_files "$repo_orphan" 'base2' 'b.txt'
git -C "$repo_orphan" update-ref refs/remotes/origin/main "$(git -C "$repo_orphan" rev-parse main)"
git -C "$repo_orphan" checkout -q --orphan lonely
git -C "$repo_orphan" rm -q -rf . >/dev/null
commit_files "$repo_orphan" 'lonely1' 'c.txt'

if out="$(run_cbs "$repo_orphan" --no-fetch --base main 2>/dev/null)"; then
  orphan_status=0
else
  orphan_status=$?
fi
assert_eq "main: 共通祖先が無くても終了コード0" "0" "$orphan_status"
assert_eq "main: hasCommonHistory=false" "false" "$(printf '%s' "$out" | jq -r '.hasCommonHistory')"
assert_eq "main: mergeBase=null" "null" "$(printf '%s' "$out" | jq -r '.mergeBase')"
assert_eq "main: 共通祖先が無いと changedFiles は空" "0" \
  "$(printf '%s' "$out" | jq -r '.changedFiles | length')"
# behind はベース側の全コミット数になる（この値だけを見て取り込みを提案してはいけない根拠）
assert_eq "main: behind はベース側の全コミット数" "2" "$(printf '%s' "$out" | jq -r '.behind')"

# --- ケース4: 切り詰めの境界（上限ちょうど／上限+1） ---
make_repo truncate; repo_trunc="$REPLY_REPO"
commit_files "$repo_trunc" 'base1' 'README.md'
git -C "$repo_trunc" checkout -q -b feature
git -C "$repo_trunc" checkout -q main
files=()
for ((i = 1; i <= 50; i++)); do files+=("f$i.txt"); done
commit_files "$repo_trunc" 'base-50' "${files[@]}"
git -C "$repo_trunc" update-ref refs/remotes/origin/main "$(git -C "$repo_trunc" rev-parse main)"
git -C "$repo_trunc" checkout -q feature
out="$(run_cbs "$repo_trunc" --no-fetch --base main)"
assert_eq "main: 上限ちょうどなら truncated=false" "false" \
  "$(printf '%s' "$out" | jq -r '.changedFilesTruncated')"
assert_eq "main: 上限ちょうどの一覧は50件" "50" "$(printf '%s' "$out" | jq -r '.changedFiles | length')"

git -C "$repo_trunc" checkout -q main
commit_files "$repo_trunc" 'base-51' 'f51.txt'
git -C "$repo_trunc" update-ref refs/remotes/origin/main "$(git -C "$repo_trunc" rev-parse main)"
git -C "$repo_trunc" checkout -q feature
out="$(run_cbs "$repo_trunc" --no-fetch --base main)"
assert_eq "main: 上限+1なら truncated=true" "true" \
  "$(printf '%s' "$out" | jq -r '.changedFilesTruncated')"
assert_eq "main: 上限+1でも総数は失わない" "51" "$(printf '%s' "$out" | jq -r '.changedFilesTotal')"
assert_eq "main: 上限+1でも一覧は50件で頭打ち" "50" \
  "$(printf '%s' "$out" | jq -r '.changedFiles | length')"

# --- ケース5: 引数の境界と異常系 ---
# 終了コードの検査に "$(func; echo $?)" は使わない（set -e 配下でサブシェルが echo へ
# 到達しないことがある。.claude/rules/shell-script-style.md「テスト」）。
if run_cbs "$repo_behind" --no-fetch --base >/dev/null 2>&1; then
  no_value_status=0
else
  no_value_status=$?
fi
assert_eq "main: --base に値が無ければ終了コード1" "1" "$no_value_status"

if run_cbs "$repo_behind" --no-fetch --base '' >/dev/null 2>&1; then
  empty_value_status=0
else
  empty_value_status=$?
fi
assert_eq "main: --base が空文字列でも終了コード1" "1" "$empty_value_status"

if run_cbs "$repo_behind" --no-fetch --base nonexistent >/dev/null 2>&1; then
  missing_base_status=0
else
  missing_base_status=$?
fi
assert_eq "main: origin/<base> が無ければ終了コード1" "1" "$missing_base_status"

if run_cbs "$repo_behind" --no-fetch --unknown-flag >/dev/null 2>&1; then
  unknown_status=0
else
  unknown_status=$?
fi
assert_eq "main: 不明な引数なら終了コード1" "1" "$unknown_status"

echo "passed=$passed failures=$failures"
[[ "$failures" -eq 0 ]]
