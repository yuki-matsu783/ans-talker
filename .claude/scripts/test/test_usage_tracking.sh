#!/usr/bin/env bash
# .claude/hooks/lib/UsageTracking.sh の単体テスト（issue #23で新設）。
# ネットワーク・MR投稿を伴わない範囲（ミラーのコピー・push-indexの追記・サブエージェント集計の
# 戻り値形・sync_usage_stateの一連の更新）を、mktemp -d のフィクスチャで検証する。
# 規約: passed=N failures=N を標準出力へ出し、失敗があれば終了コード1
#       （.claude/rules/shell-script-style.md「テスト」）。
# 実行: bash .claude/scripts/test/test_usage_tracking.sh
set -euo pipefail

script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" == "${BASH_SOURCE[0]}" ]] && script_dir="."
repo_root="$(cd "$script_dir/../../.." && pwd)"

# shellcheck source=../../../.claude/hooks/lib/UsageTracking.sh
source "$repo_root/.claude/hooks/lib/UsageTracking.sh"

passed=0
failures=0

fixture_dir="$(mktemp -d)"
cleanup_fixtures() {
  rm -rf "$fixture_dir"
}
trap cleanup_fixtures EXIT

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

assert_file_exists() {
  local name="$1" path="$2"
  if [[ -f "$path" ]]; then
    passed=$((passed + 1))
  else
    failures=$((failures + 1))
    echo "FAIL: $name"
    echo "  ファイルが存在しません: $path"
  fi
}

assert_not_exists() {
  local name="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    passed=$((passed + 1))
  else
    failures=$((failures + 1))
    echo "FAIL: $name"
    echo "  存在しないはずのパスがあります: $path"
  fi
}

# assistantエントリを1行生成する（集計対象になる最小構造）
make_entry() {
  local branch="$1" ts="$2" tool="${3:-}"
  jq -c -n --arg branch "$branch" --arg ts "$ts" --arg tool "$tool" '
    {type: "assistant", gitBranch: $branch, timestamp: $ts,
     message: {model: "claude-sonnet-5",
       usage: {input_tokens: 10, output_tokens: 5,
               cache_creation_input_tokens: 0, cache_read_input_tokens: 0},
       content: (if $tool == "" then [] else [{type: "tool_use", name: $tool, id: "t1", input: {}}] end)}}
  '
}

# =============================================================================
# _usage_append_push_index
# =============================================================================

idx_root="$fixture_dir/idxrepo"
mkdir -p "$idx_root"
index_file="$idx_root/usage/state/push-index.jsonl"

_usage_append_push_index "$idx_root" "feature-x" "sess-1" "claude" 1 10 '{}'

assert_file_exists "push-index: 初回でファイルが作られる" "$index_file"
assert_eq "push-index: 初回は push=1" "1" \
  "$(jq -r '.push' "$index_file" | tr -d '\r')"
assert_eq "push-index: 初回の行範囲" "1-10" \
  "$(jq -r '"\(.main.from)-\(.main.to)"' "$index_file" | tr -d '\r')"
assert_eq "push-index: branch/sessionId/engineが記録される" "feature-x|sess-1|claude" \
  "$(jq -r '"\(.branch)|\(.sessionId)|\(.engine)"' "$index_file" | tr -d '\r')"

_usage_append_push_index "$idx_root" "feature-x" "sess-1" "claude" 11 25 \
  '{"ag1":{"from":1,"to":7}}'

assert_eq "push-index: 2回目は push=2（最大値+1）" "2" \
  "$(jq -s -r '.[1].push' "$index_file" | tr -d '\r')"
assert_eq "push-index: 2回目の行範囲" "11-25" \
  "$(jq -s -r '"\(.[1].main.from)-\(.[1].main.to)"' "$index_file" | tr -d '\r')"
assert_eq "push-index: agentsが記録される" "1-7" \
  "$(jq -s -r '"\(.[1].agents.ag1.from)-\(.[1].agents.ag1.to)"' "$index_file" | tr -d '\r')"
assert_eq "push-index: 行数は2行" "2" "$(grep -c '' "$index_file")"
# WindowsネイティブjqのCR混入対策（tr -d '\r'）が効いていることの確認。
# `grep -c $'\r'` は環境によってパターンが空文字として渡り全行にマッチしてしまう（実機で確認）ため、
# CRを除去する前後のバイト数を比較する形で判定する。
assert_eq "push-index: CRが混入していない" \
  "$(wc -c < "$index_file")" \
  "$(tr -d '\r' < "$index_file" | wc -c)"

