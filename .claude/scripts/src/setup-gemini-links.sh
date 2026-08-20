#!/usr/bin/env bash
#
# .gemini/{docs,hooks,rules,scripts,skills} を .claude/ 配下の同名ディレクトリへのリンクとして
# 作成する（Gemini CLIとClaude Codeでルール・スキル・スクリプトの内容を二重管理しないため）。
# 設計: .claude/docs/ddr/0017-gemini配下はGit管理下に置かずセットアップスクリプトで生成する.md
#
# .gemini/{docs,hooks,rules,scripts,skills} はGit管理下に置かない（.gitignore参照）。
# NTFSジャンクションはGitがリンクとして認識できず、中身をそのまま複製してコミットしてしまうため
# （Windows版の`git status`で`.gemini/docs/*.md`等が個別の新規ファイルとして列挙されることを
# 実機確認済み）。そのためclone直後・リンクが失われた場合に、このスクリプトを1度実行して
# 各開発者のマシン上にローカルでリンクを再生成する運用にする。
#
# 使い方:
#     bash .claude/scripts/src/setup-gemini-links.sh
#
# 既にリンク（またはディレクトリ・ファイル）が存在する場合はスキップする（再実行しても安全）。
# 既存を作り直したい場合は、先に対象を手動で削除してから再実行すること
# （例: rm -rf .gemini/docs。Windowsのジャンクションは中身を巻き込まず`rmdir`/`rm -rf`で
# リンク自体だけを安全に削除できる）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

TARGETS=(docs hooks rules scripts skills)

create_link() {
  local name="$1"
  local link_path="${REPO_ROOT}/.gemini/${name}"
  local target_path="${REPO_ROOT}/.claude/${name}"

  if [ -e "$link_path" ] || [ -L "$link_path" ]; then
    echo "skip（既に存在します）: .gemini/${name}"
    return 0
  fi

  # 1. まずシンボリックリンクを試みる（Linux/macOSでは常に成功する。Windowsでは開発者モード/
  #    管理者権限がある場合のみ成功する）。
  if ln -s "$target_path" "$link_path" 2>/dev/null; then
    echo "作成しました（symlink）: .gemini/${name} -> .claude/${name}"
    return 0
  fi

  # 2. シンボリックリンクに失敗した場合、Windows専用のNTFSジャンクションへフォールバックする
  #    （ディレクトリのみ対象。管理者権限・開発者モードいずれも不要）。
  #    `//c` `//J` の先頭 `//` は、git bash（MSYS）がDOS形式の単一スラッシュ引数を
  #    POSIXパスと誤認してWindowsパスへ自動変換してしまう問題の回避策
  #    （詳細: .claude/rules/shell-script-style.md「git bashのパス変換の落とし穴」）。
  if command -v cmd.exe >/dev/null 2>&1; then
    local win_link win_target
    win_link="$(cygpath -w "$link_path")"
    win_target="$(cygpath -w "$target_path")"
    if cmd.exe //c mklink //J "$win_link" "$win_target" >/dev/null; then
      echo "作成しました（NTFSジャンクション。symlink作成に必要な権限が無かったための代替）: .gemini/${name} -> .claude/${name}"
      return 0
    fi
  fi

  echo "エラー: .gemini/${name} のリンク作成に失敗しました" >&2
  return 1
}

mkdir -p "${REPO_ROOT}/.gemini"

fail=0
for t in "${TARGETS[@]}"; do
  create_link "$t" || fail=1
done

if [ "$fail" -ne 0 ]; then
  echo "一部のリンク作成に失敗しました。上記のエラーを確認してください。" >&2
  exit 1
fi

echo "完了しました。.gemini/{docs,hooks,rules,scripts,skills} は .claude/ 配下を参照します（Git管理下には置きません）。"
