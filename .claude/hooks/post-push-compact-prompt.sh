#!/usr/bin/env bash
#
# Gemini CLI / Claude Code 共通 AfterTool・PostToolUse hook（git push検知、/compact実施を促す
# メッセージ注入）。
# 設計: issue #11 → .claude/docs/spec/issue-mr-workflow.md,
#       issue #7（Gemini CLI対応）
#
# .claude/settings.json 側で matcher: "Bash|PowerShell"、.gemini/settings.json 側で
# matcher: "run_shell_command|Bash|PowerShell" と、各エントリの if フィールド
# （"Bash(git push*)" / "PowerShell(git push*)"）によって、tool_input のコマンドが
# git push を含む場合のみ起動される（マッチしなければプロセスが起動されず、通常のBash/
# PowerShell/run_shell_command利用への性能影響は無い）。if フィルタはベストエフォートのため、
# 本スクリプト側でも念のため command 文字列を正規表現で再チェックする
# （検知ロジックは post-push-usage-report.sh と同一パターン）。tool_nameによるエンジン判定・
# プロジェクトルート取得も同様に post-push-usage-report.sh と同じパターンを使う。
#
# post-push-usage-report.sh と責務を分離した別スクリプト（使用量集計の投稿先はMRコメントだが、
# 本スクリプトはユーザーへの直接的な呼びかけであり、伝達手段・関心事が異なるため）。
# 伝達手段は session-start.sh の write_additional_context と同じ
# `hookSpecificOutput.additionalContext` 方式（stdoutへJSON出力→コンテキストへ注入→
# エージェントが応答に反映）を PostToolUse で使う。
#
# 参照リンクの付与（issue #13）: レビュー依頼メッセージにMRへのリンクが無いと、レビュアーが
# 見に行くまでに1段階ハードルがあるという指摘への対応。以下の参照リンクをadditionalContext経由で
# 具体的なURLとして渡し、エージェントがレビュー依頼メッセージに含めるよう促す。
#   - 常に: MRへのリンク、defaultブランチとの差分へのリンク
#   - このブランチで2回目以降のpush（＝レビュー指摘対応のpush）の場合のみ追加: 前回push時点から
#     今回push時点までの差分へのリンク、コメント一覧（MR画面）へのリンク
# 重点レビュー対象ファイルのリンク（issue #42）: 上記4リンクはいずれもMR/リポジトリ全体を指すため、
# レビュアーは「どのファイルを重点的に見ればよいか」を自力で探す必要があった。今回pushの差分に
# 含まれるファイルごとに「本体（blob）」「Compareページ内の該当ファイル位置（差分アンカー）」の
# 2つのURLを組み立てて候補として供給する。**どのファイルを載せるか・blobと差分アンカーの
# どちらを載せるかはエージェントが判断する**（hookは候補の供給に徹し、選定はしない）。
# コンテキストを圧迫しないよう供給件数には上限（MAX_REVIEW_FILES）を設け、超過分は件数だけ伝える。
#
# 「前回push時点」の判定は、このスクリプト自身が `.claude/state/review-links/<branch>.txt` へ
# 直前pushのHEAD SHAを保存し、次回push時に読み出す形で行う（`usage/`と同様、ブランチ横断・
# 非コミット対象のローカル作業状態。責務分離のため対応工数レポート側の状態とは別ファイルにする）。
# 差分系のURLは、MR/PRのURL文字列から`/files`等のsuffixを推測する方式ではなく、
# `get_repo_url` で取得したリポジトリの正規URLを土台に、GitHub/GitLabいずれも持つ汎用の
# 「Compare」ページ（`/compare/<from>...<to>`）を組み立てる方式にした（issue #13フォローアップ:
# 「gh/glabでURLの正確性を担保したい」という指摘への対応。詳細は
# `.claude/docs/ddr/0023-...md`参照）。`get_repo_url` 自体は当初 `gh repo view` / `glab repo view`
# を呼んでいたが、issue #44で `git remote get-url origin` の正規化（プロバイダ非依存）へ置き換えた。
# これにより、pushのたびに走る本hookから外部CLIの起動とAPI往復が1回ずつ無くなっている
# （詳細: `.claude/docs/ddr/0037-...md`）。
#
# askツールの禁止: レビュー依頼のターンは、ユーザーがその場で `/compact` を打ちたいタイミング
# でもある（このhook自身がそれを促している）。`AskUserQuestion`（askツール）を出すと入力欄が
# 選択肢への回答で塞がり、スラッシュコマンドを打てなくなるため、レビュー依頼のターンでは
# askツールを使わない旨を NO_ASK_TOOL_MESSAGE として最後に渡す（`.claude/skills/issue-mr-flow/
# SKILL.md`「レビュー依頼メッセージ」節が正）。
#
# 注意（エラー方針）: 本体処理は `main` 関数にまとめ、`( main )` のように実サブシェル（丸括弧）の
# 中で呼ぶことで、内部で失敗したコマンドの時点で確実にサブシェルごと終了させる（bashの
# 「if/||の条件式の中では-eが一時停止する」という仕様の影響を受けないようにするため。詳細:
# .claude/docs/spec/shell-scripts.md「bashでのtry/catch相当の書き方」節）。失敗はすべて
# 握りつぶし、git push自体はブロックしない。