# agent_ranges を省略した場合は {} が既定になる（`"${7:-\{\}}"` の書き方だと
# バックスラッシュが残って不正なJSONになる、というバグの回帰テスト）
_usage_append_push_index "$idx_root" "feature-x" "sess-1" "claude" 26 30
assert_eq "push-index: agent_ranges省略時は空オブジェクト" "{}" \
  "$(jq -s -c -r '.[2].agents' "$index_file" | tr -d '\r')"

# =============================================================================
# _usage_sync_session_logs（Claude Code）
# =============================================================================

cc_root="$fixture_dir/ccrepo"
cc_src="$fixture_dir/ccsrc"
mkdir -p "$cc_src/sess-cc/subagents"
make_entry "feature-y" "2026-08-18T00:00:00Z" > "$cc_src/sess-cc.jsonl"
make_entry "feature-y" "2026-08-18T00:00:10Z" "Read" > "$cc_src/sess-cc/subagents/agent-ag1.jsonl"
printf '%s\n' '{"agentType":"Explore","description":"調査用"}' \
  > "$cc_src/sess-cc/subagents/agent-ag1.meta.json"

cc_log_dir="$(_usage_sync_session_logs "$cc_root" "sess-cc" "$cc_src/sess-cc.jsonl" "claude")"

assert_eq "sync(claude): コピー先はセッション単位（ブランチ階層が無い）" \
  "$cc_root/usage/session-logs/sess-cc" "$cc_log_dir"
assert_file_exists "sync(claude): main.jsonl がコピーされる" "$cc_log_dir/main.jsonl"
assert_file_exists "sync(claude): agent-*.jsonl が subagents/ 直下へコピーされる" \
  "$cc_log_dir/subagents/agent-ag1.jsonl"
assert_file_exists "sync(claude): .meta.json もコピーされる" \
  "$cc_log_dir/subagents/agent-ag1.meta.json"

# engine省略時はclaudeとして扱う（既存呼び出しの互換性）
cc_root2="$fixture_dir/ccrepo2"
cc_log_dir2="$(_usage_sync_session_logs "$cc_root2" "sess-cc" "$cc_src/sess-cc.jsonl")"
assert_file_exists "sync: engine省略時もClaude Code構造で動く" \
  "$cc_log_dir2/subagents/agent-ag1.jsonl"

# =============================================================================
# _usage_sync_session_logs（Gemini CLI）
# =============================================================================

gm_root="$fixture_dir/gmrepo"
gm_src="$fixture_dir/gmsrc"
mkdir -p "$gm_src/sess-gm"
make_entry "feature-y" "2026-08-18T00:00:00Z" > "$gm_src/sess-gm.jsonl"
make_entry "feature-y" "2026-08-18T00:00:10Z" "Read" > "$gm_src/sess-gm/agent-inner.jsonl"

gm_log_dir="$(_usage_sync_session_logs "$gm_root" "sess-gm" "$gm_src/sess-gm.jsonl" "gemini")"

assert_file_exists "sync(gemini): main.jsonl がコピーされる" "$gm_log_dir/main.jsonl"
assert_file_exists "sync(gemini): subagents/<session_id>/ 配下へコピーされる" \
  "$gm_log_dir/subagents/sess-gm/agent-inner.jsonl"
# 集計側の glob `subagents/agent-*.jsonl` に**マッチしないこと**が、
# 「Geminiのログは保存するが集計対象にはしない」というスコープ境界の担保になっている
assert_not_exists "sync(gemini): subagents/直下には置かれない（集計globに掛からない）" \
  "$gm_log_dir/subagents/agent-inner.jsonl"

# =============================================================================
# _usage_aggregate_and_merge_subagents の戻り値形
# =============================================================================

sa_root="$fixture_dir/sarepo"
mkdir -p "$sa_root/usage/state"
empty_state='{"branch":"feature-y","sessions":{},"sinceLastPush":{"tokensByModel":{},"toolCalls":{},"turns":0,"activeSeconds":0,"skillCalls":[],"agentCalls":[],"askUserQuestions":[]}}'

# サブエージェントが1件も無い場合
no_sub_dir="$fixture_dir/nosub"
mkdir -p "$no_sub_dir"
res="$(_usage_aggregate_and_merge_subagents "$empty_state" "$no_sub_dir" "feature-y" "$sa_root")"
assert_eq "subagents: サブエージェント無しでも {state, agents} を返す" "state agents" \
  "$(printf '%s' "$res" | jq -r 'keys_unsorted | join(" ")' | tr -d '\r')"
assert_eq "subagents: サブエージェント無しなら agents は空" "{}" \
  "$(printf '%s' "$res" | jq -c '.agents' | tr -d '\r')"

