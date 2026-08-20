#!/usr/bin/env bash
# .claude/scripts/src/extract-frontmatter.sh の純粋ロジック（副作用の無い変換処理）の単体テスト。
# index.jsonl を実際に書き出す main() はテスト対象外（スクリプトをsourceして関数のみ再利用する）。
# 規約: passed=N failures=N を標準出力へ出し、失敗があれば終了コード1
#       （.claude/rules/shell-script-style.md「テスト」）。
# 実行: bash .claude/scripts/test/test_extract_frontmatter.sh
set -euo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" == "${BASH_SOURCE[0]}" ]] && script_dir="."
repo_root="$(cd "$script_dir/../../.." && pwd)"

# shellcheck source=../../../.claude/scripts/src/extract-frontmatter.sh
source "$repo_root/.claude/scripts/src/extract-frontmatter.sh"

passed=0
failures=0

fixture_dir="$(mktemp -d)"
cleanup_fixtures() {
  rm -rf "$fixture_dir"
}
trap cleanup_fixtures EXIT

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

# 部分一致の判定を 0/1 で返す。日本語を含む文字列は ${var:0:N} で切り出すとバイト単位で壊れるため、
# 位置ではなくパターンで見る（.claude/rules/shell-script-style.md「テスト」）。
status_of_contains() {
  local haystack="$1" needle="$2"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '0'
  else
    printf '1'
  fi
}

# フィクスチャのmarkdownを作り、そのパスを返す
make_md() {
  local name="$1"
  local path="$fixture_dir/$name"
  mkdir -p "${path%/*}"
  cat >"$path"
  printf '%s' "$path"
}

# --- frontmatter_to_json -----------------------------------------------------

f="$(make_md scalar.md <<'MD'
---
title: サンプル
type: spec
---

本文
MD
)"
assert_eq "スカラーのみ" \
  '{"title":"サンプル","type":"spec"}' \
  "$(frontmatter_to_json "$f")"

f="$(make_md flow_array.md <<'MD'
---
title: X
tags: [alpha, beta, gamma]
---
MD
)"
assert_eq "フロー配列（順序保持）" \
  '{"title":"X","tags":["alpha","beta","gamma"]}' \
  "$(frontmatter_to_json "$f")"

f="$(make_md block_array.md <<'MD'
---
title: X
keywords:
  - one
  - two
  - three
type: rule
---
MD
)"
assert_eq "ブロック配列（順序保持・後続キーの位置）" \
  '{"title":"X","keywords":["one","two","three"],"type":"rule"}' \
  "$(frontmatter_to_json "$f")"

f="$(make_md empty_list.md <<'MD'
---
title: X
tags:
type: Y
---
MD
)"
assert_eq "要素0個のリストキーは空配列" \
  '{"title":"X","tags":[],"type":"Y"}' \
  "$(frontmatter_to_json "$f")"

f="$(make_md quoted.md <<'MD'
---
status: superseded
superseded_by: "0019"
---
MD
)"
assert_eq "ダブルクォート付きの値はクォートを外した文字列" \
  '{"status":"superseded","superseded_by":"0019"}' \
  "$(frontmatter_to_json "$f")"

f="$(make_md boolean.md <<'MD'
---
alwaysApply: true
disabled: false
name: X
---
MD
)"
assert_eq "true/falseはJSONの真偽値" \
  '{"alwaysApply":true,"disabled":false,"name":"X"}' \
  "$(frontmatter_to_json "$f")"

f="$(make_md no_frontmatter.md <<'MD'
# 見出しから始まるファイル

frontmatterを持たない。
MD
)"
assert_eq "frontmatter無しはnull" \
  'null' \
  "$(frontmatter_to_json "$f")"

# CRLF改行でもLFと同じ結果になること
crlf="$fixture_dir/crlf.md"
printf -- '---\r\ntitle: X\r\ntags: [a, b]\r\n---\r\n\r\n本文\r\n' >"$crlf"
assert_eq "CRLF改行でもLFと同じJSON" \
  '{"title":"X","tags":["a","b"]}' \
  "$(frontmatter_to_json "$crlf")"

# --- 中間表現（FM_ITEMS）----------------------------------------------------

parse_frontmatter_block <<'MD'
title: X
tags: [a, b]
MD
assert_eq "parse_frontmatter_blockの中間表現" \
  's title X A tags  a tags a a tags b' \
  "${FM_ITEMS[*]}"

assert_eq "frontmatter_items_to_jsonは中間表現からJSONを作る" \
  '{"title":"X","tags":["a","b"]}' \
  "$(frontmatter_items_to_json)"

# --- trim / unquote ----------------------------------------------------------

