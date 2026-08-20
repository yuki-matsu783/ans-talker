#!/usr/bin/env bash
# .claude/scripts/src/vcs/{Github,Gitlab,Provider}.sh の純粋ロジック（`gh`/`glab`呼び出しを
# 伴わないURL組み立て・JSON整形・文字列判定関数）の単体テスト。issue #13対応で追加した
# `github_get_compare_url` / `github_get_mr_diff_url` / `github_get_mr_diff_since_url` /
# `gitlab_get_compare_url` / `gitlab_get_mr_diff_url` / `gitlab_get_mr_diff_since_url` が対象。
# Provider.sh経由のディスパッチ（`get_mr_diff_url`等）は外部コマンド・`git remote get-url origin`
# に依存し純粋ではないため対象外（Github.sh/Gitlab.sh の関数を直接呼ぶ）。
# issue #44で `get_repo_url` をプロバイダ非依存化した際に切り出した `repo_url_from_remote_url`
# （remote URLからリポジトリの正規URLを導出）も対象。`get_repo_url` 本体は
# `git remote get-url origin` を呼ぶため対象外で、URL文字列を受け取る純粋関数側をテストしている。
# issue #48対応で追加した `gitlab_format_discussion_notes`（discussions JSONの整形）も対象。
# issue #45対応で追加した `provider_from_remote_url`（remote URLのホスト部からプロバイダを判定）も
# 対象。`get_provider` 本体は `git remote get-url origin` を呼ぶため対象外で、URL文字列を
# 受け取る純粋関数側を切り出してテストしている。
# あわせてissue #34で追加した `parse_repo_slug`（リモートURLのパース）と `mcp_tool_hint`
# （CLI不在時に提示するMCPツール名）も対象とする。後者は `get_provider` をテスト内で上書きして
# プロバイダを固定する。
# issue #42で追加した `github_get_blob_url` / `github_get_diff_anchor_url` /
# `github_diff_anchor_algo` / `gitlab_get_blob_url` / `gitlab_get_diff_anchor_url` /
# `gitlab_diff_anchor_algo` / `gitlab_get_mr_url` / `gitlab_get_note_url` / `url_encode_path_to_reply`
# と、`hash_paths`（差分アンカー用にパス文字列のハッシュをまとめて計算する）も対象。
# `hash_paths` だけは `sha256sum`/`sha1sum` を起動するが、`gh`/`glab` に依存せず入力から出力が
# 一意に決まるため単体テストの対象に含めている。
# issue #86で追加した `add_issue_comment`（任意のissueへのコメント投稿）は `gh`/`glab` を呼ぶため
# 関数本体は対象外で、`mcp_tool_hint` が返す代替ツール名のみを対象とする。
# issue #68で追加した `github_normalize_issue_search_results` /
# `gitlab_normalize_issue_search_results`（CLIのissue検索出力を共通形式へ正規化）と
# `merge_issue_search_results`（複数キーワードぶんの結果を重複排除して統合）も対象。
# issue #121で追加した `gitlab_summary_post_kind`
# （サマリを `discussions`（スレッド）と `notes`（単発note）のどちらで投稿するかの判定）も対象。
# `gitlab_add_mr_thread` 本体は `glab` を呼ぶため対象外で、投稿先を決める純粋関数側をテストする。
# issue #115で追加した `porcelain_z_to_paths`（`git status --porcelain -z` の出力を1行1パスへ
# 変換し、改名・コピーの旧パスを捨てる）も対象。`get_branch_work_files` 本体は `git` を起動する
# ため対象外で、その未コミット分の解釈を担う純粋関数側を切り出してテストしている。
# 規約: passed=N failures=N を標準出力へ出し、失敗があれば終了コード1
#       （.claude/rules/shell-script-style.md「テスト」）。
# 実行: bash .claude/scripts/test/test_vcs_provider.sh
set -euo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" == "${BASH_SOURCE[0]}" ]] && script_dir="."
repo_root="$(cd "$script_dir/../../.." && pwd)"

# shellcheck source=../../../.claude/scripts/src/vcs/Github.sh
source "$repo_root/.claude/scripts/src/vcs/Github.sh"
# shellcheck source=../../../.claude/scripts/src/vcs/Gitlab.sh
source "$repo_root/.claude/scripts/src/vcs/Gitlab.sh"
# shellcheck source=../../../.claude/scripts/src/vcs/Provider.sh
source "$repo_root/.claude/scripts/src/vcs/Provider.sh"

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

# --- github_get_compare_url / github_get_mr_diff_url / github_get_mr_diff_since_url -------

assert_eq "github_get_compare_url: リポジトリURLに/compare/<from>...<to>を付与" \
  "https://github.com/o/r/compare/main...aaa111" \
  "$(github_get_compare_url "https://github.com/o/r" "main" "aaa111")"

assert_eq "github_get_mr_diff_url: defaultブランチとの比較URL（ブランチ名指定）" \
  "https://github.com/o/r/compare/main...feature-13-x" \
  "$(github_get_mr_diff_url "https://github.com/o/r" "main" "feature-13-x")"

assert_eq "github_get_mr_diff_since_url: 前回push〜今回pushのSHA範囲の比較URL" \
  "https://github.com/o/r/compare/aaa111...bbb222" \
  "$(github_get_mr_diff_since_url "https://github.com/o/r" "aaa111" "bbb222")"

# --- gitlab_get_compare_url / gitlab_get_mr_diff_url / gitlab_get_mr_diff_since_url --------

assert_eq "gitlab_get_compare_url: リポジトリURLに/-/compare/<from>...<to>を付与" \
  "https://gitlab.example.com/o/r/-/compare/main...aaa111" \
  "$(gitlab_get_compare_url "https://gitlab.example.com/o/r" "main" "aaa111")"

assert_eq "gitlab_get_mr_diff_url: defaultブランチとの比較URL（ブランチ名指定）" \
  "https://gitlab.example.com/o/r/-/compare/main...feature-13-x" \
  "$(gitlab_get_mr_diff_url "https://gitlab.example.com/o/r" "main" "feature-13-x")"

assert_eq "gitlab_get_mr_diff_since_url: 前回push〜今回pushのSHA範囲の比較URL" \
  "https://gitlab.example.com/o/r/-/compare/aaa111...bbb222" \
  "$(gitlab_get_mr_diff_since_url "https://gitlab.example.com/o/r" "aaa111" "bbb222")"