set -uo pipefail

CONTEXT_MESSAGE='ユーザにMRレビュー依頼をするためのフックです。下記の参照リンクをレビュー依頼メッセージに含めてください。また、前回のcompact実施から一定期間経過している場合、/compactの実施を促してください。'
FILE_LINKS_GUIDE_MESSAGE='上の候補から「重点的にレビューしてほしいファイル」をあなたが選び、レビュー依頼メッセージに含めてください（全件を載せる必要はありません）。原則は本体（blob）のリンクを載せ、「そのファイルは差分だけ見てほしい」と判断した場合のみ差分リンクを載せてください。'
REPLY_LINKS_GUIDE_MESSAGE='このpushでレビュー指摘へ返信した場合は、その返信コメントのURL（`reply` サブコマンドの出力、または `comments` の出力に含まれる url=...）もレビュー依頼メッセージに含めてください。'

# 重点レビュー対象として供給する候補ファイルの件数上限（issue #42:「変更ファイルが多い場合に
# コンテキストを圧迫しないよう、供給する件数に上限を設ける」）。
# 1ファイルにつき3行・URL2本を出すため、上限がそのまま注入量の上限になる。日本語ファイル名は
# percent-encodeで3倍近くに膨らむため、実測でこの上限だと注入テキスト全体が最大6KB程度に収まる
# （15件では8KB超になった）。このhook自体がコンテキスト肥大への対処（/compactの呼びかけ）を
# 兼ねている以上、供給側が肥大の原因になっては本末転倒のため小さめに倒している。
MAX_REVIEW_FILES=10
COMPACT_PROMPT_MESSAGE='メッセージ例: MRのレビューをお願いします。/compactを実施をしていただくと、レビュー中にコンテキストを圧縮して今後の作業が効率的になる可能性があります。キャッシュが有効なうちにcompactすると費用面で有利です'
NO_ASK_TOOL_MESSAGE='レビュー依頼のターンは通常のメッセージだけで終えてください。AskUserQuestion（askツール）を使ってはいけません（選択肢への回答でユーザーの入力欄が塞がり、その場で /compact を打てなくなるため）。確認したいことがある場合も選択式にせず、レビュー依頼メッセージの本文の中で問いかけてください。'

write_additional_context() {
  local text="$1"
  jq -nc --arg text "$text" \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $text}}'
}

