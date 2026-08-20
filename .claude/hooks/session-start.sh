#!/usr/bin/env bash
#
# Claude Code SessionStart hook（bash版）。
# 設計: .claude/docs/spec/issue-mr-workflow.md「セッション開始時の自動コンテキスト注入」,
#       .claude/docs/spec/shell-scripts.md
#
# セッション開始・resume・clear・compact時（.claude/settings.jsonのmatcher参照）に、現在チェック
# アウトされているブランチに紐づくissue/MRの状態を取得し、追加コンテキストとしてコンテキストへ
# 注入する。compactは当初「圧縮のたびに`gh` API呼び出しが走るのを避ける」という理由で対象外に
# していたが、compactは要約内容を指定できず、作業継続に必須の現在地が要約の精度次第で失われる
# ため、issue #57 でmatcherへ追加した（詳細・却下案:
# .claude/docs/ddr/0032-compact後もSessionStart-hookで作業コンテキストを再注入する.md）。
#
# 前提: `gh` CLI・`jq` がインストール・認証済みであること（未認証の場合は非侵襲的に失敗
# メッセージのみ返し、セッション開始はブロックしない）。`gh`/`glab` CLI自体が存在しない環境では、
# issue/PR情報の代わりに「MCPフォールバック経路を使うこと」と、その際に必要な情報
# （ブランチ名から抽出したissue番号・owner/repo）を注入する（issue #34）。
#
# 注意: SessionStart hookはTask tool経由のサブエージェント内でも発火する（公式ドキュメント確認済み）。
# サブエージェント実行時はstdinのJSONに`agent_id`が含まれるため、これを見て即終了する
# （メインセッションのコンテキストのみを汚す設計）。
#
# 注意（エラー方針）: PowerShell版の try/catch に相当する構造として、リスクのある処理は
# 関数化してコマンド置換 `$(...)` の中で呼ぶ（コマンド置換は必ずサブシェル＝別プロセスで実行される
# ため、`set -e` の「if の条件式の中では-eが一時停止する」というbashの仕様の影響を受けず、
# 内部で失敗したコマンドの時点で確実にサブシェルごと終了し、呼び出し元の if で失敗を検知できる。
# 詳細: .claude/docs/spec/shell-scripts.md「bashでのtry/catch相当の書き方」節）。
#
# また、frontmatterのindex.jsonl（.claude/scripts/src/extract-frontmatter.shが生成、Git管理外の
# 生成物）をセッション開始のたびに非侵襲的に再生成する（issue #36）。詳細:
# .claude/docs/ddr/0025-frontmatterのindex.jsonlをGit管理から外しSessionStart-hookで生成する.md
#
# 注意（テスト可能性、issue #57）: 本体処理は `main` にまとめ、ファイル末尾で
# 「直接実行されたときだけ `main` を呼ぶ」ガードを通す。これにより
# .claude/scripts/test/test_session_start.sh から `source` して、副作用の無い純粋関数
# （context_text_bytes / append_size_warning / extract_handoff_next_steps）だけを単体テストできる。

set -uo pipefail

# 注入テキストのサイズ上限（バイト）。これを超えた場合は、切り詰めずに全量を注入したうえで
# 末尾へ整理を促す指示文を追記する（issue #57）。日本語はUTF-8で1文字3バイトのため、
# 8000バイトはおよそ2,600文字（≒2,600トークン）に相当する。通常時の注入量（実測で約0.6〜2KB）の
# 4〜10倍にあたり、「HANDOFF.mdや作業計画が整理されないまま膨らみ続けている」状態を
# 検知する境界として設定した。環境変数で上書きできる。
CONTEXT_SIZE_WARN_BYTES="${CONTEXT_SIZE_WARN_BYTES:-8000}"

write_additional_context() {
  local text="$1"
  jq -nc --arg text "$text" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $text}}'
}

# 文字数ではなく**バイト数**を返す（日本語を含むテキストでは両者が3倍ずれるため、実際の
# 注入量を測る目的には文字数を使えない）。セッション開始あたり1回しか呼ばれない経路のため、
# forkのコストよりも読みやすさ・確実さを優先して `wc -c` を使う。
context_text_bytes() {
  local bytes
  bytes="$(printf '%s' "$1" | wc -c)"
  # `wc` は環境によって前後に空白を付けるため除去する
  printf '%s' "${bytes//[[:space:]]/}"
}