# --- gitlab_format_discussion_notes（issue #48） -------------------------------------------
# GitLabのdiscussions APIは「説明を変更した」等の操作履歴を、レビューコメントと同じ配列で
# `system: true` のnoteとして返す。これがレビュー往復の完了判定を狂わせないことを確認する。
# フィクスチャはローカルGitLab CE 18.5.4の実レスポンス形状に合わせている
# （`changed the description` は実機で実際に観測されたシステムノートのbody）。
gitlab_discussions_fixture='[
  {"id":"d1","individual_note":false,"notes":[
    {"id":1,"body":"ここは修正してください","author":{"username":"reviewer"},
     "system":false,"resolvable":true,"resolved":false}]},
  {"id":"d2","individual_note":false,"notes":[
    {"id":2,"body":"対応済みの指摘","author":{"username":"reviewer"},
     "system":false,"resolvable":true,"resolved":true}]},
  {"id":"d3","individual_note":true,"notes":[
    {"id":3,"body":"changed the description","author":{"username":"root"},
     "system":true,"resolvable":false}]},
  {"id":"d4","individual_note":true,"notes":[
    {"id":4,"body":"通常コメント","author":{"username":"root"},
     "system":false,"resolvable":false}]}
]'

assert_eq "gitlab_format_discussion_notes: 既定では未解決のみ返し、システムノートと解決済みを除外する" \
  "[unresolved threadId=d1] reviewer: ここは修正してください

[unresolved threadId=d4] root: 通常コメント" \
  "$(gitlab_format_discussion_notes "$gitlab_discussions_fixture")"

assert_eq "gitlab_format_discussion_notes: include_resolved=trueでは解決済みを含むがシステムノートは除外する" \
  "[unresolved threadId=d1] reviewer: ここは修正してください

[resolved threadId=d2] reviewer: 対応済みの指摘

[unresolved threadId=d4] root: 通常コメント" \
  "$(gitlab_format_discussion_notes "$gitlab_discussions_fixture" true)"

assert_eq "gitlab_format_discussion_notes: システムノートのbodyは全件取得時も出力に現れない" \
  "0" \
  "$(gitlab_format_discussion_notes "$gitlab_discussions_fixture" true | grep -c 'changed the description' || true)"

# issue #42: 第3引数にMRのURLを渡すと、各noteの公式パーマリンクを url= として行に含める。
assert_eq "gitlab_format_discussion_notes: mr_urlを渡すとnoteのパーマリンクをurl=として含める" \
  "[unresolved threadId=d1 url=https://gitlab.example.com/o/r/-/merge_requests/42#note_1] reviewer: ここは修正してください