# 参照リンクのテキストブロックを組み立てる。prev_shaが空（このブランチでの初回push）の場合は
# 「前回pushとの差分」「コメント一覧」の2行を省略する（issue #13受け入れ条件）。
# diff_url/repo_urlは、いずれもURL文字列からの推測ではない情報（PR/MRのURLは`gh`/`glab`由来、
# リポジトリの正規URLはremote URLの正規化由来）から組み立てたものを渡す。
# `gh`/`glab` CLI不在時（issue #34）は、MR/PRのURLをhookから取得できないため mr_url に空文字列を
# 渡す。その場合はMRリンクの行を「MCPツールで取得すること」という指示に差し替える
# （defaultブランチとの差分リンクは `get_repo_url` のローカル導出で得られるためそのまま出す）。
# since_urlが空（このブランチでの初回push）の場合は「前回pushとの差分」「コメント一覧」の
# 2行を省略する（issue #13受け入れ条件）。since_urlの算出（＝前回push SHAの有効性判定）は
# 重点ファイルの差分範囲と揃える必要があるため、呼び出し元のmainで行い結果だけを受け取る
# （issue #42）。
build_links_text() {
  local mr_url="$1" diff_url="$2" since_url="$3"
  local text mr_line
  if [ -n "$mr_url" ]; then
    mr_line="$(printf -- '- MR: %s' "$mr_url")"
  else
    mr_line='- MR: (gh/glab CLI不在のため未取得。mcp__github__list_pull_requests で head="<owner>:<branch>" を指定して取得すること)'
  fi
  text="$(printf '参照リンク:\n%s\n- defaultブランチとの差分: %s' "$mr_line" "$diff_url")"
  if [ -n "$since_url" ]; then
    text="$(printf '%s\n- 前回push時との差分: %s' "$text" "$since_url")"
    if [ -n "$mr_url" ]; then
      text="$(printf '%s\n- コメント一覧(MR画面): %s' "$text" "$mr_url")"
    fi
  fi
  printf '%s' "$text"
}

# 指定した差分範囲に含まれるファイルを、変更行数（追加＋削除）の多い順に1行1パスで返す（issue #42）。
# 「変更行数の多い順」は重点レビュー対象になりやすい順という程度の意味で、選定そのものは行わない
# （上限で打ち切る際に、影響の大きいファイルから残すための並べ替え）。
#
# - `--no-renames`: リネームがあると numstat のパス列が `old => new` 形式になり、そのままでは
#   URLへ使えないため、リネームを検出せず「削除＋追加」として扱う。
# - `-c core.quotepath=false`: 日本語ファイル名が8進エスケープされるのを防ぐ
#   （`get_branch_work_files` と同じ理由）。
# - バイナリファイルの numstat は `-` になるため 0 として扱う（末尾へ回る）。
list_changed_files() {
  local diff_range="$1"
  git -c core.quotepath=false diff --numstat --no-renames "$diff_range" \
    | awk -F'\t' 'NF >= 3 { a = ($1 == "-" ? 0 : $1); d = ($2 == "-" ? 0 : $2); print (a + d) "\t" $3 }' \
    | sort -k1,1nr -s \
    | cut -f2-
}

