---
title: 0022. push断面の全文コピーをやめ行番号インデックスで表現する
type: ddr
description: セッションログの二重保存（logs/push-<N>/とusage/session-logs/）を解消し、push断面をpush-index.jsonlの行範囲で表現する方針を記録したDDR
tags: [session-logs, usage-report, ddr]
keywords: [push-index, session-logs, 追記専用, compact, prefix一致, ミラー統合, Gemini CLI, 行範囲, show-push-log]
---

# 0022. push断面の全文コピーをやめ行番号インデックスで表現する

## 背景

issue #23。`git push` のたびにセッションログを保存する仕組みが2系統に分かれていた。

| | `logs/push-<N>/` | `usage/session-logs/` |
|---|---|---|
| 所有hook | `post-push-save-logs.sh`（issue #3） | `post-push-usage-report.sh` → `UsageTracking.sh`（issue #37） |
| 単位 | pushごとにtranscript全文 | セッションごとに1本（上書き） |
| 用途 | 人間が直接参照する生ログのアーカイブ | 対応工数レポートの集計対象 |
| 実測サイズ | 14MB（11断面時点。作業終盤には23MBまで増加） | 13MB |

いずれも同じtranscript（`~/.claude/projects/<sessionId>.jsonl`）のコピーであり、計27MBが
実質1セッション約1MBの一次データの重複だった。`logs/` はpush回数に比例して増え続ける。

加えて、`logs/` を**読むコードはリポジトリ内に一つも存在しなかった**
（`grep -rn 'logs/push\|logs_dest_dir'` でヒットするのは書き手であるhook自身とその仕様書のみ）。

## 決定の根拠となった実測

### 1. transcriptは追記専用であり、push断面は現物のprefixと完全一致する

同一セッションの各push断面を、現物transcriptの先頭N行とバイト単位で比較した。

```
push-7  (253行) → 現物の先頭253行と完全一致
push-8  (476行) → 同上
push-9  (545行) → 同上
push-10 (553行) → 同上
push-11 (698行) → 同上
（現物: 883行）
```

### 2. `/compact` はこの性質を壊さない

「compactするとログが消えるのではないか」という懸念に対し、実際に `/compact` を実行した
セッションのtranscriptを調べた。

```jsonl
{"type":"system","subtype":"compact_boundary","content":"Conversation compacted",
 "compactMetadata":{"trigger":"manual","preTokens":251995,"postTokens":15679,
 "cumulativeDroppedTokens":236316,...}}          ← 570行目に追記される
{"type":"user","message":{...},"isCompactSummary":true,...}  ← 571行目に要約が追記される
```

- compactは境界行と要約行を**追記**するだけで、それより前の行を削除しない。
- `preTokens: 251995 → postTokens: 15679` は「次回以降**モデルへ送る**コンテキスト」の圧縮量で
  あって、ディスク上のファイルサイズの話ではない。
- 上記1のpush-10（553行）は**compact境界（570行目）より前**の断面だが、compact後の現物とも
  完全一致した。これがcompact非破壊性の最も強い証拠になった。
- 対応工数レポートのカーソル（`session-cursors/<sessionId>.json` の `lastLineCount`）も、
  compact境界を問題なく通過して進んでいた。

### 3. カーソルとミラーのキー設計がずれていた

issue #37でカーソルは `usage/state/session-cursors/<sessionId>.json` と**ブランチ非依存**へ
グローバル化されたが、ミラーのパスは `usage/session-logs/<safeBranch>/<sessionId>/` と
**ブランチ単位のまま**残っていた。同一セッションが別ブランチへresumeされるたびに、全文コピーが
ブランチ数だけ増殖する構造だった。

## 決定

**push断面の全文コピーを廃止し、「1本のミラー＋行範囲の記録」で表現する。**

1. ミラーを `usage/session-logs/<sessionId>/` へ**セッション単位**で一本化する
   （カーソルのキー設計へ揃える）。
2. push断面は `usage/state/push-index.jsonl` へ1push1行で記録する。
   ```json
   {"push":1,"at":"2026-08-18T12:53:19Z","branch":"feature-23-...","sessionId":"ba52539d-...",
    "engine":"claude","main":{"from":441,"to":692},"agents":{}}
   ```
3. `post-push-save-logs.sh`・`logs/`・`.gitignore` の `/logs/` を廃止し、`.claude/settings.json` /
   `.gemini/settings.json` の登録も削除する。
4. 参照手段として `.claude/scripts/src/show-push-log.sh` を新設する。

