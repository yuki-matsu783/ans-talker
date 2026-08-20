#!/usr/bin/env bash
#
# issue駆動MRワークフロー支援の共通レイヤー（bash版）。
# 設計: .claude/docs/spec/issue-mr-workflow.md, .claude/docs/spec/shell-scripts.md
#
# GitHub/GitLabの差異を吸収する共通インターフェースを提供する。呼び出し側
# （.claude/skills/issue-mr-flow/SKILL.md 等）はこのファイルをsourceして使う。
#     source .claude/scripts/src/vcs/Provider.sh
#
# プロバイダ非依存の関数（new_issue_branch, sync_branch 等）はここに実装し、
# プロバイダ依存の関数（get_issue, new_draft_merge_request, get_mr_unresolved_comments,
# set_mr_description 等）は get_provider の判定結果に応じて Github.sh / Gitlab.sh の
# 対応関数（github_xxx / gitlab_xxx）へディスパッチする。
#
# 戻り値の受け渡しはPowerShell版のPSCustomObjectに代えてJSON文字列をstdoutへ出力する形にする
# （呼び出し側はjqでフィールドを取り出す。例: get_issue 6 | jq -r '.title'）。JSONのキー名は
# PowerShell版のPascalCase（Number/Title/...）ではなく、bash/jqのエコシステムに合わせて
# camelCase（number/title/...）に統一している（詳細: .claude/docs/spec/shell-scripts.md）。
#
# 前提: bash, git, jq, gh（GitHubの場合）または glab（GitLabの場合）。
#
# `gh`/`glab` が実行環境に存在しない場合（例: Claude Code on the webのリモート実行環境）は、
# プロバイダ依存の関数は `require_vcs_cli` により「代替すべきMCPツール名」を提示して失敗する。
# 呼び出し側（AIエージェント）はそのメッセージに従いMCPフォールバック経路へ切り替える
# （経路判定は `get_vcs_access_mode`、手順は .claude/skills/issue-mr-flow/SKILL.md
# 「`gh`/`glab` CLI不在時のMCPフォールバック」節。issue #34, DDR 0027）。
#
# 注意（文字コード）: PowerShell版はシステムのANSI/OEMコードページ対策として明示的な
# UTF-8切り替えが必要だったが、git bash + gh/jq の組み合わせではこの問題が発生しない
# （bashの標準入出力・パイプはコードページの影響を受けない）ため、本ファイルには
# 同種の対策は不要（詳細: .claude/docs/spec/shell-scripts.md「文字コード」節）。
#
# 注意（エラー方針）: PowerShell版の `$ErrorActionPreference = "Stop"` に相当する方針として
# `set -euo pipefail` を用いる。個々の関数内で「失敗してもスクリプト全体を止めたくない」箇所は
# `if ! cmd; then ...; fi` の形（`!` 付きコマンドは -e の対象外というbashの仕様）で局所的に握りつぶす。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./Github.sh
source "${SCRIPT_DIR}/Github.sh"
# shellcheck source=./Gitlab.sh
source "${SCRIPT_DIR}/Gitlab.sh"

# issue本文に標準として求める見出し（.claude/docs/spec/issue-mr-workflow.md
# 「Issueテンプレート標準化」参照。.github/ISSUE_TEMPLATE/task.md, .gitlab/issue_templates/Default.md と対応）
REQUIRED_ISSUE_SECTIONS=("目的" "現状" "期待する動作" "受け入れ条件")

get_repo_root() {
  git rev-parse --show-toplevel
}

# `.mrworkflow.json` が無い場合のデフォルト値をJSONで返す（あればファイルの内容をそのまま返す）。
get_workflow_config() {
  local config_path
  config_path="$(get_repo_root)/.mrworkflow.json"
  if [ -f "$config_path" ]; then
    cat "$config_path"
    return 0
  fi
  cat <<'EOF'
{
  "branchPrefixTemplate": "feature-{issue}-{slug}",
  "defaultBaseBranch": "main",
  "plansDir": "plans",
  "worklogDir": "worklog",
  "reportsDir": "reports",
  "specDirs": [".claude/docs/spec"],
  "ddrDirs": [".claude/docs/ddr"]
}
EOF
}

# issueタイトル等を英数字・ハイフンのスラッグへ簡易変換する（ブランチ名・ファイル名に使う）
to_slug() {
  local text="$1"
  local slug
  slug="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  if [ ${#slug} -gt 50 ]; then
    slug="$(printf '%s' "${slug:0:50}" | sed -E 's/-+$//')"
  fi
  if [ -z "$slug" ]; then
    slug="issue"
  fi
  printf '%s' "$slug"
}

# issue本文に標準4見出し（目的・現状・期待する動作・受け入れ条件）が揃っているか確認し、
# 欠けている見出し名を1行1件でstdoutへ出力する（揃っていれば何も出力しない）。プロバイダ非依存。
test_issue_sections() {
  local body="$1"
  local section
  for section in "${REQUIRED_ISSUE_SECTIONS[@]}"; do
    if ! printf '%s\n' "$body" | grep -qE "^##[[:space:]]*${section}[[:space:]]*\$"; then
      printf '%s\n' "$section"
    fi
  done
}

# 標準4見出し（目的・現状・期待する動作・受け入れ条件）に沿ってissue本文を組み立てる
# （`.github/ISSUE_TEMPLATE/task.md`, `.gitlab/issue_templates/Default.md` と同じ見出し構成）。
# 外部コマンド呼び出しを伴わない純粋関数。プロバイダ非依存。
build_issue_body() {
  local purpose="$1" current="$2" expected="$3" acceptance="$4"
  printf '## 目的\n\n%s\n\n## 現状\n\n%s\n\n## 期待する動作\n\n%s\n\n## 受け入れ条件\n\n%s\n' \
    "$purpose" "$current" "$expected" "$acceptance"
}