# 重点レビュー対象の候補ファイルと、そのblobリンク・差分アンカーリンクのテキストブロックを
# 組み立てる（issue #42）。候補が1件も無い場合は何も出力しない。
#
# `ref` には今回pushのHEAD SHAを渡す（blobリンクを「該当push時点のファイル本体」に固定するため）。
# `compare_url` は差分範囲と対になるCompareページのURL（初回pushならdefaultブランチとの差分、
# 2回目以降なら前回pushとの差分）。
#
# 性能上の注意: URL組み立ては1ファイルにつき2回の関数呼び出しが必要だが、`$(...)` を
# ファイルごとに書くとそのたびにサブシェルをforkする（git bashでは約95ms/回）。
# ループ全体を1つのプロセス置換 `< <( ... )` の中へ入れることで、fork回数をファイル数に
# 依存しない定数に抑えている（`.claude/rules/shell-script-style.md`「外部プロセス起動のコスト」節）。
# `get_provider` がメモ化されていることも前提にしており、事前に1度呼んでキャッシュを温めておく。
build_file_links_text() {
  local repo_url="$1" compare_url="$2" ref="$3" diff_range="$4" max="$5"
  local files=() line
  while IFS= read -r line; do
    [ -n "$line" ] && files+=("$line")
  done < <(list_changed_files "$diff_range")

  local total="${#files[@]}"
  [ "$total" -gt 0 ] || return 0

  local shown=("${files[@]:0:max}")
  local shown_count="${#shown[@]}"

  # このpushで削除されたファイルは、HEAD時点の本体（blob）が存在せず404になるため、
  # blobリンクを出さず差分アンカーリンクのみを出す（issue #42）。判定用の一覧はgitへの
  # 1回の問い合わせでまとめて取得し、以降はbashの文字列一致で調べる（forkを増やさない）。
  local deleted_files
  deleted_files="$(git -c core.quotepath=false diff --name-only --no-renames \
    --diff-filter=D "$diff_range" || true)"

  local algo hashes=()
  algo="$(get_diff_anchor_algo)"
  while IFS= read -r line; do
    hashes+=("$line")
  done < <(hash_paths "$algo" "${shown[@]}")
  [ "${#hashes[@]}" -eq "$shown_count" ] || return 0

  local urls=()
  while IFS= read -r line; do
    urls+=("$line")
  done < <(
    local i
    for ((i = 0; i < shown_count; i++)); do
      # 削除ファイルはblobリンクの代わりに空行を出し、1ファイル2行という対応関係を保つ
      if [[ $'\n'"${deleted_files}"$'\n' == *$'\n'"${shown[$i]}"$'\n'* ]]; then
        printf '\n'
      else
        url_encode_path_to_reply "${shown[$i]}"
        get_blob_url "$repo_url" "$ref" "$REPLY"
      fi
      get_diff_anchor_url "$compare_url" "${hashes[$i]}"
    done
  )
  [ "${#urls[@]}" -eq "$((shown_count * 2))" ] || return 0

  local text i
  printf -v text '重点レビュー対象の候補ファイル（今回pushの差分。変更行数の多い順に%s件／全%s件）:' \
    "$shown_count" "$total"
  for ((i = 0; i < shown_count; i++)); do
    if [ -n "${urls[$((i * 2))]}" ]; then
      text+=$'\n'"- ${shown[$i]}"
      text+=$'\n'"  - 本体: ${urls[$((i * 2))]}"
    else
      text+=$'\n'"- ${shown[$i]}（このpushで削除。本体のリンクは無し）"
    fi
    text+=$'\n'"  - 差分: ${urls[$((i * 2 + 1))]}"
  done
  if [ "$total" -gt "$shown_count" ]; then
    text+=$'\n'"（他 $((total - shown_count)) 件は省略）"
  fi
  printf '%s' "$text"
}