# サブエージェントが1件ある場合
res2="$(_usage_aggregate_and_merge_subagents "$empty_state" "$cc_log_dir" "feature-y" "$sa_root")"
assert_eq "subagents: 集計したagentの行範囲が agents に載る" "1-1" \
  "$(printf '%s' "$res2" | jq -r '"\(.agents.ag1.from)-\(.agents.ag1.to)"' | tr -d '\r')"
assert_eq "subagents: stateへagentIdごとの差分が畳み込まれる" "Explore" \
  "$(printf '%s' "$res2" | jq -r '.state.agents.ag1.agentType' | tr -d '\r')"

# 2回目（新規行が無い）はスキップされ、agents に現れない
res3="$(_usage_aggregate_and_merge_subagents "$empty_state" "$cc_log_dir" "feature-y" "$sa_root")"
assert_eq "subagents: 新規行が無いagentは agents に現れない" "{}" \
  "$(printf '%s' "$res3" | jq -c '.agents' | tr -d '\r')"

# =============================================================================
# sync_usage_state（一連の更新）
# =============================================================================

sy_root="$fixture_dir/syrepo"
sy_src="$fixture_dir/sysrc"
mkdir -p "$sy_root" "$sy_src"
{
  make_entry "feature-z" "2026-08-18T00:00:00Z" "Read"
  make_entry "feature-z" "2026-08-18T00:00:30Z" "Bash"
} > "$sy_src/sess-sy.jsonl"

sync_usage_state "$sy_root" "feature-z" "sess-sy" "$sy_src/sess-sy.jsonl" "claude" >/dev/null

assert_file_exists "sync_usage_state: 新レイアウトのミラーが作られる" \
  "$sy_root/usage/session-logs/sess-sy/main.jsonl"
assert_not_exists "sync_usage_state: 旧レイアウト（ブランチ階層）は作られない" \
  "$sy_root/usage/session-logs/feature-z"
assert_file_exists "sync_usage_state: 状態ファイルが作られる" \
  "$sy_root/usage/state/feature-z.json"
assert_eq "sync_usage_state: カーソルが進む" "2" \
  "$(jq -r '.lastLineCount' "$sy_root/usage/state/session-cursors/sess-sy.json" | tr -d '\r')"
assert_eq "sync_usage_state: push-indexへ1行追記される" "1" \
  "$(grep -c '' "$sy_root/usage/state/push-index.jsonl")"
assert_eq "sync_usage_state: push-indexの行範囲が全行を指す" "1-2" \
  "$(jq -r '"\(.main.from)-\(.main.to)"' "$sy_root/usage/state/push-index.jsonl" | tr -d '\r')"
assert_eq "sync_usage_state: ツール実行回数が集計される" "1" \
  "$(jq -r '.sinceLastPush.toolCalls.Read' "$sy_root/usage/state/feature-z.json" | tr -d '\r')"

# 2回目: 新規行が無いのでpush-indexは増えない
sync_usage_state "$sy_root" "feature-z" "sess-sy" "$sy_src/sess-sy.jsonl" "claude" >/dev/null
assert_eq "sync_usage_state: 新規行が無ければpush-indexは増えない" "1" \
  "$(grep -c '' "$sy_root/usage/state/push-index.jsonl")"

# 3回目: 行を追記してから呼ぶと、続きの範囲が記録される
make_entry "feature-z" "2026-08-18T00:01:00Z" "Edit" >> "$sy_src/sess-sy.jsonl"
sync_usage_state "$sy_root" "feature-z" "sess-sy" "$sy_src/sess-sy.jsonl" "claude" >/dev/null
assert_eq "sync_usage_state: 追記後は push=2 が積まれる" "2" \
  "$(grep -c '' "$sy_root/usage/state/push-index.jsonl")"
assert_eq "sync_usage_state: 続きの行範囲が記録される" "3-3" \
  "$(jq -s -r '.[1] | "\(.main.from)-\(.main.to)"' "$sy_root/usage/state/push-index.jsonl" | tr -d '\r')"


# ------------------------------------------------------------------------------------------
# Gemini CLI のセッションログ集計（issue #97）
# ------------------------------------------------------------------------------------------
# 既存33ケース（Claude Code経路）のアサーションは1行も変更していない。既存が通り続けることが
# 「Claude Code側の集計結果が変わらない」ことの担保であり、レポート内容の担保はケース13が持つ。
#
# 注意（`tr -d '\r'`）: WindowsネイティブjqはコマンドE置換経由でも行末へCRを付与するため、
# `jq -r` の結果を assert_eq へ渡す前に必ず除去する（issue #94 と同じ罠を踏まないため）。