# remote URLを「ホスト部」と「パス部」へ分解する純粋関数（issue #55）。
# 外部コマンド・コマンド置換を伴わないため、呼び出しあたりのプロセス起動はゼロ。
# 結果は標準出力ではなくグローバル変数へ返す（.claude/rules/shell-script-style.md
# 「ホットパスの小さなヘルパー関数は…`REPLY` へ返す」。値が複数あるため `REPLY` ではなく
# `REPLY_HOST` / `REPLY_PATH` / `REPLY_SCHEME` / `REPLY_PORT` を使う）。標準出力へ返すと
# コマンド置換が必要になり、
# `provider_from_remote_url` の「プロセス起動ゼロ」（DDR 0028）が守れなくなる。
#
#   REPLY_HOST … 小文字化したホスト名（scheme・認証情報・ポートを除く）
#   REPLY_PATH … `owner/repo` 形式のパス（先頭スラッシュ・末尾の `.git`・末尾スラッシュを除く。
#                 大文字小文字はそのまま保つ）
#   REPLY_SCHEME … 小文字化したscheme（`https` / `http` / `ssh` / `git` 等。`://` を持たない
#                 scp形式（`git@host:o/r.git`）では空文字列）
#   REPLY_PORT … 明示されたポート番号（無ければ空文字列）。scp形式はポートを表現できないため常に空
#
# scp形式（`git@host:o/r.git`）とポート付きURL（`host:2222/o/r.git`）は、`:` の後ろが
# **数字だけかどうか**で区別する。これがパラメータ展開だけで書ける唯一の分岐点である。
#
# ホスト名が取れない場合も失敗させず `REPLY_HOST` を空にして返す。エラーにするかは呼び出し側の
# 判断に委ねることで、`provider_from_remote_url`（終了コード1）と `parse_repo_slug`（空のまま
# JSONを返す）それぞれの従来の振る舞いを変えずに済む。
split_remote_url() {
  local url="$1" rest first tail

  # scheme:// があれば取り出して除去（無ければ scheme は空のままURLをそのまま使う）
  if [ "$url" != "${url#*://}" ]; then
    REPLY_SCHEME="${url%%://*}"
    REPLY_SCHEME="${REPLY_SCHEME,,}"
  else
    REPLY_SCHEME=""
  fi
  rest="${url#*://}"
  REPLY_PORT=""

  # 認証情報 user@ を除去する。最初の `/` より前に `@` がある場合だけ落とすことで、
  # パスに `@` を含むURL（https://gitlab.com/foo/b@r.git）で誤爆しない
  first="${rest%%/*}"
  if [ "$first" != "${first#*@}" ]; then
    rest="${rest#*@}"
    first="${rest%%/*}"
  fi

  if [ "$first" = "${first%%:*}" ]; then
    # `:` を含まない → ホストのみ
    REPLY_HOST="$first"
    if [ "$rest" = "${rest#*/}" ]; then REPLY_PATH=""; else REPLY_PATH="${rest#*/}"; fi
  else
    REPLY_HOST="${first%%:*}"
    tail="${first#*:}"
    case "$tail" in
      ''|*[!0-9]*)
        # 数字以外を含む → scp形式のパス区切り
        REPLY_PATH="${rest#*:}"
        ;;
      *)
        # 数字のみ → ポート
        REPLY_PORT="$tail"
        if [ "$rest" = "${rest#*/}" ]; then REPLY_PATH=""; else REPLY_PATH="${rest#*/}"; fi
        ;;
    esac
  fi

  REPLY_HOST="${REPLY_HOST,,}"
  REPLY_PATH="${REPLY_PATH%.git}"
  while [ "$REPLY_PATH" != "${REPLY_PATH%/}" ]; do REPLY_PATH="${REPLY_PATH%/}"; done
}

# remote URLからホスト部分を取り出し、プロバイダ名（github / gitlab）を返す純粋関数。
# 外部コマンド呼び出しを伴わないため .claude/scripts/test/test_vcs_provider.sh から単体テストできる
# （.claude/rules/shell-script-style.md「テスト」）。
# ホスト部の切り出しそのものは `split_remote_url` に委譲する（issue #55。`parse_repo_slug` と
# 同じ規則が二重に書かれていた状態を解消したもの）。関数呼び出しであってコマンド置換ではない
# ため、プロセス起動はゼロのまま。
#
# 判定規則: ホスト名に `github` を含めばGitHub、それ以外はGitLabとみなす。本ワークフローが
# 対応するのはGitHub/GitLabの2つだけで、GitHubはSaaS（github.com）・GHEとも慣習的にホスト名へ
# `github` を含むため、「GitHubでなければGitLab」で全ケースを賄える。ホスト名に `gitlab` を
# 含まないself-hosted GitLab（git.example.co.jp / localhost:8929 等）を弾かないことが目的
# （issue #45）。
#
# URL全体ではなくホスト部で判定するのが要点。旧実装は `*github.com*` を先に見ていたため、
# https://gitlab.com/github-mirror/x.git のようにパスへ `github` を含むGitLab URLをGitHubと
# 誤判定していた。
#
# 判定はremote URLの文字列のみに依存し、`gh`/`glab` の認証状態には依存しない（未ログインでも
# 同じ結果になる）。
# 詳細・却下案（glab由来の情報を使う3方式・`.mrworkflow.json`への`provider`キー追加）は
# .claude/docs/ddr/0028-プロバイダ判定はremote-URLのホスト部でgithub以外をgitlabとみなす.md 参照。
#
# 受け入れたトレードオフ: GitHub/GitLabのどちらでもないリモート（Bitbucket等、URLのtypo）にも
# `gitlab` を返すため、旧実装の「サポート対象外のリモートです」という明快なエラーは出なくなり、
# 後続の `glab` 側のエラーに変わる。対応プロバイダが2つしかない以上、self-hostedを弾かずに
# 非対応だけを弾く判定は原理的に書けないため受け入れている（issue #45）。
provider_from_remote_url() {
  local host
  split_remote_url "$1"
  host="$REPLY_HOST"

  if [ -z "$host" ]; then
    echo "remote URLからホスト名を取得できませんでした: $1" >&2
    return 1
  fi

  case "$host" in
    # 社内GitLab（Aslead）を明示的に先に判定する。既定規則（github以外はgitlab）でも同じ結果に
    # なるが、ホスト名に `github` と `aslead` が同時に含まれる場合でもGitLabを優先させるため、
    # GitHub判定より前に置く。
    *aslead*) printf 'gitlab\n' ;;
    *github*) printf 'github\n' ;;
    *) printf 'gitlab\n' ;;
  esac
}