[unresolved threadId=d4 url=https://gitlab.example.com/o/r/-/merge_requests/42#note_4] root: 通常コメント" \
  "$(gitlab_format_discussion_notes "$gitlab_discussions_fixture" false \
    "https://gitlab.example.com/o/r/-/merge_requests/42")"

assert_eq "gitlab_format_discussion_notes: mr_urlが空ならurl=は付かない（従来どおりの出力）" \
  "$(gitlab_format_discussion_notes "$gitlab_discussions_fixture")" \
  "$(gitlab_format_discussion_notes "$gitlab_discussions_fixture" false "")"

# resolvableでないnote（individual_note等）は resolved 扱いにせず常に含める。
assert_eq "gitlab_format_discussion_notes: resolvableでないnoteはunresolvedとして扱う" \
  "[unresolved threadId=d4] root: 通常コメント" \
  "$(gitlab_format_discussion_notes '[{"id":"d4","individual_note":true,"notes":[{"id":4,"body":"通常コメント","author":{"username":"root"},"system":false,"resolvable":false}]}]')"

# Windowsネイティブjqは出力行末にCRを付与するため、関数側で除去している
# （.claude/rules/shell-script-style.md「文字コード」）。CRの検査はバイト数比較で行う
# （`grep -c $'\r'` は環境によって空パターン扱いになり全行にマッチするため使わない）。
gitlab_notes_output="$(gitlab_format_discussion_notes "$gitlab_discussions_fixture" true)"
assert_eq "gitlab_format_discussion_notes: 出力にCRが混入しない" \
  "$(printf '%s' "$gitlab_notes_output" | wc -c)" \
  "$(printf '%s' "$gitlab_notes_output" | tr -d '\r' | wc -c)"

# --- parse_repo_slug / mcp_tool_hint（issue #34: gh/glab CLI不在時のMCPフォールバック） -------
#
# `parse_repo_slug` はリモートURL文字列だけを入力とする純粋関数のためそのままテストできる。
# `mcp_tool_hint` は内部で `get_provider`（`git remote get-url origin`）を呼ぶため、テスト内で
# `get_provider` を上書きしてプロバイダを固定する（冒頭で `Provider.sh` をsource済みのため、
# ここでの再定義が元の定義を差し替える）。
#
# 注意: この上書きは以降のテスト全体に効く。`get_provider` に依存するテストをこれより後ろへ
# 追加しないこと（issue #45で追加した `provider_from_remote_url` のテストは `get_provider` を
# 呼ばないため影響を受けない）。

assert_eq "parse_repo_slug: https形式（.git付き）" \
  "github.com|o|r|o/r|https://github.com/o/r" \
  "$(parse_repo_slug "https://github.com/o/r.git" | jq -r '[.host, .owner, .repo, .path, .url] | join("|")')"

assert_eq "parse_repo_slug: https形式（.git無し・末尾スラッシュ）" \
  "github.com|o|r|o/r|https://github.com/o/r" \
  "$(parse_repo_slug "https://github.com/o/r/" | jq -r '[.host, .owner, .repo, .path, .url] | join("|")')"

assert_eq "parse_repo_slug: ssh(scp形式)" \
  "github.com|o|r|o/r|https://github.com/o/r" \
  "$(parse_repo_slug "git@github.com:o/r.git" | jq -r '[.host, .owner, .repo, .path, .url] | join("|")')"

assert_eq "parse_repo_slug: ssh://形式" \
  "github.com|o|r|o/r|https://github.com/o/r" \
  "$(parse_repo_slug "ssh://git@github.com/o/r.git" | jq -r '[.host, .owner, .repo, .path, .url] | join("|")')"

assert_eq "parse_repo_slug: ssh://形式（ポート付き）" \
  "ghe.example.com|o|r|o/r|https://ghe.example.com/o/r" \
  "$(parse_repo_slug "ssh://git@ghe.example.com:2222/o/r.git" | jq -r '[.host, .owner, .repo, .path, .url] | join("|")')"

assert_eq "parse_repo_slug: GitLabのネストしたnamespaceはownerにグループ階層が入る" \
  "gitlab.example.com|g/sub|r|g/sub/r|https://gitlab.example.com/g/sub/r" \
  "$(parse_repo_slug "https://gitlab.example.com/g/sub/r.git" | jq -r '[.host, .owner, .repo, .path, .url] | join("|")')"

get_provider() { printf 'github\n'; }

assert_eq "mcp_tool_hint: get_issue（GitHub）" \
  "mcp__github__issue_read (method=\"get\", owner, repo, issue_number)" \
  "$(mcp_tool_hint get_issue)"

assert_eq "mcp_tool_hint: set_mr_description（GitHub）" \
  "mcp__github__update_pull_request (owner, repo, pullNumber, body=ファイル内容)" \
  "$(mcp_tool_hint set_mr_description)"

assert_eq "mcp_tool_hint: search_issues（GitHub。issue #68）" \
  "mcp__github__search_issues (query, owner, repo)" \
  "$(mcp_tool_hint search_issues)"

# issue #61で追加したDraft解除の関数。`set_mr_description` と同じ `update_pull_request` を使うが、
# 渡す引数が `body` ではなく `draft=false`（＝ready for review）である点が異なる
assert_eq "mcp_tool_hint: set_mr_ready（GitHub）" \
  "mcp__github__update_pull_request (owner, repo, pullNumber, draft=false)" \
  "$(mcp_tool_hint set_mr_ready)"

# issue #86で追加した関連issue通知の関数。`add_mr_comment` と同じ
# `mcp__github__add_issue_comment` を使うが、`issue_number` へ渡すのがPR番号ではなく
# **通知先のissue番号**である点が違うため、その差分がヒント文に出ることを固定する
assert_eq "mcp_tool_hint: add_issue_comment（GitHub。issue #86）" \
  "mcp__github__add_issue_comment (owner, repo, issue_number=通知先issue番号, body=ファイル内容)" \
  "$(mcp_tool_hint add_issue_comment)"

assert_eq "mcp_tool_hint: add_mr_comment はPR番号を渡す旨のまま（add_issue_commentと混同しない）" \
  "mcp__github__add_issue_comment (owner, repo, issue_number=PR番号, body=ファイル内容)" \
  "$(mcp_tool_hint add_mr_comment)"

assert_eq "mcp_tool_hint: 未知の関数名でも空にならずSKILL.mdの対応表へ誘導する" \
  "対応するMCPツールは .claude/skills/issue-mr-flow/SKILL.md の対応表を参照" \
  "$(mcp_tool_hint unknown_function)"

get_provider() { printf 'gitlab\n'; }

assert_eq "mcp_tool_hint: GitLabは対象外である旨を返す" \
  "GitLab向けのMCPフォールバックは対象外です（DDR 0027）。glab CLIをインストール・認証してください" \
  "$(mcp_tool_hint get_issue)"


# --- provider_from_remote_url（issue #45） ------------------------------------------------
# remote URLの「ホスト部」でプロバイダを判定する純粋関数。ホスト名に `github` を含めばGitHub、
# それ以外はGitLabとみなす（ホスト名に `gitlab` を含まないself-hosted GitLabを弾かないため）。
# `aslead` は社内GitLabの明示ケースでGitHub判定より先に評価される。

assert_eq "provider_from_remote_url: github.com（https）" \
  "github" "$(provider_from_remote_url 'https://github.com/foo/bar.git')"

assert_eq "provider_from_remote_url: github.com（scp形式）" \
  "github" "$(provider_from_remote_url 'git@github.com:foo/bar.git')"

# GHEは慣習的にホスト名へ `github` を含むため、GitLab扱いにしない
assert_eq "provider_from_remote_url: GHE（github.example.com）" \
  "github" "$(provider_from_remote_url 'https://github.example.com/foo/bar.git')"

assert_eq "provider_from_remote_url: gitlab.com（https）" \
  "gitlab" "$(provider_from_remote_url 'https://gitlab.com/foo/bar.git')"

assert_eq "provider_from_remote_url: gitlab.example.co.jp" \
  "gitlab" "$(provider_from_remote_url 'https://gitlab.example.co.jp/foo/bar.git')"

# 以下3件がissue #45の受け入れ条件（ホスト名に `gitlab` を含まないself-hosted GitLab）
assert_eq "provider_from_remote_url: ホスト名にgitlabを含まないself-hosted（scp形式）" \
  "gitlab" "$(provider_from_remote_url 'git@git.example.co.jp:foo/bar.git')"

assert_eq "provider_from_remote_url: localhost:8929" \
  "gitlab" "$(provider_from_remote_url 'http://localhost:8929/root/demo.git')"

assert_eq "provider_from_remote_url: 127.0.0.1:8929" \
  "gitlab" "$(provider_from_remote_url 'http://127.0.0.1:8929/root/demo.git')"

assert_eq "provider_from_remote_url: ポート付きssh形式" \
  "gitlab" "$(provider_from_remote_url 'ssh://git@gitlab.example.com:2222/foo/bar.git')"

# 旧実装はURL文字列全体へ `*github.com*` を先にマッチさせていたため、パスに `github` を含む
# GitLab URLを `github` と誤判定していた（回帰テスト）
assert_eq "provider_from_remote_url: パスにgithubを含むGitLab URL" \
  "gitlab" "$(provider_from_remote_url 'https://gitlab.com/github-mirror/x.git')"

# パス→認証情報→ポートの順に除去する（逆順だとパス中の `@` にマッチしてホスト抽出が壊れる）
assert_eq "provider_from_remote_url: パスに@を含む（抽出順序の検証）" \
  "gitlab" "$(provider_from_remote_url 'https://user@gitlab.com:8080/foo/b@r.git')"

assert_eq "provider_from_remote_url: 社内GitLab（aslead）" \
  "gitlab" "$(provider_from_remote_url 'https://aslead.example.co.jp/foo/bar.git')"

assert_eq "provider_from_remote_url: 社内GitLab（aslead・scp形式）" \
  "gitlab" "$(provider_from_remote_url 'git@aslead-git.corp.local:foo/bar.git')"

# `aslead` の判定を `github` より前に置いているため、両方を含むホストはGitLabになる
assert_eq "provider_from_remote_url: asleadがgithubより優先される" \
  "gitlab" "$(provider_from_remote_url 'https://github.aslead.example.com/foo/bar.git')"

# ホスト名が空のときだけエラー（終了コード1）にする。`set -e` 配下でも確実に終了コードを
# 拾えるよう、`if` の条件式（-e が一時停止される文脈）で判定する
# （.claude/rules/shell-script-style.md「エラー方針」）。
if provider_from_remote_url 'https://' >/dev/null 2>&1; then
  empty_host_status=0
else
  empty_host_status=1
fi
assert_eq "provider_from_remote_url: ホスト名が空なら終了コード1" \
  "1" "$empty_host_status"

# --- split_remote_url ---------------------------------------------------------------------
#
# remote URLをホスト部とパス部へ分解する純粋関数（issue #55）。`provider_from_remote_url` と
# `parse_repo_slug` が共有する土台であり、両者の既存テスト（21件）が引き続き通ることが
# 「共通化しても振る舞いが変わっていない」ことの主たる根拠になる。
#
# 結果はグローバル変数 `REPLY_HOST` / `REPLY_PATH` へ返るため、パイプ（右辺がサブシェルになり
# 代入が呼び出し元へ伝わらない）ではなく直接呼ぶ
# （.claude/rules/shell-script-style.md「`REPLY` へ返す関数はパイプではなく…」）。

split_remote_url 'https://github.com/o/r.git'
assert_eq "split_remote_url: https形式" "github.com|o/r" "$REPLY_HOST|$REPLY_PATH"

split_remote_url 'git@github.com:o/r.git'
assert_eq "split_remote_url: scp形式（:の後ろはパス）" "github.com|o/r" "$REPLY_HOST|$REPLY_PATH"

split_remote_url 'ssh://git@ghe.example.com:2222/o/r.git'
assert_eq "split_remote_url: ポート付きssh（:の後ろは数字＝ポート）" \
  "ghe.example.com|o/r" "$REPLY_HOST|$REPLY_PATH"

# 認証情報 user@ の除去がパス中の `@` へ誤爆しないこと（最初の `/` より前だけを見て判定する）
split_remote_url 'https://user@gitlab.com:8080/foo/b@r.git'
assert_eq "split_remote_url: パスに@を含む" "gitlab.com|foo/b@r" "$REPLY_HOST|$REPLY_PATH"

# ホストのみ小文字化し、パス（owner/repo）の大文字は保つ。`parse_repo_slug` の唯一の
# 振る舞い変更（issue #55）を明示的に固定する
split_remote_url 'https://GitHub.COM/O/R.git'
assert_eq "split_remote_url: ホストは小文字化・パスは保つ" "github.com|O/R" "$REPLY_HOST|$REPLY_PATH"

split_remote_url 'https://github.com'
assert_eq "split_remote_url: パス無し" "github.com|" "$REPLY_HOST|$REPLY_PATH"

# GitLabのネストしたnamespace（group/subgroup/repo）
split_remote_url 'https://gitlab.example.com/g/sub/r.git'
assert_eq "split_remote_url: ネストしたnamespace" \
  "gitlab.example.com|g/sub/r" "$REPLY_HOST|$REPLY_PATH"

# ホスト名が取れなくても失敗させない（エラーにするかは呼び出し側の判断に委ねる）
split_remote_url 'https://'
assert_eq "split_remote_url: ホスト名が空でも失敗しない" "|" "$REPLY_HOST|$REPLY_PATH"

# scheme・ポートも返す（issue #44。`repo_url_from_remote_url` がWeb URLを組み立てる際に、
# 「httpは維持する」「ポートはhttp/httpsのときだけ引き継ぐ」を判断するために使う）
split_remote_url 'https://gitlab.example.com:8443/o/r.git'
assert_eq "split_remote_url: httpsのschemeとポート" \
  "https|8443" "$REPLY_SCHEME|$REPLY_PORT"

split_remote_url 'ssh://git@ghe.example.com:2222/o/r.git'
assert_eq "split_remote_url: ssh://のschemeとポート" "ssh|2222" "$REPLY_SCHEME|$REPLY_PORT"

# scp形式は `://` を持たずポートも表現できない
split_remote_url 'git@github.com:o/r.git'
assert_eq "split_remote_url: scp形式はscheme・ポートとも空" "|" "$REPLY_SCHEME|$REPLY_PORT"

split_remote_url 'https://github.com/o/r.git'
assert_eq "split_remote_url: ポート指定が無ければ空" "https|" "$REPLY_SCHEME|$REPLY_PORT"

# schemeは小文字化する（ホスト名と同じくURLの正規化として安全）
split_remote_url 'HTTPS://github.com/o/r.git'
assert_eq "split_remote_url: schemeは小文字化" "https|github.com" "$REPLY_SCHEME|$REPLY_HOST"

# --- repo_url_from_remote_url（issue #44: リポジトリURLをgit remoteから導出） ---------------
#
# `gh repo view --json url` / `glab repo view --output json`（`.web_url`）の代わりに、
# remote URLの正規化だけでリポジトリの正規URLを得る純粋関数。CLI・ネットワークに依存しないため
# そのままテストできる。

assert_eq "repo_url_from_remote_url: https形式（.git付き）" \
  "https://github.com/o/r" \
  "$(repo_url_from_remote_url 'https://github.com/o/r.git')"

assert_eq "repo_url_from_remote_url: https形式（.git無し）" \
  "https://github.com/o/r" \
  "$(repo_url_from_remote_url 'https://github.com/o/r')"

assert_eq "repo_url_from_remote_url: 末尾スラッシュを除去" \
  "https://github.com/o/r" \
  "$(repo_url_from_remote_url 'https://github.com/o/r/')"

assert_eq "repo_url_from_remote_url: scp形式SSHはhttpsへ変換" \
  "https://github.com/o/r" \
  "$(repo_url_from_remote_url 'git@github.com:o/r.git')"

assert_eq "repo_url_from_remote_url: ssh://形式もhttpsへ変換" \
  "https://github.com/o/r" \
  "$(repo_url_from_remote_url 'ssh://git@github.com/o/r.git')"

# 本リポジトリの実際のremote URL。`gh repo view --json url --jq '.url'` の出力と一致すること
# （issue #44の受け入れ条件。実機で確認済み）
assert_eq "repo_url_from_remote_url: 本リポジトリのremote URL" \
  "https://github.com/yuki-matsu783/MR-driven-workflow" \
  "$(repo_url_from_remote_url 'https://github.com/yuki-matsu783/MR-driven-workflow.git')"

# ホスト名は小文字化し、パス（owner/repo）の大文字は保つ（`split_remote_url` の規則をそのまま継ぐ）
assert_eq "repo_url_from_remote_url: ホストは小文字化・パスは保つ" \
  "https://github.com/O/R" \
  "$(repo_url_from_remote_url 'https://GitHub.COM/O/R.git')"

# GitLabのネストしたnamespaceはパスをそのまま保つ
assert_eq "repo_url_from_remote_url: ネストしたnamespace" \
  "https://gitlab.example.com/g/sub/r" \
  "$(repo_url_from_remote_url 'https://gitlab.example.com/g/sub/r.git')"

# SSHのポートはWeb UIのポートではないため引き継がない（引き継ぐとリンクが壊れる）
assert_eq "repo_url_from_remote_url: ssh://のポートは引き継がない" \
  "https://ghe.example.com/o/r" \
  "$(repo_url_from_remote_url 'ssh://git@ghe.example.com:2222/o/r.git')"

# http/httpsのポートはWeb UIのポートなので引き継ぐ（self-hosted GitLabのdocker構成等）
assert_eq "repo_url_from_remote_url: httpsのポートは引き継ぐ" \
  "https://gitlab.example.com:8443/o/r" \
  "$(repo_url_from_remote_url 'https://gitlab.example.com:8443/o/r.git')"

# plain httpのself-hosted GitLabは http のままにする（httpsへ寄せるとリンクが壊れる）
assert_eq "repo_url_from_remote_url: httpはhttpのまま・ポートも保つ" \
  "http://localhost:8929/g/r" \
  "$(repo_url_from_remote_url 'http://localhost:8929/g/r.git')"

# 認証情報 user@ は落とす（パス中の `@` へ誤爆しないことは split_remote_url 側でも固定済み）
assert_eq "repo_url_from_remote_url: 認証情報は落とす" \
  "https://gitlab.com:8080/foo/b@r" \
  "$(repo_url_from_remote_url 'https://user@gitlab.com:8080/foo/b@r.git')"

# ホスト・パスが取れない入力は `https:///` のような壊れたURLを返さず失敗させる。
# 終了コードの検査は `$(func; echo $?)` ではなく `if` で受ける
# （.claude/rules/shell-script-style.md「テスト」）
if repo_url_from_remote_url 'https://' >/dev/null 2>&1; then
  empty_repo_url_status=0
else
  empty_repo_url_status=1
fi
assert_eq "repo_url_from_remote_url: ホスト名が空なら終了コード1" "1" "$empty_repo_url_status"

if repo_url_from_remote_url 'https://github.com' >/dev/null 2>&1; then
  no_path_status=0
else
  no_path_status=1
fi
assert_eq "repo_url_from_remote_url: パスが空なら終了コード1" "1" "$no_path_status"

# `parse_repo_slug` の `.url` は同じ組み立て規則を共有する（両者が食い違わないこと。issue #44）
assert_eq "parse_repo_slug: .url は repo_url_from_remote_url と一致する（scp形式）" \
  "$(repo_url_from_remote_url 'git@github.com:o/r.git')" \
  "$(parse_repo_slug 'git@github.com:o/r.git' | jq -r '.url')"

assert_eq "parse_repo_slug: .url は repo_url_from_remote_url と一致する（http・ポート付き）" \
  "$(repo_url_from_remote_url 'http://localhost:8929/g/r.git')" \
  "$(parse_repo_slug 'http://localhost:8929/g/r.git' | jq -r '.url')"

# --- issue検索結果の正規化・統合（issue #68: 起票前の重複チェック） ------------------------
# `github_search_issues` / `gitlab_search_issues` / `search_issues` 本体は `gh`/`glab` と
# `get_provider` に依存するため対象外とし、CLI出力を受け取るだけの純粋関数
# （`*_normalize_issue_search_results`）と、その結果を統合する `merge_issue_search_results` を
# テストする（`gitlab_format_discussion_notes` と同じ切り出し方）。
#
# キーワード抽出の関数は実装していないため、その単体テストも存在しない（抽出は
# `issue-create` スキル側でAIエージェントが行う。理由:
# .claude/docs/ddr/0033-issue起票前の重複チェックは検索をProvider層へ置きキーワード抽出はAIに委ねる.md）。

# GitHub CLIの `OPEN`/`CLOSED` を小文字へ揃え、キーを number/title/state/url に正規化する
assert_eq "github_normalize_issue_search_results: stateを小文字化しキーを揃える" \
  '[{"number":68,"title":"重複チェック","state":"open","url":"https://github.com/o/r/issues/68"},{"number":5,"title":"旧提案","state":"closed","url":"https://github.com/o/r/issues/5"}]' \
  "$(github_normalize_issue_search_results '[{"number":68,"title":"重複チェック","state":"OPEN","url":"https://github.com/o/r/issues/68"},{"number":5,"title":"旧提案","state":"CLOSED","url":"https://github.com/o/r/issues/5"}]')"

assert_eq "github_normalize_issue_search_results: 該当0件は空配列のまま" \
  '[]' \
  "$(github_normalize_issue_search_results '[]')"

# GitLabは iid / web_url / opened というキー・値を返すため読み替える
assert_eq "gitlab_normalize_issue_search_results: iid・web_url・openedを読み替える" \
  '[{"number":7,"title":"検索関数の追加","state":"open","url":"https://gitlab.example.com/g/r/-/issues/7"}]' \
  "$(gitlab_normalize_issue_search_results '[{"iid":7,"title":"検索関数の追加","state":"opened","web_url":"https://gitlab.example.com/g/r/-/issues/7"}]')"

assert_eq "gitlab_normalize_issue_search_results: closedはそのまま" \
  '[{"number":3,"title":"x","state":"closed","url":"https://gitlab.example.com/g/r/-/issues/3"}]' \
  "$(gitlab_normalize_issue_search_results '[{"iid":3,"title":"x","state":"closed","web_url":"https://gitlab.example.com/g/r/-/issues/3"}]')"

# 複数キーワードぶんの検索結果を、numberで重複排除しつつ番号の降順で統合する
assert_eq "merge_issue_search_results: 連結・重複排除・番号の降順" \
  '[{"number":68,"title":"b","state":"open","url":"u68"},{"number":12,"title":"c","state":"closed","url":"u12"},{"number":5,"title":"a","state":"open","url":"u5"}]' \
  "$(merge_issue_search_results \
    '[{"number":5,"title":"a","state":"open","url":"u5"},{"number":68,"title":"b","state":"open","url":"u68"}]' \
    '[{"number":68,"title":"b","state":"open","url":"u68"},{"number":12,"title":"c","state":"closed","url":"u12"}]')"

# 引数0個で `printf '%s\n' "$@"` の空行がjqのパースエラーになるのを防いでいること
assert_eq "merge_issue_search_results: 引数0個なら空配列" \
  '[]' \
  "$(merge_issue_search_results)"

assert_eq "merge_issue_search_results: 空配列だけを渡しても空配列" \
  '[]' \
  "$(merge_issue_search_results '[]' '[]')"

assert_eq "merge_issue_search_results: 1件だけでもそのまま配列で返す" \
  '[{"number":68,"title":"b","state":"open","url":"u68"}]' \
  "$(merge_issue_search_results '[{"number":68,"title":"b","state":"open","url":"u68"}]')"

# --- 敵対的レビュー（issue #77）: インラインコメント投稿の純粋関数 ---

fixture_files_json='[
  {"filename":"new.sh","patch":"@@ -0,0 +1,3 @@\n+a\n+b\n+c"},
  {"filename":"multi.md","patch":"@@ -1,5 +14,7 @@ ctx\n ...\n@@ -30,2 +100,3 @@\n x"},
  {"filename":"binary.png"},
  {"filename":"deleted-only.txt","patch":"@@ -1,2 +1,0 @@\n-x"},
  {"filename":"one-line.txt","patch":"@@ -5 +7 @@\n-a\n+b"}
]'