gm_dir="$fixture_dir/gemini"
mkdir -p "$gm_dir"

# 代表フィクスチャ: メタデータ行・同一idの再送（tokens欠落→値あり→再びtokens欠落）・
# $rewindTo・各statusのtoolCalls・不正JSON行 を1本に含む。
cat > "$gm_dir/main.jsonl" <<'GEMJSONL'
{"sessionId":"s1","projectHash":"abc","startTime":"2026-08-20T10:00:00.000Z","kind":"session","directories":["/x"]}
{"id":"m1","type":"user","timestamp":"2026-08-20T10:00:00.000Z","content":"hi"}
{"id":"m2","type":"gemini","timestamp":"2026-08-20T10:00:10.000Z","model":"gemini-2.5-pro","tokens":null,"toolCalls":[{"id":"t1","name":"read_file","status":"executing"}]}
{"id":"m2","type":"gemini","timestamp":"2026-08-20T10:00:10.000Z","model":"gemini-2.5-pro","tokens":{"input":100,"output":20,"cached":5,"thoughts":7,"tool":3,"total":135},"toolCalls":[{"id":"t1","name":"read_file","status":"success"}]}
{"$rewindTo":"m2"}
{"id":"m3","type":"gemini","timestamp":"2026-08-20T10:00:40.000Z","model":"gemini-2.5-pro","tokens":{"input":50,"output":10,"cached":0,"thoughts":0,"tool":0,"total":60},"toolCalls":[{"id":"t2","name":"run_shell_command","status":"error"},{"id":"t3","name":"run_shell_command","status":"cancelled"},{"id":"t4","name":"write_file","status":"awaiting_approval"}]}
{"id":"m2","type":"gemini","timestamp":"2026-08-20T10:00:10.000Z","model":"gemini-2.5-pro","toolCalls":[{"id":"t1","name":"read_file","status":"success"}]}
this line is not json
GEMJSONL

gm_snap="$(_usage_gemini_fold "$gm_dir/main.jsonl" | tr -d '\r')"

# ケース2: リビジョン再送。後勝ちマージだが tokens は消えず、ツールは1回だけ数えられる
assert_eq "gemini fold: 再送されたメッセージは1ターンとして数える" "2" \
  "$(printf '%s' "$gm_snap" | jq -r '.turns')"
assert_eq "gemini fold: 後勝ちマージでもtokensが消えない（input合計）" "150" \
  "$(printf '%s' "$gm_snap" | jq -r '.tokens["gemini-2.5-pro"].input')"
assert_eq "gemini fold: totalは加算しない（thoughtsが独立に積まれる）" "7" \
  "$(printf '%s' "$gm_snap" | jq -r '.tokens["gemini-2.5-pro"].thoughts')"
assert_eq "gemini fold: 同一idのツールは1回だけ数える" "1" \
  "$(printf '%s' "$gm_snap" | jq -r '.tools.read_file')"

# ケース4: $rewindTo はメッセージを削らない
assert_eq "gemini fold: \$rewindTo後のメッセージも残る（m2の20＋m3の10）" "30" \
  "$(printf '%s' "$gm_snap" | jq -r '.tokens["gemini-2.5-pro"].output')"

# ケース7: 不正JSON行を捨てても落ちない（行数には数える）
assert_eq "gemini fold: 不正JSON行を捨てても総行数は数える" "8" \
  "$(printf '%s' "$gm_snap" | jq -r '.totalLines')"

# ケース8: statusの扱い（error のみエラー / cancelled は実行回数 / 未完了はどちらにも入らない）
assert_eq "gemini fold: cancelledも実行回数に含める" "2" \
  "$(printf '%s' "$gm_snap" | jq -r '.tools.run_shell_command')"
assert_eq "gemini fold: 未完了(awaiting_approval)は実行回数に入れない" "null" \
  "$(printf '%s' "$gm_snap" | jq -r '.tools.write_file')"
assert_eq "gemini fold: errorのみエラーに数える" "1" \
  "$(printf '%s' "$gm_snap" | jq -r '.toolErrors.run_shell_command')"
assert_eq "gemini fold: cancelledはエラーに数えない" "1" \
  "$(printf '%s' "$gm_snap" | jq -r '.toolErrors | length')"

# ケース9: activeSeconds（timestamp昇順に並べ直す＋末尾のTAIL_BUFFER加算）
assert_eq "gemini fold: activeSecondsはgap積算＋末尾TAIL_BUFFER" "70" \
  "$(printf '%s' "$gm_snap" | jq -r '.activeSeconds')"
