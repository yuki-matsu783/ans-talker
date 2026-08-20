#!/usr/bin/env bash
#
# 敵対的レビューの実施回数カウンタ（issue #77）。
#
# 非対話モードでは「レビュー → 修正 → 再レビュー」が人間の介在なく回りうるため、実施回数を
# 機械的に記録し、各フェーズ最大3回で打ち切る。AIエージェントの自制ではなくスクリプトで
# 強制することが目的のため、上限を環境変数等で緩める口は用意しない。
#
# 使い方:
#   bash .claude/scripts/src/adversarial-review-count.sh get <phase>
#   bash .claude/scripts/src/adversarial-review-count.sh increment <phase>
#   bash .claude/scripts/src/adversarial-review-count.sh reset
#
# <phase> は 2 / 3 / 4（issue-mr-flow のフェーズ番号）。
# `increment` は上限に達している場合、加算せず終了コード1と理由メッセージ（stderr）を返す。
#
# 状態は .claude/state/adversarial-review/<ブランチ名>.json に {"2":N,"3":N,"4":N} で持つ。
# .claude/state/ は .gitignore 対象のローカル作業状態であり、ブランチ単位で持つため、
# ブランチを削除すれば自然に消える（usage/ とは責務が異なるため混ぜない）。

set -euo pipefail

ADVERSARIAL_REVIEW_MAX_RUNS=3

# 状態ファイルのパスを組み立てる（純粋関数）。ブランチ名に含まれる `/` はディレクトリ区切りと
# 解釈されてしまうため `__` へ置き換える（例: `claude/issue-77` → `claude__issue-77.json`）。
adversarial_review_state_path() {
  local branch="$1"
  printf '.claude/state/adversarial-review/%s.json' "${branch//\//__}"
}

# 状態ファイルの内容を、必ず有効なJSONオブジェクトへ正規化する（純粋関数）。
# 空・壊れたJSONは「状態なし」（{}）へフォールバックする。外部状態ファイルが壊れたまま
# 回復不能になるのを避けるため（.claude/rules/shell-script-style.md「JSON操作」）。
# 空文字列の判定を `jq -e .` より先に行うのは、空入力に対して `jq -e .` が終了コード0を
# 返すことがあるため。
adversarial_review_normalize_state() {
  local raw="${1:-}"
  if [ -z "$raw" ] || ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '{}'
    return 0
  fi
  printf '%s' "$raw"
}

# 指定フェーズで、まだ実施できるか（上限未満か）を判定する（純粋関数）。
# 実施可能なら終了コード0、上限に達していれば1。
adversarial_review_can_run() {
  local state phase count
  state="$(adversarial_review_normalize_state "${1:-}")"
  phase="$2"
  count="$(printf '%s' "$state" | jq -r --arg p "$phase" '(.[$p] // 0) | tostring')"
  [ "$count" -lt "$ADVERSARIAL_REVIEW_MAX_RUNS" ]
}

# 指定フェーズの実施回数を取り出す（純粋関数）。
adversarial_review_get_count() {
  local state phase
  state="$(adversarial_review_normalize_state "${1:-}")"
  phase="$2"
  printf '%s' "$state" | jq -r --arg p "$phase" '(.[$p] // 0) | tostring'
}

# 指定フェーズの実施回数を1つ増やした状態JSONを返す（純粋関数）。
adversarial_review_increment_state() {
  local state phase
  state="$(adversarial_review_normalize_state "${1:-}")"
  phase="$2"
  printf '%s' "$state" | jq -c --arg p "$phase" '.[$p] = ((.[$p] // 0) + 1)'
}

validate_phase() {
  case "${1:-}" in
    2 | 3 | 4) return 0 ;;
    *)
      printf 'phase は 2 / 3 / 4 のいずれかを指定してください（指定値: %s）\n' "${1:-未指定}" >&2
      return 1
      ;;
  esac
}

read_state_file() {
  local path="$1"
  [ -f "$path" ] || return 0
  cat "$path"
}

main() {
  local subcommand="${1:-}" phase branch path state new_state count

  branch="$(git rev-parse --abbrev-ref HEAD)"
  path="$(adversarial_review_state_path "$branch")"

  case "$subcommand" in
    get)
      phase="${2:-}"
      validate_phase "$phase"
      state="$(read_state_file "$path")"
      adversarial_review_get_count "$state" "$phase"
      ;;
    increment)
      phase="${2:-}"
      validate_phase "$phase"
      state="$(read_state_file "$path")"
      count="$(adversarial_review_get_count "$state" "$phase")"
      if ! adversarial_review_can_run "$state" "$phase"; then
        {
          printf '敵対的レビューはフェーズ%s で既に%s回実施済みのため、上限（%s回）に達しています。\n' \
            "$phase" "$count" "$ADVERSARIAL_REVIEW_MAX_RUNS"
          printf 'レビューを実行せずに打ち切り、その旨を報告してください（HANDOFF.mdにも残すこと）。\n'
          printf '意図的にやり直す場合は `reset` サブコマンドを人間の判断で実行してください。\n'
        } >&2
        return 1
      fi
      new_state="$(adversarial_review_increment_state "$state" "$phase")"
      mkdir -p "${path%/*}"
      printf '%s\n' "$new_state" | tr -d '\r' > "$path"
      adversarial_review_get_count "$new_state" "$phase"
      ;;
    reset)
      rm -f "$path"
      printf '%s の実施回数をリセットしました\n' "$branch"
      ;;
    *)
      printf '使い方: %s {get|increment} <phase> | %s reset\n' "$0" "$0" >&2
      return 1
      ;;
  esac
}

# stdinを読む処理は無いが、テストから関数だけを読み込めるようにガードする
# （.claude/rules/shell-script-style.md「テスト」）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
