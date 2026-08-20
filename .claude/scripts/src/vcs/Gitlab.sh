#!/usr/bin/env bash
#
# GitLab固有の処理（`glab` CLIラッパー、bash版）。
# 設計: .claude/docs/spec/issue-mr-workflow.md, .claude/docs/spec/shell-scripts.md
#
# 単体でsourceせず、必ず .claude/scripts/src/vcs/Provider.sh 経由で使う
# （Provider.sh が get_provider の判定結果に応じてこのファイルの関数へディスパッチする）。
# 前提: `glab` CLIがインストール・認証済み（`glab auth login`）であること。
#
# 検証状況（issue #48）: ローカルに立てたGitLab CE 18.5.4（Docker）に対し、`glab` 1.114.0から
# 全13関数を実機実行して動作を確認済み。この検証で見つかった3件の不具合（システムノートの混入・
# `glab mr note --message`の非推奨・空コミットフォールバックの前提誤り）は修正済み。
# 以前あった「remoteがGitHubのみのため全関数が未検証」という制約は解消している。
#
# ただし次の4点は依然として未検証。詳細は
# .claude/docs/spec/issue-mr-workflow.md の「未決定事項・懸念点」を参照。
#   - `Provider.sh`経由のディスパッチ: `get_provider`がself-hostedのGitLab URLを判定できない
#     （issue #45、未修正）ため、検証は`gitlab_*`関数を直接呼ぶ形で行った。
#   - バージョン・エディション: 確認したのはCE 18.5.4のみ。gitlab.com（SaaS）・他バージョンは未確認。
#   - プロジェクト構成: 単一プロジェクトでしか確認しておらず、サブグループ・ネストした
#     namespaceでの`glab`のプロジェクト解決は未確認。
#   - `gitlab_set_mr_ready`（issue #61で追加した14個目の関数）: 上記の実機検証より後に追加した
#     ため、この検証には含まれていない。`glab`公式ドキュメントと実装ソースで`--ready`の仕様を
#     確認したのみである。

gitlab_get_issue() {
  local number="$1"
  local issue title slug
  issue="$(glab issue view "$number" --output json)"
  title="$(printf '%s' "$issue" | jq -r '.title')"
  slug="$(to_slug "$title")"
  printf '%s' "$issue" | jq --arg slug "$slug" \
    '{number: .iid, title: .title, body: .description, url: .web_url, slug: $slug}'
}

# タイトル・本文からissueを新規作成する。作成後は `gitlab_get_issue` で正規化した
# JSON（number/title/body/url/slug）を返す（get_issueと同じ形にすることで呼び出し側の扱いを揃える）。
gitlab_new_issue() {
  local title="$1" body="$2"
  local url number
  url="$(glab issue create --title "$title" --description "$body" --yes)"
  number="$(printf '%s' "$url" | grep -oE '[0-9]+$')"
  if [ -z "$number" ]; then
    echo "glab issue create の出力からissue番号を取得できませんでした: $url" >&2
    return 1
  fi
  gitlab_get_issue "$number"
}

# `glab issue list --search` の出力を共通形式（number/title/state/url）へ正規化する（issue #68）。
# `glab` を呼ばない純粋関数（jqのみ）のため .claude/scripts/test/test_vcs_provider.sh から単体テストできる。
#
# GitLab APIのキー名の違いを `gitlab_get_issue` と同じ方針で吸収する（`iid`→`number`、
# `web_url`→`url`）。`state` はGitLabが `opened`/`closed` を返すため、GitHub側（`OPEN`/`CLOSED`を
# 小文字化）と揃うよう `opened` のみ `open` へ読み替える（`closed` はそのまま）。
gitlab_normalize_issue_search_results() {
  local raw="$1"
  printf '%s' "$raw" | jq -c \
    '[.[] | {number: .iid, title: .title, state: (if .state == "opened" then "open" else .state end), url: .web_url}]'
}