# 注入テキストのバイト数がしきい値を超える場合のみ、末尾へ警告用の指示文を追記して返す。
# 超えない場合は入力をそのまま返す。**切り詰めは行わない**（切り詰めると、この機構が守ろうと
# している「現在地」そのものを失う可能性があるため。詳細: DDR 0032）。
append_size_warning() {
  local text="$1"
  local limit="${2:-$CONTEXT_SIZE_WARN_BYTES}"
  local bytes
  bytes="$(context_text_bytes "$text")"
  if [ "$bytes" -le "$limit" ]; then
    printf '%s' "$text"
    return 0
  fi
  printf '%s\n\n%s' "$text" "$(printf '注意: この追加コンテキストは %s バイトで、しきい値 %s バイトを超えています。ユーザーへ「セッション開始時に自動注入されるコンテキストが肥大化している」ことを警告し、HANDOFF.md（特に「やったこと」「判断を迷った内容」）・plans/配下の個別作業計画を整理するよう促してください。' "$bytes" "$limit")"
}

# HANDOFF.md から「## 次にやること」節（見出し行を含み、次の `## ` 見出しの手前まで）を抜き出す。
# 末尾の空行は落とす。節が見つからない・ファイルが無い場合は非ゼロで返す（呼び出し側は
# 行自体を出さない）。**HANDOFF.md全文は注入しない**（issue #57の設計判断。詳細: DDR 0032）。
extract_handoff_next_steps() {
  local file="$1"
  [ -f "$file" ] || return 1
  local section
  section="$(awk '
    /^##[[:space:]]/ {
      if (in_section) { exit }
      if ($0 ~ /^##[[:space:]]*次にやること[[:space:]]*$/) { in_section = 1 }
    }
    in_section { print }
  ' "$file")"
  # 見出し行しか無い（本文が空）場合も「無い」とみなす。コマンド置換が末尾の改行を
  # 落とすため、本文が空なら section は見出し行1行だけになる。
  case "$section" in
    '' | '## 次にやること') return 1 ;;
  esac
  printf '%s' "$section"
}

# リスクのある本体処理。失敗した場合はこの関数のexit codeが非ゼロになり呼び出し元へ伝わる。
build_context() {
  set -euo pipefail
  cd "$CLAUDE_PROJECT_DIR"
  source "${CLAUDE_PROJECT_DIR}/.claude/scripts/src/vcs/Provider.sh"

  local branch
  branch="$(git branch --show-current 2>/dev/null || true)"
  local base_branch
  base_branch="$(get_workflow_config | jq -r '.defaultBaseBranch')"
  if [ -z "$branch" ] || [ "$branch" = "$base_branch" ]; then
    # 作業ブランチ未チェックアウト（mainブランチ上）のときは注入しない。
    # exit code 2 は「エラーではなく意図的に何も注入しない」を表す専用の合図
    # （呼び出し元はこのコードのときだけフォールバックメッセージも出さない）。
    exit 2
  fi

  local lines=()
  lines+=("## 現在の作業ブランチ情報 (SessionStart hook)")
  lines+=("- ブランチ: ${branch}")

  # `gh`/`glab` CLIが無い実行環境（例: Claude Code on the webのリモート実行環境）では、
  # issue/PR情報をhookから取得する手段が無い。「取得に失敗しました」や「PR: なし」のような
  # 誤解を招く出力に代えて、経路がMCPであること・MCPツールを使う際に必要な情報
  # （issue番号・owner/repo）・手順の参照先を注入する（issue #34）。
  local access_mode
  access_mode="$(get_vcs_access_mode)"
  if [ "$access_mode" != "cli" ]; then
    local slug issue_number_from_branch
    slug="$(get_repo_slug)"
    lines+=("- VCS情報取得経路: MCP（\`gh\`/\`glab\` CLIがこの実行環境に存在しないため、Provider.shのCLI経路は使えません）")
    if issue_number_from_branch="$(get_issue_number_from_branch "$branch")"; then
      lines+=("- issue: #${issue_number_from_branch}（ブランチ名から抽出。本文・タイトルはMCPツールで取得すること）")
    else
      lines+=("- issue: 特定できず（ブランチ名がissue命名規則に一致しません）")
    fi
    lines+=("- PR: 未取得（CLI不在のためhookからは判定できません。「PRなし」という意味ではありません）")
    lines+=("- MCPツールに渡す owner=$(printf '%s' "$slug" | jq -r '.owner') / repo=$(printf '%s' "$slug" | jq -r '.repo')")
    lines+=("- 手順: .claude/skills/issue-mr-flow/SKILL.md「\`gh\`/\`glab\` CLI不在時のMCPフォールバック」節を参照し、WebFetch・curlへはフォールバックしないこと")
    local work_context
    work_context="$(build_work_context)"
    [ -z "$work_context" ] || lines+=("$work_context")
    printf '%s\n' "${lines[@]}"
    return 0
  fi

  local issue_number
  if issue_number="$(get_issue_number_from_branch "$branch")"; then
    local issue
    issue="$(get_issue "$issue_number")"
    lines+=("- issue: #$(printf '%s' "$issue" | jq -r '.number') $(printf '%s' "$issue" | jq -r '.title') ($(printf '%s' "$issue" | jq -r '.url'))")
  else
    lines+=("- issue: 特定できず（ブランチ名がissue命名規則に一致しません）")
  fi

  local mr
  mr="$(get_mr_for_branch "$branch")"
  if [ -n "$mr" ]; then
    local draft_label
    if [ "$(printf '%s' "$mr" | jq -r '.isDraft')" = "true" ]; then
      draft_label="[Draft]"
    else
      draft_label="[Ready]"
    fi
    lines+=("- PR: #$(printf '%s' "$mr" | jq -r '.number') $(printf '%s' "$mr" | jq -r '.title') ${draft_label} ($(printf '%s' "$mr" | jq -r '.url'))")

    local mr_number comments_text ids_count
    mr_number="$(printf '%s' "$mr" | jq -r '.number')"
    if comments_text="$(get_mr_unresolved_comments "$mr_number" 2>/dev/null)"; then
      ids_count="$(printf '%s\n' "$comments_text" | grep -oE '^\[review unresolved threadId=[^ ]+' | sed -E 's/.*threadId=//' | sort -u | wc -l | tr -d ' ')"
      lines+=("- 未解決レビューコメント: ${ids_count}件")
    else
      lines+=("- 未解決レビューコメント: 取得に失敗しました")
    fi
  else
    lines+=("- PR: なし")
  fi

  local work_context
  work_context="$(build_work_context)"
  [ -z "$work_context" ] || lines+=("$work_context")
  printf '%s\n' "${lines[@]}"
}