assert_eq "github_valid_ranges_from_files_json: 新規ファイルは1行目から有効" \
  '[[1,3]]' \
  "$(printf '%s' "$fixture_files_json" | github_valid_ranges_from_files_json | jq -c '.["new.sh"]')"

assert_eq "github_valid_ranges_from_files_json: 複数hunkを連結する" \
  '[[14,20],[100,102]]' \
  "$(printf '%s' "$fixture_files_json" | github_valid_ranges_from_files_json | jq -c '.["multi.md"]')"

assert_eq "github_valid_ranges_from_files_json: patchが無いファイルは空" \
  '[]' \
  "$(printf '%s' "$fixture_files_json" | github_valid_ranges_from_files_json | jq -c '.["binary.png"]')"

# 純粋な削除hunk（新ファイル側の行数が0）は、RIGHT側にコメントできる行を持たない
assert_eq "github_valid_ranges_from_files_json: 新ファイル側0行のhunkは除外" \
  '[]' \
  "$(printf '%s' "$fixture_files_json" | github_valid_ranges_from_files_json | jq -c '.["deleted-only.txt"]')"

# `@@ -a +c @@` のように行数を省略した形は1行を意味する
assert_eq "github_valid_ranges_from_files_json: 行数省略形は1行として扱う" \
  '[[7,7]]' \
  "$(printf '%s' "$fixture_files_json" | github_valid_ranges_from_files_json | jq -c '.["one-line.txt"]')"