# キーワードで既存issueを検索する（issue #68: 起票前の重複チェック用）。
# 第1引数は1キーワードあたりの取得件数、第2引数以降が検索キーワード。
# キーワードごとに1回ずつ検索して統合する理由は `github_search_issues` のコメントを参照。
#
# `glab issue list --search` はtitleとdescriptionを対象に検索する。`--all` を付けることで
# opened/closedの両方を対象にする（closedを含めるのはissue #68の要求）。
gitlab_search_issues() {
  local limit="$1"
  shift
  local keyword results=()
  for keyword in "$@"; do
    results+=("$(gitlab_normalize_issue_search_results \
      "$(glab issue list --search "$keyword" --all --per-page "$limit" --output json)")")
  done
  merge_issue_search_results "${results[@]}"
}

gitlab_new_draft_merge_request() {
  local issue_number="$1" branch="$2" base_branch="$3" title="$4"
  local description
  description="$(printf 'Closes #%s\n\n(plan作成中。/issue-mr-flow describe で更新する)' "$issue_number")"

  if ! glab mr create --draft --source-branch "$branch" --target-branch "$base_branch" \
      --title "$title" --description "$description" --yes >/dev/null; then
    # 差分（コミット）が無いブランチで`glab mr create`が失敗するかどうかは、プロバイダによって
    # 異なる。issue #48でGitLab CE 18.5.4に対し実機確認したところ、targetブランチと同一SHAの
    # ブランチでもMR作成は成功し、この分岐には到達しなかった。差分ゼロで失敗するのは
    # `gh pr create`（GitHub）側の制約である（issue #48対応時、実際に
    # `No commits between main and feature-48-...`が発生しフォールバックが動作した。
    # 設計: .claude/docs/ddr/0005-DraftPR作成失敗時は空コミットで自動リトライする.md）。
    #
    # したがってこの分岐はGitLabでは通常到達しない安全網である。削除せず残しているのは、
    # 実機確認できたのが18.5.4の1バージョンのみで、他バージョン・他設定でも必ず成功すると
    # 言い切れないため。`glab`本体のエラーはそのまま表示した上で、想定内でありこれから
    # 空コミットにフォールバックする旨を明示する（失敗として扱わせないため）。
    echo "glab mr create が失敗しましたが、baseとの差分が無いことによる既知の制約です。空コミットを1つ積んでリトライします" >&2
    add_empty_commit_for_draft_mr
    if ! glab mr create --draft --source-branch "$branch" --target-branch "$base_branch" \
        --title "$title" --description "$description" --yes >/dev/null; then
      echo "glab mr create に失敗しました（空コミットでのリトライ後も失敗）" >&2
      return 1
    fi
  fi
  glab mr view "$branch" --output json --jq '.iid'
}

