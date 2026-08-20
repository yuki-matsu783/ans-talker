---
title: answer-talkerのspec・DDR反映結果
type: report
description: issue #1 のフェーズ4〈反映〉で、answer-talker の正史仕様 spec/answer-talker.md を新設しDDR 4件を記録した結果。反映しなかったものとその理由を含む。
tags: [answer-talker, 設計反映, spec, ddr, report]
keywords: [spec, DDR, 0058, 0059, 0060, 0061, 目次, 反映しないもの, N3, 検証]
---

# answer-talker の spec・DDR 反映結果

- issue: [#1](https://github.com/yuki-matsu783/ans-talker/issues/1) / PR: [#2](https://github.com/yuki-matsu783/ans-talker/pull/2)
- 個別反映計画: `plans/【設計反映】answer-talkerのspecとDDR.md`（flow-id 4-4 で合意）
- 実施: 2026-08-21（flow-id 4-6・1周目＝設計反映）

## 結論

計画の S1・R1〜R4・S2 をすべて反映した。**計画からの逸脱は無い。**

`plans/` `worklog/` `reports/` は flow-id 5-1 で削除されるため、そこに書かれた「現在の仕様」と
「なぜそう決めたか」を、永続する `.claude/docs/spec/` `.claude/docs/ddr/` へ移し終えた。

## 反映したもの

| # | 反映先 | 内容 |
|---|---|---|
| S1 | `.claude/docs/spec/answer-talker.md`（**新規**） | 背景・目的／仕様／影響範囲／設定項目／検証の再現手順の要点／未決定事項 |
| R1 | `.claude/docs/ddr/0058-answer-talkerには実施回数の上限機構を課さない.md` | 却下案3件 |
| R2 | `.claude/docs/ddr/0059-投稿コメントのラベルは共有関数の省略可能引数で切り替える.md` | 却下案3件 |
| R3 | `.claude/docs/ddr/0060-正解ソースがローカルパスならcloneしない.md` | 却下案4件 |
| R4 | `.claude/docs/ddr/0061-ネタバレ検査は誤検知の側へ倒し識別子は分割しない.md` | 却下案4件 |
| S2 | `.claude/docs/README.md` | spec一覧に1行、DDR一覧に4行を追記 |

**DDR番号は取得直前に `origin/main` を再確認した**（`git fetch origin main` のうえで
`git ls-tree -r --name-only origin/main .claude/docs/ddr/` を見た）。最新は `0057` で、
計画時点の想定どおり `0058`〜`0061` を充てられた。

### S1 で意識的に書いた3点

1. **`adversarial-review` との違いを表で並べた**（対象／観点の出どころ／探すもの／投稿前の検査／
   上限／投稿ラベル）。2つのスキルは投稿経路を共有しており、**違いが語1つ**であることを
   spec 側で明示しておかないと、次に読む人がどちらを触ればよいか判断できない。
2. **「検証の再現手順の要点」節を置いた。** 演習の題材はこのリポジトリに残さないと決めているため
   （N3）、題材の構成・Commits APIを使う必要がある理由・5軸のパターン・「指摘しないことを
   確かめるパターンを必ず含める」という原則を、spec 側に文章として残した。
3. **未決定事項を3件、正直に残した。** 上限到達時の挙動が実データで未確認であること、
   正解と同じ形にしても指摘が0件になるとは限らないこと、凝集度の低い別解には強めの指摘が
   出ること。いずれも「そういう仕様である」と言い切れるところまでは確かめていない。

### R1〜R4 で守った書き方

**すべてのDDRに「却下した案」を複数書き、却下の理由を実測または論理で示した。** 「〇〇を採用した」
だけでは、後から読む人が同じ検討を最初からやり直すことになる。

- R3（cloneしない）は、却下理由が**実測**である（`--depth 1` が局所cloneで無視される／
  素のディレクトリはcloneできない）。
- R1（上限を課さない）は、却下案に**実害**を書いた（流用すると、同じ演習で複数の受講者のMRを
  続けてレビューしたときに3人目で止まる）。
- R4（誤検知へ倒す）は、「誤検知へ倒す」と「何も出ない」が別物であることを、識別子分割案の
  却下理由として明示した。**判断の向きを、程度の無制限な許容と読み替えられないようにする**ため。

## 反映しなかったもの（と、その理由）

計画の時点で決めていたとおり。**何を捨てたかを残さないと、次に読む人が同じ検討をやり直す。**

| 見送ったもの | 理由 |
|---|---|
| 検証用セットアップスクリプトを `.claude/` に残すこと（**N3**） | 題材は演習の題材であってこのリポジトリの成果物ではない（plugin配布単位に混ぜない）。再現に必要な情報は spec の「検証の再現手順の要点」で足りる |
| `plans/` `worklog/` `reports/` の削除 | flow-id 5-1 の担当。設計反映で行うのは**内容の反映**であってファイルの削除ではない |
| `.claude/rules/` `.claude/skills/` `index.md` への反映 | 次の `【AIアセット反映】` の担当（計画を分けている） |
| 既存DDRの本文の変更 | DDRは本文不変（frontmatterの `status` のみ後から更新可）。今回、無効化された既存の決定は無い |

## 検証

計画の「検証（この作業が完了したと言える条件）」5項目すべてを満たした。

| # | 条件 | 結果 |
|---|---|---|
| 1 | spec が存在しfrontmatter規約に沿う | `type: spec`。`title`/`description`/`tags`/`keywords` を持つ |
| 2 | DDR 4件が連番で存在し `main` と番号が重複しない | `check-base-conflicts.sh` → `duplicateDdrNumbers: []` / `hasConflict: false` |
| 3 | `.claude/docs/README.md` の一覧に載っている | spec 1行・DDR 4行を追記。差し込み位置の前後を目視確認済み |
| 4 | `search-frontmatter.sh` に spec とDDR 4件が現れる | spec 1件・ddr 4件すべてヒット |
| 5 | 反映したもの／しなかったものの両方を記録 | 本レポートの上記2節 |

`.claude/docs/README.md` への差し込みは、`sed` の行範囲分割とヒアドキュメントで書き出した行を
連結する方法で行った（置換文字列にバックスラッシュを含めないため）。連結後に差し込み位置の前後を
表示し、**空行が2つ連続していないこと・次の見出しの直前に空行が1つあること**を確認した。

## 次

`plans/【AIアセット反映】shell規約とフロー定義への反映.md` に基づき、flow-id 4-6 の2周目として
`.claude/rules/shell-script-style.md`（3箇所）・`.claude/skills/issue-mr-flow/SKILL.md`・
`index.md` へ反映する。**結果は本レポートへ追記する。**