printf '%s\n' '{"id":"only","type":"gemini","timestamp":"2026-08-20T10:00:00.000Z","model":"m"}' \
  > "$gm_dir/single.jsonl"
assert_eq "gemini fold: メッセージ1件でもactiveSecondsが0にならない（末尾加算）" "$TAIL_BUFFER_SECONDS" \
  "$(_usage_gemini_fold "$gm_dir/single.jsonl" | tr -d '\r' | jq -r '.activeSeconds')"

# ケース7（続き）: 空ファイル
: > "$gm_dir/empty.jsonl"
assert_eq "gemini fold: 空ファイルでも落ちない" "0" \
  "$(_usage_gemini_fold "$gm_dir/empty.jsonl" | tr -d '\r' | jq -r '.turns')"

# ケース3: $set.messages による全メッセージ再送でも二重計上しない
cp "$gm_dir/main.jsonl" "$gm_dir/reset.jsonl"
{
  printf '{"$set":{"messages":['
  printf '{"id":"m2","type":"gemini","timestamp":"2026-08-20T10:00:10.000Z","model":"gemini-2.5-pro","tokens":{"input":100,"output":20,"cached":5,"thoughts":7,"tool":3,"total":135},"toolCalls":[{"id":"t1","name":"read_file","status":"success"}]},'
  printf '{"id":"m3","type":"gemini","timestamp":"2026-08-20T10:00:40.000Z","model":"gemini-2.5-pro","tokens":{"input":50,"output":10,"cached":0,"thoughts":0,"tool":0,"total":60},"toolCalls":[{"id":"t2","name":"run_shell_command","status":"error"}]}'
  printf ']}}\n'
} >> "$gm_dir/reset.jsonl"
assert_eq "gemini fold: \$set.messagesの再送で二重計上しない" "150" \
  "$(_usage_gemini_fold "$gm_dir/reset.jsonl" | tr -d '\r' | jq -r '.tokens["gemini-2.5-pro"].input')"

# ケース1: 同じスナップショットを2回突き合わせると差分が全て0
gm_prev="$(printf '%s' "$gm_snap" | jq -c 'del(.models)')"
gm_first="$(_usage_gemini_merge_state '{}' "$gm_snap" '{}' "s1" "br-a")"
assert_eq "gemini merge: 初回は差分0ではない" "false" \
  "$(printf '%s' "$gm_first" | jq -r '.diffAllZero')"
assert_eq "gemini merge: 初回のturnsが計上される" "2" \
  "$(printf '%s' "$gm_first" | jq -r '.state.sinceLastPush.turns')"
assert_eq "gemini merge: cachedはcacheReadへ入る" "5" \
  "$(printf '%s' "$gm_first" | jq -r '.state.sinceLastPush.tokensByModel["gemini-2.5-pro"].cacheRead')"
assert_eq "gemini merge: Geminiではのま cacheCreate は0のまま" "0" \
  "$(printf '%s' "$gm_first" | jq -r '.state.sinceLastPush.tokensByModel["gemini-2.5-pro"].cacheCreate')"
assert_eq "gemini merge: modelsが載る" "gemini-2.5-pro" \
  "$(printf '%s' "$gm_first" | jq -r '.state.sinceLastPush.models | join(",")')"
gm_state1="$(printf '%s' "$gm_first" | jq -c '.state')"
assert_eq "gemini merge: 同じスナップショットの再突合は差分0（二重計上しない）" "true" \
  "$(_usage_gemini_merge_state "$gm_state1" "$gm_snap" "$gm_prev" "s1" "br-a" | jq -r '.diffAllZero')"

# ケース5: 切り詰め（累計が一致していれば差分0のまま）
assert_eq "gemini merge: 切り詰めても累計が同じなら差分0" "true" \
  "$(_usage_gemini_merge_state "$gm_state1" "$gm_snap" "$gm_prev" "s1" "br-a" | jq -r '.diffAllZero')"

# ケース6: セッションファイル消失（累計が減る）
gm_shrunk="$(printf '%s' "$gm_snap" | jq -c '.turns = 1 | .tokens["gemini-2.5-pro"].input = 10')"
gm_reset="$(_usage_gemini_merge_state "$gm_state1" "$gm_shrunk" "$gm_prev" "s1" "br-a")"
assert_eq "gemini merge: 消失検知でneedsResetが立つ" "true" \
  "$(printf '%s' "$gm_reset" | jq -r '.needsReset')"
assert_eq "gemini merge: 消失時はdiffAllZeroにしない（早期リターンさせない）" "false" \
  "$(printf '%s' "$gm_reset" | jq -r '.diffAllZero')"