# discussion内のnoteを整形して返す純粋関数（`glab`呼び出しを伴わないため単体テストできる。
# .claude/rules/shell-script-style.md「テスト」）。第1引数はGitLab REST APIの
# `projects/:id/merge_requests/<n>/discussions` が返すJSON配列そのもの。
#
# GitLabは「説明を変更した」等の操作履歴を、レビューコメントと同じdiscussions APIから
# `system: true` のnoteとして返す（issue #48で実機確認: `changed the description`）。
# レビュー往復の完了判定を狂わせるため機械的に除外する。GitHub側（github_get_mr_unresolved_comments）は
# GraphQLの`reviewThreads`を使っておりシステムイベントを返さないため、同種の問題は無い。
#
# 既定では resolved: false（未解決）のnoteのみを対象とし、対応済み（解決済み）は機械的に除外する。
# include_resolved=true 指定時は解決済みも含めた全件を返す。
# 個人メモ（individual_note）等 resolvable でないnoteは常に含める。
# インラインコメント（`position` を持つnote）は、GitHub側（`path:line`）と揃えて位置を出力する。
# 位置を出さないと「どのファイルの何行目への指摘か」がレビュー対応時に分からない（issue #77）。
# 削除行への指摘は `new_line` が無く `old_line` のみを持つため、その場合は `old_path:old_line` を使う。
# 第3引数 `mr_url`（省略可）を渡すと、各noteの公式パーマリンク `<mr_url>#note_<noteId>` を
# `url=...` として行に含める（issue #42。GitHubのGraphQL `url` フィールドに相当するものが
# GitLabのdiscussions APIには無いため、note `id` から組み立てる）。
gitlab_format_discussion_notes() {
  local discussions="$1" include_resolved="${2:-false}" mr_url="${3:-}"

  printf '%s' "$discussions" | jq -r --argjson includeResolved "$include_resolved" \
    --arg mrUrl "$mr_url" '
    [
      .[] as $d
      | $d.notes[]
      | . as $n
      | select($n.system | not)
      | ($n.resolvable and $n.resolved) as $isResolved
      | select(($isResolved | not) or $includeResolved)
      | (
          if ($n.position // null) == null then null
          elif ($n.position.new_line // null) != null
            then ($n.position.new_path // "") + ":" + ($n.position.new_line | tostring)
          elif ($n.position.old_line // null) != null
            then ($n.position.old_path // "") + ":" + ($n.position.old_line | tostring)
          else ($n.position.new_path // $n.position.old_path // null)
          end
        ) as $loc
      | "[" + (if $isResolved then "resolved" else "unresolved" end)
        + " threadId=" + ($d.id | tostring)
        + (if $loc then " " + $loc else "" end)
        + (if ($mrUrl | length) > 0 then (" url=" + $mrUrl + "#note_" + ($n.id | tostring)) else "" end)
        + "] " + $n.author.username + ": " + $n.body
    ] | join("\n\n")
  ' | tr -d '\r'
}

gitlab_get_mr_unresolved_comments() {
  local mr_number="$1" include_resolved="${2:-false}"
  local discussions repo_url="" mr_url=""
  discussions="$(glab api "projects/:id/merge_requests/${mr_number}/discussions")"
  # コメントのパーマリンク（issue #42）用にMRのURLを求める。ここで失敗しても本体の
  # コメント取得は成功させたいため、握りつぶしてurl無しの出力へ縮退する。
  if repo_url="$(gitlab_get_repo_url 2>/dev/null)" && [ -n "$repo_url" ]; then
    mr_url="$(gitlab_get_mr_url "$repo_url" "$mr_number")"
  fi
  gitlab_format_discussion_notes "$discussions" "$include_resolved" "$mr_url"
}

# 指定したdiscussion（スレッド）に対応内容を返信する。スレッドの解決（resolved）はレビュアー側の
# 操作のためここでは行わない。
#
# 投稿した返信自身のパーマリンク（`<mrUrl>#note_<noteId>`）を標準出力へ返す（issue #42）。
# POSTレスポンスのnote `id` から組み立てる。MRのURLを取得できなかった場合は何も出力しない。
gitlab_add_mr_thread_reply() {
  local mr_number="$1" thread_id="$2" reply_body="$3"
  local response note_id repo_url="" mr_url=""
  response="$(glab api "projects/:id/merge_requests/${mr_number}/discussions/${thread_id}/notes" \
    -X POST -f "body=${reply_body}")"
  note_id="$(printf '%s' "$response" | jq -r '.id // empty' | tr -d '\r')"
  [ -n "$note_id" ] || return 0
  if repo_url="$(gitlab_get_repo_url 2>/dev/null)" && [ -n "$repo_url" ]; then
    mr_url="$(gitlab_get_mr_url "$repo_url" "$mr_number")"
    gitlab_get_note_url "$mr_url" "$note_id"
  fi
}

# 指定ブランチに紐づくMRのJSONを返す（無ければ何も出力せず終了コード0）。途中引き継ぎ対応（resume）と、
# comments/describeサブコマンドでの「現在のブランチのMR番号取得」の共通実装として使う。
gitlab_get_mr_for_branch() {
  local branch="$1"
  local json
  if ! json="$(glab mr view "$branch" --output json 2>/dev/null)"; then
    return 0
  fi
  printf '%s' "$json" | jq '{number: .iid, url: .web_url, isDraft: .work_in_progress, title: .title}'
}

gitlab_set_mr_description() {
  local mr_number="$1" body_file="$2"
  local description
  description="$(cat "$body_file")"
  glab mr update "$mr_number" --description "$description" >/dev/null
}

# Draft MRのDraft状態を解除し、レビュー・マージ可能な状態にする（flow-id 5-4）。
# GitLabはDraftをタイトルの `Draft:` 接頭辞で表現するため、`glab mr update <id> --ready` は
# タイトル先頭の `Draft:` / `WIP:`（大文字小文字・重複を問わない）を除去した新タイトルを
# APIへ送る実装になっている（glab本体のソース `internal/commands/mr/update/mr_update.go` で確認）。
# 接頭辞が無い（＝既にDraftでない）MRに対しても、除去後のタイトルが元と同じになるだけで
# エラーにはならないため冪等に扱える。
gitlab_set_mr_ready() {
  local mr_number="$1"
  glab mr update "$mr_number" --ready >/dev/null
}

# 2つのref（ブランチ名・SHAいずれも可）間の差分を見れる「Compare」ページのURLを組み立てる
# （純粋関数。`glab`呼び出しを伴わない）。GitLabの`/-/compare/<from>...<to>`はMR作成前から
# 使われている汎用の比較ページ。issue #13フォローアップ。
gitlab_get_compare_url() {
  local repo_url="$1" from="$2" to="$3"
  printf '%s/-/compare/%s...%s\n' "$repo_url" "$from" "$to"
}

# MRの「defaultブランチとの差分」を見れるURLを組み立てる（純粋関数）。issue #13。
gitlab_get_mr_diff_url() {
  local repo_url="$1" base_branch="$2" head_branch="$3"
  gitlab_get_compare_url "$repo_url" "$base_branch" "$head_branch"
}

# MRの「前回push時点(from_sha)から今回push時点(to_sha)までの差分」を見れるURLを組み立てる
# （純粋関数）。issue #13。
gitlab_get_mr_diff_since_url() {
  local repo_url="$1" from_sha="$2" to_sha="$3"
  gitlab_get_compare_url "$repo_url" "$from_sha" "$to_sha"
}

# MR本体のページURLを組み立てる（純粋関数）。issue #42。noteのパーマリンクの土台に使う。
gitlab_get_mr_url() {
  local repo_url="$1" mr_number="$2"
  printf '%s/-/merge_requests/%s\n' "$repo_url" "$mr_number"
}

# note（コメント）の公式パーマリンクを組み立てる（純粋関数）。issue #42。
gitlab_get_note_url() {
  local mr_url="$1" note_id="$2"
  printf '%s#note_%s\n' "$mr_url" "$note_id"
}

# 特定ファイルの「そのref時点の本体」を開くblobページのURLを組み立てる（純粋関数）。issue #42。
# `path`は呼び出し側でpercent-encode済みのものを渡す（`url_encode_path_to_reply`）。
gitlab_get_blob_url() {
  local repo_url="$1" ref="$2" path="$3"
  printf '%s/-/blob/%s/%s\n' "$repo_url" "$ref" "$path"
}

# Compareページ内の特定ファイルの差分位置を指すアンカー付きURLを組み立てる（純粋関数）。issue #42。
# GitLabの差分アンカーは `#<パス文字列のsha1>`（GitHubと違い `diff-` 接頭辞が付かない）。
# 【未検証】このリポジトリにGitLab remoteが無いため実機確認できていない。
gitlab_get_diff_anchor_url() {
  local compare_url="$1" path_hash="$2"
  printf '%s#%s\n' "$compare_url" "$path_hash"
}

# 差分アンカーのハッシュ算出に使うアルゴリズム名を返す（純粋関数）。issue #42。【未検証】
gitlab_diff_anchor_algo() {
  printf 'sha1\n'
}

# MRへ新規コメントを1件投稿する（スレッド返信・レビューではない通常コメント）。
gitlab_add_mr_comment() {
  local mr_number="$1" body_file="$2"
  local body
  body="$(cat "$body_file")"
  # 安定版のREST APIを直接叩く（`glab mr note --message`はglab 1.114.0で非推奨警告を出し、
  # 代替の`glab mr note create`はEXPERIMENTAL扱いのため採用しない。issue #48）。
  # 同ファイルの gitlab_add_mr_thread_reply と実装方式が揃う。
  glab api "projects/:id/merge_requests/${mr_number}/notes" \
    -X POST -f "body=${body}" >/dev/null
}

# MRへ新規スレッド（discussion）を1件立てる（issue #121）。インラインではない（`position` を
# 持たない）が、`gitlab_add_mr_comment` の単発noteと違い**返信と解決（resolve）ができる**形になる。
#
# `notes` APIで作ったnoteはGitLab上で `individual_note: true` / `resolvable: false` となり、
# `gitlab_format_discussion_notes` は resolvable でないnoteを常に「未解決」として出力する
# （解決しようが無いため、レビュー往復の未解決一覧に残り続ける）。対応を求めるコメントは
# `discussions` APIで投稿し、レビュアーが解決できる状態にする。
#
# 本文は `gitlab_add_mr_comment` と同じくファイル経由で受け取る（コマンド文字列へ長文を
# 埋め込むとpush検知hookが誤発火するため。`.claude/rules/git-workflow.md`）。
gitlab_add_mr_thread() {
  local mr_number="$1" body_file="$2"
  local body
  body="$(cat "$body_file")"
  glab api "projects/:id/merge_requests/${mr_number}/discussions" \
    -X POST -f "body=${body}" >/dev/null
}

# --- 敵対的レビュー: インラインコメントの投稿（issue #77） ---
#
# GitLabは1リクエスト1指摘のため、GitHubのような「1件が不正だと全件失敗する」巻き添えは
# 起きない。代わりに失敗理由をAPIが区別して返さないため、失敗した指摘はまとめてサマリへ回す。

# finding 1件とMRの `diff_refs` から、`discussions` APIへPOSTするJSONボディを組み立てる（純粋関数）。
# `position` の必須項目は `diff_refs`（base_sha / start_sha / head_sha）だけで揃う。
#   - 新規行への指摘: `new_line` のみ
#   - 削除行への指摘: `old_line` のみ（findingが `old_line` を持ち `line` を持たない場合）
#   - コンテキスト行への指摘: 両方
# `old_path` / `new_path` はGitLabが常に要求するため、片方しか無い場合は同じ値で埋める。
gitlab_build_discussion_body() {
  local finding="$1" diff_refs="$2"
  printf '%s' "$finding" | jq -c --argjson refs "$diff_refs" '
    . as $f
    | {
        body: ("Claude Codeより（敵対的レビュー）:\n\n"
               + "**[" + ($f.severity // "minor") + " / 確度: " + ($f.confidence // "medium")
               + (if $f.category then " / " + $f.category else "" end) + "]** "
               + ($f.title // "") + "\n\n" + ($f.body // "")),
        position: (
          {
            base_sha: $refs.base_sha,
            start_sha: $refs.start_sha,
            head_sha: $refs.head_sha,
            position_type: "text",
            old_path: ($f.old_path // $f.path),
            new_path: ($f.path // $f.old_path)
          }
          + (if ($f.line // null) != null then {new_line: $f.line} else {} end)
          + (if ($f.old_line // null) != null then {old_line: $f.old_line} else {} end)
        )
      }
  ' | tr -d '\r'
}

# サマリ（インラインで示せなかった指摘のまとめ）を、スレッドと単発noteのどちらで投稿するかを
# 決める純粋関数（issue #121）。`thread` / `note` のいずれかを出力する。
#
# GitHubと違いGitLabにはまとめ役のレビュー本文が無いため、サマリは別の1コメントとして投稿する。
# このとき**指摘を1件でも含むなら `discussions`（スレッド）で投稿する**。インラインの指摘と同じく
# 対応を求める内容であり、レビュアーが解決でき、`add_mr_thread_reply` で返信できる形にする必要が
# あるため。
#
# 逆に**0件のとき（全件をインラインで示せたとき）は単発noteのままにする**。本文は
# 「すべての指摘をインラインコメントで示しています」という通知でしか無く、スレッドにすると
# 誰も解決しないまま未解決一覧に残り続けてレビュー往復の完了判定を濁す。
gitlab_summary_post_kind() {
  local summarized="$1"
  if [ "$summarized" -gt 0 ]; then
    printf 'thread\n'
  else
    printf 'note\n'
  fi
}

# findings JSONファイルの指摘を、MRへインラインコメントとして投稿する。
# 戻り値の形はGitHub版と揃える（呼び出し元にプロバイダ差を意識させない）。
#
# findingごとに `jq` を起動するが、1件ごとにHTTPリクエストが発生する経路であり、
# 起動コストは無視できる（.claude/rules/shell-script-style.md「外部プロセス起動のコスト」は
# ファイル数に比例して外部コマンドを起動するホットパスを対象とした指針）。
gitlab_add_mr_inline_comments() {
  local mr_number="$1" findings_file="$2"
  local tmpdir diff_refs finding posted=0 summarized

  tmpdir="$(mktemp -d)"
  diff_refs="$(glab api "projects/:id/merge_requests/${mr_number}" | jq -c '.diff_refs')"
  if [ -z "$diff_refs" ] || [ "$diff_refs" = "null" ]; then
    # MR作成直後は diff_refs が null のことがある（issue #77 のフェーズ2で実機確認）。
    sleep 5
    diff_refs="$(glab api "projects/:id/merge_requests/${mr_number}" | jq -c '.diff_refs')"
  fi
  if [ -z "$diff_refs" ] || [ "$diff_refs" = "null" ]; then
    printf 'gitlab_add_mr_inline_comments: MR %s の diff_refs を取得できませんでした\n' "$mr_number" >&2
    rm -rf "$tmpdir"
    return 1
  fi

  jq -c '(.findings // [])[]' "$findings_file" > "$tmpdir/findings.jsonl"
  : > "$tmpdir/failed.jsonl"
  while IFS= read -r finding; do
    gitlab_build_discussion_body "$finding" "$diff_refs" > "$tmpdir/body.json"
    if glab api "projects/:id/merge_requests/${mr_number}/discussions" \
         -X POST -H "Content-Type: application/json" --input "$tmpdir/body.json" \
         >/dev/null 2>&1 </dev/null; then
      posted=$((posted + 1))
    else
      printf '%s\n' "$finding" >> "$tmpdir/failed.jsonl"
    fi
  done < "$tmpdir/findings.jsonl"

  jq -s '.' "$tmpdir/failed.jsonl" | format_findings_summary > "$tmpdir/summary.md"
  # Windowsネイティブのjqはコマンド置換でも行末へCRを付ける（`.claude/rules/shell-script-style.md`
  # 「文字コード」）。CRが残ると数値比較が `integer expression expected` で落ちるため取り除く。
  summarized="$(jq -s 'length' "$tmpdir/failed.jsonl" | tr -d '\r')"
  case "$(gitlab_summary_post_kind "$summarized")" in
    thread) gitlab_add_mr_thread "$mr_number" "$tmpdir/summary.md" ;;
    note) gitlab_add_mr_comment "$mr_number" "$tmpdir/summary.md" ;;
  esac

  rm -rf "$tmpdir"
  jq -nc --argjson posted "$posted" --argjson summarized "$summarized" \
    '{posted: $posted, summarized: $summarized}'
}

# 任意のissueへ新規コメントを1件投稿する（flow-id 5-3: マージ前の関連issue通知。issue #86）。【未検証】
# 宛先がMRである `gitlab_add_mr_comment` とは別関数（エンドポイントが `merge_requests` ではなく
# `issues` になる）。同関数と同じく安定版のREST APIを直接叩く（`glab issue note --message` は
# `glab mr note --message` と同様に非推奨の可能性があり、代替のサブコマンドはEXPERIMENTAL扱いの
# ため採用しない。issue #48・issue #86）。`<issue番号>` はGitLabのiid（プロジェクト内番号）。
gitlab_add_issue_comment() {
  local issue_number="$1" body_file="$2"
  local body
  body="$(cat "$body_file")"
  glab api "projects/:id/issues/${issue_number}/notes" \
    -X POST -f "body=${body}" >/dev/null
}