assert_eq "trimは前後の空白を落とす" "abc" "$(trim '  abc  ')"
assert_eq "unquoteは前後のダブルクォートを落とす" "abc" "$(unquote '"abc"')"

trim_unquote_to_reply '  "abc"  '
assert_eq "trim_unquote_to_replyはREPLYへ返す" "abc" "$REPLY"

unquote_to_reply '"0019"'
assert_eq "unquote_to_replyはREPLYへ返す" "0019" "$REPLY"

# --- resolve_repo_root -------------------------------------------------------

assert_eq "resolve_repo_rootはリポジトリルートを返す" \
  "$(cd "$repo_root" && pwd)" \
  "$(resolve_repo_root "$repo_root/.claude")"

# --- build_index_line --------------------------------------------------------

f="$(make_md line/sample.md <<'MD'
---
title: 行組み立ての確認
type: spec
tags: [x, y]
---
MD
)"
assert_eq "build_index_lineは4キーの1行JSONを返す" \
  '{"concept_id":"docs/sample","directory":"docs","frontmatter":{"title":"行組み立ての確認","type":"spec","tags":["x","y"]},"mtime":"2026-01-02T03:04:05"}' \
  "$(build_index_line "$f" "docs/sample" "docs" "2026-01-02T03:04:05")"

f="$(make_md line/plain.md <<'MD'
frontmatterを持たないファイル。
MD
)"
assert_eq "build_index_lineはfrontmatter無しでnullを埋める" \
  '{"concept_id":"docs/plain","directory":"docs","frontmatter":null,"mtime":"2026-01-02T03:04:05"}' \
  "$(build_index_line "$f" "docs/plain" "docs" "2026-01-02T03:04:05")"

# --- ハイフンで始まる要素（issue #69）----------------------------------------

# jqへ位置引数として渡す中間表現に `-A` のようなハイフン始まりの要素が含まれると、jqが
# それをオプションとして解釈して `jq: Unknown option -A` で失敗し、index.jsonlの行が
# 丸ごと欠落していた回帰（`keywords: [git add, -A, pathspec]` で発生）。

parse_frontmatter_block <<'MD'
title: X
keywords: [git add, -A, pathspec]
MD
assert_eq "フロー配列のハイフン始まり要素" \
  '{"title":"X","keywords":["git add","-A","pathspec"]}' \
  "$(frontmatter_items_to_json)"

parse_frontmatter_block <<'MD'
title: -A
keywords:
  - -A
  - --force
  - -
MD
assert_eq "ブロック配列・スカラーのハイフン始まり値" \
  '{"title":"-A","keywords":["-A","--force","-"]}' \
  "$(frontmatter_items_to_json)"

# 引数長上限を超えて --rawfile 経路へフォールバックした場合も同じ結果になること
FM_ITEMS=(s title X A keywords "")
for i in $(seq 1 900); do
  FM_ITEMS+=(a keywords "padding-padding-padding-padding-$i")
done
FM_ITEMS+=(a keywords "-A")
assert_eq "--rawfile経路でもハイフン始まり要素を保持する" \
  '["-A",901]' \
  "$(frontmatter_items_to_json | jq -c '[.keywords[-1], (.keywords | length)]')"

# jqが失敗した場合に run_fm_jq が失敗を握りつぶさないこと（index.jsonlへ空行が入り、
# 終了コード0のまま完了してしまうのを防ぐ）。`set -e` 配下では `$(func; echo $?)` が
# 使えないため if で受ける（.claude/rules/shell-script-style.md「テスト」）。
FM_ITEMS=(s title X)
if run_fm_jq 'this is not a valid jq filter' >/dev/null 2>&1; then
  run_fm_jq_status=0
else
  run_fm_jq_status=1
fi
assert_eq "run_fm_jqはjqの失敗を非ゼロで返す" "1" "$run_fm_jq_status"

# yq の有無にかかわらず同じ結果になること。yq不在の環境は、jq/mktemp だけを置いた
# ディレクトリを PATH にすることで再現する（yq経路とフォールバック経路の両方を通す）。
fake_bin="$fixture_dir/bin"
mkdir -p "$fake_bin"
ln -s "$(command -v jq)" "$fake_bin/jq"
ln -s "$(command -v mktemp)" "$fake_bin/mktemp"

f="$(make_md hyphen/sample.md <<'MD'
---
title: ハイフン始まり要素の確認
type: log
keywords: [git add, -A, pathspec]
---

