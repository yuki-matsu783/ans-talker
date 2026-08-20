---
title: 0036. GitLab issueテンプレートは予約名Default.mdを正とし文書側を合わせる
type: ddr
description: 実体Default.mdと文書上のtask.mdの不整合を、実体の改名ではなく文書側の統一で解消すると決めた記録
tags: [ddr, gitlab, issue-template, docs]
keywords: [Default.md, task.md, 予約名, description-templates, issueテンプレート, 自動適用, リンク切れ, 未同梱DDR]
---

# 0036. GitLab issueテンプレートは予約名`Default.md`を正とし文書側を合わせる

issue #32。

## 背景

GitLab用issueテンプレートの実体は `.gitlab/issue_templates/Default.md` だが、文書側は9箇所が
`.gitlab/issue_templates/task.md` と記載しており、実体と一致していなかった
（正しく `Default.md` と書かれていたのは `.claude/skills/issue-mr-flow/SKILL.md` の1箇所のみ）。

GitHub側は `.github/ISSUE_TEMPLATE/task.md` が実体であり、そちらは一致している。両者を
「`task.md`」という同じ名前で並べて書いていたことが、不整合を見えにくくしていた。

## 決定

**実体（`Default.md`）を正とし、文書側の記載を `Default.md` へ統一する。** 実体の
`task.md` への改名は行わない。

対象は次の9箇所（`.gitlab/issue_templates/task.md` という文字列8箇所＋
`.claude/docs/spec/issue-mr-workflow.md` のツリー図中の裸の `task.md` 1行）。

- `.claude/skills/issue-create/SKILL.md`
- `.claude/skills/issue-mr-flow/SKILL.md`（2箇所）
- `.claude/scripts/src/vcs/Provider.sh`（2箇所。コメント）
- `.claude/rules/markdown-frontmatter.md`
- `.claude/docs/spec/issue-mr-workflow.md`（3箇所。うち1箇所はツリー図）

## 理由

`Default.md` はGitLabの[Description templates](https://docs.gitlab.com/user/project/description_templates/)
における**予約名**であり、新規issueの説明欄へ**自動的に適用される**。

`task.md` という任意名にすると、起票者がテンプレート選択ドロップダウンから「task」を能動的に
選ばない限り本文が空のままになる。本ワークフローは「目的・現状・期待する動作・受け入れ条件の
4見出しが揃っていること」を前提に組まれており（`Provider.sh` の `create_issue`、
`issue-mr-flow` の flow-id 1-4 での過不足チェック）、**テンプレートが既定で適用されること**に
価値がある。GitLab側だけ手動選択が必要になるのは、この前提を弱める。

したがって、名前を揃えること（GitHubと同じ `task.md`）よりも、既定適用されること
（`Default.md`）を優先した。GitHub側にはこの予約名の仕組みが無く `task.md` のままでよいため、
**両プロバイダで名前が異なるのは意図的**である。

## 却下した案

- **実体を `task.md` へ改名し、文書はそのままにする**: 変更箇所が1ファイルで済む点は魅力だが、
  上記のとおりGitLabでの自動適用が失われる。「文書の記載が多数派だから実体を合わせる」という
  理由は、機能上の損失を正当化しない。
- **`Default.md` と `task.md` の両方を置く**: GitLabは `Default.md` を自動適用しつつ `task.md` も
  ドロップダウンへ出すため技術的には可能だが、同じ内容のファイルが2つになり二重管理になる。

## 付随して定めたこと: 未同梱DDRへのリンクは記法を外して注記へ置き換える

同じissue #32で、移植時に持ち込まなかったDDR（0001・0002・0008・0015）のうち `0002` への
markdownリンクが3箇所残っており、リンク切れになっていた。

**リンク記法を外し、「移植元のDDR 0002。本テンプレートには未同梱」という注記と
`.claude/docs/README.md` への誘導へ置き換える**（実体のファイルは作らない）。欠番の理由は
`.claude/docs/README.md`「ddr（意思決定ログ）」に既に記載があり、そこへ誘導すれば読み手が辿れる。
欠番を埋め直さない方針は同README記載のとおり（既存DDR本文中の相互参照とずれるため）。

このうち1箇所は `.claude/docs/ddr/0019-...md` の**本文**にあった。DDRの本文は
`.claude/rules/docs-workflow.md` により「一度マージしたら追記のみ（変更不可）」だが、
**表示テキストを一切変えずリンク記法だけを外し、括弧書きの注記を追記する**形に留めることで、
決定内容の記録を書き換えずにリンク切れを解消できると判断した。DDR本文中のリンク切れを直す
必要が今後生じた場合も、この範囲（表示テキスト不変＋追記）に収めること。

あわせて `index.md` の `./plans/` `./build/` へのリンクも外した。前者は flow-id 5-1 で削除される
寿命を持ち、後者は `.gitignore` の `/build/` 対象であり、いずれも**Git管理下に実体を持てない**
ため、リンクにできない。各行に理由を併記した。
