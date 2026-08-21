---
title: 受講者ソースの受け渡しの実装結果
type: report
description: issue #6 の実装結果。6ファイルへ受講者ソースの取得・受け渡しを実装し、3段の縮退をGitHub・GitLab両方の実MRで確認した。単体テストは全16スイート NG=0。サブエージェントを起動する検証2項目は未実施。
tags: [answer-talker, 実装結果, report]
keywords: [submission, 縮退, degraded, materialScope, forbiddenCount, subtractedBySubmission, scope, 単体テスト, 実機確認, 未実施]
---

# 実装結果: 受講者ソースの受け渡し（issue #6・フェーズ3の2周目）

- 計画: `plans/【実装】【テスト】受講者ソースの受け渡し.md`
- 前提の設計: `reports/20260821_bubbly-exploring-biscuit_受講者ソースの受け渡しの設計結果.md`
- 実施日: 2026-08-21〜2026-08-22
- worklog: `worklog/…_push1.md`（取得側）・`worklog/…_push2.md`（受け取り側）

## 結論（3行）

1. **6ファイルすべてを実装した。** 設計から変えたのは1点（`resolve` へ `--repo` を追加）で、
   理由は「`_PROVIDER_CACHE` はシェル変数であり別プロセスへ継承されない」ことの実測。
2. **3段の縮退は GitHub・GitLab の実MRで動いた。** 段2・段3は上限値を人工的に0にして到達させた。
3. **サブエージェントを起動する検証2項目（受け入れ条件1・7）は未実施。**
   起動にユーザーの許可が要るため。**「実装は終わったが検証は終わっていない」状態である。**

## 実装した6ファイル

| # | 対象 | 実装した内容 |
|---|---|---|
| 1 | `.claude/scripts/src/vcs/Github.sh` / `Gitlab.sh` / `Provider.sh` | `get_mr_head_repo` / `get_repo_size_kb` / `get_repo_tree` / `get_repo_file` / `fetch_repo_archive` の5関数と、head側リポジトリへ一時的に切り替える `with_mr_head_repo` |
| 2 | `.claude/scripts/src/answer-talker-submission.sh`（新規） | `resolve` / `cleanup`。3段の縮退・上限・タイムアウト・除外 |
| 3 | `.claude/scripts/src/answer-talker-map.sh` | `--submission-root` と出力の `scope` |
| 4 | `.claude/scripts/src/answer-talker-spoiler-check.sh` | `--submission-root` と出力の `materialScope` / `forbiddenCount` / `subtractedBySubmission` |
| 5 | `.claude/agents/answer-talker-reviewer.md` | 入力仕様に `submission` と `mapping.scope`、「読んでよいもの」の是正、読む手順、`degraded` の分岐 |
| 6 | `.claude/skills/answer-talker/SKILL.md` | 手順3bの新設（採番は繰り下げず）、手順4・6・7・10・11・読み替え表・してはいけないこと |

### 設計から変えた点

**`resolve` へ `--repo` を追加した**（設計時には無かった引数）。`use_target_repo` が設定する
`_PROVIDER_CACHE` はシェル変数であり、`bash answer-talker-submission.sh …` で起動した別プロセスへ
継承されない。呼び出し側が先に `use_target_repo` を呼んでいても、プロバイダの判定がcwd基準へ
戻ってしまう（実測で `gh: Not Found (HTTP 404)` が出た）。

これは設計の見落としではなく、**設計時には「同じシェルで動く」という前提を明示していなかった**
ことによる。SKILL.md の手順3bにも理由付きで明記した（スクリプト側のコメントだけでは、
呼び出し手順を書く人に届かないため）。

## 検証1: 3段の縮退（受け入れ条件2）

**両プロバイダの実MRに対して実行した。** 段2・段3は、上限値を人工的に0にして到達させている。

### GitHub（`yuki-matsu783/test-repo` PR #1）

```
段1（通常）              {"stage":1,"fileCount":2,"truncated":false,"degraded":false,"reason":"stage-1"}
段2（--max-size-kb 0）   {"stage":2,"fileCount":2,"truncated":false,"degraded":false,"reason":"stage-2/size-over-limit"}
段3（+ --max-fetch-files 0）{"stage":3,"root":null,"tmpdir":null,"degraded":true,"reason":"size-over-limit"}
```

### GitLab（`root/answer-talker-verify` MR !1、self-hosted `localhost:8929`）

```
段1（通常）              {"stage":1,"fileCount":2,"truncated":false,"degraded":false,"reason":"stage-1"}
段2（--max-size-kb 0）   {"stage":2,"fileCount":2,"truncated":false,"degraded":false,"reason":"stage-2/size-over-limit"}
段3（+ --max-fetch-files 0）{"stage":3,"root":null,"degraded":true,"reason":"size-over-limit"}
```

段1では `README.md` と `main.sh` の2ファイルが展開された。**`README.md` は今回のMRで
変更していない**（diffには `main.sh` しか無い）——これが issue #6 が取りに行った対象そのものである。

### 副産物: 段2は一過性の失敗に弱い

GitLab の段2を測る過程で、**3回中2回、段2が失敗して段3へ落ちた**。

```
試行1  {"stage":3,...,"reason":"head-sha-unavailable"}   ← MRメタ情報の取得が失敗
試行2  {"stage":3,...,"reason":"size-over-limit"}        ← tree列挙かファイル取得が失敗
試行3  {"stage":2,...,"reason":"stage-2/size-over-limit"} ← 成功
```

