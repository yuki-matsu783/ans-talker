#!/usr/bin/env bash
# .claude/scripts/src/cleanup-task.sh の単体テスト（issue #28）。
# 2部構成。
#   1. 外部コマンド呼び出しを伴わない純粋関数（is_safe_relative_dir / is_keep_path /
#      is_handoff_template）と、埋め込みテンプレート HANDOFF_TEMPLATE の内容。
#   2. main の結合テスト（issue #117）。**実リポジトリは汚さない**方針は変えず、`mktemp -d` +
#      `git init` の使い捨てリポジトリの中で実プロセスとして起動する
#      （test_search_frontmatter.sh と同じ切り分け）。削除は実際に走るが対象はフィクスチャのみ。
# 規約: passed=N failures=N を標準出力へ出し、失敗があれば終了コード1
#       （.claude/rules/shell-script-style.md「テスト」）。
# 実行: bash .claude/scripts/test/test_cleanup_task.sh
set -euo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" == "${BASH_SOURCE[0]}" ]] && script_dir="."
repo_root="$(cd "$script_dir/../../.." && pwd)"

# shellcheck source=../../../.claude/scripts/src/cleanup-task.sh
source "$repo_root/.claude/scripts/src/cleanup-task.sh"

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

# 終了コードは `if` の条件式で受ける（`"$(func; echo $?)"` は set -e 配下で空文字列になりうる。
# .claude/rules/shell-script-style.md「テスト」）。
status_of() {
  if "$@"; then
    printf '0'
  else
    printf '1'
  fi
}

# --- is_safe_relative_dir -------------------------------------------------

assert_eq "is_safe_relative_dir: 通常の相対パスは安全" "0" "$(status_of is_safe_relative_dir "plans")"
assert_eq "is_safe_relative_dir: ネストした相対パスも安全" "0" "$(status_of is_safe_relative_dir "docs/plans")"
assert_eq "is_safe_relative_dir: 空文字列は不正" "1" "$(status_of is_safe_relative_dir "")"
assert_eq "is_safe_relative_dir: カレント指定は不正" "1" "$(status_of is_safe_relative_dir ".")"
assert_eq "is_safe_relative_dir: 絶対パスは不正" "1" "$(status_of is_safe_relative_dir "/etc")"
assert_eq "is_safe_relative_dir: Windowsの絶対パスは不正" "1" "$(status_of is_safe_relative_dir "C:/tmp")"
assert_eq "is_safe_relative_dir: バックスラッシュ区切りは不正" "1" "$(status_of is_safe_relative_dir 'plans\sub')"
assert_eq "is_safe_relative_dir: 親ディレクトリそのものは不正" "1" "$(status_of is_safe_relative_dir "..")"
assert_eq "is_safe_relative_dir: 先頭の親参照は不正" "1" "$(status_of is_safe_relative_dir "../outside")"
assert_eq "is_safe_relative_dir: 途中の親参照は不正" "1" "$(status_of is_safe_relative_dir "plans/../../etc")"
assert_eq "is_safe_relative_dir: 末尾の親参照は不正" "1" "$(status_of is_safe_relative_dir "plans/..")"
# 「..」で始まるだけの通常のディレクトリ名を巻き込まないこと
assert_eq "is_safe_relative_dir: ..foo は親参照ではない" "0" "$(status_of is_safe_relative_dir "..foo")"

# --- is_keep_path ---------------------------------------------------------

assert_eq "is_keep_path: worklog/TEMPLATE.md は残す" "0" "$(status_of is_keep_path "worklog/TEMPLATE.md")"
assert_eq "is_keep_path: タスク固有のworklogは残さない" "1" "$(status_of is_keep_path "worklog/2026-08-19_計画_個別_push1.md")"
assert_eq "is_keep_path: 別ディレクトリの同名ファイルは残さない" "1" "$(status_of is_keep_path "plans/TEMPLATE.md")"
assert_eq "is_keep_path: 部分一致では残さない" "1" "$(status_of is_keep_path "worklog/TEMPLATE.md.bak")"
# REVIEW-POINTS.md は plans/ reports/ 配下にあっても残す（issue #77。ファイル名で判定する）
assert_eq "is_keep_path: plans/REVIEW-POINTS.md は残す" "0" "$(status_of is_keep_path "plans/REVIEW-POINTS.md")"
assert_eq "is_keep_path: reports/REVIEW-POINTS.md は残す" "0" "$(status_of is_keep_path "reports/REVIEW-POINTS.md")"
assert_eq "is_keep_path: サブディレクトリのREVIEW-POINTS.mdも残す" "0" "$(status_of is_keep_path "reports/sub/REVIEW-POINTS.md")"
assert_eq "is_keep_path: 名前が似ているだけのファイルは残さない" "1" "$(status_of is_keep_path "plans/REVIEW-POINTS.md.bak")"
assert_eq "is_keep_path: 接尾辞が一致するだけのファイルは残さない" "1" "$(status_of is_keep_path "plans/OLD-REVIEW-POINTS.md")"