assert_eq "gemini merge: 負値はクランプされsinceLastPushが減らない" "150" \
  "$(printf '%s' "$gm_reset" | jq -r '.state.sinceLastPush.tokensByModel["gemini-2.5-pro"].input')"

# ケース10: sync_usage_state を engine=gemini で通す結合ケース
gm_root="$fixture_dir/gemini-repo"
mkdir -p "$gm_root"
sync_usage_state "$gm_root" "br-a" "s1" "$gm_dir/main.jsonl" "gemini" >/dev/null
assert_file_exists "sync(gemini): 状態ファイルが書かれる" "$gm_root/usage/state/br-a.json"
assert_file_exists "sync(gemini): 前回累計がセッション単位で書かれる" \
  "$gm_root/usage/state/gemini-totals/s1.json"
assert_not_exists "sync(gemini): 行カーソルは使わない" \
  "$gm_root/usage/state/session-cursors/s1.json"
assert_eq "sync(gemini): ミラーが作られる" "1" \
  "$([ -f "$gm_root/usage/session-logs/s1/main.jsonl" ] && echo 1 || echo 0)"
assert_eq "sync(gemini): sinceLastPushへ計上される" "2" \
  "$(jq -r '.sinceLastPush.turns' "$gm_root/usage/state/br-a.json" | tr -d '\r')"
gm_state_before="$(cat "$gm_root/usage/state/br-a.json")"
sync_usage_state "$gm_root" "br-a" "s1" "$gm_dir/main.jsonl" "gemini" >/dev/null
assert_eq "sync(gemini): 2回目は差分0で状態が変わらない" "$gm_state_before" \
  "$(cat "$gm_root/usage/state/br-a.json")"

# ケース11: 同一sessionIdでブランチを A → B へ切り替えても再計上しない（issue #37と同型の回帰）
sync_usage_state "$gm_root" "br-b" "s1" "$gm_dir/main.jsonl" "gemini" >/dev/null
assert_not_exists "sync(gemini): ブランチ切替後も新ブランチへ再計上しない" \
  "$gm_root/usage/state/br-b.json"

# ケース12: 消失検知の翌回。前回累計が上書きされ、続く断面が正しく計上される
gm_root2="$fixture_dir/gemini-repo2"
mkdir -p "$gm_root2"
sync_usage_state "$gm_root2" "br-a" "s2" "$gm_dir/main.jsonl" "gemini" >/dev/null
# セッションが作り直されて短くなった状況を作る（m2のみ）
sed -n '1p;4p' "$gm_dir/main.jsonl" > "$gm_dir/shrunk.jsonl"
sync_usage_state "$gm_root2" "br-a" "s2" "$gm_dir/shrunk.jsonl" "gemini" 2>/dev/null >/dev/null
assert_eq "sync(gemini): 消失検知後は前回累計が新しい値へ上書きされる" "1" \
  "$(jq -r '.turns' "$gm_root2/usage/state/gemini-totals/s2.json" | tr -d '\r')"
# 続けて新しいメッセージが増えたら、その分だけが計上される
gm_turns_before="$(jq -r '.sinceLastPush.turns' "$gm_root2/usage/state/br-a.json" | tr -d '\r')"
printf '%s\n' '{"id":"m9","type":"gemini","timestamp":"2026-08-20T10:00:20.000Z","model":"gemini-2.5-pro","tokens":{"input":1,"output":1,"cached":0,"thoughts":0,"tool":0,"total":2}}' \
  >> "$gm_dir/shrunk.jsonl"
sync_usage_state "$gm_root2" "br-a" "s2" "$gm_dir/shrunk.jsonl" "gemini" >/dev/null
assert_eq "sync(gemini): 消失後も次の断面から計上が再開する" "$((gm_turns_before + 1))" \
  "$(jq -r '.sinceLastPush.turns' "$gm_root2/usage/state/br-a.json" | tr -d '\r')"

# ------------------------------------------------------------------------------------------
# ケース13: レポート本文の組み立て（post-push-usage-report.sh の build_usage_report_body）
# ------------------------------------------------------------------------------------------
# (a) が「Claude Codeでのレポート内容が変化しない」ことの担保である。上の既存33ケースは
# UsageTracking.sh（集計側）のテストであり、レポート本文は1ケースも通っていない。
# shellcheck source=../../../.claude/hooks/post-push-usage-report.sh
source "$repo_root/.claude/hooks/post-push-usage-report.sh"