# 作業継続に必須のローカル情報（ブランチ固有のplans/worklog/reportsの**ファイル名一覧**と、
# HANDOFF.mdの「次にやること」節）を組み立てて標準出力へ返す（issue #57）。該当が無ければ
# 何も出力しない。いずれもローカル操作のみで得られるため、CLI経路・MCP経路のどちらでも
# 同じ内容を足す。**ファイルの中身は注入しない**（一覧はファイル名のみ、HANDOFF.mdは
# 「次にやること」節のみ。詳細: DDR 0032）。
# 取得できなかった項目は行自体を出さない（fail-open。ここでの失敗が
# ブランチ・issue・PR情報の注入を妨げてはならない）。
build_work_context() {
  local lines=()

  local work_files
  if work_files="$(get_branch_work_files 2>/dev/null)" && [ -n "$work_files" ]; then
    local joined="" f
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ -z "$joined" ]; then joined="$f"; else joined="${joined}, ${f}"; fi
    done <<<"$work_files"
    lines+=("- このブランチの作業ファイル: ${joined}")
  fi

  local next_steps
  if next_steps="$(extract_handoff_next_steps "${CLAUDE_PROJECT_DIR}/HANDOFF.md")"; then
    lines+=("")
    lines+=("$next_steps")
    lines+=("")
    lines+=("（上記はHANDOFF.mdからの抜粋です。フロー進捗状況・やったこと等の全体は HANDOFF.md を読むこと）")
  fi

  [ "${#lines[@]}" -gt 0 ] || return 0
  printf '%s\n' "${lines[@]}"
}

regenerate_frontmatter_index() {
  bash "${CLAUDE_PROJECT_DIR}/.claude/scripts/src/extract-frontmatter.sh" "$CLAUDE_PROJECT_DIR" \
    >/dev/null 2>&1
}

main() {
  local raw
  raw="$(cat)"
  local agent_id=""
  if [ -n "$raw" ]; then
    agent_id="$(printf '%s' "$raw" | jq -r '.agent_id // empty' 2>/dev/null || true)"
  fi

  # サブエージェント内実行では何もしない（agent_idはサブエージェント呼び出し時のみ付与される）
  if [ -n "$agent_id" ]; then
    exit 0
  fi

  if [ -z "${CLAUDE_PROJECT_DIR:-}" ]; then
    exit 0
  fi

  # frontmatterのindex.jsonl（Git管理外の生成物）をセッション開始時に再生成する。
  # hookの標準出力はJSON1行のみが期待される契約のため、extract-frontmatter.shの出力
  # （wrote: ...等）は標準出力・標準エラー出力ともに捨てる。失敗してもセッション開始・
  # コンテキスト注入はブロックしない（非侵襲的・fail-open。build_contextとは独立に実行する）。
  regenerate_frontmatter_index || true

  local context_text rc
  if context_text="$(build_context)"; then
    write_additional_context "$(append_size_warning "$context_text")"
  else
    rc=$?
    if [ "$rc" -ne 2 ]; then
      write_additional_context "(issue/MR情報の取得に失敗しました)"
    fi
  fi

  exit 0
}

# 直接実行されたときだけ本体を走らせる（テストからsourceされた場合は関数定義のみ読み込む）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main
fi
