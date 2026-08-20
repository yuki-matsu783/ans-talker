---
title: issue #1 answer-talker スキル追加 全体作業計画
type: plan
description: 演習MRを正解ソースと照合して概念的な指摘を返す answer-talker スキルを追加するための、issue #1 の全体作業計画。
tags: [issue-mr-flow, answer-talker, review, plan]
keywords: [answer-talker, 正解ソース, 演習, レビュー, インラインコメント, Provider.sh, サブエージェント, ネタバレ防止, diff取得, findings]
---

# issue #1 全体作業計画 — answer-talker スキルの追加

- issue: [#1 演習MRを正解ソースと照合してレビューする answer-talker スキルを追加する](https://github.com/yuki-matsu783/ans-talker/issues/1)
- ブランチ: `feature-1-add-answer-talker-review-skill`
- PR: [#2](https://github.com/yuki-matsu783/ans-talker/pull/2)（Draft）
- ベースブランチ: `main`

## Context（なぜこの変更を行うか）

開発演習では、受講者が初期状態から実装を進めたMRを講師がレビューする。このとき手元には別途
「正解ソース」があるが、**正解をそのまま提示してしまうと演習にならない**。求められているのは、
分割方針・責務の置き方・命名やルールの考え方が正解と同じ方向へ向かうような**概念的な指摘**である。

現状これを支える仕組みが無い。

- 既存の `adversarial-review` スキルは「壊れるとしたらどこか」を探すレビューで、**参照実装との
  照合という観点を持たない**。サブエージェントにも正解ソースは渡されない。
- レビュー観点の出どころである `REVIEW-POINTS.md` は本リポジトリの運用規約向けで、演習課題ごとの
  設計方針は表現できない。
- `Provider.sh` に **MR/PR番号を起点にdiffを取得する関数が無い**（`get_mr_for_branch` は
  ブランチ→MR番号の逆方向）。関数一覧を確認済みで、`get_mr_diff_url`（URLを組み立てるだけ）は
  あるが本文を取る関数は無い。
- 正解ソースを別リポジトリのcloneやローカルディレクトリから取り込む手段が無い。

結果として演習MRのレビューは毎回その場の判断になり、指摘の粒度とネタバレの度合いが実行ごとに
ぶれる。これを、起動方法・観点・ネタバレ防止・承認モデルまで含めて機構として固定するのが本issueの
狙いである。

**成果物の性質**: 追加するのはアプリのコードではなく、`.claude/` 配下のAIアセット（スキル定義・
サブエージェント定義・スクリプト・spec/DDR）である。本リポジトリはissue駆動MRワークフロー機構の
テンプレートであり、plugin配布単位である `.claude/` の外にはファイルを置かない。

## issueの粒度判定（分割提案の要否）

**分割は提案しない。** 受け入れ条件は6項目あるが、これらは同型の成果物の並列列挙ではなく、
1つの機能を成立させるための不可分な部品である（スキル定義だけをマージしても、diff取得関数と
サブエージェント定義が無ければ動かない）。「各項目が単独でマージされてもシステムが壊れないか」
という判定に対し**壊れる**ため、`issue-mr-flow` SKILL.md「issueが大きすぎる場合の分割提案」の
**横断的変更**に該当する。

レビューの粒度は、issueではなく**個別計画ファイルの分割**で調整する（フェーズ3で
`【設計】` と `【実装】【テスト】` を分けるなど）。

## フェーズ2〈調査〉

**実施する。** 本issueは「既存のどの仕組みに、どう相乗りするか」を決めないと設計に入れない。
フェーズ1時点の事前調査は所在確認までに留めてあり、以下は未調査である。

調査したい論点（個別調査計画 flow-id 2-1 で確定させる。ここでは枠と当たりのみ）:

1. **既存 `adversarial-review` からの再利用範囲**。承認モデル（投稿前1回の `AskUserQuestion`）・
   findings JSONスキーマ・確度×重大度の選別表・`add_mr_inline_comments` による投稿は、そのまま
   踏襲できる可能性が高い。**どこまでを共通化し、どこから answer-talker 固有にするか**を決める。
   - 判断が必要な点: 実施回数の上限機構（`adversarial-review-count.sh`）を answer-talker にも
     課すか。演習レビューは人間が明示的に呼ぶ想定のため、不要かもしれない。
2. **MR番号起点のdiff取得**。`Provider.sh` に新設する関数のインターフェース（何を返すか。
   変更ファイル一覧とdiff本文を1つのJSONで返すか、2関数に分けるか）と、GitHub/GitLabの
   コマンドの差異。既存の `get_mr_unresolved_comments` / `get_mr_for_branch` の返却形と揃える。
3. **正解ソースの取得方式**。URL clone（shallow）とローカルパスの正規化、一時ディレクトリの
   後始末（`trap`）、既存スクリプトの流儀（`set -euo pipefail`・jq・`REPLY` 返し）の確認。
   Windows/git bash 固有の罠（`MSYS_NO_PATHCONV`・パス変換）が効く箇所かを確認する。
4. **ファイル対応付けの方針**。受講者の変更ファイルと正解側ファイルをどう突き合わせるか。
   **正解側にしか存在しない構成要素**を「未作成の分割単位」として扱う方法。
5. **ネタバレ防止の機械的検査**。findings本文と正解ファイルの行の一致検査を、どの粒度
   （行単位・正規化後のトークン列・識別子）で行うか。誤検知（一般的な語で弾く）と見逃しの
   トレードオフ。**検査は既存 `.claude/scripts/test/` の流儀で単体テスト可能な純粋関数に切る。**

調査結果は `reports/日付_bubbly-exploring-biscuit_<内容>.md`（正文）と同名の `.html` に記録する。
個別調査計画には結果を書かない。

## フェーズ3〈作業〉

調査結果を受けて個別作業計画を立てる。現時点で見込んでいる成果物は次のとおり
（**確定ではなく、フェーズ2の結果で変わりうる**）。

| 成果物 | 内容 |
|---|---|
| `.claude/skills/answer-talker/SKILL.md` | `/answer-talker <MR番号> --reference <正解の場所>` の手順定義。起動・正解取得・diff取得・対応付け・サブエージェント起動・ネタバレ検査・承認・投稿・後始末 |
| `.claude/agents/answer-talker-reviewer.md` | 正解を参照できる専任サブエージェント。観点（責務の分割単位／層と依存の向き／命名・配置・エラー処理・設定の持ち方／正解が避けている作り／別解を潰さない）と、**正解のコード片を出力しない**規約、findings JSONスキーマ |
| `.claude/scripts/src/<正解ソース取得スクリプト>` | URL clone（shallow, 一時ディレクトリ）とローカルパスの正規化・後始末 |
| `.claude/scripts/src/<ネタバレ検査スクリプト>` | findings本文と正解ファイルの一致検査。混入時は投稿させない |
| `.claude/scripts/src/vcs/Provider.sh` | MR番号起点のdiff取得関数を追加（GitHub/GitLab差異を吸収） |
| `.claude/scripts/test/test_*.sh` | 上記のうち純粋ロジックの単体テスト（`passed=N failures=N` / 失敗時 exit 1） |

分割方針: `【設計】` と `【実装】【テスト】` は分けることを既定とする（サブエージェントの観点
設計とネタバレ検査の線引きは、実装前に人間の合意を取りたいため）。フェーズ2の結果が薄ければ
併記に変更してよい。

レビュー往復のたびに `reports/` の結果mdを更新する（個別作業計画は更新しない）。

## フェーズ4〈反映〉

**必ず flow-id 4-1 で反映対象を洗い出す。** 現時点では反映内容を確定させない（洗い出した結果が
空だったときに限り、そこから先をスキップする）。

見込みのある候補（**確定した反映内容ではない**）:

- `.claude/docs/spec/answer-talker.md`（新規）— 受け入れ条件で明示的に要求されている
- `.claude/docs/ddr/00NN-*.md` — 設計判断が生じた場合。想定される論点は「ネタバレ防止を
  サブエージェントの規約だけでなく機械的検査でも担保する二重化」「正解ソースの取得方式」
  「`adversarial-review` と統合せず別スキルとして分ける判断」など
- `.claude/docs/spec/shell-scripts.md` / `.claude/rules/shell-script-style.md` — 実装中に
  新しい罠を踏んだ場合
- `.claude/skills/issue-mr-flow/SKILL.md` — answer-talker がフローのどこに位置づくか
  （`adversarial-review` と同じく flow-id を増やさない並行手順になる見込み）

**DDRの番号は取得直前に `main` の最新を確認して決める**（並走ブランチとの番号衝突は
`check-base-conflicts.sh` が検知するが、繰り下げの手戻りを減らすため）。

`【設計反映】` と `【AIアセット反映】` は原則として計画ファイルを分ける。

## フェーズ5〈クローズ〉

- flow-id 5-1: `cleanup-task.sh` で `plans/` `worklog/` `reports/` を片付け、`HANDOFF.md` を
  リセットする（`REVIEW-POINTS.md` と `worklog/TEMPLATE.md` は残る）
- flow-id 5-2: `check-base-conflicts.sh` で `main` とのコンフリクトを検知（DDR番号重複を含む）
- flow-id 5-3: 関連issueへの通知。**本issueは現状このリポジトリで唯一のissueのため、影響先なしで
  スキップになる見込み**。実施時点で `search_issues` により再確認する
- flow-id 5-4: Draft解除まで。**マージ（5-5）はユーザーの明示指示があるまで行わない**

## 検証（受け入れ条件の確認方法）

| 受け入れ条件 | 確認方法 |
|---|---|
| SKILL.md / agent定義のfrontmatter | `bash .claude/scripts/src/search-frontmatter.sh` でインデックスに載ること、`.claude/rules/markdown-frontmatter.md` のキー定義に沿うこと |
| 正解ソース取得スクリプト | `bash -n` を通す。URL形態・ローカルパス形態の両方で実行し、**一時ディレクトリが実行後に残らないこと**を確認 |
| MR番号起点のdiff取得関数 | **GitHub経路で実在のMRに対して実行**（本PR #2 を対象にできる）。変更ファイル一覧とdiff本文が返ること |
| ネタバレ検査 | 正解のコード片を意図的に含む findings を投入し、**投稿されないこと**を確認。単体テストにこのケースを含める |
| 正解側にしかない分割単位の指摘 | 実例で確認する。「正解ではこうなっている」ではなく「この処理はどういう単位で分けられるか」という形になっていること |
| spec / DDR | フェーズ4で追加。`.claude/docs/spec/answer-talker.md` の存在と、DDR番号の重複が無いこと |

**実例での確認に使う演習MR・正解ソースをどう用意するか**は、フェーズ2の調査論点に含める
（本リポジトリ自身のPRを代用できるか、簡易な題材を用意するか）。

## 進め方の前提

- コミットはすべて `commit` スキル経由（`git commit` の直接実行はhookでブロックされる）
- 各pushの直後と flow-id 5-2 で `check-base-conflicts.sh` を実行する（PR作成後のdefaultブランチ
  追従。本セッションはローカル実行のため購読は行わず、手動確認とする）
- 敵対的レビューは対話セッションのためAIから自律起動しない（人間が `/adversarial-review` を
  呼んだときのみ）

## 承認記録

- 2026-08-20: ベースブランチ `main`・Draft PR作成をユーザー承認（flow-id 1-3）
- 2026-08-20: 本全体作業計画をユーザー承認（flow-id 1-5）
