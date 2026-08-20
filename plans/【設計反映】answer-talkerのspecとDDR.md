---
title: 【設計反映】answer-talkerのspecとDDR
type: plan
description: issue #1 の answer-talker について、正史仕様 spec/answer-talker.md を新設し、実装中に下した設計判断4件をDDRとして記録するための個別反映計画。
tags: [issue-mr-flow, answer-talker, 設計反映, plan]
keywords: [spec, DDR, answer-talker, 上限機構, ラベル引数, clone, ネタバレ検査, 誤検知, 反映]
---

# 【設計反映】answer-talker の spec と DDR

- issue: [#1](https://github.com/yuki-matsu783/ans-talker/issues/1) / PR: [#2](https://github.com/yuki-matsu783/ans-talker/pull/2)
- 全体作業計画: `plans/bubbly-exploring-biscuit.md`
- 前提となる結果: `reports/20260820_bubbly-exploring-biscuit_answer-talker設計.md` /
  `reports/20260820_bubbly-exploring-biscuit_answer-talker実装.md`（いずれも合意済み）
- 対象フェーズ: フェーズ4〈反映〉の1セット目（flow-id 4-1〜4-10）

## 目的

`plans/` `worklog/` `reports/` は flow-id 5-1 で削除される。**そこに書かれた「現在の仕様」と
「なぜそう決めたか」を、永続する `.claude/docs/spec/` `.claude/docs/ddr/` へ移す**のがこの計画の
範囲である。

`【AIアセット反映】` とは**分ける**（`.claude/skills/issue-mr-flow/SKILL.md`「種別を複数併記する
場合／分ける場合」。正史ドキュメントへの記録と運用ルールの改訂では、レビューで求められる
認知の種類が違うため）。本計画を完了・レビューしてから、AIアセット反映に着手する。

**実施結果は `reports/20260820_bubbly-exploring-biscuit_answer-talker反映.md` へ記録する。**
この計画には結果を書かない。

## 反映対象の洗い出し（flow-id 4-1）

**空ではない。** 下記のとおり spec 1件・DDR 4件・目次1件を反映する。

| # | 反映先 | 種別 | 出どころ |
|---|---|---|---|
| S1 | `.claude/docs/spec/answer-talker.md` | **新規** | 設計結果 D1〜D7、実装結果 V1〜V5 |
| R1 | `.claude/docs/ddr/0058-*.md` | **新規** | 実施回数の上限機構を課さない |
| R2 | `.claude/docs/ddr/0059-*.md` | **新規** | 投稿ラベルを共有関数の省略可能引数として足した |
| R3 | `.claude/docs/ddr/0060-*.md` | **新規** | 正解ソースのローカルパスはcloneしない |
| R4 | `.claude/docs/ddr/0061-*.md` | **新規** | ネタバレ検査を誤検知の側へ倒す |
| S2 | `.claude/docs/README.md` | 追記 | 上記DDR4件を一覧へ |

**DDR 4件すべてを起こすことはレビューで合意済み**（`#issuecomment-5363076871`）。

**DDR番号は取得直前に `main` の最新を再確認する。** 本計画作成時点では `origin/main` の最新が
`0057` のため `0058`〜`0061` を充てるが、並走ブランチがあれば繰り下げる
（flow-id 5-2 の `check-base-conflicts.sh` が重複を検知するが、手戻りを減らすため先に確認する）。

## S1. `.claude/docs/spec/answer-talker.md`（新規）

既存 spec の書式（`.claude/docs/spec/adversarial-review.md` を参照）に合わせ、
**背景・目的／仕様／影響範囲／設定項目／未決定事項・懸念点** を持たせる。

書く内容:

- **背景・目的**: 正解を見て、正解を書かない。この非対称を機構として固定する。
- **仕様**: 起動引数（`<MR番号>` / `--reference` / `--ref` / `--repo`）、手順11段、
  確度×重大度の選別表、1回10件の投稿上限、承認は投稿前1回、CLI不在時のMCP読み替え。
- **構成要素**: 6ファイル（SKILL / agent / reference / map / spoiler-check / Provider.shへの追加）と、
  それぞれの責務。
- **`adversarial-review` との違い**と、**投稿経路を共有していること**（ラベル引数で切り替える）。
- **影響範囲**: `Provider.sh` / `Github.sh` / `Gitlab.sh` に**省略可能引数を足しただけ**であり、
  既定値が従来の文言のため `adversarial-review` の呼び出しは変わらない。
- **確認済みの制約**: `--repo` はスラッグだとcwdのプロバイダで解決される／`get_mr_changed_files`
  の結果はコマンド置換で受けない／GitHubの3000ファイル上限とGitLabの `too_large`/`collapsed` は
  `truncatedFiles` / `capped` で報告する。
- **検証の再現手順の要点**: 題材（極小のbash CLI）の構成と、ローカルGitLabへ `git` で到達
  できないため Commits API を使う必要があること。**N3の判断もここに書く**（下記）。
- **未決定事項**: 実データでの上限到達（3000ファイル・`too_large`）は未確認である旨。

### N3の判断（検証用セットアップスクリプトを `.claude/` に残すか）

**残さない。** 理由は次の2点。

- 題材はこのリポジトリの成果物ではなく、**演習の題材**である（flow-id 1-5 / 2-9 で
  「このリポジトリに残さない」と合意済み）。plugin配布単位である `.claude/` に混ぜない。
- スクリプトの実体を残さなくても、**再現に必要な情報は spec の「検証の再現手順の要点」で足りる**
  （題材の構成・Commits APIを使う理由・パターンの一覧）。

## R1〜R4. DDR 4件

いずれも **「〇〇を検討したが✕✕を採用した」** の形で、**却下案とその理由**を必ず含める。

| # | 決めたこと | 却下した案 |
|---|---|---|
| R1 | answer-talker に実施回数の上限機構を課さない | `adversarial-review-count.sh` と同じ上限を課す |
| R2 | 投稿ラベルを共有関数の**省略可能引数**として足す | answer-talker 専用の投稿処理を持つ／文言を無条件に変える |
| R3 | 正解ソースがローカルパスなら **cloneしない** | 常に clone して読む（`--depth 1` 付き） |
| R4 | ネタバレ検査を**誤検知の側へ倒す** | 見逃しを避けつつ誤検知も抑えるため、識別子を分割して照合する |

各DDRに必ず書く根拠（結果mdに証跡がある）:

- R1: 上限は「非対話モードでAIが人間の介在なくレビュー→修正→再レビューを回しうる」ことへの
  対策であり、本スキルはその前提を満たさない（人間が引数付きで明示的に呼ぶ／flow-idを持たない／
  対象が実行者のブランチと無関係）。埋め尽くしは**投稿前の承認1回**と**1回10件**で抑える。
- R2: 既定値を従来の文言にすることで**既存呼び出しに影響しない**。専用処理を持つ案は、
  同じ投稿ロジックが2つになり、片方だけが直される事故を招く。
- R3: `--depth 1` は局所cloneで**無視され**（浅くならない）、素のディレクトリは**cloneできない**。
  いずれも実機で確認済み。後始末の対象を「自分が作った一時ディレクトリだけ」に限定できる利点もある。
- R4: 正当な指摘を落としてでも転記の見逃しを避ける（flow-id 3-4 で合意）。この向きの失敗は
  「指摘が落ちすぎて実質何も出ない」形になるため、**落とした件数と反応した語を必ず報告する**
  ことで可視化する。識別子を分割しないのは、分割すると一般語に当たって誤検知が爆発するため。

## この計画で決めないこと（スコープ外）

- **`.claude/rules/` `.claude/skills/` `index.md` への反映**。次の `【AIアセット反映】` の担当。
- **`plans/` `worklog/` `reports/` の削除**。flow-id 5-1 の担当であり、設計反映では行わない。
- **既存DDRの本文の変更**。DDRは本文不変（frontmatterの `status` のみ後から更新可）。
- **`adversarial-review` 側の仕様変更**。

## 検証（この作業が完了したと言える条件）

1. `.claude/docs/spec/answer-talker.md` が存在し、frontmatter規約
   （`.claude/rules/markdown-frontmatter.md`、`type: spec`）に沿っている。
2. DDR 4件が連番で存在し、**`main` の最新と番号が重複しない**
   （`bash .claude/scripts/src/check-base-conflicts.sh` の `duplicateDdrNumbers` が空）。
3. `.claude/docs/README.md` のDDR一覧に4件が載っている。
4. `bash .claude/scripts/src/search-frontmatter.sh --text answer-talker` に spec とDDR 4件が現れる。
5. **結果mdへ、反映したものと反映しなかったものの両方が記録されている**
   （何を捨てたかが分からないと、次に読む人が同じ検討をやり直す）。
