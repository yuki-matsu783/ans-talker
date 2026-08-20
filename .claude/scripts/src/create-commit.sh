#!/usr/bin/env bash
#
# `commit` スキル専用のコミット実行ラッパー（issue #39）。
# `.claude/skills/commit/SKILL.md` のStep 5から呼び出す想定。
#
# `git add -- <files>` → `git commit -m <message>` を行うだけの薄いラッパーだが、呼び出し文字列
# 自体（例: `bash .claude/scripts/src/create-commit.sh --message "..." -- file1 file2`）に
# "git commit" という部分文字列を含まないことが目的。`.claude/hooks/block-direct-git-commit.sh`
# （PreToolUse hook）は Bash/PowerShell ツールのコマンド文字列に "git commit" が含まれる場合を
# ブロックするため、このラッパー経由のコミットはhookの対象外になり、commitスキルの正規の実行を
# 妨げない（詳細: .claude/docs/ddr/0012-コミットはcommitスキル経由を機構的に強制する.md）。
#
# 使い方:
#   .claude/scripts/src/create-commit.sh --message "<コミットメッセージ>" -- <file1> [file2 ...]
#
# `--amend` `--no-verify` `git add .`/`-A` 相当のオプションは持たない（commitスキルの絶対ルールを
# 呼び出し側だけでなくラッパー側でも構造的に不可能にするため）。渡されたパスは追跡状態で分類して
# から `git add` へ渡すが、`-A` は使わないため、パス指定が空になっても無制限のステージングへ
# 化けることはない。
#
# 削除済みファイルのパスは、そのまま `--` の後ろに渡してよい（issue #60）。追跡済みのファイルを
# 削除しただけのパスは、`git add` がそのまま「削除」としてステージする。**`git rm` で先に削除を
# ステージしてから残りをこのラッパーへ渡す、という2段構えは不要**であり、むしろそれを行うと当該
# パスが index から消えるため、後続の `git add` が pathspec 不一致で失敗する。既に削除がステージ
# 済みのパスを渡した場合は、冪等にスキップして通知するだけにする。
# 詳細: .claude/docs/spec/create-commit.md

set -euo pipefail

usage() {
  cat <<'EOF'
使い方: create-commit.sh --message <コミットメッセージ> -- <file1> [file2 ...]

--message と、`--` 以降の対象ファイル1件以上が必須です。
EOF
}

message=""
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --message) message="$2"; shift 2 ;;
    --) shift; files=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "不明な引数です: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "$message" ]; then
  echo "エラー: --message は必須です" >&2
  usage >&2
  exit 1
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "エラー: コミット対象ファイルを -- の後に1件以上指定してください" >&2
  usage >&2
  exit 1
fi

# 渡されたパスを分類する（`git add` が失敗したときだけ呼ぶ。issue #60）。
#   add    : worktree に存在する、または index にマッチするものがある
#            （通常の変更・新規追加・追跡済みファイルの削除・配下を持つディレクトリ）
#   skip   : worktree にも index にも無いが HEAD にはある
#            （削除が既にステージ済み。再度渡されても冪等に扱う）
#   unknown: いずれにも無い（未追跡のまま削除された・パスの綴り誤り等）
# 判定はパス文字列の一致ではなく git 自身のpathspec解釈に委ねる（ディレクトリ指定・末尾スラッシュ・
# 相対/絶対表記の違いを自前で正規化しないため）。
classify_files() {
  add_files=()
  skip_files=()
  unknown_files=()
  local path
  for path in "$@"; do
    # 出力の中身は使わず「1件でもマッチしたか」だけを見るため、`-z` は付けない
    # （コマンド置換はNULを扱えず警告になる。日本語パスが8進エスケープされても判定に影響しない）。
    if [ -e "$path" ] || [ -n "$(git ls-files -- "$path")" ]; then
      add_files+=("$path")
    elif [ -n "$(git ls-tree -r --name-only HEAD -- "$path" 2>/dev/null || true)" ]; then
      skip_files+=("$path")
    else
      unknown_files+=("$path")
    fi
  done
}

# 通常はここで完了する（`git add` の呼び出し方は従来と同一で、追加のgit起動も発生しない）。
# `git add` はpathspecを先に検証し、1つでも不一致があれば何もステージせずに終了するため、
# 失敗しても中途半端にステージされた状態にはならない。
if ! add_error="$(git add -- "${files[@]}" 2>&1)"; then
  classify_files "${files[@]}"

  # 不明なパスが混ざっていたら、一切ステージせずに終了する。推測した原因は並べず、事実のみを
  # 述べてspecへ誘導する。
  if [ "${#unknown_files[@]}" -gt 0 ]; then
    {
      echo "エラー: 次のパスは git が把握していません（ステージング・コミットは行いませんでした）:"
      printf '  - %s\n' "${unknown_files[@]}"
      echo "詳細: .claude/docs/spec/create-commit.md"
    } >&2
    exit 1
  fi

  # 分類上すべてステージ可能なのに失敗した場合（`.gitignore` 対象を渡した等）は、gitの
  # エラーをそのまま見せて終了する。
  if [ "${#skip_files[@]}" -eq 0 ]; then
    printf '%s\n' "$add_error" >&2
    exit 1
  fi

  echo "注記: 次のパスは削除が既にステージ済みのため、そのままコミットに含めます: ${skip_files[*]}"

  # 残りのパスだけで再試行する。空のパス指定は「何も指定していない」扱いになり、将来 `-A`
  # 相当のオプションが足された場合に無制限のステージングへ化けうるため、空なら呼ばない。
  if [ "${#add_files[@]}" -gt 0 ]; then
    git add -- "${add_files[@]}"
  fi
fi

git commit -m "$message"