原因はローカルGitLabが接続を切ったこと（`wsarecv: An existing connection was forcibly closed`）で、
実装の欠陥ではない。**縮退そのものは設計どおりに働いた**（エラーを握りつぶさず、
`degraded:true` と理由を返して終了コード0で続行した）。

ただし**段2はファイル数に比例してAPIを呼ぶため、段1（1回）に比べて一過性の失敗を踏む確率が
構造的に高い**という性質が実測で見えた。現在の実装は1回でも失敗すると段3へ落ちる。
リトライを持たせるかは**フェーズ4で扱うか、別issueとするかを判断する**（この計画のスコープ外）。

## 検証2: `mapping` の意味の切り替え

`yuki-matsu783/test-repo` PR #1 の実データで、`--submission-root` の有無を比較した。

```
なし  {"scope":"diff","matched":["main.sh"],"referenceOnly":["io.sh"],"submissionOnly":[]}
あり  {"scope":"full","matched":["main.sh"],"referenceOnly":["io.sh"],"submissionOnly":["README.md"]}
```

**`README.md`（hunk外のファイル）が対応付けの視野に入った。** `scope` が `diff` → `full` へ
変わり、`submissionOnly` の意味の違いが機械的に判別できる。

## 検証3: ネタバレ検査の回帰が消えたこと

設計時に「差し引く材料が差分だけだと、hunkに現れない受講者ファイルに基づく指摘**だけ**が
選択的に落ちる」ことを実測していた。今回その逆を確かめた。

正解に `read_lines` / `write_lines` があり、受講者は `read_lines` を**diffに現れないファイル**に
書いている、という状況を作った。

| | `kept` | `dropped` | `materialScope` | `forbiddenCount` | `subtractedBySubmission` |
|---|---|---|---|---|---|
| `--submission-root` なし | 2 | **1**（`read_lines`） | `diff` | 2 | 0 |
| `--submission-root` あり | **3** | 0 | `full` | 1 | 1 |

**`forbiddenCount` が 2 → 1 で止まっている点が重要**である。受講者が書いていない `write_lines` は
禁止語のまま残っており、「差し引きすぎて禁止語が空になり検査が実質無効になる」という逆方向の
壊れ方をしていない。この値を出力へ足したのは、まさにその区別のためである
（`dropped: 0` だけでは「転記が無かった」のか「禁止語が空だった」のかが分からない）。

**検出力が落ちていないことも実データで確かめた。** `test-repo` PR #1 に対し、正解にしか無い
識別子（受講者は別名を使っている）を含む指摘を投入したところ、**`--submission-root` を渡しても
落ちた**（`forbiddenCount:1`）。材料を広げても、本来落とすべきものは落ちる。

## 検証4: 単体テスト

**全16スイート `NG=0`（合計 `passed=740 failures=0`）。**

| スイート | 変更前 | 変更後 |
|---|---|---|
| `test_answer_talker_submission.sh`（新規） | — | 30 |
| `test_answer_talker_map.sh` | 16 | 27 |
| `test_answer_talker_spoiler_check.sh` | 21 | 32 |
| `test_vcs_provider.sh` | （既存） | 143 |

新規のアサーションは、いずれも**「渡さないと落ちる／渡すと残る」を両側から押さえる**形にした。
片側だけだと「常に落とさない実装」も合格してしまうため。終了コードの検査は
`"$(func; echo $?)"` を使わず `if` で受けている（`set -e` 配下で空文字が返るため。
`.claude/rules/shell-script-style.md`「テスト」）。

## 未実施の項目

**以下は「確かめられなかった」ではなく「まだ確かめていない」である。** 実装は終わっているが、
実行にユーザーの許可が要るため止めている。

| # | 項目 | 必要なもの |
|---|---|---|
| 1 | **受け入れ条件1**: hunk外ファイルにのみ存在する責務について指摘が**出て、かつ届く**こと（`summarized` の件数と本文まで） | `answer-talker-reviewer` の起動許可＋MRへの投稿許可 |
| 2 | **受け入れ条件7**: 17パターン相当の再検証（とくに**②別解・⑤ほぼ正解で分割単位の指摘が出ない**こと。**最大の回帰リスク**） | 同上（パターン数だけ起動する） |
| 3 | **受け入れ条件3**: `degraded: true` の場合の入力JSONと定義の突き合わせ | 同上（段3を人工的に作って起動する） |

**受け入れ条件1と7は、今回の変更の中心に対する検証である。** 実装が終わったことをもって
「受け入れ条件を満たした」とは言えない。

## 計画のD（設計で未確認のまま残した項目）の扱い

| 項目 | 結果 |
|---|---|
| **GitHub非公開リポジトリでのアーカイブ取得** | **未確認。** `test-repo` は公開であり、一時的に非公開へ切り替えてよいかをユーザーへ確認していない（**非公開リポジトリを新規に作らない**という制約がある） |
| **サイズが取得できない環境での挙動** | **コード上は確認済み・実環境では未確認。** 設計どおり「サイズ不明なら段1を試す」実装になっていることは読み取れるが、実際にサイズを返さないGitLabインスタンスは手元に無い |
| **上限値（100MB・50件・500件・60秒）の妥当性** | **未確認。** 実運用のデータが無いまま決めた値であり、今回の検証対象（2ファイル）では一度も上限に触れていない。**「妥当だと確認した」とは書けない** |

## 次の一手

1. **ユーザーへ、`answer-talker-reviewer` の起動と投稿の許可を求める**（未実施の3項目）。
2. 許可が得られたら、hunk外パターン → 17パターン → `degraded` の順で検証し、
   本ファイルへ結果を追記する。
3. その後 flow-id 3-8（敵対的レビューのフェーズ3・3回目＝最後）へ進む。
