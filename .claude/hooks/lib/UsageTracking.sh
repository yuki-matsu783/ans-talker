#!/usr/bin/env bash
#
# post-push-usage-report.sh（PostToolUse, git push検知）が使う共有ロジック（bash版）。
# 設計: issue #37 →
#       .claude/docs/spec/issue-mr-workflow.md, .claude/docs/spec/shell-scripts.md
#
# 単体でsourceせず、`source "$(dirname "${BASH_SOURCE[0]}")/lib/UsageTracking.sh"` の形でsourceして
# 使う。
#
# 注意: transcript_path が指すJSONLの形式はClaude Code非公開の内部フォーマットであり、
# 将来のバージョンで変更されうる（公式ドキュメントに明記）。他に取得手段が無いためベストエフォートで
# パースする。呼び出し元（post-push-usage-report.sh）側で失敗を検知して握りつぶす想定で、本ファイル内
# では集計ロジックの失敗（`set -e`によるエラー）をそのまま呼び出し元へ伝播させる。
#
# 注意: 各assistantメッセージには実行時のgitBranchが記録されている（実機確認済み）。これで
# フィルタしない場合、同一セッション内で複数ブランチを跨いだ際に他ブランチ分のトークンが
# 混入するため、必ず `.gitBranch == $branch` で絞り込む。
#
# 注意（tools/tokens/turns/skillCalls/agentCalls/askUserQuestionsの集計方式、issue #37）:
# 同一セッションが複数回・複数ブランチにわたってresumeされると、transcript JSONL上に同一行が
# 複数回（異なるgitBranchラベル付きで）出現することが実データで確認された。「毎回全件を再パースし、
# 前回の累計との差分（引き算）を計上する」という以前の方式では、セッションが新しいブランチで
# 初めてpushされた際に前回スナップショットが存在せず、蓄積済みの全件がその新ブランチの初回差分と
# して計上されてしまう不具合があった。
# 対策として、これらのフィールドは「セッション単位でグローバルなカーソル
# （usage/state/session-cursors/<sessionId>.json の lastLineCount）が指す、前回処理済み行数
# 以降の新規行のみ」を対象に集計する方式へ変更した（_usage_aggregate_new_lines）。この方式は
# 行の中身（重複かどうか・どのgitBranchラベルが「正しい」か）を一切詮索せず、「一度数えた範囲は
# 二度と数え直さない」という機械的な原則だけで問題を回避する。集計結果はそのまま「新規分（差分）」
# であるため、_usage_merge_state 側での引き算は不要で、sinceLastPush へ単純加算・追記するだけでよい。
#
# 注意（重要・追加バグ修正）: _usage_aggregate_new_lines は当初、新規行の切り出し（別関数
# _usage_read_new_lines）とその集計を2段階に分け、切り出したパース済みJSON配列をシェル変数へ
# 格納したうえで `--argjson` のコマンドライン引数としてjqへ渡していた。しかしtranscriptの各行には
# tool_use/tool_resultの生の入出力（Read/Bashの出力、Editの差分等）がそのまま含まれるため、
# 新規行がわずか32件（約120KB）程度でもこの引数が肥大化し、Windowsのプロセス生成時の
# コマンドライン長上限（実測でおよそ32KB程度）を超えて`jq`の起動自体が`Argument list too long`
# （終了コード126）で失敗することが実データで確認された（対応工数レポートが投稿されなくなる
# 不具合の直接原因）。対策として両関数を1つに統合し、_usage_aggregate_transcript と同じ安全な
# パターン（`jq -R -n ... "$transcript_path"` でファイルパスを渡し、jqの`inputs`でファイル内容を
# 読ませる。中身をシェル変数やコマンドライン引数として運ばない）に統一した。一般的な注意事項として
# `.claude/rules/shell-script-style.md`「JSON操作」節にも追記した。
#
# 注意（activeSecondsだけは全件再パース方式を維持する理由）: 稼働時間(activeSeconds)のgapベースの
# 区間計算は「毎回全件を時系列で走査し直す」ことを前提に単調非減少性を保証する設計になっており
# （後述のコメント参照）、新規行だけの断片的な走査では前回pushの「暫定クローズした末尾セグメント」を
# 正しく補正できない。そのため activeSeconds の算出だけは _usage_aggregate_transcript
# （全件再パース＋sessions[sessionId].lastActiveSeconds とのスナップショット差分）を維持する。
#
# 注意（issue #23: セッションログの一本化とpush断面のインデックス化）: 以前はこのライブラリの
# ミラー（usage/session-logs/）とは別に、post-push-save-logs.sh という独立したhookが
# logs/push-<N>/ へtranscript全文をpushのたびにコピーしていた。実データ検証により、各push断面が
# 現物transcriptの先頭N行とバイト単位で完全一致すること（transcriptは追記専用で、`/compact` を
# 挟んでもこの性質が保たれること）が確認されたため、全文コピーを廃止し「1本のミラー＋行範囲の
# 記録」へ置き換えた。これに伴い本ファイルは次の変更を受けている。
#   - ミラーの置き場所を usage/session-logs/<sessionId>/ へセッション単位化（カーソルのキー設計に
#     揃えた。_usage_sync_session_logs のコメント参照）
#   - サブエージェント探索のengine分岐（claude / gemini）を post-push-save-logs.sh から移植
#   - push断面を usage/state/push-index.jsonl へ1行追記（_usage_append_push_index）
#   - _usage_aggregate_and_merge_subagents の戻り値を {state, agents} へ変更
#
# 注意（PowerShell版との差分）: PowerShell版が持っていた ConvertTo-HashtableDeep は、
# Windows PowerShell 5.1 の `ConvertFrom-Json` が `-AsHashtable` を持たないための回避策であり、
# jqにはその制約が無いためbash版には存在しない（詳細: dev-tools/docs/shell-scripts.md）。

# 稼働時間（activeSeconds）算出用の閾値（秒）。連続するtranscript entry間の経過時間がこれ以上の
# 場合は「人間の入力待ち」（AskUserQuestionの回答待ち・応答終了後の次指示待ち等）とみなし、
# その区間（gapそのもの）は稼働時間に加算しない（ちょうど閾値と同じgapも「待ち」側として扱う）。
# 閾値未満のgapはツール実行待ち等の実作業とみなしそのまま加算する。
# `:=` を使い、呼び出し側（テスト等）が事前に設定していればそちらを優先する。
: "${IDLE_GAP_THRESHOLD_SECONDS:=300}"

# 稼働時間の区間（セグメント）が閉じるたびに末尾へ加算する固定秒数。応答を読む・確認する等、
# 次のgapとしては現れない実作業時間を補うためのもの。
: "${TAIL_BUFFER_SECONDS:=30}"

# ブランチ名を状態ファイル名・ディレクトリ名に使える形へサニタイズする（英数字・ハイフン・
# アンダースコア以外を`_`へ置換）。
_usage_safe_branch_name() {
  printf '%s' "$1" | sed -E 's/[^a-zA-Z0-9_-]/_/g'
}