# `split_remote_url` が設定した `REPLY_*` から、リポジトリのWeb URLを組み立てる純粋関数
# （issue #44）。外部コマンド・コマンド置換を伴わないためプロセス起動はゼロ。結果は `REPLY` へ返す。
#
# 組み立ての規則:
#   - schemeは `http` のときだけ `http` を保ち、それ以外（`https` / `ssh` / `git` / scp形式）は
#     `https` にする。self-hosted GitLabをplain httpで立てている構成（`http://localhost:8929/g/r.git`）
#     でリンクが壊れるのを避けつつ、SSH系リモートからはWeb URLとして妥当な `https` を導く。
#   - ポートは **schemeが `http`/`https` のときだけ引き継ぐ**。`ssh://host:2222/o/r.git` の `2222` は
#     SSHの待ち受けポートであってWeb UIのポートではないため、引き継ぐとリンクが壊れる。
#     scp形式はそもそもポートを表現できない（`REPLY_PORT` は常に空）。
#   - `.git` サフィックス・末尾スラッシュの除去、ホスト名の小文字化は `split_remote_url` が済ませている。
#
# 入力が不正（ホスト・パスが取れない）場合の扱いは呼び出し側に委ねる（この関数は検証しない）。
build_repo_url_from_reply() {
  local scheme='https' authority="$REPLY_HOST"
  case "$REPLY_SCHEME" in
    http) scheme='http' ;;
  esac
  case "$REPLY_SCHEME" in
    http|https) [ -n "$REPLY_PORT" ] && authority="$REPLY_HOST:$REPLY_PORT" ;;
  esac
  REPLY="$scheme://$authority/$REPLY_PATH"
}

# remote URL（https / http / ssh(scp形式) / `ssh://`）から、リポジトリの正規URLを導出する
# 純粋関数（issue #44）。`gh repo view` / `glab repo view` の戻り値と同じ値を、CLI・ネットワーク
# 無しで得るためのもの。外部コマンド呼び出しを伴わないため
# .claude/scripts/test/test_vcs_provider.sh から単体テストできる。
#
# ホストまたはパス（`owner/repo`）が取れない場合は終了コード1を返す（URLを組み立てても
# リンクとして機能しないため、`https:///` のような壊れた値を返さず明示的に失敗させる）。
repo_url_from_remote_url() {
  split_remote_url "$1"
  if [ -z "$REPLY_HOST" ] || [ -z "$REPLY_PATH" ]; then
    echo "remote URLからリポジトリURLを導出できませんでした: $1" >&2
    return 1
  fi
  build_repo_url_from_reply
  printf '%s\n' "$REPLY"
}

# `git remote get-url origin` のホスト名からプロバイダを判定する。
#
# 判定結果はプロセス内でメモ化する（issue #42）。`get_blob_url` / `get_diff_anchor_url` のような
# ディスパッチ関数は変更ファイルの件数だけ繰り返し呼ばれ、そのたびに `$(git remote get-url origin)`
# のコマンド置換でサブシェルをforkするため（git bashでは1回あたり約95ms。
# `.claude/rules/shell-script-style.md`「外部プロセス起動のコスト」節）。同一プロセス内で
# originのURLが変わることは想定しないため、キャッシュの無効化は用意しない。
_PROVIDER_CACHE=""
get_provider() {
  if [ -z "$_PROVIDER_CACHE" ]; then
    local url
    url="$(git remote get-url origin)"
    _PROVIDER_CACHE="$(provider_from_remote_url "$url")"
  fi
  printf '%s\n' "$_PROVIDER_CACHE"
}

# --- gh/glab CLI不在環境向けのMCPフォールバック経路（issue #34） --------------------------------
#
# Claude Code on the webのリモート実行環境のように `gh`/`glab` CLIが存在しない環境では、
# 以下の関数群が「どのMCPツールで代替するか」を機械的に決めるための土台になる。
# 手順の正（サブコマンドごとの読み替え）は `.claude/skills/issue-mr-flow/SKILL.md`
# 「`gh`/`glab` CLI不在時のMCPフォールバック」節。WebFetch/curlへはフォールバックしない
# （DDR 0020, DDR 0027）。

# 実行環境に該当プロバイダのCLIがあるかを判定し、`cli`（CLI経路）または `mcp`（MCPフォールバック
# 経路）を標準出力へ返す。AIエージェントは各サブコマンドの冒頭でこれを呼び、経路を決める。
get_vcs_access_mode() {
  local provider cli
  provider="$(get_provider)"
  case "$provider" in
    github) cli="gh" ;;
    gitlab) cli="glab" ;;
    *) cli="" ;;
  esac
  if [ -n "$cli" ] && command -v "$cli" >/dev/null 2>&1; then
    printf 'cli\n'
  else
    printf 'mcp\n'
  fi
}

