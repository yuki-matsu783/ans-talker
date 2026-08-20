#!/usr/bin/env bash
#
# flow-id 5-1（次タスクのための片付け）を自動化する（issue #28）。
# `.claude/skills/issue-mr-flow/SKILL.md` の flow-id 5-1 が手順として持っていた次の4操作を、
# 手作業（消し忘れ・消しすぎ）を排して1コマンドへまとめる。
#
#   1. `plans/` `worklog/` `reports/` を、下記「残すパス」以外すべて削除する
#      （`worklog/TEMPLATE.md` と、どの階層にあっても `REVIEW-POINTS.md` は残す）
#      （ディレクトリは .mrworkflow.json の plansDir / worklogDir / reportsDir から読む）
#   2. 上記配下の index.jsonl（frontmatterの機械可読インデックス。Git管理外の生成物）も一緒に消える
#   3. `.claude/scripts/src/extract-frontmatter.sh .` で残りの index.jsonl 群を再生成する
#   4. `HANDOFF.md` を次タスク向けのテンプレート（各見出しのみ）へリセットする
#
# **コミットはしない。** このリポジトリのコミットは `commit` スキル経由に限られる
# （`.claude/rules/git-workflow.md`「コミット運用」）。削除・リセット後の変更を
# `commit` スキルへ渡すのは呼び出し側（flow-id 5-4）の責務。
#
# 使い方:
#   cleanup-task.sh [--dry-run] [--skip-index] [-h|--help]
#
#   --dry-run     ... 何も変更せず、削除対象・リセット要否のみを出力する
#   --skip-index  ... frontmatterインデックスの再生成をスキップする
#
# 出力: 実行内容のJSONをstdoutへ1つ出力する（check-base-conflicts.sh・Provider.sh と同じ規約）。
#   {
#     "dryRun": false, "repoRoot": "...", "targetDirs": ["plans","worklog","reports"],
#     "keptPaths": ["worklog/TEMPLATE.md"], "keptBasenames": ["REVIEW-POINTS.md"],
#     "removedDirs": ["plans","reports"],
#     "deletedFiles": ["plans/....md"],
#     "handoff": {"path":"HANDOFF.md","reset":true,"alreadyTemplate":false,"created":false},
#     "frontmatterIndex": {"ran":true,"exitCode":0}
#   }
#   --dry-run のときは removedDirs / deletedFiles / handoff.reset が「そうなる予定」を表す。
#   人間向けの進捗ログはstderrへ出す（stdoutをJSONだけに保ち、`jq` でそのまま読めるようにするため）。
#
# 終了コード: 0=成功 / 1=失敗（不正な引数・設定、HANDOFF.mdの書き込み失敗など）。
#   frontmatterインデックスの再生成に失敗した場合は**警告に留め0で終える**（index.jsonl はGit管理外の
#   生成物で、SessionStart hookが毎セッション再生成するため。失敗は JSON の frontmatterIndex.exitCode と
#   stderrの警告で分かる）。
#
# 仕様: .claude/docs/spec/cleanup-task.md
# 規約: .claude/rules/shell-script-style.md（set -euo pipefail / jq前提 / ループ内で外部コマンドを呼ばない）
set -euo pipefail

# 削除対象ディレクトリ配下で**消してはいけない**リポジトリ相対パス。
# worklog/TEMPLATE.md は worklog を書き起こすときの雛形で、タスクごとの成果物ではない
# （`.claude/rules/directory-structure.md`）。ここに載るパスが1つでも残るディレクトリは、
# ディレクトリ自体を削除しない。
readonly -a KEEP_PATHS=(
  "worklog/TEMPLATE.md"
)

# 同じく、**どの階層にあっても**消してはいけないファイル名。
# `plans/REVIEW-POINTS.md` `reports/REVIEW-POINTS.md` は、これらのディレクトリ配下にあるが
# タスク単位の成果物ではなく、そのディレクトリに対する永続のレビュー観点である（issue #77。
# `.claude/rules/docs-workflow.md`「ドキュメント運用」表・`.claude/docs/spec/adversarial-review.md`）。
readonly -a KEEP_BASENAMES=(
  "REVIEW-POINTS.md"
)