# transcript(JSONL)を全件再パースし、{tokens, tools, assistantCount, activeSeconds} のJSONを
# stdoutへ出力する。空行・不正なJSON行は無視する（ベストエフォート）。指定ブランチ以外の
# assistantエントリは除外する。
#
# 注意（issue #37以降の使いどころ）: 本関数はもはやtools/tokens/assistantCountの差分計算には
# 使われない（新規行diff方式へ移行したため）。activeSeconds算出専用として維持している
# （呼び出し元は戻り値のうち .activeSeconds のみを使う）。
#
# activeSeconds: 集計対象entry（gitBranch一致・assistant）を出現順（transcriptは時系列で
# 書き出される前提）に走査し、直前entryとの`.timestamp`差（gap）が IDLE_GAP_THRESHOLD_SECONDS
# 未満ならその区間分を、以上ならセグメント終端として TAIL_BUFFER_SECONDS を積算する「累計稼働秒数」。
# 最初のentryには比較対象が無いため加算しない。タイムスタンプが逆行する（負のgap）場合は異常値として
# 何も加算しない。走査完了後、集計対象entryが1件以上あれば、末尾の（まだ閉じていない）セグメントを
# 閉じる分として TAIL_BUFFER_SECONDS をもう1回加算する（entryが1件のみのセッションでも
# activeSecondsが0にならない）。
#
# 単調性メモ: 上記「末尾セグメントの暫定クローズ」は、次回pushで同じセッションのtranscriptが
# 伸びて再集計されると「実際のgap＋新しい末尾へのtail buffer」に置き換わる。置き換え後の値は常に
# 元の値以上になる（新しく追加された時間の分だけ増える）ため、activeSecondsは再集計を繰り返しても
# 単調非減少であり続ける。これにより呼び出し元（_usage_merge_state）の
# 「current - prevSession値（下限0）」という累計差分パターンがそのまま安全に使える。
#
# 注意（`fromdateiso8601`を使わない理由）: 開発機のjq（Windowsネイティブ版jq 1.6）は
# `strptime`/`mktime`が未実装のため、`days_from_civil`アルゴリズムによる自前のISO8601→epoch秒変換を
# 実装する（詳細: .claude/rules/shell-script-style.md「JSON操作」節）。
_usage_aggregate_transcript() {
  local transcript_path="$1" branch="$2"
  jq -R -n --arg branch "$branch" \
    --argjson idleThreshold "$IDLE_GAP_THRESHOLD_SECONDS" \
    --argjson tailBuffer "$TAIL_BUFFER_SECONDS" '
    def zero_bucket: {input: 0, output: 0, cacheCreate: 0, cacheRead: 0};
    # グレゴリオ暦の年月日→エポック日数（1970-01-01を0とする）。strptime/mktimeに依存しない。
    def days_from_civil($y; $m; $d):
      (if $m <= 2 then $y - 1 else $y end) as $yAdj
      | ($yAdj / 400 | floor) as $era
      | ($yAdj - $era * 400) as $yoe
      | ((153 * ($m + (if $m > 2 then -3 else 9 end)) + 2) / 5 | floor) as $doy
      | ($yoe * 365 + ($yoe / 4 | floor) - ($yoe / 100 | floor) + $doy + $d - 1) as $doe
      | ($era * 146097 + $doe - 719468);
    # "YYYY-MM-DDTHH:MM:SS" で始まる文字列（末尾のミリ秒・Zは無視）をUTCエポック秒へ変換する。
    def epoch_from_iso8601:
      . as $s
      | ($s[0:4]   | tonumber) as $Y
      | ($s[5:7]   | tonumber) as $Mo
      | ($s[8:10]  | tonumber) as $D
      | ($s[11:13] | tonumber) as $H
      | ($s[14:16] | tonumber) as $Mi
      | ($s[17:19] | tonumber) as $S
      | (days_from_civil($Y; $Mo; $D) * 86400 + $H * 3600 + $Mi * 60 + $S);
    reduce (
      inputs
      | select(length > 0)
      | (try fromjson catch empty)
      | select(.type == "assistant" and .message != null and ((.gitBranch // "") == $branch))
    ) as $entry (
      {tokens: {}, tools: {}, assistantCount: 0, activeSeconds: 0, prevTimestamp: null};
      .assistantCount += 1
      | (if $entry.message.usage then
          ($entry.message.model // "unknown") as $model
          | .tokens[$model] = ((.tokens[$model] // zero_bucket)
              | .input += ($entry.message.usage.input_tokens // 0)
              | .output += ($entry.message.usage.output_tokens // 0)
              | .cacheCreate += ($entry.message.usage.cache_creation_input_tokens // 0)
              | .cacheRead += ($entry.message.usage.cache_read_input_tokens // 0))
        else . end)
      | (reduce (($entry.message.content // [])[] | select(.type == "tool_use" and .name != null)) as $block (
          .; .tools[$block.name] = ((.tools[$block.name] // 0) + 1)
        ))
      | (if ($entry.timestamp != null) then
          ($entry.timestamp | epoch_from_iso8601) as $ts
          | (if .prevTimestamp != null then
              (($ts - .prevTimestamp) as $gap
               | if $gap < 0 then
                   .
                 elif $gap < $idleThreshold then
                   .activeSeconds += $gap
                 else
                   .activeSeconds += $tailBuffer
                 end)
            else . end)
          | .prevTimestamp = $ts
        else . end)
    )
    | (if .assistantCount > 0 then .activeSeconds += $tailBuffer else . end)
    | del(.prevTimestamp)
  ' "$transcript_path"
}

# transcript(JSONL)を対象に、前回カーソル位置（last_line_count）以降の新規行のみから
# tokens/tools/assistantCount（turns）と、skillCalls/agentCalls/askUserQuestions（対応工数レポートの
# 詳細テーブル用、issue #37）を集計し、あわせて空行を除いた総行数（totalLines。次回カーソルの更新に
# 使う）を返す。指定ブランチ以外のエントリは除外する。`totalLines`以外のフィールドはそのまま
# 「前回pushからの新規分（差分）」であり、呼び出し元は引き算せずsinceLastPushへ加算・追記すればよい。
#
# 注意（重要・issue #37の追加バグ修正）: 当初は「_usage_read_new_lines で新規行をパース済みJSONの
# 配列としてシェル変数へ切り出し、_usage_aggregate_new_lines へ `--argjson entries "$new_entries"`
# でコマンドライン引数として渡す」という2関数構成だった。しかしtranscriptの各行には
# tool_use/tool_resultの生の入出力（Read/Bashの出力、Editの差分等）がそのまま含まれるため、
# 新規行がわずか32件（約120KB）程度でもこの引数が肥大化し、Windowsのプロセス生成時の
# コマンドライン長上限（実測でおよそ32KB程度）を超えて`jq`の起動自体が `Argument list too long`
# （終了コード126）で失敗することが実データで確認された（対応工数レポートが投稿されなくなる
# 不具合の直接原因）。対策として、_usage_aggregate_transcript と同じ安全なパターン
# （`jq -R -n ... "$transcript_path"` でファイルパスを渡し、jqの`inputs`でファイル内容を読ませる。
# 中身をシェル変数やコマンドライン引数として運ばない）に統一し、新規行の切り出し・集計を
# 1回のjq呼び出しの中で完結させた。stdoutへ返る値は集計済みの小さいオブジェクトのみであり、
# transcriptがどれだけ大きくても影響を受けない。一般的な注意事項として
# `.claude/rules/shell-script-style.md`「JSON操作」節にも追記した。
#
# 行の位置基準は _usage_aggregate_transcript の `select(length > 0)` と同じ「空行を除いた行数」で
# 揃えている（カーソルの整合性を保つため）。
#
# skillCalls: `Skill` tool_useブロックから {id, skill, args} を抽出する。
# agentCalls: `Agent` tool_useブロックから {id, subagentType, description, prompt} を抽出する
#   （メインセッションのtranscriptのみを対象とする想定。ネストしたサブエージェント・
#   サブエージェント自身が呼んだAgent/Skillは対象外＝plan「対象外」節参照）。
# askUserQuestions: `.type=="user"`エントリのtool_result本文（"Your questions have been
#   answered: \"Q\"=\"A\", ... "形式。実データで確認済み）から質問=回答ペアを正規表現で抽出する。
#   質問・回答の文字列自体に `"..."="..."` と一致するパターンが含まれる場合は誤抽出しうる
#   既知の制約（レアケースとして許容する）。
_usage_aggregate_new_lines() {
  local transcript_path="$1" last_line_count="$2" branch="$3"
  jq -R -n --argjson offset "$last_line_count" --arg branch "$branch" '
    def zero_bucket: {input: 0, output: 0, cacheCreate: 0, cacheRead: 0};
    # message.content はcontent-blockの配列であることが多いが、人間が直接入力したシンプルな
    # userメッセージでは1本の文字列のまま格納される（実データで確認済み: issue #37の追加バグ）。
    # 配列でない場合に`.[]`でイテレートすると`Cannot iterate over string`で例外になるため、
    # 配列の場合のみ中身を返す安全なヘルパーとして定義する。
    def content_blocks: if type == "array" then .[] else empty end;
    [inputs | select(length > 0)] as $rawLines
    | ($rawLines | length) as $totalLines
    | ($rawLines[$offset:] | map(try fromjson catch empty) | map(select(. != null))) as $newEntries
    | ($newEntries | map(select(.message != null and ((.gitBranch // "") == $branch)))) as $filtered
    | ($filtered | map(select(.type == "assistant"))) as $assistantEntries
    | ($filtered | map(select(.type == "user"))) as $userEntries
    | (reduce $assistantEntries[] as $entry (
        {tokens: {}, tools: {}, assistantCount: 0, skillCalls: [], agentCalls: []};
        .assistantCount += 1
        | (if $entry.message.usage then
            ($entry.message.model // "unknown") as $model
            | .tokens[$model] = ((.tokens[$model] // zero_bucket)
                | .input += ($entry.message.usage.input_tokens // 0)
                | .output += ($entry.message.usage.output_tokens // 0)
                | .cacheCreate += ($entry.message.usage.cache_creation_input_tokens // 0)
                | .cacheRead += ($entry.message.usage.cache_read_input_tokens // 0))
          else . end)
        | (reduce (($entry.message.content // []) | content_blocks | select(.type == "tool_use" and .name != null)) as $block (
            .;
            .tools[$block.name] = ((.tools[$block.name] // 0) + 1)
            | if $block.name == "Skill" then
                .skillCalls += [{id: $block.id, skill: ($block.input.skill // null), args: ($block.input.args // null)}]
              elif $block.name == "Agent" then
                .agentCalls += [{id: $block.id, subagentType: ($block.input.subagent_type // null),
                  description: ($block.input.description // null), prompt: ($block.input.prompt // null)}]
              else . end
          ))
      )) as $assistantAgg
    | (reduce $userEntries[] as $entry (
        {askUserQuestions: []};
        (reduce (($entry.message.content // []) | content_blocks | select(.type == "tool_result")) as $block (
            .;
            ($block.content
              | if type == "string" then .
                elif type == "array" then ([.[] | .text? // ""] | join(""))
                else "" end) as $text
            | if ($text | test("Your questions have been answered:")) then
                reduce ($text | scan("\"([^\"]*)\"=\"([^\"]*)\"")) as $pair (
                  .;
                  (.askUserQuestions | length) as $idx
                  | .askUserQuestions += [{id: (($entry.uuid // "noid") + "#" + ($idx | tostring)),
                      question: $pair[0], answer: $pair[1]}]
                )
              else . end
          ))
      )) as $userAgg
    | {totalLines: $totalLines} + $assistantAgg + $userAgg
  ' "$transcript_path"
}

# 状態ファイル(既存JSON)・今回の新規分（delta。_usage_aggregate_new_linesの戻り値から
# `totalLines`を除いたもの）・
# activeSecondsの累計値（_usage_aggregate_transcriptの戻り値の.activeSeconds）・セッションIDを
# 突き合わせ、更新後の状態JSONを返す。
#
# tokens/tools/turns（assistantCount）/skillCalls/agentCalls/askUserQuestions は既に「新規分」
# として渡されるため、sinceLastPushへそのまま加算・追記する（引き算は不要。issue #37対応）。
# activeSecondsだけは従来通り「累計値 - 前回スナップショット」という差分計算を行う
# （_usage_aggregate_transcriptがactiveSeconds専用に全件再パースする設計のため。ファイル冒頭の
# コメント参照）。
#
# 注意（`agents`のpassthrough）: `$existing.agents`（サブエージェントのagentId単位累計
# スナップショット。`_usage_merge_agent_state`が読み書きする）は本関数が管理するフィールドでは
# ないが、出力オブジェクトへそのまま引き継ぐ。
_usage_merge_state() {
  local existing="$1" delta="$2" active_seconds="$3" session_id="$4" branch="$5"
  local jq_program
  jq_program="$(cat <<'JQ'
def zero_bucket: {input: 0, output: 0, cacheCreate: 0, cacheRead: 0};

($existing.sessions // {}) as $sessions
| ($sessions[$sessionId] // {lastActiveSeconds: 0}) as $prevSession
| (($prevSession.lastActiveSeconds // 0) | tonumber) as $prevActiveSeconds
| ($existing.sinceLastPush // {tokensByModel: {}, toolCalls: {}, turns: 0, activeSeconds: 0,
    skillCalls: [], agentCalls: [], askUserQuestions: []}) as $sincePrev
| (reduce (($delta.tokens // {}) | keys[]) as $model (
    $sincePrev;
    ($delta.tokens[$model]) as $d
    | (.tokensByModel[$model] // zero_bucket) as $acc
    | .tokensByModel[$model] = {
        input: ($acc.input + ($d.input // 0)),
        output: ($acc.output + ($d.output // 0)),
        cacheCreate: ($acc.cacheCreate + ($d.cacheCreate // 0)),
        cacheRead: ($acc.cacheRead + ($d.cacheRead // 0))
      }
  )) as $sinceTokens
| (reduce (($delta.tools // {}) | keys[]) as $tool (
    $sinceTokens;
    .toolCalls[$tool] = ((.toolCalls[$tool] // 0) + $delta.tools[$tool])
  )) as $sinceTools
| ($sinceTools
    | .turns = ((.turns // 0) + ($delta.assistantCount // 0))
    | .activeSeconds = ((.activeSeconds // 0) + ([0, ($activeSeconds - $prevActiveSeconds)] | max))
    | .skillCalls = ((.skillCalls // []) + ($delta.skillCalls // []))
    | .agentCalls = ((.agentCalls // []) + ($delta.agentCalls // []))
    | .askUserQuestions = ((.askUserQuestions // []) + ($delta.askUserQuestions // []))
  ) as $newSince
| ($existing.sessions // {}) as $existingSessions
| ($existingSessions + {($sessionId): {lastActiveSeconds: $activeSeconds}}) as $newSessions
| {branch: $branch, sessions: $newSessions, sinceLastPush: $newSince}
  + (if $existing.lastPostedAt then {lastPostedAt: $existing.lastPostedAt} else {} end)
  + (if $existing.agents then {agents: $existing.agents} else {} end)
JQ
)"
  jq -n --argjson existing "$existing" --argjson delta "$delta" --argjson activeSeconds "$active_seconds" \
    --arg sessionId "$session_id" --arg branch "$branch" \
    "$jq_program"
}

# git push検知時に、集計対象のtranscript（メイン＋サブエージェント）をリポジトリ内の
# gitignore対象ディレクトリ（usage/session-logs/<sessionId>/）へコピーする
# （非公開・ユーザープロファイル配下の揮発性のあるパスに集計処理が直接依存し続けるのを避け、
# pushのたびにリポジトリ内へスナップショットを退避する）。
# コピー先ディレクトリパスをstdoutへ返す。
#
# 注意（issue #23: セッション単位化）: コピー先は元々
# `usage/session-logs/<safeBranch>/<sessionId>/` とブランチ単位だったが、issue #37でカーソル
# （session-cursors/<sessionId>.json）がブランチ非依存のセッション単位へグローバル化されたのに対し、
# ミラーだけがブランチ単位のまま残っていた。同一セッションが別ブランチへresumeされるたびに
# 全文コピーがブランチ数だけ増殖するため、カーソルのキー設計へ揃えてセッション単位にした。
# これに伴い `branch` 引数は不要になった（この関数は branch をコピー先パスの組み立てにしか
# 使っておらず、集計側のブランチフィルタは _usage_aggregate_new_lines /
# _usage_aggregate_transcript がそれぞれ独立に branch を受け取って行うため）。
#
# 注意（issue #23: engine分岐）: 旧 post-push-save-logs.sh（logs/push-<N>/ へ全文コピーしていた
# 別hook。同issueで廃止）が持っていたGemini CLI向けのサブエージェント探索を本関数へ移植した。
# サブエージェントのディレクトリ構造がエンジンごとに異なるため分岐する。
#
#   claude: `${transcript_path%.jsonl}/subagents/agent-*.jsonl`（＋対応する .meta.json）
#           → `subagents/` 直下（直接の子、spawnDepth 1相当）
#   gemini: `$(dirname "$transcript_path")/<session_id>/` をディレクトリごと
#           → `subagents/<session_id>/`
#
# Gemini分を1階層下へ置くのは意図的である。集計側 _usage_aggregate_and_merge_subagents の
# glob は `subagents/agent-*.jsonl` であり、`subagents/<session_id>/` というディレクトリには
# マッチしない。「Geminiの**サブエージェント**は保存するが対応工数の集計対象にはしない」という
# スコープ境界が、追加のガード条件を書かずに構造だけで保証される。
#
# 注意（issue #97）: このスコープ境界は**サブエージェントについてのみ**成り立つ。issue #23時点では
# Geminiのログ全体（メイン・サブエージェントとも）が集計対象外だったが、issue #97で
# **メインセッションは集計対象になった**。この関数がコピーする `${log_dir}/main.jsonl` は
# _sync_usage_state_gemini → _usage_gemini_fold の集計入力である。両者を区別せずに
# 「Geminiのログは集計しない」と読まないこと（設計判断:
# .claude/docs/ddr/0054-Gemini-CLIのサブエージェントは保存のみとし集計しない.md）。
_usage_sync_session_logs() {
  local repo_root="$1" session_id="$2" transcript_path="$3" engine="${4:-claude}"

  local log_dir="${repo_root}/usage/session-logs/${session_id}"
  mkdir -p "${log_dir}/subagents"
  cp "$transcript_path" "${log_dir}/main.jsonl"

  if [ "$engine" = "gemini" ]; then
    local chats_dir subagents_src
    chats_dir="$(dirname "$transcript_path")"
    subagents_src="${chats_dir}/${session_id}"
    if [ -n "$session_id" ] && [ -d "$subagents_src" ]; then
      cp -R "$subagents_src" "${log_dir}/subagents/" 2>/dev/null || true
    fi
  else
    local session_dir="${transcript_path%.jsonl}"
    if [ -d "${session_dir}/subagents" ]; then
      local f meta
      for f in "${session_dir}/subagents"/agent-*.jsonl; do
        [ -e "$f" ] || continue
        cp "$f" "${log_dir}/subagents/" 2>/dev/null || true
        meta="${f%.jsonl}.meta.json"
        if [ -f "$meta" ]; then
          cp "$meta" "${log_dir}/subagents/" 2>/dev/null || true
        fi
      done
    fi
  fi

  printf '%s' "$log_dir"
}

# push断面（そのpushで新たに記録された行の範囲）を usage/state/push-index.jsonl へ1行追記する
# （issue #23）。
#
# 背景: 旧 post-push-save-logs.sh は push のたびにtranscript全文を logs/push-<N>/ へコピーして
# いたが、transcriptは追記専用であることが実データで確認された（各push断面が現物transcriptの
# 先頭N行とバイト単位で完全一致。`/compact` を挟んでも成立する。compactは compact_boundary 行と
# 要約行を追記するだけで過去の行を削除しないため）。したがって「push断面」は
# 「1本のミラー＋行番号2つ」で完全に代替でき、全文コピーは冗長である。
#
# 行番号は1始まり・両端含む。基準は既存の集計と同じ「空行を除いた行数」
# （_usage_aggregate_new_lines の `select(length > 0)`）に揃えているため、
# `from = 前回カーソル値 + 1`, `to = totalLines` となる。
#
# push番号は行数ではなく既存エントリの `push` の最大値+1を使う（旧 post-push-save-logs.sh が
# logs/push-<N>/ の連番決定で採っていた「常に最大値+1」と同じ方針。手動編集や末尾改行の欠落が
# あっても壊れない）。
_usage_append_push_index() {
  local repo_root="$1" branch="$2" session_id="$3" engine="$4"
  local main_from="$5" main_to="$6" agent_ranges="${7:-}"
  # 二重引用符内では `\{` がバックスラッシュごと残るため、既定値は代入後に補う
  [ -n "$agent_ranges" ] || agent_ranges='{}'

  local state_dir="${repo_root}/usage/state"
  local index_file="${state_dir}/push-index.jsonl"
  mkdir -p "$state_dir"

  local push_num=1
  if [ -f "$index_file" ] && [ -s "$index_file" ]; then
    push_num="$(jq -s '[.[].push // 0] | (max // 0) + 1' "$index_file" 2>/dev/null || printf '1')"
  fi
  [ -n "$push_num" ] || push_num=1

  # `tr -d '\r'`: Windowsネイティブjqは出力をファイルへリダイレクトする際に行末へCRを付与する
  # （.claude/rules/shell-script-style.md「文字コード」節）。
  jq -c -n --argjson push "$push_num" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg branch "$branch" --arg sessionId "$session_id" --arg engine "$engine" \
    --argjson from "$main_from" --argjson to "$main_to" --argjson agents "$agent_ranges" '
    {push: $push, at: $at, branch: $branch, sessionId: $sessionId, engine: $engine,
     main: {from: $from, to: $to}, agents: $agents}
  ' | tr -d '\r' >> "$index_file"
}

# セッション横断（ブランチをまたいでも共有）のカーソルファイル
# （usage/state/session-cursors/<cursorKey>.json）から lastLineCount を読む。無ければ0を返す。
_usage_read_cursor() {
  local repo_root="$1" cursor_key="$2"
  local cursor_file="${repo_root}/usage/state/session-cursors/${cursor_key}.json"
  if [ -f "$cursor_file" ]; then
    jq -r '.lastLineCount // 0' "$cursor_file"
  else
    printf '0'
  fi
}

# カーソルファイルへ lastLineCount を書き込む。
_usage_write_cursor() {
  local repo_root="$1" cursor_key="$2" total_lines="$3"
  local cursor_dir="${repo_root}/usage/state/session-cursors"
  mkdir -p "$cursor_dir"
  jq -n --argjson n "$total_lines" '{lastLineCount: $n}' > "${cursor_dir}/${cursor_key}.json"
}

# 1つのサブエージェント（agentId単位）について、_usage_merge_state と全く同じ
# 「delta加算＋activeSecondsのみ差分」ロジックを適用する。累計スナップショット・sinceLastPush差分の
# いずれもagentId単位で保持する。レポート表示はagentIdごとに1行とする方針のため、agentType単位での
# 合算は行わない（issue #34）。`agentType`・`description`はスナップショット・sinceLastPushの
# 両方に付与して保存する。
#
# _usage_merge_state 本体は無改造のまま、agentId を「疑似session_id」、agentId別の累計を
# 「疑似sinceLastPush」としてラップして渡すことで、既存の差分計算ロジックをそのまま再利用する。
_usage_merge_agent_state() {
  local existing="$1" agent_id="$2" agent_type="$3" description="$4" delta="$5" active_seconds="$6" branch="$7"

  local pseudo_existing
  pseudo_existing="$(printf '%s' "$existing" | jq -c --arg agentId "$agent_id" '
    {
      sessions: {($agentId): (.agents[$agentId] // {})},
      sinceLastPush: (.sinceLastPush.subagents[$agentId]
        // {tokensByModel: {}, toolCalls: {}, turns: 0, activeSeconds: 0,
            skillCalls: [], agentCalls: [], askUserQuestions: []})
    }
  ')"

  local merged
  merged="$(_usage_merge_state "$pseudo_existing" "$delta" "$active_seconds" "$agent_id" "$branch")"

  jq -n --argjson existing "$existing" --argjson merged "$merged" \
    --arg agentId "$agent_id" --arg agentType "$agent_type" --arg description "$description" '
    $existing
    | .agents[$agentId] = ($merged.sessions[$agentId] + {agentType: $agentType, description: $description})
    | .sinceLastPush.subagents[$agentId] = ($merged.sinceLastPush + {agentType: $agentType, description: $description})
  '
}

# コピー済みディレクトリ（_usage_sync_session_logsの戻り値）配下のサブエージェントtranscriptを
# 列挙し、agentId単位のセッションカーソル（usage/state/session-cursors/<agentId>.json）を使って
# 新規行のみを集計→_usage_merge_agent_state で existing へ畳み込む。新規行が無いagentはスキップする。
#
# 戻り値は `{state: <更新後の状態JSON>, agents: {<agentId>: {from, to}}}`（issue #23で変更）。
# `agents` は push-index.jsonl へ記録するための行範囲で、実際に集計したagent（新規行があった
# agent）のみが現れる。スキップしたagentは含まれない。行番号は1始まり・両端含む
# （_usage_append_push_index と同じ基準）。
#
# 注意: Gemini CLIのサブエージェントは `subagents/<session_id>/` という1階層下へコピーされるため、
# ここの glob `subagents/agent-*.jsonl` には意図的にマッチしない（保存はするが集計はしない。
# _usage_sync_session_logs のコメント参照）。
_usage_aggregate_and_merge_subagents() {
  local existing="$1" log_dir="$2" branch="$3" repo_root="$4"
  local subagents_dir="${log_dir}/subagents"
  local ranges='{}'

  if [ ! -d "$subagents_dir" ]; then
    jq -n --argjson state "$existing" '{state: $state, agents: {}}'
    return 0
  fi

  local f
  for f in "$subagents_dir"/agent-*.jsonl; do
    [ -e "$f" ] || continue
    local agent_id agent_type description meta_file
    agent_id="$(basename "$f" .jsonl)"
    agent_id="${agent_id#agent-}"
    meta_file="${f%.jsonl}.meta.json"
    if [ -f "$meta_file" ]; then
      agent_type="$(jq -r '.agentType // "unknown"' "$meta_file" 2>/dev/null || echo "unknown")"
      description="$(jq -r '.description // ""' "$meta_file" 2>/dev/null || echo "")"
    else
      agent_type="unknown"
      description=""
    fi
    [ -n "$agent_type" ] || agent_type="unknown"

    local last_line_count
    last_line_count="$(_usage_read_cursor "$repo_root" "$agent_id")"

    local agg_result total_lines
    agg_result="$(_usage_aggregate_new_lines "$f" "$last_line_count" "$branch")"
    total_lines="$(printf '%s' "$agg_result" | jq -r '.totalLines')"

    if [ "$total_lines" -le "$last_line_count" ]; then
      continue
    fi

    local delta active_seconds
    delta="$(printf '%s' "$agg_result" | jq -c 'del(.totalLines)')"
    active_seconds="$(_usage_aggregate_transcript "$f" "$branch" | jq -r '.activeSeconds')"

    existing="$(_usage_merge_agent_state "$existing" "$agent_id" "$agent_type" "$description" "$delta" "$active_seconds" "$branch")"

    ranges="$(printf '%s' "$ranges" | jq -c --arg id "$agent_id" \
      --argjson from "$(( last_line_count + 1 ))" --argjson to "$total_lines" \
      '.[$id] = {from: $from, to: $to}')"

    _usage_write_cursor "$repo_root" "$agent_id" "$total_lines"
  done

  jq -n --argjson state "$existing" --argjson agents "$ranges" '{state: $state, agents: $agents}'
}

# --------------------------------------------------------------------------------------------
# Gemini CLI のセッションログ（追記型JSONL）専用の集計（issue #97）
# --------------------------------------------------------------------------------------------
#
# Claude Code の transcript と違い、Gemini CLI の chats/*.jsonl は「同じ id のメッセージが
# 複数行にわたって再送される」（トークンの後埋め・ツールの status 遷移）。そのため
# _usage_aggregate_new_lines のような「前回カーソル以降の新規行だけを足す」方式は使えず、
# 同じメッセージを何度も数えてしまう。代わりに **毎回ファイル全体を id 単位で畳んで累計
# スナップショットを作り、前回の累計との差分を取る**（設計判断C）。
#
# セッションログのレコードは3種類（Gemini CLI v0.39.0 以降）。
#   - メッセージ本体（`id` を持つ）
#   - `{"$set": {...}}`   メタデータの部分更新。`messages` を含む場合は全メッセージの再送
#   - `{"$rewindTo": "<messageId>"}`  `/rewind` の記録。**集計からは外さない**（設計判断D。
#     会話としては切り詰められても、課金とツール実行は実際に起きているため）

# セッションJSONLを畳み込み、累計スナップショットをJSONでstdoutへ返す。
#
#   出力: {totalLines, turns, activeSeconds,
#          tokens: {"<model>": {input, output, cached, thoughts, tool}},
#          tools: {"<toolName>": <回数>},
#          toolErrors: {"<toolName>": <回数>},
#          models: ["<model>", ...]}
#
# 実装上の注意:
#   - jqへはファイルパスを渡し `-R -n` + `inputs` で読ませる（ファイル内容を --argjson で運ぶと
#     `Argument list too long` になる。.claude/rules/shell-script-style.md「JSON操作」）。
#   - `def days_from_civil` / `def epoch_from_iso8601` は _usage_aggregate_transcript の
#     jqプログラム内に定義されている同名defの **複製** である（あちらはシェル関数ではなく
#     jqのdefなので外から呼べない）。共通化するとClaude Code側の関数へ手を入れることになり、
#     「既存の集計結果を変えない」という担保が弱くなるため、意図的に複製している。
#   - `tokens.total` は加算しない（内訳の合計であり、二重計上になる）。
#   - activeSeconds は _usage_aggregate_transcript と同じ算出方式（設計判断Q）。**走査後の
#     末尾セグメントを閉じる TAIL_BUFFER_SECONDS の加算まで含めて**同じにする。これを落とすと
#     メッセージ1件のセッションが常に0秒になり、Claude Code経路と定義がずれる。
_usage_gemini_fold() {
  local jsonl_path="$1"
  jq -R -n \
    --argjson idleThreshold "$IDLE_GAP_THRESHOLD_SECONDS" \
    --argjson tailBuffer "$TAIL_BUFFER_SECONDS" '
    def zero_bucket: {input: 0, output: 0, cached: 0, thoughts: 0, tool: 0};
    # グレゴリオ暦の年月日→エポック日数（1970-01-01を0とする）。strptime/mktimeに依存しない。
    def days_from_civil($y; $m; $d):
      (if $m <= 2 then $y - 1 else $y end) as $yAdj
      | ($yAdj / 400 | floor) as $era
      | ($yAdj - $era * 400) as $yoe
      | ((153 * ($m + (if $m > 2 then -3 else 9 end)) + 2) / 5 | floor) as $doy
      | ($yoe * 365 + ($yoe / 4 | floor) - ($yoe / 100 | floor) + $doy + $d - 1) as $doe
      | ($era * 146097 + $doe - 719468);
    # "YYYY-MM-DDTHH:MM:SS" で始まる文字列（末尾のミリ秒・Zは無視）をUTCエポック秒へ変換する。
    def epoch_from_iso8601:
      . as $s
      | ($s[0:4]   | tonumber) as $Y
      | ($s[5:7]   | tonumber) as $Mo
      | ($s[8:10]  | tonumber) as $D
      | ($s[11:13] | tonumber) as $H
      | ($s[14:16] | tonumber) as $Mi
      | ($s[17:19] | tonumber) as $S
      | (days_from_civil($Y; $Mo; $D) * 86400 + $H * 3600 + $Mi * 60 + $S);

    # 1行を0個以上のメッセージへ展開する。メタデータ行・$rewindTo は空を返す（読み飛ばす）。
    def to_messages:
      if type != "object" then empty
      elif has("$rewindTo") then empty
      elif has("$set") then (.["$set"].messages // [])[]
      elif (.id != null) then .
      else empty
      end;

    # 後勝ちマージ。ただし新しい版の tokens が null/欠落なら、前の版の tokens を引き継ぐ
    # （実測で「tokens なしの版が後に来る」ことがあるため。設計判断F）。
    def merge_message($prev; $new):
      if $prev == null then $new
      else $new + (if ($new.tokens // null) == null and ($prev.tokens // null) != null
                   then {tokens: $prev.tokens} else {} end)
      end;

    reduce (inputs | select(length > 0)) as $line (
      {byId: {}, totalLines: 0};
      .totalLines += 1
      | reduce (($line | (try fromjson catch empty)) | to_messages) as $msg (
          .;
          .byId[$msg.id] = merge_message(.byId[$msg.id]; $msg)
        )
    )
    | .totalLines as $totalLines
    | ([.byId[]] | sort_by(.timestamp // "")) as $msgs
    | ($msgs | map(select(.type == "gemini"))) as $geminiMsgs
    | {
        totalLines: $totalLines,
        turns: ($geminiMsgs | length),
        models: ($geminiMsgs | map(.model // "unknown") | unique),
        tokens: (reduce $geminiMsgs[] as $m ({};
          if ($m.tokens // null) == null then .
          else
            ($m.model // "unknown") as $model
            | .[$model] = ((.[$model] // zero_bucket)
                | .input += ($m.tokens.input // 0)
                | .output += ($m.tokens.output // 0)
                | .cached += ($m.tokens.cached // 0)
                | .thoughts += ($m.tokens.thoughts // 0)
                | .tool += ($m.tokens.tool // 0))
          end)),
        # 実行回数は「完了した」ツール呼び出しのみ数える。`cancelled` は実行されたものとして
        # 含め、未完了（validating/scheduled/executing/awaiting_approval）は実行回数にも
        # エラーにも入れない（設計判断H。status の値集合は設計判断A-1）。
        tools: (reduce ($msgs[] | (.toolCalls // [])[]
                        | select(.name != null
                                 and ((.status // "") | IN("success", "error", "cancelled")))) as $tc ({};
          .[$tc.name] = ((.[$tc.name] // 0) + 1))),
        toolErrors: (reduce ($msgs[] | (.toolCalls // [])[]
                             | select(.name != null and .status == "error")) as $tc ({};
          .[$tc.name] = ((.[$tc.name] // 0) + 1))),
        activeSeconds: (
          ($msgs | map(select(.timestamp != null) | (.timestamp | epoch_from_iso8601))) as $ts
          | (reduce range(1; ($ts | length)) as $i (0;
              (($ts[$i] - $ts[$i - 1]) as $gap
               | if $gap < 0 then .
                 elif $gap < $idleThreshold then . + $gap
                 else . + $tailBuffer
                 end)))
            + (if ($ts | length) > 0 then $tailBuffer else 0 end))
      }
  ' "$jsonl_path"
}

# 累計スナップショットと前回累計を突き合わせ、差分を sinceLastPush へ加算した新しい状態を返す。
#
#   引数: <existing状態JSON> <snapshot> <prev_totals> <session_id> <branch>
#   出力: {state: {...}, needsReset: <bool>, diffAllZero: <bool>}
#
# **前回累計を existing（ブランチ別の状態ファイル）から読まない。** 呼び出し元が
# usage/state/gemini-totals/<sessionId>.json から読んで引数で渡す。ブランチ別に持つと、同じ
# セッションのままブランチを切り替えたときに前回累計が見つからず、蓄積済みの全件が新ブランチの
# 初回差分として再計上される（issue #37 がカーソルのグローバル化で直したのと同じ不具合）。
#
# needsReset / diffAllZero は **クランプ前（raw）の差分**で判定し、排他になる。
#   - needsReset: 1指標でも負 → セッションファイルの消失（設計判断S）。呼び出し元は早期リターン
#     せず gemini-totals を今回のスナップショットで必ず上書きする。
#   - diffAllZero: すべて0 → 呼び出し元は状態ファイルを書かずに早期リターンしてよい（設計判断O）。
# クランプ後の差分で早期リターンを判定すると、消失直後（全指標が負→0）に前回累計が古いまま残り、
# 以後ずっと「差分0・書き込みなし」で計上が止まる。
_usage_gemini_merge_state() {
  local existing="$1" snapshot="$2" prev_totals="$3" session_id="$4" branch="$5"
  local jq_program
  jq_program="$(cat <<'JQ'
def zero_bucket: {input: 0, output: 0, cacheCreate: 0, cacheRead: 0, thoughts: 0, tool: 0};
def num($v): ($v // 0);

# model別トークンの raw 差分（クランプしない）。
def token_diff($cur; $prev):
  reduce (($cur // {}) | keys[]) as $model ({};
    (($prev // {})[$model] // {}) as $p
    | ($cur[$model]) as $c
    | .[$model] = {
        input:    (num($c.input)    - num($p.input)),
        output:   (num($c.output)   - num($p.output)),
        cached:   (num($c.cached)   - num($p.cached)),
        thoughts: (num($c.thoughts) - num($p.thoughts)),
        tool:     (num($c.tool)     - num($p.tool))
      });

# 名前別カウンタの raw 差分。
def count_diff($cur; $prev):
  reduce (($cur // {}) | keys[]) as $k ({};
    .[$k] = (num($cur[$k]) - num(($prev // {})[$k])));

(token_diff($snapshot.tokens; $prevTotals.tokens)) as $tokenDiff
| (count_diff($snapshot.tools; $prevTotals.tools)) as $toolDiff
| (count_diff($snapshot.toolErrors; $prevTotals.toolErrors)) as $toolErrDiff
| (num($snapshot.turns) - num($prevTotals.turns)) as $turnsDiff
| (num($snapshot.activeSeconds) - num($prevTotals.activeSeconds)) as $activeDiff
| ([$tokenDiff[] | .input, .output, .cached, .thoughts, .tool]
   + [$toolDiff[]] + [$toolErrDiff[]] + [$turnsDiff, $activeDiff]) as $rawValues
| (($rawValues | map(select(. < 0)) | length) > 0) as $needsReset
| (($rawValues | map(select(. != 0)) | length) == 0) as $diffAllZero
| ($existing.sinceLastPush // {tokensByModel: {}, toolCalls: {}, turns: 0, activeSeconds: 0,
    skillCalls: [], agentCalls: [], askUserQuestions: []}) as $sincePrev
| (reduce ($tokenDiff | keys[]) as $model ($sincePrev;
    ($tokenDiff[$model]) as $d
    | (.tokensByModel[$model] // zero_bucket) as $acc
    | .tokensByModel[$model] = {
        input:      ($acc.input      + ([0, $d.input]    | max)),
        output:     ($acc.output     + ([0, $d.output]   | max)),
        cacheCreate: num($acc.cacheCreate),
        cacheRead:  (num($acc.cacheRead) + ([0, $d.cached] | max)),
        thoughts:   (num($acc.thoughts)  + ([0, $d.thoughts] | max)),
        tool:       (num($acc.tool)      + ([0, $d.tool]     | max))
      })) as $sinceTokens
| (reduce ($toolDiff | keys[]) as $t ($sinceTokens;
    .toolCalls[$t] = (num(.toolCalls[$t]) + ([0, $toolDiff[$t]] | max)))) as $sinceTools
| (reduce ($toolErrDiff | keys[]) as $t ($sinceTools;
    .toolErrors[$t] = (num(.toolErrors[$t]) + ([0, $toolErrDiff[$t]] | max)))) as $sinceToolErrs
| ($sinceToolErrs
    | .turns = (num(.turns) + ([0, $turnsDiff] | max))
    | .activeSeconds = (num(.activeSeconds) + ([0, $activeDiff] | max))
    | .models = (((.models // []) + ($snapshot.models // [])) | unique)) as $newSince
| {state: ({branch: $branch, sessions: ($existing.sessions // {}), sinceLastPush: $newSince}
     + (if $existing.lastPostedAt then {lastPostedAt: $existing.lastPostedAt} else {} end)
     + (if $existing.agents then {agents: $existing.agents} else {} end)),
   needsReset: $needsReset,
   diffAllZero: $diffAllZero}
JQ
)"
  jq -nc --argjson existing "$existing" --argjson snapshot "$snapshot" \
    --argjson prevTotals "$prev_totals" --arg sessionId "$session_id" --arg branch "$branch" \
    "$jq_program" | tr -d '\r'
}

# gemini-totals/<sessionId>.json（ブランチ非依存の前回累計）を読む。
# 壊れている（空文字列・不正JSON）場合は「累計なし」として `{}` を返す
# （sync_usage_state の状態ファイル読み込みと同じ自己回復方針）。
_usage_read_gemini_totals() {
  local repo_root="$1" session_id="$2"
  local totals_file="${repo_root}/usage/state/gemini-totals/${session_id}.json"
  local content=""
  if [ -f "$totals_file" ]; then
    content="$(cat "$totals_file")"
  fi
  if [ -n "$content" ] && printf '%s' "$content" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$content"
  else
    printf '%s' '{}'
  fi
}

# gemini-totals/<sessionId>.json へ今回の累計スナップショットを書く。
# レポートに使わない派生値（models）は落として保存する。
_usage_write_gemini_totals() {
  local repo_root="$1" session_id="$2" snapshot="$3"
  local totals_dir="${repo_root}/usage/state/gemini-totals"
  mkdir -p "$totals_dir"
  printf '%s' "$snapshot" | jq -c 'del(.models)' | tr -d '\r' \
    > "${totals_dir}/${session_id}.json"
}

# sync_usage_state の Gemini CLI 経路（issue #97）。Claude Code経路の行は1行も動かさず、
# 分岐先をこの関数へ丸ごと分けている（差分を読んだときに「既存経路は変わっていない」と一目で
# 分かる形にするため）。
#
# Claude Code経路との違い:
#   - 行カーソル（_usage_read_cursor / _usage_write_cursor）を使わない（設計判断O）。同じidの
#     メッセージが再送されるため、行番号は「まだ数えていない量」を意味しない。
#   - サブエージェントは集計しない（設計判断I。保存のみ）。
#   - **早期リターンの位置が違う。** Claude Code経路は「新規行が無ければミラーもスキップ」だが、
#     Gemini経路は内容ベースでしか判定できないため「ミラー → 畳み込み → 差分判定」の順になる。
#     ミラーは冪等な上書きコピーなので実害は無い。
#   - 前回累計はブランチ別の状態ファイルではなく usage/state/gemini-totals/<sessionId>.json
#     （ブランチ非依存）に持つ。ブランチ別に持つと、同じセッションのままブランチを切り替えた
#     ときに蓄積済みの全件が新ブランチの初回差分として再計上される。
_sync_usage_state_gemini() {
  local repo_root="$1" branch="$2" session_id="$3" transcript_path="$4"
  local state_dir="$5" state_file="$6"

  local log_dir
  log_dir="$(_usage_sync_session_logs "$repo_root" "$session_id" "$transcript_path" "gemini")"

  local snapshot
  snapshot="$(_usage_gemini_fold "${log_dir}/main.jsonl" | tr -d '\r')"

  # 状態ファイルが壊れている（空文字列・不正なJSON）場合は「状態なし」として扱う
  # （Claude Code経路と同じ自己回復方針。理由はそちらのコメントを参照）。
  local existing="{}"
  if [ -f "$state_file" ]; then
    local existing_content
    existing_content="$(cat "$state_file")"
    if [ -n "$existing_content" ] && printf '%s' "$existing_content" | jq -e . >/dev/null 2>&1; then
      existing="$existing_content"
    fi
  fi

  local prev_totals merged needs_reset diff_all_zero new_state
  prev_totals="$(_usage_read_gemini_totals "$repo_root" "$session_id")"
  merged="$(_usage_gemini_merge_state "$existing" "$snapshot" "$prev_totals" "$session_id" "$branch")"
  needs_reset="$(printf '%s' "$merged" | jq -r '.needsReset')"
  diff_all_zero="$(printf '%s' "$merged" | jq -r '.diffAllZero')"
  new_state="$(printf '%s' "$merged" | jq -c '.state')"

  if [ "$needs_reset" = "true" ]; then
    # セッションファイルの消失・縮小を検知した（設計判断S）。**早期リターンしない。**
    # 消失直後は全指標の差分が負→クランプ後すべて0になるため、クランプ後の差分で早期リターンを
    # 判定すると前回累計が古いまま残り、以後ずっと計上が止まる。
    echo "sync_usage_state: Gemini CLIのセッションログが縮小しました（sessionId=${session_id}）。前回累計をリセットし、次の断面から計上し直します（issue #97）" >&2
  elif [ "$diff_all_zero" = "true" ]; then
    # 差分なし: 状態ファイルも前回累計も書かず、既存状態をそのまま返す（設計判断O）。
    if [ -f "$state_file" ]; then
      cat "$state_file"
    fi
    return 0
  fi

  mkdir -p "$state_dir"
  printf '%s' "$new_state" > "$state_file"
  printf '%s' "$new_state"

  _usage_write_gemini_totals "$repo_root" "$session_id" "$snapshot"
}

# 指定ブランチ・セッションのtranscriptを集計し、状態ファイル（usage/state/<branch>.json）の
# sinceLastPush へ「前回pushからの新規分」を加算して保存する。更新後の状態JSONをstdoutへ出力する。
# 呼び出し元は post-push-usage-report.sh（PostToolUse, git push検知）。
# transcript_pathが存在しない場合は何も出力せず終了コード1を返す。
#
# セッション横断のカーソル（usage/state/session-cursors/<sessionId>.json）を見て、前回処理済み
# 行数以降に新規行が無ければ、session-logsへのコピー・状態更新をスキップし既存状態をそのまま返す
# （issue #37「差分がなければコピーしない」対応。push-index.jsonlへの追記も行わない）。
# 新規行があれば、usage/session-logs/<sessionId>/ へメイン・サブエージェント両方のtranscriptを
# コピーし、新規行の集計（tools/tokens/turns/詳細3種）とactiveSecondsの全件再パースをそれぞれ
# 行ったうえで、そのpushで記録された行範囲を usage/state/push-index.jsonl へ追記する。
#
# `engine`（第5引数、既定 "claude"）はサブエージェントログの探索方法の分岐に使い、
# push-index.jsonl にも記録する（issue #23）。省略時に "claude" へ倒すのは、既存の呼び出し・
# テストを壊さないため。
sync_usage_state() {
  local repo_root="$1" branch="$2" session_id="$3" transcript_path="$4" engine="${5:-claude}"

  if [ ! -f "$transcript_path" ]; then
    return 1
  fi

  local state_dir="${repo_root}/usage/state"
  local safe_branch state_file
  safe_branch="$(_usage_safe_branch_name "$branch")"
  state_file="${state_dir}/${safe_branch}.json"

  if [ "$engine" = "gemini" ]; then
    _sync_usage_state_gemini "$repo_root" "$branch" "$session_id" "$transcript_path" \
      "$state_dir" "$state_file"
    return $?
  fi

  local last_line_count
  last_line_count="$(_usage_read_cursor "$repo_root" "$session_id")"

  local agg_result total_lines
  agg_result="$(_usage_aggregate_new_lines "$transcript_path" "$last_line_count" "$branch")"
  total_lines="$(printf '%s' "$agg_result" | jq -r '.totalLines')"

  if [ "$total_lines" -le "$last_line_count" ]; then
    # 新規行が無い: session-logsへのコピー・状態更新をスキップし、既存状態をそのまま返す
    if [ -f "$state_file" ]; then
      cat "$state_file"
    fi
    return 0
  fi

  local log_dir
  log_dir="$(_usage_sync_session_logs "$repo_root" "$session_id" "$transcript_path" "$engine")"

  local delta active_seconds
  delta="$(printf '%s' "$agg_result" | jq -c 'del(.totalLines)')"
  active_seconds="$(_usage_aggregate_transcript "${log_dir}/main.jsonl" "$branch" | jq -r '.activeSeconds')"

  mkdir -p "$state_dir"
  # 状態ファイルが壊れている（空文字列・不正なJSON）場合は「状態なし」として扱う。
  # 一度でも壊れた内容が書き込まれると、_usage_merge_state の `--argjson existing "$existing"` が
  # 不正なJSONとして必ず失敗し、修正後も恒久的に集計不能になってしまうため（このバグの調査時に、
  # 実際に0バイトの状態ファイルとカーソルだけが進んだ状態を確認した）、既存データより
  # 「壊れた状態から自己回復できること」を優先する。
  local existing="{}"
  if [ -f "$state_file" ]; then
    local existing_content
    existing_content="$(cat "$state_file")"
    # `-n "$existing_content"` を先に見る理由: 空文字列（0バイトファイル）を `jq -e .` へ渡すと
    # 「有効な出力が無い」扱いとなり、環境によっては exit 0 のまま何も出力しない（＝falsyとしての
    # 失敗を検知できない）ことを実機で確認した。空文字列チェックを先に行うことで確実に弾く。
    if [ -n "$existing_content" ] && printf '%s' "$existing_content" | jq -e . >/dev/null 2>&1; then
      existing="$existing_content"
    fi
  fi

  local new_state
  new_state="$(_usage_merge_state "$existing" "$delta" "$active_seconds" "$session_id" "$branch")"

  # サブエージェント集計の戻り値は {state, agents}（issue #23）。agents はそのpushで集計した
  # agentIdごとの行範囲で、push-index.jsonl へそのまま載せる。
  local subagent_result agent_ranges
  subagent_result="$(_usage_aggregate_and_merge_subagents "$new_state" "$log_dir" "$branch" "$repo_root")"
  new_state="$(printf '%s' "$subagent_result" | jq -c '.state')"
  agent_ranges="$(printf '%s' "$subagent_result" | jq -c '.agents')"

  printf '%s' "$new_state" > "$state_file"
  printf '%s' "$new_state"

  _usage_append_push_index "$repo_root" "$branch" "$session_id" "$engine" \
    "$(( last_line_count + 1 ))" "$total_lines" "$agent_ranges"

  _usage_write_cursor "$repo_root" "$session_id" "$total_lines"
}

# post-push-usage-report.sh がMRへの投稿成功後に呼ぶ、sinceLastPushのゼロ初期化。
# 状態JSON全体（state）を受け取り、sinceLastPushをゼロ初期化・lastPostedAtを現在時刻に更新した
# 新しい状態JSONをstdoutへ返す（呼び出し元がstate_fileへ書き戻す）。他のフィールド（sessions,
# agents等）はそのまま保持する。
_usage_reset_since_last_push() {
  local state="$1"
  printf '%s' "$state" | jq \
    --arg postedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.sinceLastPush = {tokensByModel: {}, toolCalls: {}, turns: 0, activeSeconds: 0, subagents: {},
        skillCalls: [], agentCalls: [], askUserQuestions: []} | .lastPostedAt = $postedAt'
}

# サブエージェントレポート用: 前回pushからの差分が0（tokensByModel全モデル・toolCalls・
# activeSecondsのいずれも0）のagentIdを `sinceLastPush.subagents` から除外して返す（issue #34、
# 「差分0のagentはレポートに出力しない」というフィードバックへの対応）。
_usage_filter_nonzero_subagents() {
  local subagents="$1"
  printf '%s' "$subagents" | jq '
    to_entries
    | map(select(
        (((.value.tokensByModel // {}) | [.[] | (.input // 0) + (.output // 0) + (.cacheCreate // 0) + (.cacheRead // 0)] | add // 0) > 0)
        or (((.value.toolCalls // {}) | [.[]] | add // 0) > 0)
        or ((.value.activeSeconds // 0) > 0)
      ))
    | from_entries
  '
}