本文
MD
)"
hyphen_expected='{"concept_id":"docs/sample","directory":"docs","frontmatter":{"title":"ハイフン始まり要素の確認","type":"log","keywords":["git add","-A","pathspec"]},"mtime":"2026-01-02T03:04:05"}'
assert_eq "build_index_lineはハイフン始まり要素の行を生成する" \
  "$hyphen_expected" \
  "$(build_index_line "$f" "docs/sample" "docs" "2026-01-02T03:04:05")"
assert_eq "build_index_lineはyq不在でも同じ行を生成する" \
  "$hyphen_expected" \
  "$(PATH="$fake_bin"; build_index_line "$f" "docs/sample" "docs" "2026-01-02T03:04:05")"

# --- 削除済みの追跡ファイル（issue #117）-------------------------------------

# 列挙に使う `git ls-files --cached` は「削除したがまだステージしていない」追跡ファイルも返す。
# 実体の無いパスをそのまま stat へ渡していたため、一括取得（xargs）と1件ずつの再取得の両方が
# 倒れ、**走査全体が中断**していた（無関係なディレクトリの index.jsonl まで再生成されない）。
# `cleanup-task.sh` はコミットせずに削除するため、この状態は異常系ではなく正常系として必ず起きる。
# 列挙は main にしか無く純粋関数では再現できないため、使い捨てのgitリポジトリを作って実プロセスと
# して起動する（test_search_frontmatter.sh と同じ切り分け）。
# ステージするだけで `--cached` の列挙対象になるので、コミットは行わない。

ef_script="$repo_root/.claude/scripts/src/extract-frontmatter.sh"
del_repo="$fixture_dir/deleted-repo"
mkdir -p "$del_repo/plans" "$del_repo/docs"
git -C "$del_repo" init -q 2>/dev/null || git -C "$del_repo" init >/dev/null 2>&1
printf '**/index.jsonl\n' >"$del_repo/.gitignore"
printf -- '---\ntitle: 残るファイル\ntype: plan\n---\n\n本文\n' >"$del_repo/plans/keep.md"
printf -- '---\ntitle: 消えるファイル\ntype: plan\n---\n\n本文\n' >"$del_repo/plans/gone.md"
printf -- '---\ntitle: 無関係\ntype: spec\n---\n\n本文\n' >"$del_repo/docs/other.md"
git -C "$del_repo" add -A >/dev/null 2>&1

# 実プロセスとして起動する。cd はサブシェルへ閉じ込め、テスト側のカレントを動かさない。
run_ef() { ( cd "$del_repo" && bash "$ef_script" "$@" 2>"$fixture_dir/ef-stderr.txt" ); }
run_ef_status() { if run_ef "$@" >/dev/null; then echo 0; else echo 1; fi; }
ef_stderr() { cat "$fixture_dir/ef-stderr.txt"; }

assert_eq "削除前: 全ファイルを走査して成功する" "0" "$(run_ef_status .)"
assert_eq "削除前: サマリのskippedは0" "files=3 built=3 reused=0 failed=0 skipped=0" \
  "$(ef_stderr | tail -1)"
# 残るファイルの行だけを控えておき、削除後も内容が一致する（行が作り直されない）ことを確かめる
keep_line_before="$(grep -F -- '"concept_id":"plans/keep"' "$del_repo/plans/index.jsonl")"

# 追跡されたまま削除する（ステージしない）。index.jsonl も一緒に消えるのは cleanup-task.sh と同じ。
rm -f "$del_repo/plans/gone.md" "$del_repo/plans/index.jsonl"

assert_eq "削除済みが混じっても成功する" "0" "$(run_ef_status .)"
assert_eq "削除済みをスキップし、残り2件を走査する" "files=2 built=1 reused=1 failed=0 skipped=1" \
  "$(ef_stderr | tail -1)"
assert_eq "スキップした件数を警告として出す" "0" \
  "$(status_of_contains "$(ef_stderr)" 'skipped 1 deleted file(s)')"
assert_eq "削除済みファイルはインデックスから消える" "$keep_line_before" \
  "$(cat "$del_repo/plans/index.jsonl")"
assert_eq "無関係なディレクトリのindex.jsonlも再生成される" "1" \
  "$(wc -l <"$del_repo/docs/index.jsonl")"

# 対象ディレクトリのmarkdownが全滅した場合も、stat で落ちずに正常終了する
rm -f "$del_repo/plans/keep.md" "$del_repo/plans/index.jsonl"
assert_eq "対象が全滅しても成功する" "0" "$(run_ef_status plans)"
assert_eq "対象が全滅したら走査対象なしとして終わる" "0" \
  "$(status_of_contains "$(ef_stderr)" 'no markdown files found')"

# --- 結果 --------------------------------------------------------------------

echo "passed=$passed failures=$failures"
if [[ $failures -gt 0 ]]; then
  exit 1
fi
