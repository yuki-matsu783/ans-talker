#!/usr/bin/env bash
#
# answer-talker スキルの「正解ソース」を用意し、後始末する（issue #1）。
#
# 使い方:
#   answer-talker-reference.sh resolve --reference <URL|パス> [--ref <ブランチ/タグ>]
#     → {"kind":"url"|"local","root":"<絶対パス>","cleanup":true|false,"tmpdir":"…"|null}
#   answer-talker-reference.sh cleanup --tmpdir <パス>
#     → {"removed":true|false,"reason":"…"}
#
# 設計上の要点（reports/…answer-talker設計.md の D3）:
#   - **ローカルパスは clone しない。** `git clone --depth 1` は局所cloneでは無視され
#     （`warning: --depth is ignored in local clones`）浅くならないうえ、正解が素のディレクトリ
#     （gitリポジトリでない）の場合は clone 自体が失敗する。読み取り専用でそのまま使う。
#   - URLのみ shallow clone する。後始末の対象は**自分が作った一時ディレクトリだけ**であり、
#     ローカルパス指定時は絶対に削除しない（`cleanup:false` で表す）。
#   - `cleanup` は冪等。誤って別のディレクトリを消さないよう、`resolve` が置いたマーカーファイルの
#     存在を確認してからでないと削除しない。
#
# 認証は扱わない（非公開リポジトリのcloneはgitの資格情報ヘルパ任せ）。
#
# 規約: .claude/rules/shell-script-style.md（set -euo pipefail / jq前提 / BOM無しUTF-8・LF）
set -euo pipefail

# `resolve` が一時ディレクトリの直下へ置くマーカー。`cleanup` はこれがある場合しか削除しない。
readonly ATR_MARKER='.answer-talker-reference'

# 取得元が「URL」か「ローカルパス」かを判定して REPLY へ返す（純粋関数）。
# scheme付きURL（https:// など）と scp形式（git@host:group/repo.git）を url とみなす。
reference_kind_to_reply() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    REPLY=""
    return 1
  fi
  if [ "$target" != "${target#*://}" ] || [ "$target" != "${target#git@}" ]; then
    REPLY="url"
  else
    REPLY="local"
  fi
  return 0
}

# 一時ディレクトリを削除してよいかを判定する（純粋関数。外部コマンドを呼ばない）。
# 削除してよい条件は「実在するディレクトリで、直下にマーカーファイルがある」こと。
# これに満たないパスは、`cleanup` に何を渡されても削除しない。
cleanup_is_safe_dir() {
  local dir="${1:-}"
  [ -n "$dir" ] || return 1
  [ "$dir" != "/" ] || return 1
  [ -d "$dir" ] || return 1
  [ -f "$dir/$ATR_MARKER" ] || return 1
  return 0
}

# 相対パスを絶対パスへ正規化して REPLY へ返す。存在しない場合は終了コード1。
abs_path_to_reply() {
  local path="${1:-}"
  if [ -z "$path" ] || [ ! -d "$path" ]; then
    REPLY=""
    return 1
  fi
  REPLY="$(cd "$path" && pwd)"
  return 0
}

# URL から一時ディレクトリへ shallow clone する。clone先のパスを標準出力へ返す。
# **失敗をパイプで潰さない**こと（`git clone … | tail` はパイプ右辺の終了コードを返すため、
# cloneが fatal で終わっていても成功に見える。調査時に実際に踏んだ）。
clone_reference() {
  local url="$1" ref="${2:-}" tmpdir
  tmpdir="$(mktemp -d)"
  : > "$tmpdir/$ATR_MARKER"
  local -a args=(clone --depth 1 --single-branch --no-tags)
  [ -n "$ref" ] && args+=(--branch "$ref")
  args+=("$url" "$tmpdir/source")
  # **認証を要するURLで対話プロンプトを出させない**（issue #1 の検証中に実際に踏んだ）。
  # 非公開リポジトリのURLを渡すと、gitが資格情報の入力を待って**固まる**。AIエージェントから
  # 呼ばれる前提のスクリプトでは、待たされるより即座に失敗したほうがよい。
  # 認証自体はこのスクリプトの責務ではない（gitの資格情報ヘルパ任せ）。
  export GIT_TERMINAL_PROMPT=0
  export GCM_INTERACTIVE=never
  if ! git "${args[@]}" >/dev/null 2>"$tmpdir/clone.err"; then
    printf 'answer-talker-reference: clone に失敗しました: %s\n' "$url" >&2
    sed -n '1,5p' "$tmpdir/clone.err" >&2 || true
    rm -rf "$tmpdir"
    return 1
  fi
  printf '%s\n' "$tmpdir"
}

cmd_resolve() {
  local reference="" ref=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reference) reference="${2:-}"; shift 2 ;;
      --ref) ref="${2:-}"; shift 2 ;;
      *) printf 'answer-talker-reference resolve: 不明な引数: %s\n' "$1" >&2; return 2 ;;
    esac
  done

  if ! reference_kind_to_reply "$reference"; then
    printf 'answer-talker-reference resolve: --reference は必須です\n' >&2
    return 2
  fi
  local kind="$REPLY"

  if [ "$kind" = "local" ]; then
    if [ -n "$ref" ]; then
      printf 'answer-talker-reference resolve: ローカルパスに --ref は指定できません\n' >&2
      return 2
    fi
    if ! abs_path_to_reply "$reference"; then
      printf 'answer-talker-reference resolve: ディレクトリが見つかりません: %s\n' "$reference" >&2
      return 1
    fi
    jq -nc --arg root "$REPLY" '{kind: "local", root: $root, cleanup: false, tmpdir: null}'
    return 0
  fi

  local tmpdir
  tmpdir="$(clone_reference "$reference" "$ref")" || return 1
  jq -nc --arg root "$tmpdir/source" --arg tmpdir "$tmpdir" \
    '{kind: "url", root: $root, cleanup: true, tmpdir: $tmpdir}'
}

cmd_cleanup() {
  local tmpdir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tmpdir) tmpdir="${2:-}"; shift 2 ;;
      *) printf 'answer-talker-reference cleanup: 不明な引数: %s\n' "$1" >&2; return 2 ;;
    esac
  done

  # 冪等にする。空・存在しない・マーカーが無いパスは「消すものが無い」として正常終了する
  # （渡された任意のパスを削除しないための安全弁でもある）。
  if ! cleanup_is_safe_dir "$tmpdir"; then
    jq -nc --arg reason 'answer-talkerが作成した一時ディレクトリではないため、何もしませんでした' \
      '{removed: false, reason: $reason}'
    return 0
  fi
  rm -rf "$tmpdir"
  jq -nc '{removed: true, reason: ""}'
}

usage() {
  printf 'usage: answer-talker-reference.sh resolve --reference <URL|パス> [--ref <ブランチ/タグ>]\n' >&2
  printf '       answer-talker-reference.sh cleanup --tmpdir <パス>\n' >&2
}

main() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift || true
  case "$sub" in
    resolve) cmd_resolve "$@" ;;
    cleanup) cmd_cleanup "$@" ;;
    ''|-h|--help) usage; return 2 ;;
    *) printf 'answer-talker-reference: 不明なサブコマンド: %s\n' "$sub" >&2; usage; return 2 ;;
  esac
}

# テストから source したときに副作用を起こさないためのガード
# （.claude/rules/shell-script-style.md「テスト」）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