assert_eq "github_valid_ranges_from_files_json: 空配列なら空オブジェクト" \
  '{}' \
  "$(printf '%s' '[]' | github_valid_ranges_from_files_json)"

ranges_file="$(mktemp)"
printf '%s' '{"new.sh":[[1,3]],"multi.md":[[14,20],[100,102]],"binary.png":[]}' > "$ranges_file"

assert_eq "github_filter_findings_by_valid_lines: findingsが0件なら両方空" \
  '{"post":[],"summary":[]}' \
  "$(printf '%s' '{"findings":[]}' | github_filter_findings_by_valid_lines "$ranges_file")"

assert_eq "github_filter_findings_by_valid_lines: 有効行内なら投稿対象" \
  '2' \
  "$(printf '%s' '{"findings":[{"path":"new.sh","line":2}]}' | github_filter_findings_by_valid_lines "$ranges_file" | jq -r '.post[0].line')"

assert_eq "github_filter_findings_by_valid_lines: sideの既定はRIGHT" \
  'RIGHT' \
  "$(printf '%s' '{"findings":[{"path":"new.sh","line":2}]}' | github_filter_findings_by_valid_lines "$ranges_file" | jq -r '.post[0].side')"

# ファイル全体にかかる指摘（line未指定）は、そのファイルの有効行の最小値へ寄せる。
# 新規追加ファイルではhunkが `@@ -0,0 +1,N @@` になるため1行目に一致する。
assert_eq "github_filter_findings_by_valid_lines: line未指定は有効行の最小値へ寄る" \
  '1' \
  "$(printf '%s' '{"findings":[{"path":"new.sh"}]}' | github_filter_findings_by_valid_lines "$ranges_file" | jq -r '.post[0].line')"