# HANDOFF.mdのリセット後の内容（見出しだけを残した次タスク向けテンプレート）。
# 見出し構成は `.claude/rules/docs-workflow.md`「ドキュメント運用」表の HANDOFF.md 行に対応する。
# 変更する場合は同表と `.claude/docs/spec/cleanup-task.md` も合わせて更新すること。
# `IFS=` を付けないと read が先頭・末尾の改行を落とす（末尾改行の有無が変わる）。
IFS= read -r -d '' HANDOFF_TEMPLATE <<'EOF' || true
---
title: HANDOFF
type: handoff
description: セッション間・作業者間の引継ぎメモ（現在地・次回やること等）
tags: [handoff, workflow]
keywords: [フロー進捗, worklog, 引き継ぎ, plan, レビュー]
---

# HANDOFF

<!--
AI⇔AI/AI⇔人間の状況引継ぎメモ。常に「このブランチの現状」を表現する
-->

## フロー進捗状況

（次タスク着手時に記入する）

## やったこと

（無し）

## 次にやること

（無し）

## 判断を迷った内容

（無し）

## 未解決の内容

（無し）

## 守るべき条件・触ってはいけない範囲

（無し）
EOF
readonly HANDOFF_TEMPLATE

# 削除対象として収集したリポジトリ相対パス（collect_files_under が積む）。
CLEANUP_FILES=()
# ディレクトリごと削除できるもの（同上）。
CLEANUP_REMOVED_DIRS=()

