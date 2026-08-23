---
title: 【AIアセット反映】受講者ソースの受け渡し
type: plan
description: issue #6 のフェーズ4のうち、rules・skills・agents・REVIEW-POINTSへの反映（AIアセット反映）の個別計画。作業中に踏んだ罠と、レビューで露呈した確認の抜けをルール側へ戻す。
tags: [issue-mr-flow, answer-talker, AIアセット反映, plan]
keywords: [REVIEW-POINTS, shell-script-style, 空ファイル, grep -rlI, 変更箇所を通る入力, markdown, docs-workflow]
---

# 【AIアセット反映】受講者ソースの受け渡し（flow-id 4-6 の2セット目）

- issue: [#6](https://github.com/yuki-matsu783/ans-talker/issues/6) / PR: [#7](https://github.com/yuki-matsu783/ans-talker/pull/7)
- 全体作業計画: `plans/bubbly-exploring-biscuit.md`
- **前提: `plans/【設計反映】受講者ソースの受け渡し.md` の実施とレビューが完了していること**
  （設計反映を完了・レビューしてからAIアセット反映に着手する。`issue-mr-flow/SKILL.md`）

## この計画で決めないこと（スコープ外）

- `.claude/docs/spec/` `.claude/docs/ddr/` への反映 → **`【設計反映】` の担当**。
- `.claude/skills/issue-mr-flow/SKILL.md` のMCP対応表 → **flow-id 3-9 で反映済み**（再掲しない）。

## やること1: `.claude/rules/shell-script-style.md` へ罠を2件足す

いずれも**今回実際に踏んだ**もので、既存の項目では防げなかった。

| 罠 | どこへ足すか | 何を書くか |
|---|---|---|
| **`grep -rlI` は空ファイルにマッチしない** | 新規の小節（「テキスト/バイナリ判定」） | 補集合を取ると**0バイトのファイルがバイナリ扱いで消える**。`__init__.py` `.gitkeep` は普通に存在する。`find ... -empty` / `! -empty` で補う。`-size 0` ではなく `-empty` を使う（`-size` の既定単位は512バイトブロックで意味が紛れる） |
| **`jq --args` の引数長の具体的な境界** | 既存「JSON操作」の該当項へ**追記** | 既存項目は「サイズが可変なら渡さない」までしか書いておらず、**どこから壊れるかの目安が無い**。実測値（**500件・平均パス長65文字で `Argument list too long`**）を足す。`--rawfile` + `rtrimstr`/`split` という受け口の例も添える |

**新規項目として立てるのは1件目だけ**にする。2件目は既存項目の強化であり、
別項目にすると同じ内容が2箇所に増える（観点表「同じ内容が複数ファイルに重複していないか」）。

## やること2: `REVIEW-POINTS.md` へ観点を1つ足す

**ルート直下の `REVIEW-POINTS.md`**（「変えないはずのものが変わっていないか」の節）へ、
次の観点を追加する。

> **その確認は、変更箇所を通る入力で行ったか。** 変更した分岐を通らない入力ばかりで
> 「挙動は変わっていない」と確認しても、何も確かめたことにならない。

- **これは今回の実例から出た観点である。** flow-id 3-9 で `old_line` の分岐を足した際、
  GitHub側の確認を「`line` 無し・diff外・有効行外」の3ケースで行い、**`old_line` を持つ入力を
  一度も流さなかった**。結果、GitHub経路が壊れていることを 3-8 の敵対的レビューまで検出できなかった。
- 置き場所を `.claude/REVIEW-POINTS.md` ではなく**ルート直下**にするのは、
  `.claude/` 配下に限らない一般的な観点だからである（「一般的な観点ほど上位へ置き、下位で
  重複して書かない」）。

## やること3: `.claude/rules/docs-workflow.md` へ機械的検査を足す

markdownへ節を差し込む際の**空行2連続の検査**を、既存の「既存ドキュメントへ新しい見出しを
差し込むときは…」の節へ追記する。**書く式は次の形にする**（`NR` ではなく `FNR`、かつ
ファイル先頭で `prev` を初期化する）。

```bash
awk 'FNR==1{prev="x"} prev=="" && $0=="" {print FILENAME":"FNR} {prev=$0}' <files...>
```

- 既存の節は「**目視で**前後3行を確認する」と書いているが、今回はHTMLも含め繰り返し崩れた。
  目視の指示は残したうえで、**機械的に検査できる形**を併記する。
- **素朴な `prev=="" && $0=="" {print FILENAME": "NR}` は複数ファイルを渡すと壊れる**
  （フェーズ4の敵対的レビュー1回目の指摘）。`NR` は全ファイル通算のレコード番号なので
  実ファイルの行数を超えた値が出て `sed -n` で開けず、`prev` がファイル境界でリセットされない
  ため「前のファイルの末尾が空行・次のファイルの先頭が空行」を違反として誤検知する。
  実際に3ファイル（末尾が空行／先頭が空行／4行目に違反）へ流したところ、旧式は
  `b.md: 4`（誤検知）と `c.md: 12`（正しくは4行目）を出し、上の式は `c.md:4` のみを出した。
- **恒久ルールとして載せる以上、意図的に空行を2つ並べたファイルへ流して検出できることを
  確かめる手順も併記する**（観点表の「検証コマンドが空振りしないか」）。

## やること4: エージェント定義へ「本文はmarkdown」を明記する

`.claude/agents/adversarial-reviewer.md` と `.claude/agents/answer-talker-reviewer.md` の
findings スキーマの説明へ、**`body` はmarkdownとしてMRへ投稿される**旨を書く。

- issue #6 の検証中、12回の起動のうち**3回**でHTMLエンティティ（`&gt;` 等）が本文へ現れ、
  投稿前に元の文字へ戻す必要があった。
- **両ファイルに同じ文を書くことになるが、これは許容する。** 2つのエージェントは独立に選択・
  起動されるものであり、片方だけを読む状況が普通にあるため（参照で済ませると、参照先を
  読まないまま出力する経路が残る）。

## やること5: `.claude/skills/adversarial-review/SKILL.md` 手順7へ限定を足す

手順7の「**`line` を持たない finding はサマリへ回らず、そのファイルの diff 上で最初に現れる
有効行へインラインで付く**」という記述は、flow-id 3-9 の実装で**両プロバイダについて正しく
なった**。ただし限定が抜けている。

> ただし**有効行を持たないファイル（diffに現れない・`patch` が省略された）ではサマリへ回る**。
> また `old_line` のみを持つ指摘は、GitHubではサマリ・GitLabではインラインになる。

## やらないこと

- **`AGENTS.md` / `CLAUDE.md` の変更**。今回の知見はいずれも詳細ルール側（`.claude/rules/`・
  `REVIEW-POINTS.md`）に収まり、セッション開始時に常時読ませるべき粒度ではない。
- **`answer-talker/SKILL.md` の変更**。flow-id 3-6 で実装と同時に更新済みで、追加の反映は無い。
- **段1の入口・段2のリトライ方針の作り込み**（実装結果mdの候補1）。これは
  **ローカルGitLab環境の不安定さへの対処**であり、恒久ルールではない。
  → **別issueとして起票するかを 4-6 の実施時に判断する**（本計画では実装しない）。

## 検証

```bash
# 1. 変更したmdの空行2連続（今回足す検査自体を、今回の変更にも適用する）
#    NR ではなく FNR を使い、ファイル先頭で prev を初期化する（複数ファイルを渡すため）
awk 'FNR==1{prev="x"} prev=="" && $0=="" {print FILENAME":"FNR} {prev=$0}' \
  .claude/rules/*.md .claude/agents/*.md REVIEW-POINTS.md \
  .claude/skills/adversarial-review/SKILL.md

# 1b. 上の検査が空振りしないことを確かめる（違反を作って検出できるか）
printf 'c1\nc2\n\n\nc5\n' > /tmp/awkcheck.md
awk 'FNR==1{prev="x"} prev=="" && $0=="" {print FILENAME":"FNR} {prev=$0}' /tmp/awkcheck.md
#    → /tmp/awkcheck.md:4 が出ること。出なければ検査が壊れている
rm -f /tmp/awkcheck.md

# 2. 観点表が収集経路に載ることを確認する（ルート直下へ足したものが拾えるか）
bash .claude/scripts/src/collect-review-points.sh .claude/scripts/src/vcs/Provider.sh \
  | grep -c '変更箇所を通る入力'        # 1以上であること

# 3. frontmatterの再生成（新規ファイルは無い見込みだが description/keywords を更新した場合に備える）
bash .claude/scripts/src/extract-frontmatter.sh .

# 4. 単体テストが引き続き通ること（ルール変更のみだが、collect-review-points の検査があるため）
bash .claude/scripts/test/test_collect_review_points.sh
```

## 実施後

- 結果は `reports/日付_bubbly-exploring-biscuit_AIアセット反映の結果.md` へ書く
  （**この計画には書かない**）。
- worklog は `worklog/日付_bubbly-exploring-biscuit_【AIアセット反映】受講者ソースの受け渡し_push<N>.md`。