追記専用が保証される以上、「pushした時点のログ」は「ミラーの1行目〜N行目」と等価であり、
全文コピーは冗長である。結果として、ローカル状態はpush回数に比例して増えなくなった
（実測: `logs/` 23MB＋旧ミラー13MB → ミラー1本のみ）。

### 行番号の基準

`from`/`to` は**1始まり・両端含む**で、基準は既存の集計と同じ「**空行を除いた**行数」
（`_usage_aggregate_new_lines` の `select(length > 0)`）に揃えている。そのため
`show-push-log.sh` は物理行番号で切る素の `sed -n 'N,Mp'` を使えず、先に空行を落としてから
範囲を取る（`extract_range`）。実データのtranscriptに空行は観測されていないため通常は一致するが、
基準を揃えておかないと空行が1つ入った瞬間にずれる。

### Gemini CLI対応の扱い

**ミラーへの保存は維持し、対応工数の集計対象に含めることはスコープ外とした。**
現行の `UsageTracking.sh` はClaude Codeの `agent-*.jsonl` 構造を前提にしており、Gemini分は
元々集計されていない。集計まで広げるには、旧 `session-log-hooks.md` が「Gemini CLI本体の挙動と
整合しない可能性がある（未検証）」と認めていた前提の検証から必要になり、別issueの規模になる。

保存先は `subagents/<session_id>/` という**1階層下**にした。集計側
`_usage_aggregate_and_merge_subagents` の glob は `subagents/agent-*.jsonl` であり、
ディレクトリにはマッチしない。**「保存はするが集計はしない」というスコープ境界が、追加のガード
条件を書かずに構造だけで保証される**（この不一致はテストで明示的に検証している）。

## 却下した案

- **`logs/` を単純廃止する（インデックスも作らない）**: 最も単純で、`logs/` に読み手が無い以上
  実害も小さい。しかし「どのpushで何が起きたか」という境界情報が完全に失われる。行番号2つを
  記録するコストは極めて小さく、失う情報に見合わないため却下した。
- **現状維持＋保持世代数の上限のみ導入する**: 容量だけは抑えられるが、2系統・2仕様書という
  責務の重複と「どちらを見ればよいのか」という混乱が残る。今回の主目的は容量ではなく重複の
  解消であるため却下した。
- **ミラー自体をやめ、`~/.claude/projects` を直接読む**: 最も重複が少ないが、PR #29のレビューで
  「ユーザープロファイル配下の非公開・揮発性のあるパスへ集計処理が直接依存し続けるのは避ける」と
  判断してミラーを導入した経緯（DDR 0006の追記参照）を覆すことになるため採らない。
- **push断面をuuid等の内容ベースで識別する**: issue #37で「`uuid` は `parentUuid` チェーン上の
  ノード識別子であり、重複自体は異常ではない」という理由でuuidベースの重複排除が却下されている
  （DDR 0006の追記）。同じ理由で、行の中身を判断基準にしない位置ベースの表現を維持する。

## 既知の限界

- **別マシン・別環境で記録されたpushは再現できない**: `push-index.jsonl` に行範囲があっても、
  対応するミラー（`usage/session-logs/<sessionId>/main.jsonl`）はgitignore対象のローカル状態で
  あるため、そのマシンに無ければ `show-push-log.sh` は範囲を切り出せない（その旨をstderrへ出して
  終了コード1を返す）。これは旧 `logs/` も同じ性質だった（gitignore対象）ため、後退ではない。
- **行番号の基準が「空行を除いた行数」であること**を意識せずに `sed` 等で直接切り出すと、
  transcriptに空行が含まれた場合にずれる（上記「行番号の基準」参照。実装では `extract_range` に
  隠蔽している）。
- **Gemini CLI側のサブエージェント探索の前提は未検証のまま**引き継いでいる
  （gemini-cli の Issue #20258 との不整合の可能性。詳細は
  `.claude/docs/spec/issue-mr-workflow.md` の「未決定事項・懸念点」参照）。

## 副次的な確認事項（push検知hookの実挙動）

本issueの作業中、`.claude/settings.json` の `if: "Bash(git push*)"` が、**実際にはpushしていない
コマンド**（`cd ...` で始まるコマンドや、heredoc本文に該当語が含まれるだけのコマンド）でも
発火することを計3回観測した。`issue-mr-workflow.md` は当時この判定を「前方一致マッチ」と説明し、
それを根拠に「スクリプト経由のpushは検知されない」という制約を導いていたが、前方一致であれば
発火しないはずのケースで発火している。実挙動は**部分一致**であるとして同ドキュメントの記述を
修正し、あわせて `.claude/rules/git-workflow.md` へ、地の文に該当語を書くと誤検知する旨の
注記（commit側には既にあったがpush側には無かった）を追加した。