assert_eq "github_filter_findings_by_valid_lines: 既存ファイルのline未指定は1ではなく最小有効行" \
  '14' \
  "$(printf '%s' '{"findings":[{"path":"multi.md"}]}' | github_filter_findings_by_valid_lines "$ranges_file" | jq -r '.post[0].line')"

assert_eq "github_filter_findings_by_valid_lines: 有効行外はサマリ行き" \
  '1' \
  "$(printf '%s' '{"findings":[{"path":"multi.md","line":5}]}' | github_filter_findings_by_valid_lines "$ranges_file" | jq -r '.summary | length')"

assert_eq "github_filter_findings_by_valid_lines: 2つ目のhunk内なら投稿対象" \
  '101' \
  "$(printf '%s' '{"findings":[{"path":"multi.md","line":101}]}' | github_filter_findings_by_valid_lines "$ranges_file" | jq -r '.post[0].line')"

assert_eq "github_filter_findings_by_valid_lines: diffに無いパスはサマリ行き" \
  '0 1' \
  "$(printf '%s' '{"findings":[{"path":"not-in-diff.md","line":1}]}' | github_filter_findings_by_valid_lines "$ranges_file" | jq -r '"\(.post | length) \(.summary | length)"')"

assert_eq "github_filter_findings_by_valid_lines: 有効行が空のファイルはサマリ行き" \
  '0 1' \
  "$(printf '%s' '{"findings":[{"path":"binary.png"}]}' | github_filter_findings_by_valid_lines "$ranges_file" | jq -r '"\(.post | length) \(.summary | length)"')"

assert_eq "github_filter_findings_by_valid_lines: findingsキーが無くても落ちない" \
  '{"post":[],"summary":[]}' \
  "$(printf '%s' '{}' | github_filter_findings_by_valid_lines "$ranges_file")"

review_body_file="$(mktemp)"
printf 'レビュー本文' > "$review_body_file"

assert_eq "github_build_review_payload: 投稿0件でも本文だけのレビューになる" \
  'COMMENT 0 レビュー本文' \
  "$(printf '%s' '[]' | github_build_review_payload "$review_body_file" | jq -r '"\(.event) \(.comments | length) \(.body)"')"

assert_eq "github_build_review_payload: マルチバイトのパスをそのまま保つ" \
  'plans/【設計】計画.md' \
  "$(printf '%s' '[{"path":"plans/【設計】計画.md","line":1,"title":"T","body":"B"}]' | github_build_review_payload "$review_body_file" | jq -r '.comments[0].path')"

# gh/glab CLIは人間のアカウントで認証されているため、投稿者名では誰が書いたか判別できない。
# 本文側に署名を入れる（issue-mr-flow の `reply` サブコマンド手順2と同じ理由）。
assert_eq "github_build_review_payload: 本文の先頭にAIの署名を付ける" \
  'Claude Codeより（敵対的レビュー）:' \
  "$(printf '%s' '[{"path":"a.sh","line":1,"title":"タイトル","body":"本文"}]' | github_build_review_payload "$review_body_file" | jq -r '.comments[0].body' | head -1)"

assert_eq "github_build_review_payload: 重大度・確度・カテゴリを署名の次の段落へ付ける" \
  '**[major / 確度: high / shell-pitfall]** タイトル' \
  "$(printf '%s' '[{"path":"a.sh","line":1,"severity":"major","confidence":"high","category":"shell-pitfall","title":"タイトル","body":"本文"}]' | github_build_review_payload "$review_body_file" | jq -r '.comments[0].body' | sed -n '3p')"

assert_eq "format_findings_summary: 0件でも本文は空にしない" \
  'すべての指摘をインラインコメントで示しています。' \
  "$(printf '%s' '[]' | format_findings_summary | tail -1)"

assert_eq "format_findings_summary: 件数を見出しに出す" \
  '### インラインで示せなかった指摘（2件）' \
  "$(printf '%s' '[{"path":"a.sh","title":"T1"},{"path":"b.sh","title":"T2"}]' | format_findings_summary | sed -n '3p')"

# --- GitLab: サマリの投稿先（スレッド or 単発note） ---

assert_eq "gitlab_summary_post_kind: 指摘を含むサマリはスレッドで投稿する" \
  'thread' \
  "$(gitlab_summary_post_kind 1)"

assert_eq "gitlab_summary_post_kind: 複数件でもスレッドで投稿する" \
  'thread' \
  "$(gitlab_summary_post_kind 5)"

assert_eq "gitlab_summary_post_kind: 0件の通知はスレッドにしない（未解決一覧に残るため）" \
  'note' \
  "$(gitlab_summary_post_kind 0)"

# --- GitLab: position付き投稿 ---

gitlab_refs='{"base_sha":"b1","start_sha":"s1","head_sha":"h1"}'

assert_eq "gitlab_build_discussion_body: 新規行への指摘はnew_lineのみ" \
  '{"base_sha":"b1","start_sha":"s1","head_sha":"h1","position_type":"text","old_path":"a.sh","new_path":"a.sh","new_line":10}' \
  "$(gitlab_build_discussion_body '{"path":"a.sh","line":10}' "$gitlab_refs" | jq -c '.position')"

