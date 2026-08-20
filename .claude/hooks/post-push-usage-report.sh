#!/usr/bin/env bash
#
# Gemini CLI / Claude Code 共通 AfterTool・PostToolUse hook（git push検知、bash版）。
# 設計: issue #15 → .claude/docs/spec/issue-mr-workflow.md,
#       .claude/docs/spec/shell-scripts.md（issue #6、bash化）,
#       issue #7（Gemini CLI対応）, issue #23（セッションログの一本化）
#
# .claude/settings.json 側で matcher: "Bash|PowerShell"、.gemini/settings.json 側で
# matcher: "run_shell_command|Bash|PowerShell" と、各エントリの if フィールド
# （"Bash(git push*)" / "PowerShell(git push*)"）によって、tool_input のコマンドが
# git push を含む場合のみ起動される（マッチしなければプロセスが起動されず、通常のBash/
# PowerShell/run_shell_command利用への性能影響は無い）。if フィルタはベストエフォートのため、
# 本スクリプト側でも念のため command 文字列を正規表現で再チェックする。tool_name から実行中の
# エンジン（Gemini CLI / Claude Code）を判定する（両エンジンのtool_nameの値集合は重複しないため
# 機械的に一意判定できる。詳細: .claude/docs/spec/issue-mr-workflow.md「エンジン判定」節）。
# 判定した engine は、フッター署名（engine_label）に加えて sync_usage_state へ渡し、
# サブエージェントログの探索方法の分岐と push-index.jsonl への記録に使う（issue #23）。
#
# 投稿前に、自分自身で .claude/hooks/lib/UsageTracking.sh の sync_usage_state を呼んで
# 状態を最新化する（トークン数・ツール実行回数・assistant応答回数のいずれも、このタイミングで
# transcriptとの差分を計算する）。これにより、当該ターンの途中でgit pushが実行されるケース
# （例: 最初のpushがブランチ作成・調査・実装と同じターン内で行われる場合）でも、その時点までに
# transcriptへ書き出し済みの内容を漏れなく反映できる。
#
# `sinceLastPush` を読み、MRへ新規コメントとして投稿する（レビューではない通常コメントのため、
# レビュー合否判定には影響しない）。投稿に成功したら `sinceLastPush` をリセットする。失敗時は
# 状態を変更せず握りつぶす（次のpush時に繰り越されるだけで、git push自体をブロックしない）。
#
# 注意（エラー方針）: 本体処理は `main` 関数にまとめ、`( main )` のように実サブシェル（丸括弧）の
# 中で呼ぶことで、内部で失敗したコマンドの時点で確実にサブシェルごと終了させる（bashの
# 「if/||の条件式の中では-eが一時停止する」という仕様の影響を受けないようにするため。詳細:
# .claude/docs/spec/shell-scripts.md「bashでのtry/catch相当の書き方」節）。失敗はすべて
# 握りつぶし、git push自体はブロックしない。

set -uo pipefail

fmt_num() {
  # 3桁ごとにカンマを挿入する（PowerShell版の "{0:N0}" 相当）
  printf '%d' "$1" | sed -E ':a; s/([0-9])([0-9]{3})(,|$)/\1,\2\3/; ta'
}

fmt_duration() {
  # 秒 → "H時間M分" / "M分" 形式（UsageTracking.shのactiveSecondsをレポート表示用に整形する）
  local total_seconds="$1"
  local hours minutes
  hours=$(( total_seconds / 3600 ))
  minutes=$(( (total_seconds % 3600) / 60 ))
  if [ "$hours" -gt 0 ]; then
    printf '%d時間%d分' "$hours" "$minutes"
  else
    printf '%d分' "$minutes"
  fi
}

