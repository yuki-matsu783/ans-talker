---
title: worklog 【実装】【テスト】受講者ソースの受け渡し push2
type: log
description: issue #6 のフェーズ3の2周目（実装・テスト）の記録の続き。受け渡し経路の残り4ファイル（map/spoiler-check/エージェント定義/SKILL.md）を実装した。
tags: [worklog, answer-talker, 実装, テスト]
keywords: [materialScope, forbiddenCount, scope, submissionOnly, degraded, sed, エスケープ, 単体テスト, 実機確認]
---

# worklog: 【実装】【テスト】受講者ソースの受け渡し（push2）

対象: issue #6 のフェーズ3の**2周目**（2026-08-22）。
全体作業計画: `plans/bubbly-exploring-biscuit.md`
個別作業計画: `plans/【実装】【テスト】受講者ソースの受け渡し.md`
設計（前提）: `reports/20260821_bubbly-exploring-biscuit_受講者ソースの受け渡しの設計結果.md`
push1の続き: `worklog/20260821_bubbly-exploring-biscuit_【実装】【テスト】受講者ソースの受け渡し_push1.md`
push回数: 10

## 試したこと

push1で取得側（`Provider.sh` 3ファイル＋`answer-talker-submission.sh`＋その単体テスト）を
終えたので、**受け取り側の残り4ファイル**を実装した。

1. `answer-talker-map.sh` — `--submission-root` と `scope`（push1の末尾で着手済み）
2. `answer-talker-spoiler-check.sh` — `--submission-root` と `materialScope` / `forbiddenCount`
3. `.claude/agents/answer-talker-reviewer.md` — 入力仕様・読んでよいもの・手順・`degraded` 分岐
4. `.claude/skills/answer-talker/SKILL.md` — 手順3bの新設と、手順4/6/7/10/11・mcp表の追随

## うまくいかなかったこと

### `sed` の置換文字列に書いた `\n` が改行にならなかった

jqの引数を2行に折り返そうとして、`sed -i 's|…|… \\\n      --argjson …|g'` と書いたところ、
**`\n` がそのまま2文字として出力された**（`... \n      --argjson forbiddenCount ...` という
1行になった）。`bash -n` は通ってしまうため、出力を目視するまで気づけない。

`.claude/rules/shell-script-style.md`「文字コード」節が
**「`awk`/`sed` の置換文字列で `\r` を含むシェルコードを生成しない」**として記録している罠と
同じ系統で、**ツールへ渡すコマンド文字列の中でバックスラッシュがもう1段解釈される**ことが原因。
同じ節が結論として書いている**「数行程度の修正ならEdit/Writeツールで直接行う」**に従って
やり直したところ一発で通った。**規約に書いてある回避策を、書いてあるとおり最初から採る**べき
だった（`sed` を選んだ理由は「Bashツールでやれと言われているから」で、規約より優先させる
理由になっていない）。

### テストの挿入位置で空行が2つ続いた

`{ sed -n '1,N-1p'; cat 追記; sed -n 'N,$p'; }` の形で単体テストへブロックを追記したところ、
追記側の先頭の空行と、元ファイルの空行が重なって**空行が2連続**した。
`.claude/rules/docs-workflow.md` の「差し込むファイルは、先頭に空行を置かず、末尾に空行を
ちょうど1つ持たせる」がそのまま当てはまる（markdownの話として書かれているが、シェルスクリプトでも
同じ）。`awk 'prev=="" && $0==""' ` で全ファイルを検査する形にして、以後は機械的に確認した。

### `python` から `/tmp` のファイルが見えなかった

追記処理を一度 `python` で書こうとしたところ、git bashのヒアドキュメントが作った
`/tmp/atr_append.txt` が `IOError: No such file or directory` で開けなかった
（Windowsネイティブの `python` からはMSYSの `/tmp` が解決できない）。
`.claude/rules/shell-script-style.md`「git bashのパス変換の落とし穴」でjqについて記録されている
のと同じ現象。**bashだけで完結させる**（`sed -n` で前後を切って `cat` で連結する）ほうが速かった。

## うまくいったこと

### 禁止語の回帰が消えることを、両方向で実測した

push1の時点で「差し引く材料が差分だけだと、hunkに現れない受講者ファイルに基づく指摘だけが
選択的に落ちる」ことを実測していた。今回その逆を確かめた。

```
--submission-root なし: {"kept":2,"dropped":1,"materialScope":"diff","forbiddenCount":2,
                         "drops":[{"title":"read_lines の責務","words":["read_lines"]}]}
--submission-root あり: {"kept":3,"dropped":0,"materialScope":"full","forbiddenCount":1}
```

**`forbiddenCount` が 2 → 1 になっている点が重要**で、受講者が書いていない `write_lines` は
禁止語のまま残っている。「差し引きすぎて禁止語が空になり、検査が実質無効になる」という
逆方向の壊れ方をしていないことが、この1つの値で分かる（これが `forbiddenCount` を出力へ
足した理由そのもの）。

### 実機（GitHub PR）で 3b → 4 → 7 → 10 が繋がった

`yuki-matsu783/test-repo` の PR #1（`p2b-single-file`）に対して通し実行した。

```
resolve → {"stage":1,"fileCount":2,"truncated":false,"degraded":false}
展開されたファイル: README.md, main.sh   ← diffには main.sh しか無い
map（--submission-root なし）: {"scope":"diff","submissionOnly":[]}
map（--submission-root あり）: {"scope":"full","submissionOnly":["README.md"]}
cleanup → {"removed":true} → 2回目 {"removed":false,"reason":"not-found"}
```

**`README.md` が `submissionOnly` に現れるところが issue #6 の目的そのもの**で、
今回のMRで変更していない受講者ファイルが対応付けの視野に入った。

ネタバレ検査も同じ実データで確認した。`read_input`（正解にしか無く、受講者は `take_lines`
という別名を使っている）を含む指摘は、**`--submission-root` を渡しても落ちた**
（`forbiddenCount:1`）。材料を広げても本来の検出力が落ちていない。

### 単体テストは全16スイート合格

`passed=740 failures=0`（`test_answer_talker_map.sh` 16→27、
`test_answer_talker_spoiler_check.sh` 21→30）。

新しく足したのは、いずれも**「渡さないと落ちる／渡すと残る」を両側から押さえる**形にした。
片側だけだと「常に落とさない実装」も合格してしまう。

## 気づいたこと（フェーズ4の反映候補）

- **`sed` を選ばずEdit/Writeを使う判断**は、既に `shell-script-style.md` に書いてある。
  今回踏んだのは「書いてあるのに読み返さずに `sed` を選んだ」という運用の問題であって、
  ルールの不備ではない。**AIアセット反映の候補にはするが、文言追加ではなく
  「いつ読み返すか」の側**として整理する。
- **空行2連続の検査**（`awk 'prev=="" && $0==""'`）は、`docs-workflow.md` の
  「差し込み位置の前後3行を目視で確認する」より機械的で速い。ルール側へ足す価値がある。
- `answer-talker-submission.sh` の `--repo` 追加（push1）と同じ「別プロセスは
  `_PROVIDER_CACHE` を継承しない」問題は、**SKILL.md の手順3bにも明記した**。
  スクリプト側のコメントだけだと、呼び出し手順を書く人には届かない。