rp_claude='{"tokensByModel":{"claude-3-5-sonnet-20241022":{"input":12345,"output":6789,"cacheCreate":100,"cacheRead":2000},"<synthetic>":{"input":0,"output":0,"cacheCreate":0,"cacheRead":0}},"toolCalls":{"Bash":3,"Read":0},"turns":5,"activeSeconds":3700,"skillCalls":[],"agentCalls":[],"askUserQuestions":[]}'
rp_gemini='{"tokensByModel":{"gemini-2.5-pro":{"input":150,"output":30,"cacheCreate":0,"cacheRead":5,"thoughts":7,"tool":3}},"toolCalls":{"read_file":1},"toolErrors":{"run_shell_command":1},"models":["gemini-2.5-pro"],"turns":2,"activeSeconds":70,"skillCalls":[],"agentCalls":[],"askUserQuestions":[]}'
rp_mixed='{"tokensByModel":{"gemini-2.5-pro":{"input":150,"output":30,"cacheCreate":0,"cacheRead":5,"thoughts":7,"tool":3},"claude-opus-5":{"input":9000,"output":800,"cacheCreate":70,"cacheRead":1200}},"toolCalls":{},"models":["gemini-2.5-pro"],"turns":4,"activeSeconds":300,"skillCalls":[],"agentCalls":[],"askUserQuestions":[]}'
rp_notokens='{"tokensByModel":{},"toolCalls":{"read_file":3},"toolErrors":{},"models":["gemini-2.5-pro"],"turns":2,"activeSeconds":70,"skillCalls":[],"agentCalls":[],"askUserQuestions":[]}'
rp_toolonly='{"tokensByModel":{"gemini-2.5-flash":{"input":0,"output":0,"cacheCreate":0,"cacheRead":0,"thoughts":0,"tool":42}},"toolCalls":{},"models":["gemini-2.5-flash"],"turns":1,"activeSeconds":30,"skillCalls":[],"agentCalls":[],"askUserQuestions":[]}'

rp_body="$(build_usage_report_body "$rp_claude" "feature-x" "true" '{}' 'Claude Code')"
# (a) Claude Code経路: 現行と同じ4列・同じ0行除外・Gemini固有の行が出ないこと
assert_eq "report(claude): 列構成が現行のまま" "| モデル | Input | Output | Cache Write | Cache Read |" \
  "$(printf '%s' "$rp_body" | grep -F '| モデル |')"
assert_eq "report(claude): 3桁区切りが入りモデル名の数字は区切られない" \
  "| claude-3-5-sonnet-20241022 | 12,345 | 6,789 | 100 | 2,000 |" \
  "$(printf '%s' "$rp_body" | grep -F 'claude-3-5-sonnet')"
assert_eq "report(claude): 全項目0のモデル行は出ない" "0" \
  "$(printf '%s' "$rp_body" | grep -cF '<synthetic>' || true)"
assert_eq "report(claude): 使用モデル行は出ない" "0" \
  "$(printf '%s' "$rp_body" | grep -cF -- '- 使用モデル:' || true)"
assert_eq "report(claude): ツールエラー行は出ない" "0" \
  "$(printf '%s' "$rp_body" | grep -cF 'ツールエラー回数' || true)"
assert_eq "report(claude): 初回投稿では過小カウントの注記が出る" "1" \
  "$(printf '%s' "$rp_body" | grep -cF '既知の過小カウント要因が報告されています。')"
assert_eq "report(claude): 過小カウントの詳細リンクが出る" "1" \
  "$(printf '%s' "$rp_body" | grep -cF 'claude-code-jsonl-logs-undercount-tokens')"
assert_eq "report(claude): ブランチ帰属の注記は出ない" "0" \
  "$(printf '%s' "$rp_body" | grep -cF 'ブランチ情報が無いため' || true)"

# (b) Gemini経路: Thoughts/Tool列・ツールエラー行・使用モデル行
rp_body="$(build_usage_report_body "$rp_gemini" "feature-x" "false" '{}' 'Gemini CLI')"
assert_eq "report(gemini): Cache Writeを出さずThoughts/Toolを出す" \
  "| モデル | Input | Output | Cache Read | Thoughts | Tool |" \
  "$(printf '%s' "$rp_body" | grep -F '| モデル |')"
assert_eq "report(gemini): 使用モデル行が出る" "- 使用モデル: gemini-2.5-pro" \
  "$(printf '%s' "$rp_body" | grep -F -- '- 使用モデル:')"
assert_eq "report(gemini): ツールエラー行が出る" "**ツールエラー回数**: run_shell_command: 1" \
  "$(printf '%s' "$rp_body" | grep -F 'ツールエラー回数')"
assert_eq "report(gemini): ブランチ帰属の注記が出る" "1" \
  "$(printf '%s' "$rp_body" | grep -cF 'ブランチ情報が無いため')"