# .mrworkflow.json から読んだディレクトリ名が、リポジトリルート配下を指す安全な相対パスかを
# 判定する。設定ファイル由来の値をそのまま `rm -rf` へ渡さないためのガード。
# 外部コマンドを呼ばない純粋関数。
is_safe_relative_dir() {
  local path="$1"
  [ -n "$path" ] || return 1
  [ "$path" != "." ] || return 1
  [[ "$path" != /* ]] || return 1
  [[ "$path" != *:* ]] || return 1          # C:/... のようなWindowsの絶対パス
  [[ "$path" != *'\'* ]] || return 1        # 区切り文字を混ぜた表記は受け付けない
  [[ "$path" != ".." && "$path" != "../"* && "$path" != *"/../"* && "$path" != *"/.." ]] || return 1
  return 0
}

# リポジトリ相対パスが KEEP_PATHS（完全一致）または KEEP_BASENAMES（ファイル名一致）に
# 該当するか（＝削除してはいけないか）を判定する。
# 外部コマンドを呼ばない純粋関数。
is_keep_path() {
  local path="$1" keep
  for keep in "${KEEP_PATHS[@]}"; do
    [[ "$path" == "$keep" ]] && return 0
  done
  local base="${path##*/}"
  for keep in "${KEEP_BASENAMES[@]}"; do
    [[ "$base" == "$keep" ]] && return 0
  done
  return 1
}

# HANDOFF.mdが既にテンプレートと同じ内容かを判定する（同じならリセットしない）。
# 末尾の改行の個数の差だけは同一とみなす（`$(<file)` が末尾改行をすべて落とすため、
# 呼び出し側で補わなくても判定がぶれないようにする）。外部コマンドを呼ばない純粋関数。
is_handoff_template() {
  local actual="$1" expected="$HANDOFF_TEMPLATE"
  while [[ "$actual" == *$'\n' ]]; do actual="${actual%$'\n'}"; done
  while [[ "$expected" == *$'\n' ]]; do expected="${expected%$'\n'}"; done
  [[ "$actual" == "$expected" ]]
}

# 与えられたディレクトリ配下のファイルを走査し、削除対象を CLEANUP_FILES へ、
# 「ディレクトリごと消してよい」場合はディレクトリ名を CLEANUP_REMOVED_DIRS へ積む。
# find は1ディレクトリにつき1回だけ起動する（`.claude/rules/shell-script-style.md`
# 「外部プロセス起動のコスト」）。
collect_files_under() {
  local dir="$1"
  local path kept=0
  [ -d "$dir" ] || return 0

  # -print0 で受けるのは、NULを保持したいからではなく非ASCIIパスがクォートされるのを避けるため
  # （日本語を含む計画ファイル名がそのまま渡るようにする）。
  while IFS= read -r -d '' path; do
    if is_keep_path "$path"; then
      kept=$((kept + 1))
      continue
    fi
    CLEANUP_FILES+=("$path")
  done < <(find "$dir" -type f -print0 | LC_ALL=C sort -z)

  if [ "$kept" -eq 0 ]; then
    CLEANUP_REMOVED_DIRS+=("$dir")
  fi
}

log() {
  printf '%s\n' "$*" >&2
}

usage() {
  sed -n '2,42p' "${BASH_SOURCE[0]}" >&2
}

main() {
  local dry_run=0 skip_index=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      --skip-index) skip_index=1; shift ;;
      -h|--help) usage; return 0 ;;
      *)
        echo "error: 不明な引数です: $1" >&2
        usage
        return 1
        ;;
    esac
  done

  local repo_root
  if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "error: gitリポジトリの中で実行してください（git rev-parse --show-toplevel に失敗しました）" >&2
    return 1
  fi
  cd "$repo_root"

  # 設定の読み出しはjq 1回にまとめる。.mrworkflow.json が無ければ既定値で動く。
  local config dirs_tsv
  if [ -f ".mrworkflow.json" ]; then
    config="$(<.mrworkflow.json)"
  else
    config='{}'
  fi
  dirs_tsv="$(printf '%s' "$config" | jq -r '[(.plansDir // "plans"), (.worklogDir // "worklog"), (.reportsDir // "reports")] | @tsv')"
  dirs_tsv="${dirs_tsv//$'\r'/}"

  local -a target_dirs=()
  IFS=$'\t' read -r -a target_dirs <<<"$dirs_tsv"

  local dir
  for dir in "${target_dirs[@]}"; do
    if ! is_safe_relative_dir "$dir"; then
      echo "error: .mrworkflow.json のディレクトリ設定が不正です（リポジトリルート配下の相対パスにしてください）: '${dir}'" >&2
      return 1
    fi
  done

  CLEANUP_FILES=()
  CLEANUP_REMOVED_DIRS=()
  for dir in "${target_dirs[@]}"; do
    collect_files_under "$dir"
  done

  local f
  if [ "${#CLEANUP_FILES[@]}" -eq 0 ]; then
    log "削除対象のファイルはありません（${target_dirs[*]}）"
  elif [ "$dry_run" -eq 1 ]; then
    for f in "${CLEANUP_FILES[@]}"; do log "削除予定: $f"; done
  else
    for f in "${CLEANUP_FILES[@]}"; do log "削除: $f"; done
  fi

  if [ "$dry_run" -eq 0 ]; then
    # ディレクトリごと消せるものはまとめて消し、残す物があるディレクトリは個別に消す。
    if [ "${#CLEANUP_REMOVED_DIRS[@]}" -gt 0 ]; then
      for dir in "${CLEANUP_REMOVED_DIRS[@]}"; do
        rm -rf -- "$dir"
        log "ディレクトリ削除: ${dir}/"
      done
    fi
    if [ "${#CLEANUP_FILES[@]}" -gt 0 ]; then
      for f in "${CLEANUP_FILES[@]}"; do
        [ -e "$f" ] || continue
        rm -f -- "$f"
      done
    fi
    # 残ったディレクトリの中で空になったサブディレクトリを畳む（削除対象外のファイルが
    # 残っているディレクトリ自身は消えない）。
    for dir in "${target_dirs[@]}"; do
      [ -d "$dir" ] || continue
      find "$dir" -mindepth 1 -depth -type d -empty -delete
    done
  elif [ "${#CLEANUP_REMOVED_DIRS[@]}" -gt 0 ]; then
    for dir in "${CLEANUP_REMOVED_DIRS[@]}"; do log "ディレクトリ削除予定: ${dir}/"; done
  fi

  # --- HANDOFF.md のリセット ------------------------------------------------
  local handoff="HANDOFF.md" handoff_reset=0 handoff_already=0 handoff_created=0
  if [ -f "$handoff" ]; then
    if is_handoff_template "$(<"$handoff")"; then
      handoff_already=1
      log "HANDOFF.md は既にテンプレートと同じ内容です（リセット不要）"
    else
      handoff_reset=1
    fi
  else
    handoff_created=1
    handoff_reset=1
    log "warning: HANDOFF.md が存在しないため、テンプレートから新規作成します"
  fi

  if [ "$handoff_reset" -eq 1 ]; then
    if [ "$dry_run" -eq 1 ]; then
      log "リセット予定: HANDOFF.md"
    elif printf '%s' "$HANDOFF_TEMPLATE" >"$handoff"; then
      log "HANDOFF.md をテンプレートへリセットしました"
    else
      echo "error: HANDOFF.md の書き込みに失敗しました: ${repo_root}/${handoff}" >&2
      return 1
    fi
  fi

  # --- frontmatterインデックスの再生成 --------------------------------------
  local index_ran=0 index_status=0
  if [ "$skip_index" -eq 1 ]; then
    log "frontmatterインデックスの再生成はスキップしました（--skip-index）"
  elif [ "$dry_run" -eq 1 ]; then
    log "再生成予定: index.jsonl（.claude/scripts/src/extract-frontmatter.sh .）"
  elif [ ! -f ".claude/scripts/src/extract-frontmatter.sh" ]; then
    log "warning: .claude/scripts/src/extract-frontmatter.sh が見つからないため、index.jsonl の再生成をスキップしました"
  else
    index_ran=1
    if bash .claude/scripts/src/extract-frontmatter.sh . >/dev/null; then
      log "index.jsonl を再生成しました"
    else
      index_status=$?
      # index.jsonl はGit管理外の生成物で、SessionStart hookが毎セッション再生成する。
      # ここで異常終了させると、成功済みの削除・リセットまで失敗に見えるため警告に留める。
      log "warning: index.jsonl の再生成に失敗しました（終了コード ${index_status}）。SessionStart hookでの再生成に委ねます"
    fi
  fi

  # --- 実行内容のJSON -------------------------------------------------------
  # 可変長の一覧は --args の位置引数でまとめて渡し、フィルタの直後に `--` を置く
  # （ハイフンで始まる値をjqがオプションと誤認するのを防ぐ。`.claude/rules/shell-script-style.md`）。
  local -a positional=("${target_dirs[@]}" "${KEEP_PATHS[@]}" "${KEEP_BASENAMES[@]}")
  if [ "${#CLEANUP_REMOVED_DIRS[@]}" -gt 0 ]; then positional+=("${CLEANUP_REMOVED_DIRS[@]}"); fi
  if [ "${#CLEANUP_FILES[@]}" -gt 0 ]; then positional+=("${CLEANUP_FILES[@]}"); fi

  local counts
  printf -v counts '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$dry_run" "$handoff_reset" "$handoff_already" "$handoff_created" \
    "$index_ran" "$index_status" "${#target_dirs[@]}" "${#KEEP_PATHS[@]}" \
    "${#KEEP_BASENAMES[@]}" "${#CLEANUP_REMOVED_DIRS[@]}"

  jq -n --arg repoRoot "$repo_root" --arg counts "$counts" --args '
    ($counts | split("\t")) as $c
    | ($c[6] | tonumber) as $nDirs
    | ($c[7] | tonumber) as $nKeep
    | ($c[8] | tonumber) as $nKeepBase
    | ($c[9] | tonumber) as $nRemoved
    | ($nDirs + $nKeep) as $o1
    | ($o1 + $nKeepBase) as $o2
    | ($o2 + $nRemoved) as $o3
    | {
        dryRun: ($c[0] == "1"),
        repoRoot: $repoRoot,
        targetDirs: $ARGS.positional[0:$nDirs],
        keptPaths: $ARGS.positional[$nDirs:$o1],
        keptBasenames: $ARGS.positional[$o1:$o2],
        removedDirs: $ARGS.positional[$o2:$o3],
        deletedFiles: $ARGS.positional[$o3:],
        handoff: {
          path: "HANDOFF.md",
          reset: ($c[1] == "1"),
          alreadyTemplate: ($c[2] == "1"),
          created: ($c[3] == "1")
        },
        frontmatterIndex: { ran: ($c[4] == "1"), exitCode: ($c[5] | tonumber) }
      }
  ' -- "${positional[@]}"
}

# 単体テスト（.claude/scripts/test/test_cleanup_task.sh）からsourceして純粋関数だけを再利用できるよう、
# 直接実行された場合のみ main を呼ぶ（update-handoff-progress.sh と同じガードパターン）。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