# --- is_handoff_template --------------------------------------------------

assert_eq "is_handoff_template: テンプレートそのものは真" "0" "$(status_of is_handoff_template "$HANDOFF_TEMPLATE")"
# `$(<file)` は末尾改行をすべて落とすため、その差だけで「リセット必要」と誤判定しないこと
assert_eq "is_handoff_template: 末尾改行が無くても真" "0" "$(status_of is_handoff_template "${HANDOFF_TEMPLATE%$'\n'}")"
assert_eq "is_handoff_template: 末尾改行が増えても真" "0" "$(status_of is_handoff_template "${HANDOFF_TEMPLATE}"$'\n\n')"
assert_eq "is_handoff_template: 作業中の内容は偽" "1" "$(status_of is_handoff_template "${HANDOFF_TEMPLATE}進捗あり")"
assert_eq "is_handoff_template: 空文字列は偽" "1" "$(status_of is_handoff_template "")"

# --- HANDOFF_TEMPLATE の内容 ----------------------------------------------
# 見出し構成は .claude/rules/docs-workflow.md「ドキュメント運用」表の HANDOFF.md 行に対応する。
# 日本語を含む文字列は ${var:0:N} で切り出すとバイト単位で壊れるため、部分一致で確認する
# （.claude/rules/shell-script-style.md「テスト」）。
for heading in \
  "## フロー進捗状況" \
  "## やったこと" \
  "## 次にやること" \
  "## 判断を迷った内容" \
  "## 未解決の内容" \
  "## 守るべき条件・触ってはいけない範囲"
do
  if [[ "$HANDOFF_TEMPLATE" == *"$heading"$'\n'* ]]; then
    passed=$((passed + 1))
  else
    failures=$((failures + 1))
    echo "FAIL: HANDOFF_TEMPLATE に見出し「${heading}」が無い"
  fi
done