# リモートURL（https / ssh(scp形式) / ssh:// のいずれも可）から
# {host, owner, repo, path, url} のJSONを組み立てる純粋関数（外部の`gh`/`glab`に依存しない）。
# MCPツールが必須引数として要求する `owner` / `repo` を、CLI不在環境でも機械的に得るために使う。
# GitLabのネストしたnamespace（group/subgroup/repo）では、`owner` に `group/subgroup` が入る。
parse_repo_slug() {
  local host path owner repo url
  split_remote_url "$1"
  host="$REPLY_HOST"
  path="$REPLY_PATH"
  owner="${path%/*}"
  repo="${path##*/}"
  # `.url` は `get_repo_url` と同じ組み立て規則を共有する（issue #44。plain httpのself-hosted
  # GitLabやポート付きURLで両者の値が食い違わないようにするため）
  build_repo_url_from_reply
  url="$REPLY"
  jq -nc --arg host "$host" --arg owner "$owner" --arg repo "$repo" --arg path "$path" \
    --arg url "$url" \
    '{host: $host, owner: $owner, repo: $repo, path: $path, url: $url}'
}

# `git remote get-url origin` の値を parse_repo_slug へ渡す（MCPツールの owner/repo 引数用）。
get_repo_slug() {
  parse_repo_slug "$(git remote get-url origin)"
}

# Provider関数名に対応するGitHub MCPツールと主な引数を1行で返す（require_vcs_cli の
# メッセージ用。対応表の正はSKILL.mdの該当節で、ここはその要約）。
# GitLabは対象外（DDR 0027「GitLab側は対象外とする」）。
mcp_tool_hint() {
  local func_name="$1"
  if [ "$(get_provider)" != "github" ]; then
    printf 'GitLab向けのMCPフォールバックは対象外です（DDR 0027）。glab CLIをインストール・認証してください\n'
    return 0
  fi
  case "$func_name" in
    get_issue) printf 'mcp__github__issue_read (method="get", owner, repo, issue_number)\n' ;;
    new_issue) printf 'mcp__github__issue_write (method="create", owner, repo, title, body)\n' ;;
    search_issues) printf 'mcp__github__search_issues (query, owner, repo)\n' ;;
    new_draft_merge_request) printf 'mcp__github__create_pull_request (owner, repo, title, head, base, draft=true, body)\n' ;;
    get_mr_for_branch) printf 'mcp__github__list_pull_requests (owner, repo, head="<owner>:<branch>", state="open")\n' ;;
    get_mr_unresolved_comments) printf 'mcp__github__pull_request_read (method="get_review_comments" / "get_comments", owner, repo, pullNumber)\n' ;;
    add_mr_thread_reply) printf 'mcp__github__add_reply_to_pull_request_comment (owner, repo, pullNumber, commentId=スレッド先頭コメントの数値ID, body)\n' ;;
    set_mr_description) printf 'mcp__github__update_pull_request (owner, repo, pullNumber, body=ファイル内容)\n' ;;
    set_mr_ready) printf 'mcp__github__update_pull_request (owner, repo, pullNumber, draft=false)\n' ;;
    add_mr_comment) printf 'mcp__github__add_issue_comment (owner, repo, issue_number=PR番号, body=ファイル内容)\n' ;;
    add_mr_inline_comments) printf 'mcp__github__pull_request_review_write (method="create" → 各指摘を "add_comment_to_pending_review" → "submit_pending"。owner, repo, pullNumber, path, line, side, body)\n' ;;
    add_issue_comment) printf 'mcp__github__add_issue_comment (owner, repo, issue_number=通知先issue番号, body=ファイル内容)\n' ;;
    *) printf '対応するMCPツールは .claude/skills/issue-mr-flow/SKILL.md の対応表を参照\n' ;;
  esac
}

# CLI経路が使えない場合に、代替すべきMCPツールを名指ししたメッセージをstderrへ出して失敗する。
# 各Provider関数の先頭で `require_vcs_cli <自関数名> || return 1` の形で呼ぶ。
# 目的は「CLI不在時にAIエージェントが即興でツールを選ぶ」状態をなくすこと（issue #34）。
require_vcs_cli() {
  local func_name="$1"
  if [ "$(get_vcs_access_mode)" = "cli" ]; then
    return 0
  fi
  {
    printf '%s: gh/glab CLIがこの実行環境に存在しないため、CLI経路では実行できません。\n' "$func_name"
    printf '  代替（MCPフォールバック経路）: %s\n' "$(mcp_tool_hint "$func_name")"
    printf '  owner/repo は `get_repo_slug` で取得できます（例: get_repo_slug | jq -r ".owner, .repo"）。\n'
    printf '  手順: .claude/skills/issue-mr-flow/SKILL.md 「`gh`/`glab` CLI不在時のMCPフォールバック」節\n'
    printf '  WebFetchツール・curlへはフォールバックしないこと（DDR 0020, DDR 0027）。\n'
  } >&2
  return 1
}

get_issue() {
  require_vcs_cli get_issue || return 1
  local number="$1"
  case "$(get_provider)" in
    github) github_get_issue "$number" ;;
    gitlab) gitlab_get_issue "$number" ;;
  esac
}

new_issue() {
  require_vcs_cli new_issue || return 1
  local title="$1" body="$2"
  case "$(get_provider)" in
    github) github_new_issue "$title" "$body" ;;
    gitlab) gitlab_new_issue "$title" "$body" ;;
  esac
}

# --- 既存issueの検索（起票前の重複チェック用。issue #68） ---------------------------------------

# 1キーワードあたりの取得件数。重複チェックの提示件数として現実的な上限。
SEARCH_ISSUES_LIMIT=20
# 1回の `search_issues` で受け付けるキーワードの最大数。キーワードごとにCLIを1回起動するため、
# 起動回数（＝ネットワークI/O）を有界にする目的で設ける。超過分は切り捨てるが、
# 無言では捨てず標準エラーへ通知する。
SEARCH_ISSUES_MAX_KEYWORDS=5