assert_eq "gitlab_build_discussion_body: 削除行への指摘はold_lineのみ" \
  '{"base_sha":"b1","start_sha":"s1","head_sha":"h1","position_type":"text","old_path":"a.sh","new_path":"a.sh","old_line":3}' \
  "$(gitlab_build_discussion_body '{"old_path":"a.sh","old_line":3}' "$gitlab_refs" | jq -c '.position')"

assert_eq "gitlab_build_discussion_body: コンテキスト行への指摘は両方" \
  '10 8' \
  "$(gitlab_build_discussion_body '{"path":"a.sh","line":10,"old_line":8}' "$gitlab_refs" | jq -r '"\(.position.new_line) \(.position.old_line)"')"

assert_eq "gitlab_build_discussion_body: 本文の先頭にAIの署名を付ける" \
  'Claude Codeより（敵対的レビュー）:' \
  "$(gitlab_build_discussion_body '{"path":"a.sh","line":1,"title":"タイトル","body":"本文"}' "$gitlab_refs" | jq -r '.body' | head -1)"

assert_eq "gitlab_build_discussion_body: 本文の形式をGitHub版と揃える" \
  '**[major / 確度: high / shell-pitfall]** タイトル' \
  "$(gitlab_build_discussion_body '{"path":"a.sh","line":1,"severity":"major","confidence":"high","category":"shell-pitfall","title":"タイトル","body":"本文"}' "$gitlab_refs" | jq -r '.body' | sed -n '3p')"

# gitlab_format_discussion_notes が position を出力すること（issue #77 で修正）。
# 位置が出ないと「どのファイルの何行目への指摘か」がレビュー対応時に分からない。
gitlab_notes_fixture='[
  {"id":"abc","notes":[{"system":false,"resolvable":true,"resolved":false,"author":{"username":"u1"},"body":"新規行","position":{"new_path":"a.sh","new_line":10,"old_path":"a.sh"}}]},
  {"id":"def","notes":[{"system":false,"resolvable":true,"resolved":false,"author":{"username":"u2"},"body":"削除行","position":{"old_path":"b.sh","old_line":3,"new_path":"b.sh","new_line":null}}]},
  {"id":"ghi","notes":[{"system":false,"resolvable":false,"author":{"username":"u3"},"body":"通常コメント"}]},
  {"id":"jkl","notes":[{"system":true,"author":{"username":"u4"},"body":"changed the description"}]},
  {"id":"mno","notes":[{"system":false,"resolvable":true,"resolved":true,"author":{"username":"u5"},"body":"解決済み"}]}
]'

assert_eq "gitlab_format_discussion_notes: position付きはpath:lineを出す" \
  '[unresolved threadId=abc a.sh:10] u1: 新規行' \
  "$(gitlab_format_discussion_notes "$gitlab_notes_fixture" | sed -n '1p')"

assert_eq "gitlab_format_discussion_notes: 削除行はold_path:old_lineを出す" \
  '[unresolved threadId=def b.sh:3] u2: 削除行' \
  "$(gitlab_format_discussion_notes "$gitlab_notes_fixture" | sed -n '3p')"

assert_eq "gitlab_format_discussion_notes: position無しの通常コメントは従来どおり" \
  '[unresolved threadId=ghi] u3: 通常コメント' \
  "$(gitlab_format_discussion_notes "$gitlab_notes_fixture" | sed -n '5p')"

assert_eq "gitlab_format_discussion_notes: systemノートと解決済みは除外されたまま" \
  '3' \
  "$(gitlab_format_discussion_notes "$gitlab_notes_fixture" | grep -c 'threadId=')"

assert_eq "gitlab_format_discussion_notes: include_resolved=trueなら解決済みも出る" \
  '4' \
  "$(gitlab_format_discussion_notes "$gitlab_notes_fixture" true | grep -c 'threadId=')"

# CLI不在時に提示するMCPツール名（mcp_tool_hint）へ、新しい関数を追加したか
get_provider() { printf 'github\n'; }
assert_eq "mcp_tool_hint: add_mr_inline_comments はレビュー作成ツールを案内する" \
  '1' \
  "$(mcp_tool_hint add_mr_inline_comments | grep -c 'pull_request_review_write')"

# --- issue #42: blobリンク・差分アンカーリンク・パーマリンクの組み立て --------------------

assert_eq "github_get_blob_url: リポジトリURLに/blob/<ref>/<path>を付与" \
  "https://github.com/o/r/blob/aaa111/.claude/scripts/src/vcs/Github.sh" \
  "$(github_get_blob_url "https://github.com/o/r" "aaa111" ".claude/scripts/src/vcs/Github.sh")"

assert_eq "github_get_diff_anchor_url: CompareページURLに#diff-<hash>を付与" \
  "https://github.com/o/r/compare/main...aaa111#diff-645d26f1" \
  "$(github_get_diff_anchor_url "https://github.com/o/r/compare/main...aaa111" "645d26f1")"

assert_eq "github_diff_anchor_algo: GitHubの差分アンカーはパスのsha256" \
  "sha256" "$(github_diff_anchor_algo)"

assert_eq "gitlab_get_blob_url: リポジトリURLに/-/blob/<ref>/<path>を付与" \
  "https://gitlab.example.com/o/r/-/blob/aaa111/src/main.go" \
  "$(gitlab_get_blob_url "https://gitlab.example.com/o/r" "aaa111" "src/main.go")"

assert_eq "gitlab_get_diff_anchor_url: CompareページURLに#<hash>を付与（diff-接頭辞は付かない）" \
  "https://gitlab.example.com/o/r/-/compare/main...aaa111#8ec9a00b" \
  "$(gitlab_get_diff_anchor_url "https://gitlab.example.com/o/r/-/compare/main...aaa111" "8ec9a00b")"

assert_eq "gitlab_diff_anchor_algo: GitLabの差分アンカーはパスのsha1" \
  "sha1" "$(gitlab_diff_anchor_algo)"

assert_eq "gitlab_get_mr_url: リポジトリURLとMR番号からMRページURLを組み立てる" \
  "https://gitlab.example.com/o/r/-/merge_requests/42" \
  "$(gitlab_get_mr_url "https://gitlab.example.com/o/r" "42")"

assert_eq "gitlab_get_note_url: MRページURLとnote idからコメントのパーマリンクを組み立てる" \
  "https://gitlab.example.com/o/r/-/merge_requests/42#note_12345" \
  "$(gitlab_get_note_url "https://gitlab.example.com/o/r/-/merge_requests/42" "12345")"

# --- url_encode_path_to_reply（issue #42） ----------------------------------------------
# 結果は標準出力ではなく REPLY へ返るため、コマンド置換ではなく呼び出し後に $REPLY を読む。

url_encode_path_to_reply ".claude/scripts/src/vcs/Github.sh"
assert_eq "url_encode_path_to_reply: unreserved文字と/はそのまま残す" \
  ".claude/scripts/src/vcs/Github.sh" "$REPLY"

