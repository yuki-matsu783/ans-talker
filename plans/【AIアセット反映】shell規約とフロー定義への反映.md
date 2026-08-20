---
title: 【AIアセット反映】shell規約とフロー定義への反映
type: plan
description: issue #1 の作業中に踏んだ罠と得た教訓を、shell-script-style.md・issue-mr-flow/SKILL.md・index.md へ反映するための個別反映計画。
tags: [issue-mr-flow, answer-talker, AIアセット反映, plan]
keywords: [shell-script-style, jq, 予約語, CR, CRLF, 原因帰属, index.md, スキル位置づけ, ルール改訂]
---

# 【AIアセット反映】shell規約とフロー定義への反映

- issue: [#1](https://github.com/yuki-matsu783/ans-talker/issues/1) / PR: [#2](https://github.com/yuki-matsu783/ans-talker/pull/2)
- 全体作業計画: `plans/bubbly-exploring-biscuit.md`
- 前提: `plans/【設計反映】answer-talkerのspecとDDR.md` の完了・レビュー合意
- 対象フェーズ: フェーズ4〈反映〉の2セット目（flow-id 4-6〜4-10 の2周目）

## 目的

作業中に**気づいたルール・スキルの不備**を、`.claude/rules/` `.claude/skills/` `index.md` へ反映する
（flow-id 4-6 の「AIアセット反映」）。設計反映（spec/ddr）とは扱うものが違うため計画を分けている。

反映の判断基準は「**次に同じ場所で同じ失敗を踏むか**」である。1回きりの偶発は書かない。

**実施結果は `reports/20260820_bubbly-exploring-biscuit_answer-talker反映.md` へ追記する。**

## 反映対象の洗い出し（flow-id 4-1）

**空ではない。** 5件を反映する。

| # | 反映先 | 内容 | なぜ再発するか |
|---|---|---|---|
| A1 | `.claude/rules/shell-script-style.md`「JSON操作」 | **jqの予約語を変数名に使わない**（`$label` は `label $out \| …` 構文の予約語で `syntax error, unexpected label` になる） | jqへ渡す変数名は自然に英単語を選ぶため、他の予約語でも同じことが起きる |
| A2 | 同「文字コード」 | WindowsネイティブjqのCRが、**複数行の値を `jq -r` で取り出したとき行の途中に残る**こと（コマンド置換が落とすのは末尾の改行だけ／**単一行の値では表面化しない**） | 既存記述は「ファイルリダイレクト・コマンド置換・パイプでCRが付く」までで、**単一行と複数行で症状が違う**ことに触れていない。単一行でしか試さないと「大丈夫」と誤認する |
| A3 | 同「テスト」 | **「`origin/main` でも失敗する」は既存不具合の証拠にならない**。原因帰属は検査対象の出力そのものを直接見て切り分ける | 「mainでも落ちる＝自分の変更のせいではない＝プロダクションの既知不具合」という推論は自然で、実際に本issueで踏んだ |
| A4 | `.claude/skills/issue-mr-flow/SKILL.md` | **`answer-talker` の位置づけ**（`adversarial-review` と同じくflow-idを増やさない並行手順であること、両者の使い分け） | 新スキルがフローのどこに載るかを書かないと、次にこのフローを回す人が「どのflow-idで呼ぶのか」を毎回考える |
| A5 | `index.md`（Repository Map） | スキル一覧に `/answer-talker` を、`agents/` の説明に `answer-talker-reviewer` を追加 | 一覧が実体と食い違うと、Repository Mapとしての信頼が落ちる |

### 反映しないと判断したもの

計画時点で**反映しない**と決めているもの。結果mdにも理由込みで残す。

| 見送るもの | 理由 |
|---|---|
| バックスラッシュがツール経由で1段潰れる罠 | **既に `shell-script-style.md` に記載がある**。今回2度踏んだのは記載不足ではなく参照漏れであり、同じ内容を増やしても再発を防げない。**ただしA2・A3の記述の中で、CR判定を誤った実例として自然に触れる** |
| 長文のヒアドキュメントではなくWriteツールを使う件 | 同上（既に記載あり） |
| `use_target_repo` にスラッグを渡すとcwdのプロバイダで解決される件 | **`SKILL.md` へ反映済み**（実装時に対応）。ルール側へ重ねて書かない |

## 書き方の制約

- **既存の節へ差し込むときは、挿入位置の直前が「節全体にかかる地の文」で終わっていないかを必ず
  確認する**（`.claude/rules/docs-workflow.md`。係り先が変わるため）。差し込み後は**前後3行を
  目視し**、空行が2つ連続していないか・次の見出しの直前に空行が1つあるかを確かめる。
- A1〜A3は既存節への**追記**であり、既存の記述を書き換えない（今回の知見は既存記述の
  「続き」であって訂正ではない）。
- 実例は**このリポジトリで実際に起きたこと**として書く（issue番号で参照する。`plans/` `worklog/`
  `reports/` は flow-id 5-1 で消えるため**参照しない**）。

## この計画で決めないこと（スコープ外）

- **spec / DDR の執筆**。`【設計反映】` の担当（先に完了させる）。
- **`adversarial-review` スキルの変更**。
- **`.claude/rules/` の全面的な再編**。今回の知見に関係する節への追記に限る。
- **`plans/` `worklog/` `reports/` の削除**。flow-id 5-1 の担当。

## 検証（この作業が完了したと言える条件）

1. A1〜A5の5箇所が反映されている。
2. 差し込み箇所の前後3行を目視し、**係り先の崩れ・空行の重複が無い**ことを確認した。
3. `bash .claude/scripts/src/search-frontmatter.sh` が全ファイルを走査でき、
   `index.jsonl` に欠落が出ていない。
4. 単体テスト13本が `failures=0` のまま（ドキュメントのみの変更だが、`session-start.sh` の
   テストが `index.jsonl` 生成に依存するため確認する）。
5. **反映しなかったもの3件が、理由込みで結果mdに残っている。**