# 複数回の検索結果（正規化済みJSON配列）を1つの配列へまとめる純粋関数。
# `number` で重複排除し、番号の降順（新しいissueが先）に並べる。
# 外部の `gh`/`glab` を呼ばないため .claude/scripts/test/test_vcs_provider.sh から単体テストできる。
#
# JSONは引数ではなく**標準入力経由で**jqへ渡す。検索結果の件数・本文長は呼び出し側で保証できず、
# `--argjson` で渡すとコマンドライン長の上限に達して `jq: Argument list too long` で起動自体が
# 失敗しうるため（.claude/rules/shell-script-style.md「JSON操作」）。
#
# 引数が0個のときは `[]` を返す。`printf '%s\n' "$@"` は引数が無いと空行を1つ出力し、
# jqがパースエラーになるため、その前に打ち切る。
merge_issue_search_results() {
  if [ $# -eq 0 ]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "$@" | jq -c -s 'add // [] | unique_by(.number) | sort_by(.number) | reverse'
}

# キーワードで既存issueを検索し、`[{number, title, state, url}]` のJSON配列を返す。
# `issue-create` スキルが起票前の重複チェックに使う（issue #68）。
#
# - **closedのissueも対象に含める。** 過去に見送られた提案が再提出されるのを検知するため。
# - キーワードは最大 `SEARCH_ISSUES_MAX_KEYWORDS` 件。プロバイダ実装がキーワードごとに1回ずつ
#   検索し、結果を `merge_issue_search_results` で統合する（AND検索1回では取りこぼすため）。
# - キーワードの抽出そのものは**呼び出し側（AIエージェント）の責務**であり、この層では行わない。
#   日本語主体のissueから意味のある語を選ぶには形態素解析が要り、bashの文字種判定では
#   代替できないため（詳細・却下案:
#   .claude/docs/ddr/0033-issue起票前の重複チェックは検索をProvider層へ置きキーワード抽出はAIに委ねる.md）。
search_issues() {
  require_vcs_cli search_issues || return 1
  if [ $# -eq 0 ]; then
    echo "search_issues: 検索キーワードを1つ以上指定してください" >&2
    return 1
  fi
  if [ $# -gt "$SEARCH_ISSUES_MAX_KEYWORDS" ]; then
    printf 'search_issues: キーワードが%s件指定されましたが、先頭%s件のみを使います（残りは無視）\n' \
      "$#" "$SEARCH_ISSUES_MAX_KEYWORDS" >&2
    set -- "${@:1:$SEARCH_ISSUES_MAX_KEYWORDS}"
  fi
  case "$(get_provider)" in
    github) github_search_issues "$SEARCH_ISSUES_LIMIT" "$@" ;;
    gitlab) gitlab_search_issues "$SEARCH_ISSUES_LIMIT" "$@" ;;
  esac
}

new_draft_merge_request() {
  require_vcs_cli new_draft_merge_request || return 1
  local issue_number="$1" branch="$2" title="$3"
  local base_branch="${4:-$(get_workflow_config | jq -r '.defaultBaseBranch')}"
  case "$(get_provider)" in
    github) github_new_draft_merge_request "$issue_number" "$branch" "$base_branch" "$title" ;;
    gitlab) gitlab_new_draft_merge_request "$issue_number" "$branch" "$base_branch" "$title" ;;
  esac
}

get_mr_unresolved_comments() {
  require_vcs_cli get_mr_unresolved_comments || return 1
  local mr_number="$1" include_resolved="${2:-false}"
  case "$(get_provider)" in
    github) github_get_mr_unresolved_comments "$mr_number" "$include_resolved" ;;
    gitlab) gitlab_get_mr_unresolved_comments "$mr_number" "$include_resolved" ;;
  esac
}

# 指定したレビュースレッドに対応内容を返信する（スレッドの解決＝resolvedはレビュアー側の操作のため
# 行わない）。thread_idは get_mr_unresolved_comments の出力に含まれる threadId=... を使う。
add_mr_thread_reply() {
  require_vcs_cli add_mr_thread_reply || return 1
  local mr_number="$1" thread_id="$2" reply_body="$3"
  case "$(get_provider)" in
    github) github_add_mr_thread_reply "$mr_number" "$thread_id" "$reply_body" ;;
    gitlab) gitlab_add_mr_thread_reply "$mr_number" "$thread_id" "$reply_body" ;;
  esac
}

get_mr_for_branch() {
  require_vcs_cli get_mr_for_branch || return 1
  local branch="$1"
  case "$(get_provider)" in
    github) github_get_mr_for_branch "$branch" ;;
    gitlab) gitlab_get_mr_for_branch "$branch" ;;
  esac
}

set_mr_description() {
  require_vcs_cli set_mr_description || return 1
  local mr_number="$1" body_file="$2"
  case "$(get_provider)" in
    github) github_set_mr_description "$mr_number" "$body_file" ;;
    gitlab) gitlab_set_mr_description "$mr_number" "$body_file" ;;
  esac
}

# Draft PR/MRのDraft状態を解除し、レビュー・マージ可能な状態にする（flow-id 5-4。issue #61）。
# Draft作成側（new_draft_merge_request）に対応する解除側で、これが無かったため当時の flow-id 5-3 では
# AIエージェントが `gh pr ready` を直接呼ぶことになり、GitLab環境で動かず、CLI不在時の
# MCPフォールバック経路（require_vcs_cli / mcp_tool_hint）にも乗らなかった。
set_mr_ready() {
  require_vcs_cli set_mr_ready || return 1
  local mr_number="$1"
  case "$(get_provider)" in
    github) github_set_mr_ready "$mr_number" ;;
    gitlab) gitlab_set_mr_ready "$mr_number" ;;
  esac
}