url_encode_path_to_reply "docs/a b.md"
assert_eq "url_encode_path_to_reply: 空白は%20へ変換する" "docs/a%20b.md" "$REPLY"

url_encode_path_to_reply "a#b?c"
assert_eq "url_encode_path_to_reply: URL上で意味を持つ記号を変換する" "a%23b%3Fc" "$REPLY"

url_encode_path_to_reply "plans/【実装】x.md"
assert_eq "url_encode_path_to_reply: 日本語はUTF-8のバイト単位で%XXへ変換する" \
  "plans/%E3%80%90%E5%AE%9F%E8%A3%85%E3%80%91x.md" "$REPLY"

url_encode_path_to_reply ""
assert_eq "url_encode_path_to_reply: 空文字列は空文字列のまま" "" "$REPLY"

# --- hash_paths（issue #42） -------------------------------------------------------------
# 期待値のうちsha256の2件は、GitHubのCompareページが遅延読込する
# `/compare/file-list?range=<from>...<to>` の断片HTMLに出力される `id="diff-<hash>"` と
# 一致することを本リポジトリで実機確認済み（issue #42の受け入れ条件）。

assert_eq "hash_paths: sha256でパス文字列（ファイルの中身ではない）のハッシュを返す" \
  "645d26f1a0efff8ca3cef055f31fd35cb9b6659de3c37add0dd34de217c74631" \
  "$(hash_paths sha256 ".claude/scripts/src/vcs/Gitlab.sh")"

assert_eq "hash_paths: sha1も選べる" \
  "8ec9a00bfd09b3190ac6b22251dbb1aa95a0579d" \
  "$(hash_paths sha1 "README.md")"

assert_eq "hash_paths: 複数パスを渡すと引数と同じ順序で1行ずつ返す" \
  "645d26f1a0efff8ca3cef055f31fd35cb9b6659de3c37add0dd34de217c74631
b78bc8687755aab014029bb3c31f93b23b4c9dd0124f9a4b7ad9fd5d08501650" \
  "$(hash_paths sha256 ".claude/scripts/src/vcs/Gitlab.sh" ".claude/scripts/src/vcs/Github.sh")"

assert_eq "hash_paths: 空白・日本語を含むパスもそのままハッシュする" \
  "46211776bb9388ae1f90d789ff6bb48b4cfa876d77b886425c0f840d20c79dd0
4bc97450a8e98a31d5f7e6d1212a21eac9a0f6a8e25631ff77a7ecde56f3686c" \
  "$(hash_paths sha256 "a b/c.md" "plans/【実装】x.md")"

assert_eq "hash_paths: 引数が無ければ何も出力しない" "" "$(hash_paths sha256)"

# 未知のアルゴリズムは失敗させる（`if` で受けるのは set -e 下でのサブシェル終了を避けるため。
# .claude/rules/shell-script-style.md「テスト」節）
if hash_paths md5 "README.md" >/dev/null 2>&1; then
  unknown_algo_status=0
else
  unknown_algo_status=1
fi
assert_eq "hash_paths: 未知のアルゴリズム名は終了コード1で失敗する" "1" "$unknown_algo_status"

# --- porcelain_z_to_paths（issue #115） ---------------------------------------------------
# `git status --porcelain -z` の出力を模したフィクスチャを標準入力へ流し、「1行＝1つの実在する
# パス」へ変換されることを確認する。gitは起動しない（純粋関数のため）。
# フィクスチャはNULを含むため `$'...'`（bashの文字列はNULを保持できない）ではなく `printf` で
# 都度書き出す。改名・コピーのエントリは `-z` 形式では `XY <新パス>\0<旧パス>\0` の順になる
# （実機確認: git 2.x。行単位形式の `<旧パス> -> <新パス>` とは順序が逆）。

# ステージ済みの改名（`R `）・改名＋未ステージ変更（`RM`）・通常の変更／追加／削除／未追跡を混ぜる
porcelain_z_fixture() {
  printf 'RM plans/ascii-new.md\0plans/ascii-old.md\0'
  printf 'R  plans/【調査】新.md\0plans/【調査】旧.md\0'
  printf ' M plans/keep.md\0'
  printf 'A  reports/2026-08-20_x_調査結果.md\0'
  printf ' D worklog/2026-08-20_x_y_push1.md\0'
  printf '?? plans/【実装】未追跡.md\0'
}

assert_eq "porcelain_z_to_paths: 改名は新パスのみを1行として返し、旧パスは返さない" \
  "plans/ascii-new.md
plans/【調査】新.md
plans/keep.md
reports/2026-08-20_x_調査結果.md
worklog/2026-08-20_x_y_push1.md
plans/【実装】未追跡.md" \
  "$(porcelain_z_fixture | porcelain_z_to_paths)"

assert_eq "porcelain_z_to_paths: 出力に \" -> \" を含む行が現れない" \
  "0" \
  "$(porcelain_z_fixture | porcelain_z_to_paths | grep -c -F -- ' -> ' || true)"

assert_eq "porcelain_z_to_paths: 非ASCIIのパスをそのまま返す（8進エスケープしない）" \
  "1" \
  "$(porcelain_z_fixture | porcelain_z_to_paths | grep -c -F -- 'plans/【調査】新.md')"

assert_eq "porcelain_z_to_paths: 未ステージ側の桁に改名（\` R\`）が来ても新パスを返す" \
  "plans/new.md" \
  "$(printf ' R plans/new.md\0plans/old.md\0' | porcelain_z_to_paths)"

assert_eq "porcelain_z_to_paths: コピー（C）も改名と同様に旧パスを読み捨てる" \
  "plans/copy.md
plans/next.md" \
  "$(printf 'C  plans/copy.md\0plans/src.md\0 M plans/next.md\0' | porcelain_z_to_paths)"

# パス自体が ` -> ` を含む場合、行単位形式では区切りを一意に決められないが、-z形式なら壊れない
assert_eq "porcelain_z_to_paths: パスに\" -> \"が含まれていても新パスを正しく返す" \
  "plans/a -> b.md" \
  "$(printf 'R  plans/a -> b.md\0plans/old -> name.md\0' | porcelain_z_to_paths)"

assert_eq "porcelain_z_to_paths: 未追跡（??）は改名扱いせず次のエントリを読み捨てない" \
  "plans/x.md
plans/y.md" \
  "$(printf '?? plans/x.md\0?? plans/y.md\0' | porcelain_z_to_paths)"

assert_eq "porcelain_z_to_paths: 入力が空なら何も出力しない" \
  "" \
  "$(printf '' | porcelain_z_to_paths)"

# 旧パスのフィールドが欠けた壊れた入力でも、無限ループせず読めたところまでを返す
assert_eq "porcelain_z_to_paths: 改名エントリの旧パスが欠けていても新パスまでは返す" \
  "plans/new.md" \
  "$(printf 'R  plans/new.md\0' | porcelain_z_to_paths)"

echo "passed=$passed failures=$failures"
[ "$failures" -eq 0 ]
