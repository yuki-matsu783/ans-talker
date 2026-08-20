---
title: worklog 20260820 answer-talkerスキルの設計調査 push1
type: log
description: issue #1（answer-talkerスキル追加）のフェーズ2〈調査〉における試行錯誤ログ。push1。
tags: [worklog, answer-talker, 調査]
keywords: [worklog, answer-talker, 調査, adversarial-review, Provider.sh, diff取得, 正解ソース, ネタバレ検査]
---

# worklog: 【調査】answer-talkerスキルの設計調査

対象: issue #1 の answer-talker スキルを設計するための調査（2026-08-20）。
全体作業計画: `plans/bubbly-exploring-biscuit.md`
個別作業計画: `plans/【調査】answer-talkerスキルの設計調査.md`
push回数: 1

## 試したこと

- `get_vcs_access_mode` で経路を確認した（`cli`）。`gh` が使えるため、Provider.shの関数を
  そのまま使う経路で進められる。
- `get_issue 1` でissue本文を取得し、`test_issue_sections` で標準4見出しの有無を確認した
  （欠落なし、終了コード0）。
- 既存ブランチの有無を `git branch --list "feature-1-*"` / `git ls-remote --heads origin "feature-1-*"`
  で確認した（いずれも0件のため新規作成の経路）。
- `new_draft_merge_request` の1回目が「No commits between main and feature-1-...」で失敗したが、
  これは既知の制約で、内部の `add_empty_commit_for_draft_mr` が空コミット＋リモート反映で
  自動リトライし、PR #2 として作成された。SKILL.mdの記載どおりの挙動で、追加操作は不要だった。
- 全体作業計画を書くための事前調査として、`.claude/skills/` `.claude/agents/`
  `.claude/scripts/src/` `.claude/docs/spec/` `.claude/docs/ddr/` の所在と、
  `Provider.sh` の関数一覧（42関数）を確認した。

## うまくいったこと

- `Provider.sh` の関数一覧を `grep -nE '^[a-z_]+\(\)'` で一覧化したことで、issueの「現状」に
  書かれていた**MR番号起点のdiff取得関数が無い**ことを実際に裏付けられた。
  `get_mr_diff_url` / `get_mr_diff_since_url` は**URLを組み立てるだけ**で、diff本文は返さない。
- `adversarial-review` のSKILL.mdを読み、answer-talker が踏襲できそうな構造
  （投稿前1回の承認・findings JSON・確度×重大度の選別表・`add_mr_inline_comments` での投稿）を
  把握できた。調査論点1の当たりが付いた。

## ダメだったこと

- `HANDOFF.md` が、テンプレート取り込み元リポジトリ（MR-driven-workflow）のissue #117 の状態を
  保持したままだった。flow-id 5-1 のリセットを経ずに取り込まれたものと判断し、本issueの内容へ
  全面的に置き換えた（進捗表も、テンプレートには含まれていないため新規に作成した）。

## 次の一歩

- flow-id 2-2: `commit` スキル経由でコミットし、リモートへ反映してレビュー依頼を出す。
- レビュー合意後、flow-id 2-6 で調査を実施する（論点1〜6）。結果は
  `reports/20260820_bubbly-exploring-biscuit_answer-talker設計調査.md` へ記録する
  （この計画・worklogには結果を書かない）。