# リポジトリの正規URL（フルパス）を取得する。`git remote get-url origin` の値を
# `repo_url_from_remote_url` で正規化して返す、**プロバイダ非依存**の関数（issue #44）。
#
# issue #13フォローアップの当初実装は `gh repo view --json url` / `glab repo view --output json`
# （`.web_url`）へディスパッチしていたが、実機で両者の戻り値がremote URLと `.git` サフィックスの
# 有無しか違わないことを確認したため、gitだけで解決できる差分としてプロバイダ依存を解消した。
# あわせて、pushのたびに走る `post-push-compact-prompt.sh` から外部CLIの起動（git bashで
# 約95ms/回）とAPI往復が1回ずつ無くなり、`gh`/`glab` 不在の環境（Claude Code on the web）でも
# CLI経路と同じ経路で動くようになる（issue #34で入れたMCP経路向けの分岐も不要になった）。
#
# DDR 0023 が却下したのは「MR/PRの**URL文字列**へsuffixを推測で付け足す」案であり、remote URLからの
# 導出はそれとは別物（推測ではなく、リポジトリの所在そのものを表す一次情報の変換）である。
# 正規URLと一致しないリスクケースの扱いは
# .claude/docs/ddr/0037-リポジトリURLはgh_glabではなくgit-remoteから導出する.md 参照。
get_repo_url() {
  repo_url_from_remote_url "$(git remote get-url origin)"
}

# MR/PRの「defaultブランチとの差分」を見れるURLを組み立てる（issue #13:
# レビュー依頼メッセージに含める参照リンク用）。`repo_url`は`get_repo_url`で取得したものを渡す。
get_mr_diff_url() {
  local repo_url="$1" base_branch="$2" head_branch="$3"
  case "$(get_provider)" in
    github) github_get_mr_diff_url "$repo_url" "$base_branch" "$head_branch" ;;
    gitlab) gitlab_get_mr_diff_url "$repo_url" "$base_branch" "$head_branch" ;;
  esac
}

# MR/PRの「前回push時点(from_sha)から今回push時点(to_sha)までの差分」を見れるURLを組み立てる
# （issue #13: レビュー指摘対応push時にレビュー依頼メッセージへ追加で含める参照リンク用）。
# `repo_url`は`get_repo_url`で取得したものを渡す。
get_mr_diff_since_url() {
  local repo_url="$1" from_sha="$2" to_sha="$3"
  case "$(get_provider)" in
    github) github_get_mr_diff_since_url "$repo_url" "$from_sha" "$to_sha" ;;
    gitlab) gitlab_get_mr_diff_since_url "$repo_url" "$from_sha" "$to_sha" ;;
  esac
}

# 特定ファイルの「そのref時点の本体」を開くblobページのURLを組み立てる（issue #42:
# レビュー依頼メッセージへ重点レビュー対象ファイルのリンクを含めるため）。`repo_url`は
# `get_repo_url` で取得したものを、`path` は `url_encode_path_to_reply` でencode済みのものを渡す。
get_blob_url() {
  local repo_url="$1" ref="$2" path="$3"
  case "$(get_provider)" in
    github) github_get_blob_url "$repo_url" "$ref" "$path" ;;
    gitlab) gitlab_get_blob_url "$repo_url" "$ref" "$path" ;;
  esac
}

# Compareページ内の特定ファイルの差分位置を指すアンカー付きURLを組み立てる（issue #42）。
# `compare_url` は `get_mr_diff_url` / `get_mr_diff_since_url` の戻り値を、`path_hash` は
# `hash_paths "$(get_diff_anchor_algo)" <path>` の結果を渡す。
get_diff_anchor_url() {
  local compare_url="$1" path_hash="$2"
  case "$(get_provider)" in
    github) github_get_diff_anchor_url "$compare_url" "$path_hash" ;;
    gitlab) gitlab_get_diff_anchor_url "$compare_url" "$path_hash" ;;
  esac
}

# 差分アンカーのハッシュ算出に使うアルゴリズム名（`sha256` / `sha1`）を返す（issue #42）。
# ハッシュの種類はプロバイダの非公開内部仕様であり、GitHubはパス文字列のsha256、GitLabはsha1。
get_diff_anchor_algo() {
  case "$(get_provider)" in
    github) github_diff_anchor_algo ;;
    gitlab) gitlab_diff_anchor_algo ;;
  esac
}

# パスをURLへ埋め込める形へpercent-encodeし、結果を `REPLY` へ返す（issue #42）。
# unreserved文字（`A-Za-z0-9-._~`）と、パス区切りである `/` はそのまま残し、それ以外は
# UTF-8のバイト単位で `%XX` へ変換する（日本語ファイル名・空白を含むパスへの対応）。
#
# 標準出力ではなく `REPLY` へ返すのは、変更ファイルの件数だけ繰り返し呼ばれるため
# （コマンド置換 `$(...)` はそのたびにサブシェルをforkする。
# `.claude/rules/shell-script-style.md`「外部プロセス起動のコスト」節）。
# `LC_ALL=C` をローカルに設定して `${s:i:1}` をバイト単位の切り出しにしている（ロケール依存で
# 文字単位になるとマルチバイト文字を `%XX` へ分解できないため）。
url_encode_path_to_reply() {
  local s="$1" out="" i c
  local LC_ALL=C
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._~/-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  REPLY="$out"
}

# 渡した各パス文字列のハッシュを、引数と同じ順序で1行ずつ標準出力へ返す（issue #42。
# 差分アンカー用）。ファイルの中身ではなく**パス文字列そのもの**のハッシュである点に注意。
#
# パスの件数に比例して `sha256sum` を起動しないよう、各パスを一時ファイルへ書き出して
# **1回**の呼び出しでまとめて計算する（`sha256sum`/`sha1sum` は引数の順序どおりに出力する）。
# 一時ファイル名は連番にしており、パスに改行・記号が含まれても影響を受けない
# （`.claude/rules/shell-script-style.md`「外部プロセス起動のコスト」節）。
hash_paths() {
  local algo="$1"
  shift
  [ "$#" -gt 0 ] || return 0
  local cmd
  case "$algo" in
    sha256) cmd="sha256sum" ;;
    sha1) cmd="sha1sum" ;;
    *) printf 'hash_paths: 未知のアルゴリズムです: %s\n' "$algo" >&2; return 1 ;;
  esac
  local tmpdir files=() i=0 p
  tmpdir="$(mktemp -d)"
  for p in "$@"; do
    i=$((i + 1))
    printf '%s' "$p" > "${tmpdir}/${i}"
    files+=("${tmpdir}/${i}")
  done
  "$cmd" "${files[@]}" | awk '{print $1}'
  rm -rf "$tmpdir"
}