# (c) 混在: 両方の列の和集合（6列）が出る
rp_body="$(build_usage_report_body "$rp_mixed" "feature-x" "false" '{}' 'Gemini CLI')"
assert_eq "report(混在): 6列すべてが出る" \
  "| モデル | Input | Output | Cache Write | Cache Read | Thoughts | Tool |" \
  "$(printf '%s' "$rp_body" | grep -F '| モデル |')"
assert_eq "report(混在): Claude由来の行のCache Writeが消えない" "1" \
  "$(printf '%s' "$rp_body" | grep -cF '| claude-opus-5 | 9,000 | 800 | 70 | 1,200 | 0 | 0 |')"

# (d) トークンが1件も取れないとき、テーブルをヘッダごと出さない
rp_body="$(build_usage_report_body "$rp_notokens" "feature-x" "false" '{}' 'Gemini CLI')"
assert_eq "report: モデル行が0件ならテーブルのヘッダごと出さない" "0" \
  "$(printf '%s' "$rp_body" | grep -cF '| モデル |' || true)"
assert_eq "report: テーブルが無くてもツール実行回数は出る" "1" \
  "$(printf '%s' "$rp_body" | grep -cF '**ツール実行回数**: read_file: 3')"

# (e) thoughts/tool だけが正のモデル行がスキップされない
rp_body="$(build_usage_report_body "$rp_toolonly" "feature-x" "false" '{}' 'Gemini CLI')"
assert_eq "report: toolトークンのみ正のモデル行もスキップしない" \
  "| gemini-2.5-flash | 0 | 0 | 0 | 0 | 42 |" \
  "$(printf '%s' "$rp_body" | grep -F '| gemini-2.5-flash |')"

# (f) 過小カウントの注記はClaude Code由来のトークンを含むレポートにだけ出す
#     （Gemini CLIについては同種の報告が無いため。engineではなくデータで決める）
rp_body="$(build_usage_report_body "$rp_gemini" "feature-x" "true" '{}' 'Gemini CLI')"
assert_eq "report(gemini): 初回投稿でもフッター署名は出る" "1" \
  "$(printf '%s' "$rp_body" | grep -cF '### Gemini CLIより')"
assert_eq "report(gemini): 目安である旨の注記は出る" "1" \
  "$(printf '%s' "$rp_body" | grep -cF '目安として扱ってください。')"
assert_eq "report(gemini): 過小カウントの注記は出ない" "0" \
  "$(printf '%s' "$rp_body" | grep -cF '既知の過小カウント要因が報告されています。' || true)"
assert_eq "report(gemini): 過小カウントの詳細リンクも出ない" "0" \
  "$(printf '%s' "$rp_body" | grep -cF 'claude-code-jsonl-logs-undercount-tokens' || true)"

rp_body="$(build_usage_report_body "$rp_notokens" "feature-x" "true" '{}' 'Gemini CLI')"
assert_eq "report(gemini/トークン無し): 過小カウントの注記は出ない" "0" \
  "$(printf '%s' "$rp_body" | grep -cF '既知の過小カウント要因が報告されています。' || true)"

# Gemini CLIからの投稿でも、繰り越しでClaude Code由来の行が載っていれば注記が要る
rp_body="$(build_usage_report_body "$rp_mixed" "feature-x" "true" '{}' 'Gemini CLI')"
assert_eq "report(混在): Gemini CLIからの投稿でも過小カウントの注記が出る" "1" \
  "$(printf '%s' "$rp_body" | grep -cF '既知の過小カウント要因が報告されています。')"

# 全項目0で表から除外されるClaude Code由来の行は、注記の根拠にしない
rp_zeroclaude='{"tokensByModel":{"gemini-2.5-pro":{"input":150,"output":30,"cacheCreate":0,"cacheRead":5,"thoughts":7,"tool":3},"<synthetic>":{"input":0,"output":0,"cacheCreate":0,"cacheRead":0}},"toolCalls":{},"models":["gemini-2.5-pro"],"turns":1,"activeSeconds":30,"skillCalls":[],"agentCalls":[],"askUserQuestions":[]}'
rp_body="$(build_usage_report_body "$rp_zeroclaude" "feature-x" "true" '{}' 'Gemini CLI')"
assert_eq "report(0行のみClaude由来): 表に出ない行を根拠に注記を出さない" "0" \
  "$(printf '%s' "$rp_body" | grep -cF '既知の過小カウント要因が報告されています。' || true)"

echo "passed=$passed failures=$failures"
[ "$failures" -eq 0 ]