assert_eq "HANDOFF_TEMPLATE: frontmatterのtypeはhandoff" "0" \
  "$(status_of test "${HANDOFF_TEMPLATE#*$'type: handoff\n'}" != "$HANDOFF_TEMPLATE")"
assert_eq "HANDOFF_TEMPLATE: 先頭はfrontmatterの区切り" "---" "$(printf '%s' "$HANDOFF_TEMPLATE" | head -1)"
# 末尾改行はちょうど1つ（リセット後のHANDOFF.mdが余分な空行を持たないこと）。
# 日本語を含む文字列は ${var:0:N} / ${var: -N} で切り出すとバイト単位で壊れるため、
# 改行だけをパターンで見る（.claude/rules/shell-script-style.md「テスト」）。
assert_eq "HANDOFF_TEMPLATE: 末尾に改行がある" "0" \
  "$(status_of test "${HANDOFF_TEMPLATE: -1}" = $'\n')"
assert_eq "HANDOFF_TEMPLATE: 末尾の改行は2つ以上にならない" "1" \
  "$(status_of test "${HANDOFF_TEMPLATE: -2}" = $'\n\n')"
# 進捗表はリセット時点では持たない（次タスク着手時にissue-mr-flowが書き起こす）
assert_eq "HANDOFF_TEMPLATE: 進捗表の記号を含まない" "1" \
  "$(status_of test "${HANDOFF_TEMPLATE#*'[x]'}" != "$HANDOFF_TEMPLATE")"

# --- main の結合テスト: 削除済みファイルが混じった状態（issue #117）-----------
# 本スクリプトは**コミットしない**（DDR 0048）ため、手順3（frontmatterインデックスの再生成）は
# 常に「追跡ファイルが削除済みだが未ステージ」の状態で走る。`git ls-files --cached` はその
# パスも返すため、実体の無いファイルを stat しようとして**通常の実行では必ず失敗していた**
# （issue #97 の flow-id 5-1 で実際に発生。`frontmatterIndex.exitCode: 1`）。
# 純粋関数では再現できないので、使い捨てのgitリポジトリを作り実プロセスとして起動する
# （実リポジトリは汚さない。test_search_frontmatter.sh と同じ切り分け）。
# ステージするだけで `--cached` の列挙対象になるので、コミットは行わない。

ct_script="$repo_root/.claude/scripts/src/cleanup-task.sh"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
ct_repo="$fixture_dir/repo"

# 毎回まっさらなフィクスチャを作り直す（--dry-run / --skip-index / 実行 を独立に確かめるため）
setup_ct_repo() {
  rm -rf "$ct_repo"
  mkdir -p "$ct_repo/plans" "$ct_repo/worklog" "$ct_repo/reports" "$ct_repo/.claude/scripts/src"
  git -C "$ct_repo" init -q 2>/dev/null || git -C "$ct_repo" init >/dev/null 2>&1
  cp "$repo_root/.claude/scripts/src/extract-frontmatter.sh" "$ct_repo/.claude/scripts/src/"
  printf '**/index.jsonl\n' >"$ct_repo/.gitignore"
  # 日本語・全角【】を含むファイル名を混ぜる（実運用の個別計画と同じ形）
  printf -- '---\ntitle: 個別計画\ntype: plan\n---\n\n本文\n' >"$ct_repo/plans/【調査】テスト.md"
  printf -- '---\ntitle: 観点\ntype: review-points\n---\n\n本文\n' >"$ct_repo/plans/REVIEW-POINTS.md"
  printf -- '---\ntitle: 雛形\ntype: log\n---\n\n本文\n' >"$ct_repo/worklog/TEMPLATE.md"
  printf -- '---\ntitle: ログ\ntype: log\n---\n\n本文\n' >"$ct_repo/worklog/2026-08-20_計画_個別_push1.md"
  printf -- '---\ntitle: 結果\ntype: report\n---\n\n本文\n' >"$ct_repo/reports/2026-08-20_計画_結果.md"
  printf -- '---\ntitle: HANDOFF\ntype: handoff\n---\n\n# HANDOFF\n\n作業中の内容\n' >"$ct_repo/HANDOFF.md"
  git -C "$ct_repo" add -A >/dev/null 2>&1
  ( cd "$ct_repo" && bash .claude/scripts/src/extract-frontmatter.sh . >/dev/null 2>&1 )
}

# 実プロセスとして起動する。cd はサブシェルへ閉じ込め、テスト側のカレントを動かさない。
run_ct() { ( cd "$ct_repo" && bash "$ct_script" "$@" 2>"$fixture_dir/ct-stderr.txt" ); }
run_ct_status() { if run_ct "$@" >/dev/null; then printf '0'; else printf '1'; fi; }

# 通常実行（ここが issue #117 の本題）
setup_ct_repo
assert_eq "main: 削除済みが混じっても終了コード0" "0" "$(run_ct_status)"

setup_ct_repo
ct_json="$(run_ct)"
assert_eq "main: frontmatterIndex.exitCode が0になる" "0" \
  "$(printf '%s' "$ct_json" | jq -r '.frontmatterIndex.exitCode')"
assert_eq "main: frontmatterIndex.ran が真" "true" \
  "$(printf '%s' "$ct_json" | jq -r '.frontmatterIndex.ran')"
assert_eq "main: 再生成の警告を出さない" "1" \
  "$(status_of grep -qF -- 'warning: index.jsonl' "$fixture_dir/ct-stderr.txt")"
# 残すファイルだけがインデックスに残る（削除したファイルの行が消えていること）
assert_eq "main: plans/index.jsonl はREVIEW-POINTS.mdの1件だけになる" "plans/REVIEW-POINTS" \
  "$(jq -r '.concept_id' "$ct_repo/plans/index.jsonl")"
assert_eq "main: worklog/index.jsonl はTEMPLATE.mdの1件だけになる" "worklog/TEMPLATE" \
  "$(jq -r '.concept_id' "$ct_repo/worklog/index.jsonl")"
# 残すファイルが無い reports/ はディレクトリごと消える（index.jsonl も一緒に消える）
assert_eq "main: reports/ はディレクトリごと消える" "1" "$(status_of test -e "$ct_repo/reports")"
assert_eq "main: removedDirs に reports が入る" "reports" \
  "$(printf '%s' "$ct_json" | jq -r '.removedDirs[]')"
assert_eq "main: HANDOFF.md をリセットする" "0" \
  "$(status_of is_handoff_template "$(<"$ct_repo/HANDOFF.md")")"

# --dry-run: 何も変更せず、再生成も走らせない
setup_ct_repo
ct_json="$(run_ct --dry-run)"
assert_eq "--dry-run: frontmatterIndex.ran は偽のまま" "false" \
  "$(printf '%s' "$ct_json" | jq -r '.frontmatterIndex.ran')"
assert_eq "--dry-run: frontmatterIndex.exitCode は0" "0" \
  "$(printf '%s' "$ct_json" | jq -r '.frontmatterIndex.exitCode')"
assert_eq "--dry-run: ファイルを削除しない" "0" "$(status_of test -e "$ct_repo/plans/【調査】テスト.md")"
assert_eq "--dry-run: HANDOFF.md を書き換えない" "1" \
  "$(status_of is_handoff_template "$(<"$ct_repo/HANDOFF.md")")"

# --skip-index: 削除は行うが再生成はしない（index.jsonl は消えたまま）
setup_ct_repo
ct_json="$(run_ct --skip-index)"
assert_eq "--skip-index: frontmatterIndex.ran は偽" "false" \
  "$(printf '%s' "$ct_json" | jq -r '.frontmatterIndex.ran')"
assert_eq "--skip-index: ファイルは削除される" "1" "$(status_of test -e "$ct_repo/plans/【調査】テスト.md")"
assert_eq "--skip-index: index.jsonl は再生成されない" "1" \
  "$(status_of test -e "$ct_repo/plans/index.jsonl")"

echo "passed=${passed} failures=${failures}"
[[ "$failures" -eq 0 ]]