# MRへ新規コメントを1件投稿する（スレッド返信ではなく、レビューでもない通常コメント。
# レビュー合否判定には影響しない）。呼び出し元想定: 対応工数レポート（post-push-usage-report.sh）。
add_mr_comment() {
  require_vcs_cli add_mr_comment || return 1
  local mr_number="$1" body_file="$2"
  case "$(get_provider)" in
    github) github_add_mr_comment "$mr_number" "$body_file" ;;
    gitlab) gitlab_add_mr_comment "$mr_number" "$body_file" ;;
  esac
}

# 任意のissueへ新規コメントを1件投稿する（flow-id 5-3: マージ前の関連issue通知。issue #86）。
# 宛先がPR/MRである `add_mr_comment` とは別関数である点に注意する。GitHub実装が `gh pr comment`
# であるためPR以外へは投げられず、「今回のMRが影響する他のissue」への通知に流用できなかった。
#
# 本文は**ファイル経由**で受け取る（`add_mr_comment` / `set_mr_description` と同じ）。
# コマンド文字列へ長文を埋め込むと、`git` と `push` が連続する語を含んだだけでpush検知hookが
# 誤発火するため（`.claude/rules/git-workflow.md`「push検知hookの誤検知」）。
#
# 投稿先・本文の決定と**人間の承認**は呼び出し側（`.claude/skills/issue-mr-flow/SKILL.md`
# 「マージ前の関連issue通知」節）の責務であり、この層では行わない
# （経緯: .claude/docs/ddr/0044-マージ前の関連issue通知はDraft解除の直前に置き投稿前の人間承認を必須にする.md）。
add_issue_comment() {
  require_vcs_cli add_issue_comment || return 1
  local issue_number="$1" body_file="$2"
  case "$(get_provider)" in
    github) github_add_issue_comment "$issue_number" "$body_file" ;;
    gitlab) gitlab_add_issue_comment "$issue_number" "$body_file" ;;
  esac
}

# baseとの差分（コミット）が無いブランチでは `gh pr create` / `glab mr create` が失敗するため
# （new_issue_branch直後など。.claude/docs/spec/issue-mr-workflow.md の既知の制約参照）、
# 空コミットを1つ積んでpushすることで回避する。呼び出し元（github_/gitlab_new_draft_merge_request）が
# 失敗を検知した後にこれを呼び、作成を1回だけリトライする。
add_empty_commit_for_draft_mr() {
  git commit --allow-empty -m "chore: Draft PR作成のための空コミット（baseとの差分が無いため）" >/dev/null
  git push >/dev/null
}

# issue番号・スラッグ生成用テキストから `.mrworkflow.json` の branchPrefixTemplate に沿った
# ブランチを作成しcheckout、リモートへpushする（flow-id 1-3: 「issueからMRとブランチを作る」
# 「作成したブランチをfetch, checkout」）。第2引数はslug化対象のテキストであり、生のissueタイトル
# である必要はない（呼び出し元が英語の意訳フレーズ等を渡してよい。`.claude/skills/issue-mr-flow/
# SKILL.md` の `start` サブコマンド参照。issue #22）。第3引数（省略可）でベースブランチを上書き
# できる。省略時は従来どおり `.mrworkflow.json` の `defaultBaseBranch` を使う（issue #15:
# `start` サブコマンドが `AskUserQuestion` で確認した結果を渡す用途）。
new_issue_branch() {
  local issue_number="$1" slug_source="$2"
  local config slug branch base_branch template
  config="$(get_workflow_config)"
  slug="$(to_slug "$slug_source")"
  base_branch="${3:-$(printf '%s' "$config" | jq -r '.defaultBaseBranch')}"
  template="$(printf '%s' "$config" | jq -r '.branchPrefixTemplate')"
  branch="${template//\{issue\}/$issue_number}"
  branch="${branch//\{slug\}/$slug}"

  git fetch origin "$base_branch" >/dev/null
  git switch -c "$branch" "origin/$base_branch" >/dev/null
  git push -u origin "$branch" >/dev/null

  printf '%s\n' "$branch"
}

# 新しいセッションで作業を再開するとき用（flow-id 1-3の再開版）。
# ローカルにブランチが無ければ origin から作成し、あれば最新化する。
sync_branch() {
  local branch="$1"
  git fetch origin
  if git branch --list "$branch" | grep -q .; then
    git checkout "$branch"
    git pull --ff-only origin "$branch"
  else
    git checkout -b "$branch" "origin/$branch"
  fi
}