# レポート本文を組み立てて標準出力へ書く（issue #97でmain内の無名ブロックから切り出した）。
#
# 切り出した理由は**テスト可能にするため**である。従来は `main` の中の `{ … } > "$tmp_file"` で
# 組み立てていたため外から呼べず、レポート内容を検証する単体テストが1件も書けなかった
# （`.claude/scripts/test/test_usage_tracking.sh` の既存ケースはすべて UsageTracking.sh
# ＝集計側のテストであり、本文は1ケースも通っていなかった）。
#
#   引数: <usage(sinceLastPush)> <branch> <is_first_post> <subagent_usage> <engine_label>
#
# トークンテーブルの列構成は **engine ではなくデータで決める**（issue #97）。状態ファイルは
# ブランチ単位で、`sinceLastPush` は投稿に成功するまで繰り越されるため（`gh`/`glab` 不在環境では
# 投稿がスキップされて繰り越される。issue #34）、同じブランチの `tokensByModel` に
# Gemini由来のモデル（thoughts/tool を持つ）とClaude Code由来のモデル（cacheCreate を持つ）が
# 同時に載りうる。「今回のengine」で列を決めると、混在時にどちらかの数値が無言で表から消える。
build_usage_report_body() {
  local usage="$1" branch="$2" is_first_post="$3" subagent_usage="$4" engine_label="$5"
  {
    echo "## 対応工数レポート（前回pushからの差分）"
    echo ""
    echo "> **このレポートはレビューの合否判定には使用しないでください。**"
    echo ""
    echo "- ブランチ: ${branch}"
    echo "- assistant応答回数: $(printf '%s' "$usage" | jq -r '.turns')"
    echo "- 対応時間（入力待ち時間を除く）: $(fmt_duration "$(printf '%s' "$usage" | jq -r '.activeSeconds // 0')")"
    # 使用モデル（issue #97）。Gemini CLIでは、`tokens` が付かないリビジョンばかりのセッションだと
    # `tokensByModel` が空になりトークンテーブルごと出ないため、モデル名がレポートから完全に
    # 消えてしまう。集計側が `sinceLastPush.models` を独立に持つので、それを1行で出す。
    # Claude Code経路では `models` キー自体が無いため、この行は出ない。
    local models_summary
    models_summary="$(printf '%s' "$usage" | jq -r '(.models // []) | join(", ")' | tr -d '\r')"
    if [ -n "$models_summary" ]; then
      echo "- 使用モデル: ${models_summary}"
    fi
    echo ""
    # トークン列の構成をデータで決める（issue #97。理由は関数のコメントを参照）。
    #   thoughts キーを持つバケット = Gemini由来 / 持たないバケット = Claude Code由来
    # 全項目0のモデル行は表示しない（"<synthetic>"等、transcript側がusageの無いプレースホルダー
    # entryにmodel名を割り当てているケースがあるため）。判定を「そのバケットが持つ数値項目が
    # すべて0か」へ一般化しているが、Claude Codeのバケットはキーがちょうど4つなので現行式と
    # 同値であり、Claude Code経路の出力は変わらない。
    local table
    table="$(printf '%s' "$usage" | jq -r '
      # 3桁区切り（fmt_num と同じ規則）。**数値セルにだけ**適用する。行全体へsed等で一括適用すると
      # モデル名に含まれる数字列（例: claude-3-5-sonnet-20241022）まで区切られてしまう。
      def commafy:
        (tostring | explode | reverse) as $d
        | [range(0; ($d | length)) | if (. > 0 and . % 3 == 0) then [44, $d[.]] else [$d[.]] end]
        | flatten | reverse | implode;
      (.tokensByModel // {}) as $t
      | ($t | to_entries | map(select([.value[] | select(type == "number")] | any(. != 0)))
             | sort_by(.key)) as $rows
      | if ($rows | length) == 0 then ""
        else
          ([$rows[] | .value | has("thoughts")] | any) as $hasGemini
          | ([$rows[] | .value | has("thoughts") | not] | any) as $hasClaude
          | (["Input", "Output"]
             + (if $hasClaude then ["Cache Write"] else [] end)
             + ["Cache Read"]
             + (if $hasGemini then ["Thoughts", "Tool"] else [] end)) as $cols
          | (["input", "output"]
             + (if $hasClaude then ["cacheCreate"] else [] end)
             + ["cacheRead"]
             + (if $hasGemini then ["thoughts", "tool"] else [] end)) as $keys
          | (["| モデル | " + ($cols | join(" | ")) + " |",
              "|---|" + ([$cols[] | "---:"] | join("|")) + "|"]
             + [$rows[] | "| " + .key + " | "
                 + ([.value as $v | $keys[] | ($v[.] // 0) | commafy] | join(" | ")) + " |"])
          | join("\n")
        end' | tr -d '\r')"
    if [ -n "$table" ]; then
      printf '%s\n' "$table"
      echo ""
    fi
    local tool_summary
    # 差分0のツールはキーごと表示しない（`_usage_merge_state`のtoolCalls集計は、過去に一度でも
    # 使われたツールなら差分0でもキー自体は必ず作る仕様のため、フィルタしないと「XXXツール: 0」が
    # 過去に使ったツール分だけ延々と残り続けてしまう。トークンテーブルの0行除外と同じ考え方）
    tool_summary="$(printf '%s' "$usage" | jq -r '.toolCalls | to_entries | map(select(.value > 0)) | sort_by(.key) | map("\(.key): \(.value)") | join(", ")')"
    if [ -n "$tool_summary" ]; then
      echo "**ツール実行回数**: ${tool_summary}"
      echo ""
    fi
    # ツールエラー回数（issue #97。Gemini CLIのセッションログの `toolCalls[].status == "error"`）。
    # Claude Code経路では `toolErrors` キー自体が無いため、この行は出ない。
    local tool_error_summary
    tool_error_summary="$(printf '%s' "$usage" | jq -r '
      (.toolErrors // {}) | to_entries | map(select(.value > 0)) | sort_by(.key)
      | map("\(.key): \(.value)") | join(", ")' | tr -d '\r')"
    if [ -n "$tool_error_summary" ]; then
      echo "**ツールエラー回数**: ${tool_error_summary}"
      echo ""
    fi
    # ブランチ帰属の限界（issue #97、設計判断E）。Gemini CLIのセッションログには実行時のブランチが
    # 記録されないため、断面時点のブランチへまとめて計上するほかない。
    if [ "$(printf '%s' "$usage" | jq 'has("models")')" = "true" ]; then
      echo "> Gemini CLIのセッションログにはブランチ情報が無いため、1つのセッション内でブランチを"
      echo "> 切り替えた場合、切り替え前の作業分もこのブランチの数値に含まれます。"
      echo ""
    fi

    # skill呼び出し・Agent呼び出し・ユーザーへの質問の詳細テーブル（issue #37）。
    # いずれもメインセッションのtranscriptのみを対象とする（サブエージェント自身が呼び出した分・
    # ネストしたサブエージェントは対象外）。各セルは`description`列と同じくパイプをエスケープし、
    # 改行は半角スペースへつぶす（表が崩れないようにするため）。`tr -d '\r'`はWindowsネイティブjqの
    # コマンド置換CR混入対策（既存箇所と同じ理由）。

    if [ "$(printf '%s' "$usage" | jq '.skillCalls | length')" != "0" ]; then
      echo "### skill呼び出し"
      echo ""
      echo "| skill | args |"
      echo "|---|---|"
      local skill_count i
      skill_count="$(printf '%s' "$usage" | jq '.skillCalls | length')"
      for i in $(seq 0 $((skill_count - 1))); do
        local skill_name skill_args
        skill_name="$(printf '%s' "$usage" | jq -r --argjson i "$i" '.skillCalls[$i].skill // ""' | tr -d '\r' | tr '\n' ' ' | sed 's/|/\\|/g')"
        skill_args="$(printf '%s' "$usage" | jq -r --argjson i "$i" '.skillCalls[$i].args // ""' | tr -d '\r' | tr '\n' ' ' | sed 's/|/\\|/g')"
        echo "| ${skill_name} | ${skill_args} |"
      done
      echo ""
    fi

    if [ "$(printf '%s' "$usage" | jq '.agentCalls | length')" != "0" ]; then
      echo "### Agent呼び出し"
      echo ""
      echo "Agentツールで起動されたサブエージェントの呼び出し記録です（呼び出し時点の記録のため、"
      echo "対応するサブエージェントがまだ完了していなくても表示されます。下記の「### サブエージェント」"
      echo "＝トークン/稼働時間の実績テーブルとは別集計です。プロンプトは300文字を超える場合"
      echo "末尾を省略しています）。"
      echo ""
      echo "| サブエージェント種別 | 説明 | プロンプト |"
      echo "|---|---|---|"
      local agent_call_count i
      agent_call_count="$(printf '%s' "$usage" | jq '.agentCalls | length')"
      for i in $(seq 0 $((agent_call_count - 1))); do
        local a_subtype a_desc a_prompt
        a_subtype="$(printf '%s' "$usage" | jq -r --argjson i "$i" '.agentCalls[$i].subagentType // ""' | tr -d '\r' | tr '\n' ' ' | sed 's/|/\\|/g')"
        a_desc="$(printf '%s' "$usage" | jq -r --argjson i "$i" '.agentCalls[$i].description // ""' | tr -d '\r' | tr '\n' ' ' | sed 's/|/\\|/g')"
        a_prompt="$(printf '%s' "$usage" | jq -r --argjson i "$i" '.agentCalls[$i].prompt // "" | if (length > 300) then (.[0:300] + "…") else . end' | tr -d '\r' | tr '\n' ' ' | sed 's/|/\\|/g')"
        echo "| ${a_subtype} | ${a_desc} | ${a_prompt} |"
      done
      echo ""
    fi

    if [ "$(printf '%s' "$usage" | jq '.askUserQuestions | length')" != "0" ]; then
      echo "### ユーザーへの質問"
      echo ""
      echo "| 質問 | 回答 |"
      echo "|---|---|"
      local question_count i
      question_count="$(printf '%s' "$usage" | jq '.askUserQuestions | length')"
      for i in $(seq 0 $((question_count - 1))); do
        local q a
        q="$(printf '%s' "$usage" | jq -r --argjson i "$i" '.askUserQuestions[$i].question // ""' | tr -d '\r' | tr '\n' ' ' | sed 's/|/\\|/g')"
        a="$(printf '%s' "$usage" | jq -r --argjson i "$i" '.askUserQuestions[$i].answer // ""' | tr -d '\r' | tr '\n' ' ' | sed 's/|/\\|/g')"
        echo "| ${q} | ${a} |"
      done
      echo ""
    fi

    # サブエージェント（Task/Agentツール等で起動された別セッション）の使用量。メインセッションの
    # 数値には含まれないため独立セクションとして表示する（既存テーブルへの行追加ではなく、
    # 主体が異なる数値を明確に区別するため。PR #29レビュー指摘）。ネストしたサブエージェント
    # （depth 2以降）は対象外。agentId単位で1行ずつ表示する（issue #34: 同じagentTypeを複数回
    # 起動してもどのagentがどれだけ使ったか見えるようにするため、agentType合算表示から変更）。
    # 差分0のagentは呼び出し元で`_usage_filter_nonzero_subagents`により除外済み。
    if [ "$(printf '%s' "$subagent_usage" | jq 'keys | length')" != "0" ]; then
      echo "### サブエージェント"
      echo ""
      echo "Task/Agentツールで起動されたサブエージェント内の使用量です（メインセッションの数値には"
      echo "含まれません。ネストしたサブエージェントは対象外です。前回pushから差分の無いagentは"
      echo "表示していません）。"
      echo ""
      echo "| エージェント種別 | 説明 | モデル | Input | Output | Cache Write | Cache Read |"
      echo "|---|---|---|---:|---:|---:|---:|"
      local agent_id
      # `tr -d '\r'`の理由は上のモデルループのコメントと同じ（Windowsネイティブjqのコマンド置換
      # 経由でのCR混入対策）。agentIdが2件以上ある場合に必ず顕在化するため、
      # このagent単位表示（issue #34の主目的）では特に重要。
      for agent_id in $(printf '%s' "$subagent_usage" | jq -r 'to_entries | sort_by(.value.agentType, .value.description) | .[].key' | tr -d '\r'); do
        local a_usage a_type a_desc model
        a_usage="$(printf '%s' "$subagent_usage" | jq -c --arg id "$agent_id" '.[$id]')"
        a_type="$(printf '%s' "$a_usage" | jq -r '.agentType // "unknown"')"
        # description中の"|"はMarkdownテーブルの区切りと衝突するためエスケープする
        a_desc="$(printf '%s' "$a_usage" | jq -r '.description // ""' | sed 's/|/\\|/g')"
        for model in $(printf '%s' "$a_usage" | jq -r '.tokensByModel | keys[]' | tr -d '\r' | sort); do
          local m input_v output_v create_v read_v
          m="$(printf '%s' "$a_usage" | jq -c --arg model "$model" '.tokensByModel[$model]')"
          input_v="$(printf '%s' "$m" | jq -r '.input // 0')"
          output_v="$(printf '%s' "$m" | jq -r '.output // 0')"
          create_v="$(printf '%s' "$m" | jq -r '.cacheCreate // 0')"
          read_v="$(printf '%s' "$m" | jq -r '.cacheRead // 0')"
          # 全項目0の行は表示しない（トークンテーブルの<synthetic>行除外と同じ考え方）
          if [ "$input_v" = "0" ] && [ "$output_v" = "0" ] && [ "$create_v" = "0" ] && [ "$read_v" = "0" ]; then
            continue
          fi
          echo "| ${a_type} | ${a_desc} | ${model} | $(fmt_num "$input_v") | $(fmt_num "$output_v") | $(fmt_num "$create_v") | $(fmt_num "$read_v") |"
        done
      done
      echo ""
      local subagent_tool_summary
      # 差分0のツールはキーごと表示しない（メインのtool_summaryと同じ理由）
      subagent_tool_summary="$(printf '%s' "$subagent_usage" | jq -r '
        [.[] | .toolCalls | to_entries[]]
        | group_by(.key)
        | map({key: .[0].key, value: (map(.value) | add)})
        | map(select(.value > 0))
        | sort_by(.key)
        | map("\(.key): \(.value)")
        | join(", ")
      ')"
      if [ -n "$subagent_tool_summary" ]; then
        echo "**ツール実行回数（サブエージェント合計）**: ${subagent_tool_summary}"
        echo ""
      fi
      local subagent_active_seconds
      subagent_active_seconds="$(printf '%s' "$subagent_usage" | jq '[.[] | .activeSeconds // 0] | add // 0')"
      echo "- 稼働時間（サブエージェント内・参考値。メインの対応工数とは別集計で重複除去はしていません）: $(fmt_duration "$subagent_active_seconds")"
      echo ""
    fi
    if [ "$is_first_post" = "true" ]; then
      echo "---"
      echo "### ${engine_label}より"
      echo "post-push-usage-report.sh による集計。"
      echo "セッション情報ログを解析した集計のため、目安として扱ってください。"
      # 既知の過小カウント（ストリーミング応答の開始時点で書かれたプレースホルダー値が更新されない）は
      # Claude Codeのtranscript JSONLについて報告されているものであり、Gemini CLIのセッションログに
      # ついては同種の報告が無い。そのため、この2行はClaude Code由来のトークンを含むレポートにだけ出す。
      # 出すかどうかは**engineではなくデータで決める**（issue #97・DDR 0052のトークン列と同じ理由。
      # 状態ファイルはブランチ単位で、投稿に成功するまで `sinceLastPush` が繰り越されるため、
      # Gemini CLIからの投稿でもClaude Code由来のモデル行が載りうる。その場合は注記が必要になる）。
      # 判定条件はトークンテーブルの行と揃える（thoughtsキーを持たない＝Claude Code由来、かつ
      # 全項目0で除外されない行）。表に出ていない行を根拠に注記だけが出ることを避けるため。
      local has_claude_tokens
      has_claude_tokens="$(printf '%s' "$usage" | jq -r '
        (.tokensByModel // {}) | to_entries
        | map(select([.value[] | select(type == "number")] | any(. != 0)))
        | any(.[]; .value | has("thoughts") | not)' | tr -d '\r')"
      if [ "$has_claude_tokens" = "true" ]; then
        echo "既知の過小カウント要因が報告されています。"
        echo "詳細:https://gille.ai/en/blog/claude-code-jsonl-logs-undercount-tokens/"
      fi
    fi
  }
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
  # サブエージェント内実行では何もしない（SessionStart hookと同じガード。並行書き込みによる
  # 状態ファイル競合を避ける意味もある）
  [ -z "$agent_id" ] || exit 0

  # tool_name から実行中のエンジンを判定する。該当しないtool_nameは対象外として即終了する
  # （Gemini CLI: run_shell_command / Claude Code: Bash・PowerShell。post-push-compact-prompt.shと
  # 同じ判定パターン）。
  local tool_name engine engine_label
  tool_name="$(printf '%s' "$hook_input" | jq -r '.tool_name // empty')"
  case "$tool_name" in
    run_shell_command) engine="gemini"; engine_label="Gemini CLI" ;;
    Bash|PowerShell) engine="claude"; engine_label="Claude Code" ;;
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
  source "${project_dir}/.claude/hooks/lib/UsageTracking.sh"

  local branch base_branch
  branch="$(git branch --show-current 2>/dev/null || true)"
  base_branch="$(get_workflow_config | jq -r '.defaultBaseBranch')"
  [ -n "$branch" ] && [ "$branch" != "$base_branch" ] || exit 0

  local session_id transcript_path repo_root
  session_id="$(printf '%s' "$hook_input" | jq -r '.session_id // empty')"
  transcript_path="$(printf '%s' "$hook_input" | jq -r '.transcript_path // empty')"
  repo_root="$(get_repo_root)"

  local safe_branch state_dir state_file state=""
  safe_branch="$(_usage_safe_branch_name "$branch")"
  state_dir="${repo_root}/usage/state"
  state_file="${state_dir}/${safe_branch}.json"

  # 投稿判定の前に、その時点までtranscriptへ書き出し済みの内容を状態へ反映する
  # （ターンの途中でのpushでも、初回pushなどで記録漏れが起きないようにするための同期）
  # engineは、サブエージェントログの探索方法の分岐（Claude Code / Gemini CLIで構造が異なる）と
  # push-index.jsonlへの記録に使う（issue #23。それ以前はフッター署名のengine_labelにしか
  # 使っていなかった）。
  if [ -n "$session_id" ] && [ -n "$transcript_path" ]; then
    state="$(sync_usage_state "$repo_root" "$branch" "$session_id" "$transcript_path" "$engine" || true)"
  fi

  if [ -z "$state" ]; then
    [ -f "$state_file" ] || exit 0
    state="$(cat "$state_file")"
  fi

  if [ "$(printf '%s' "$state" | jq 'has("sinceLastPush")')" != "true" ]; then
    exit 0
  fi
  local usage subagent_usage
  usage="$(printf '%s' "$state" | jq -c '.sinceLastPush')"
  # サブエージェントはagentId単位で保持されている（issue #34: agentType単位の合算からagentIdごと
  # の表示へ変更）。投稿要否判定の合計計算はagentId単位のままでも合計値に影響しない
  # （0件除外は合計を変えないため、表示用フィルタは後段でのみ適用する）。
  subagent_usage="$(printf '%s' "$state" | jq -c '.sinceLastPush.subagents // {}')"

  # 合計が0なら投稿しない（初回push・使用量が積み上がっていないpush対策）。メイン自身の消費が
  # ほぼ0でも、サブエージェント作業だけが行われたpushでレポートが握りつぶされないよう、
  # サブエージェント分のトークン合計も含める。
  #
  # Gemini CLI経路（engine = gemini）では、トークンだけでなく**ツール実行回数・応答回数**も見る
  # （issue #97、設計判断G）。`tokens` が付かないリビジョンばかりのセッションではトークン合計が0
  # になりうるが、ツールを実行し応答も返っている以上、対応工数は発生しているため。
  # **Claude Code経路の判定式は変更しない。**
  local total
  total="$(jq -n --argjson usage "$usage" --argjson subagentUsage "$subagent_usage" '
    ([$usage.tokensByModel[] | (.input // 0) + (.output // 0) + (.cacheCreate // 0) + (.cacheRead // 0)] | add // 0)
    + ([$subagentUsage[] | .tokensByModel[]? | ((.input // 0) + (.output // 0) + (.cacheCreate // 0) + (.cacheRead // 0))] | add // 0)
  ')"
  if [ "$engine" = "gemini" ] && [ "$total" = "0" ]; then
    total="$(jq -n --argjson usage "$usage" '
      ([($usage.toolCalls // {})[]] | add // 0) + ($usage.turns // 0)
    ')"
  fi
  [ "$total" != "0" ] || exit 0

  # 表示は「差分0のagentは出力しない」方針（issue #34のユーザー指示）。合計計算後、
  # テーブル描画・稼働時間参考値等の表示処理はすべてこのフィルタ後の値に対して行う。
  subagent_usage="$(_usage_filter_nonzero_subagents "$subagent_usage")"

  # `gh`/`glab` CLIが無い実行環境（例: Claude Code on the webのリモート実行環境）では、
  # MRコメントの投稿手段がhookから使えない（hookはMCPツールを呼べない）。状態同期までは
  # 従来どおり行ったうえで、ここでスキップした旨を1行だけ伝えて終了する。sinceLastPushは
  # リセットしないため、CLIのある環境で次にpushしたときにまとめて投稿される（issue #34）。
  if [ "$(get_vcs_access_mode)" != "cli" ]; then
    echo "post-push-usage-report.sh: gh/glab CLI不在のため対応工数レポートの自動投稿をスキップしました（集計状態の更新のみ実施。issue #34）" >&2
    exit 0
  fi

  local mr
  mr="$(get_mr_for_branch "$branch")"
  [ -n "$mr" ] || exit 0
  local mr_number
  mr_number="$(printf '%s' "$mr" | jq -r '.number')"

  # このMR（ブランチ）に対して過去に投稿成功したことがあるか（state.lastPostedAtの有無で判定）。
  # 免責事項の説明文（フッター）は初回投稿時のみ表示し、毎回同じ文言が繰り返し投稿されるのを防ぐ
  # （PR #29レビュー指摘）。
  local is_first_post
  is_first_post="$(printf '%s' "$state" | jq -r 'if .lastPostedAt then "false" else "true" end')"

  # --- コメント本文の組み立て ---
  local tmp_file
  tmp_file="$(mktemp)"
  build_usage_report_body "$usage" "$branch" "$is_first_post" "$subagent_usage" "$engine_label" \
    > "$tmp_file"

  add_mr_comment "$mr_number" "$tmp_file"
  rm -f "$tmp_file"

  # 投稿成功時のみ sinceLastPush をリセットする（失敗時は次回pushへ繰り越す。
  # add_mr_commentが失敗した場合はここに到達せず、set -e により main ごと中断される）。
  # リセットロジック本体は UsageTracking.sh の _usage_reset_since_last_push に切り出してある
  # （.claude/scripts/test/test_usage_tracking.sh から同じロジックで「2回目push」を再現できるようにするため）。
  local reset_state
  reset_state="$(_usage_reset_since_last_push "$state")"
  mkdir -p "$state_dir"
  printf '%s' "$reset_state" > "$state_file"
}

# `source` されたときは関数定義のみを読み込ませ、`main` を実行しない（issue #97）。
# `main` は冒頭で `raw="$(cat)"` を実行するため、ガードが無いとテストから `source` した時点で
# stdin待ちのままハングする（`.claude/rules/shell-script-style.md`「テスト」節）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  ( main ) || true
  exit 0
fi