main() {
  set -euo pipefail

  local raw
  raw="$(cat)"
  [ -n "$raw" ] || exit 0

  local hook_input
  hook_input="$(printf '%s' "$raw" | jq -c '.' 2>/dev/null)" || exit 0
  [ -n "$hook_input" ] || exit 0

  local agent_id
  agent_id="$(printf '%s' "$hook_input" | jq -r '.agent_id // empty')"
  # サブエージェント内実行では何もしない（post-push-usage-report.shと同じガード）
  [ -z "$agent_id" ] || exit 0

  # tool_name から実行中のエンジンを判定する。該当しないtool_nameは対象外として即終了する
  # （Gemini CLI: run_shell_command / Claude Code: Bash・PowerShell。post-push-usage-report.shと
  # 同じ判定パターン）。
  local tool_name
  tool_name="$(printf '%s' "$hook_input" | jq -r '.tool_name // empty')"
  case "$tool_name" in
    run_shell_command|Bash|PowerShell) ;;
    *) exit 0 ;;
  esac

  local command
  command="$(printf '%s' "$hook_input" | jq -r '.tool_input.command // empty')"
  if [ -z "$command" ] || ! printf '%s' "$command" | grep -qiE 'git[[:space:]]+push'; then
    exit 0
  fi

  local project_dir="${GEMINI_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}"
  [ -n "$project_dir" ] || exit 0
  cd "$project_dir"
  source "${project_dir}/.claude/scripts/src/vcs/Provider.sh"

  local branch base_branch
  branch="$(git branch --show-current 2>/dev/null || true)"
  base_branch="$(get_workflow_config | jq -r '.defaultBaseBranch')"
  [ -n "$branch" ] && [ "$branch" != "$base_branch" ] || exit 0

  # `gh`/`glab` CLI不在時（issue #34）はMR/PRのURLを取得できないが、`get_repo_url` は
  # `git remote` から導出するプロバイダ非依存の関数（issue #44）でCLIに依存しないため、
  # Compare系のリンクは出せる。
  # MRリンクだけをMCPでの取得指示に差し替えたうえで、レビュー依頼メッセージ自体は従来どおり促す
  # （ここで終了してしまうと、CLIの無い環境ではレビュー依頼と/compactの呼びかけが一切
  # 行われなくなるため）。
  local mr mr_url=""
  if [ "$(get_vcs_access_mode)" = "cli" ]; then
    mr="$(get_mr_for_branch "$branch")"
    [ -n "$mr" ] || exit 0
    mr_url="$(printf '%s' "$mr" | jq -r '.url')"
  fi

  local repo_url diff_url
  repo_url="$(get_repo_url)"
  diff_url="$(get_mr_diff_url "$repo_url" "$base_branch" "$branch")"

  local repo_root safe_branch state_file current_sha prev_sha=""
  repo_root="$(get_repo_root)"
  safe_branch="$(printf '%s' "$branch" | sed -E 's/[^a-zA-Z0-9_-]/_/g')"
  state_file="${repo_root}/.claude/state/review-links/${safe_branch}.txt"
  current_sha="$(git rev-parse HEAD)"
  if [ -f "$state_file" ]; then
    prev_sha="$(cat "$state_file")"
  fi

  # 重点レビュー対象ファイルの差分範囲は、既存の差分リンクの意味論に合わせる（issue #42）。
  # 前回push SHAが記録されており、かつそのコミットがローカルに存在する場合のみ
  # 「前回push...HEAD」を使い、それ以外は「defaultブランチ...HEAD」にフォールバックする
  # （rebase・履歴書き換えで前回SHAが失われていると `git diff` が失敗するため）。
  # `...`（3点）はGitHub/GitLabのCompareページと同じmerge-base起点の比較で、URL側と意味が揃う。
  local base_ref="origin/${base_branch}" since_url="" diff_range
  git rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null 2>&1 || base_ref="$base_branch"
  diff_range="${base_ref}...HEAD"
  if [ -n "$prev_sha" ] && [ "$prev_sha" != "$current_sha" ] \
    && git cat-file -e "${prev_sha}^{commit}" 2>/dev/null; then
    since_url="$(get_mr_diff_since_url "$repo_url" "$prev_sha" "$current_sha")"
    diff_range="${prev_sha}...HEAD"
  fi

  local links_text
  links_text="$(build_links_text "$mr_url" "$diff_url" "$since_url")"

  # 重点ファイルのURL組み立てに入る前に `get_provider` のキャッシュを温めておく
  # （build_file_links_text の性能上の前提。同関数のコメント参照）。
  get_provider >/dev/null

  local anchor_compare_url="$diff_url" file_links_text=""
  [ -z "$since_url" ] || anchor_compare_url="$since_url"
  # 候補ファイルの供給に失敗しても、既存の参照リンクと/compactの呼びかけは従来どおり行う。
  file_links_text="$(build_file_links_text \
    "$repo_url" "$anchor_compare_url" "$current_sha" "$diff_range" "$MAX_REVIEW_FILES" || true)"

  # 次回push時の「前回pushとの差分」計算のため、今回pushのHEAD SHAを保存する
  mkdir -p "$(dirname "$state_file")"
  printf '%s' "$current_sha" > "$state_file"

  local text
  text="$(printf '%s\n\n%s' "$CONTEXT_MESSAGE" "$links_text")"
  if [ -n "$file_links_text" ]; then
    text="$(printf '%s\n\n%s\n\n%s' "$text" "$file_links_text" "$FILE_LINKS_GUIDE_MESSAGE")"
  fi
  if [ -n "$since_url" ]; then
    text="$(printf '%s\n\n%s' "$text" "$REPLY_LINKS_GUIDE_MESSAGE")"
  fi
  write_additional_context "$(printf '%s\n\n%s\n\n%s' \
    "$text" "$COMPACT_PROMPT_MESSAGE" "$NO_ASK_TOOL_MESSAGE")"
}

( main ) || true

exit 0