# ブランチ名を branchPrefixTemplate に照らしてissue番号を抽出する（途中引き継ぎ対応のresumeで使用）。
# {issue}/{slug} を記号を含まないプレースホルダに置換してから正規表現エスケープすることで、
# テンプレートのリテラル部分だけを正しくエスケープしつつプレースホルダを正規表現化する。
# マッチした場合はissue番号をstdoutへ出力し終了コード0、マッチしなければ何も出力せず終了コード1を返す。
get_issue_number_from_branch() {
  local branch="${1:-$(git branch --show-current)}"
  local template tokenized escaped pattern
  template="$(get_workflow_config | jq -r '.branchPrefixTemplate')"
  tokenized="${template//\{issue\}/ZZISSUEZZ}"
  tokenized="${tokenized//\{slug\}/ZZSLUGZZ}"
  escaped="$(printf '%s' "$tokenized" | sed -E 's/[.[\*^$()+?{}|\\]/\\&/g')"
  pattern="${escaped//ZZISSUEZZ/([0-9]+)}"
  pattern="${pattern//ZZSLUGZZ/.+}"

  if [[ "$branch" =~ ^${pattern}$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# `git status --porcelain -z` の出力（標準入力）を「1行＝1つの実在するパス」へ変換する純粋関数。
# 改名・コピーされたエントリは**新パスのみ**を返す（旧パスは既に存在しないため捨てる。issue #115）。
#
# `-z` 形式を使う理由（行単位の `--porcelain` を `sed -E 's/^...//'` で削っていた旧実装の問題）:
# - 改名は行単位形式では `R  <旧パス> -> <新パス>` の1行になるため、先頭3文字（XY＋空白）を
#   落としても `<旧パス> -> <新パス>` という**どちらのパスとしても存在しない1行**が残る。
#   そのままファイル操作へ渡すと `No such file or directory` になる（issue #97の作業中に2回踏み、
#   2回とも目視で回避した。ASCIIのみのパスなら見逃していた可能性が高い）。
# - パス自体が ` -> ` を含みうる以上、行単位形式は本質的に曖昧で、区切りを一意に決められない。
# - `-z` 形式では改名エントリが `XY <新パス>\0<旧パス>\0` という**新パスが先**の2フィールドになり
#   （行単位形式とは順序が逆）、パスのクォートも行われないため、曖昧さなく分解できる。
# - コミット済み分（`git diff --name-only`）は改名を新パス1件として返すため、この問題は
#   未コミット分にのみ現れる。
#
# NUL区切りの出力はコマンド置換で受けられない（`.claude/rules/shell-script-style.md`
# 「コマンド置換とNULバイト」）。この関数がNULを吸収して改行区切りへ変換することで、呼び出し側は
# 従来どおり `$(...)` で結果を受け取れる。
porcelain_z_to_paths() {
  local entry status origin
  while IFS= read -r -d '' entry; do
    [ -n "$entry" ] || continue
    status="${entry:0:2}"
    printf '%s\n' "${entry:3}"
    # 改名（R）・コピー（C）は、インデックス側・作業ツリー側のどちらの桁に現れても、直後に
    # 旧パスのフィールドが続く（`R ` / `RM` / ` R` 等）。読み捨てて次のエントリへ進む。
    case "$status" in
      [RC]?|?[RC]) IFS= read -r -d '' origin || break ;;
    esac
  done
}

# 現在のブランチ固有（<defaultBaseBranch> には無い）の plans/worklog/reports ファイル一覧を返す
# （コミット済み差分＋作業ツリーの未コミット分をマージ・重複排除）。プロバイダ非依存。
# 出力は常に「1行＝1つの実在するパス」であり、`while IFS= read -r f` で回してそのままファイル
# 操作へ渡せる（改名の扱いは上記 `porcelain_z_to_paths` を参照。issue #115）。
#
# 注意（core.quotepath）: gitは既定（core.quotepath=true）で、非ASCII文字を含むパスを
# 8進エスケープ＋ダブルクォートで囲んだ形（例: "plans/\343\200\220..."）で出力する。
# 個別作業計画は `plans/【調査】〜.md` のように日本語を含む命名（issue #9）のため、既定のままだと
# 戻り値が人間にもスクリプトにも使えない文字列になる。`-c core.quotepath=false` を付けて
# 生のパスを出力させる（未コミット分は `--porcelain -z` のNUL区切り出力になったため元から影響を
# 受けないが、コミット済み分の `--name-only` は行単位出力のため明示指定が必要。両方に付けて
# 揃えている）。
get_branch_work_files() {
  local config plans_dir worklog_dir reports_dir base_branch committed working
  config="$(get_workflow_config)"
  plans_dir="$(printf '%s' "$config" | jq -r '.plansDir')"
  worklog_dir="$(printf '%s' "$config" | jq -r '.worklogDir')"
  reports_dir="$(printf '%s' "$config" | jq -r '.reportsDir')"
  base_branch="$(printf '%s' "$config" | jq -r '.defaultBaseBranch')"

  committed="$(git -c core.quotepath=false diff --name-only "origin/${base_branch}...HEAD" -- "$plans_dir" "$worklog_dir" "$reports_dir" 2>/dev/null || true)"
  working="$(git -c core.quotepath=false status --porcelain -z -- "$plans_dir" "$worklog_dir" "$reports_dir" | porcelain_z_to_paths)"

  printf '%s\n%s\n' "$committed" "$working" | sed '/^$/d' | sort -u
}

# --- 敵対的レビュー: インラインコメントの投稿（issue #77） ---

# インラインで示せなかった指摘の配列（標準入力）から、レビュー本文（サマリ）を組み立てる
# 純粋関数。プロバイダに依存しないため Provider.sh 側に置く。
# 指摘が0件でも本文は空にしない（GitHubのレビューは本文が空だと意味を成さないため）。
format_findings_summary() {
  jq -r '
    "Claude Codeより: 敵対的レビュー（AIによる自動レビュー）の結果です。\n"
    + (
        if (length == 0) then
          "\nすべての指摘をインラインコメントで示しています。"
        else
          "\n### インラインで示せなかった指摘（" + (length | tostring) + "件）\n\n"
          + "対象がdiffに含まれないため、行を指定できませんでした。\n\n"
          + ([
              .[]
              | "- **[" + (.severity // "minor") + " / 確度: " + (.confidence // "medium")
                + (if .category then " / " + .category else "" end) + "]** `"
                + (.path // "(パス不明)") + "` — " + (.title // "")
                + "\n" + ((.body // "") | split("\n") | map("  " + .) | join("\n"))
            ] | join("\n"))
        end
      )
  ' | tr -d '\r'
}

# findings JSONファイルの指摘を、MRへインラインコメントとして投稿する。
# findingsは必ずファイル経由で渡す（jqの引数長上限と、コマンド文字列へのhook誤検知語の
# 混入を避けるため。.claude/rules/shell-script-style.md）。
add_mr_inline_comments() {
  require_vcs_cli add_mr_inline_comments || return 1
  local mr_number="$1" findings_file="$2"
  case "$(get_provider)" in
    github) github_add_mr_inline_comments "$mr_number" "$findings_file" ;;
    gitlab) gitlab_add_mr_inline_comments "$mr_number" "$findings_file" ;;
  esac
}
