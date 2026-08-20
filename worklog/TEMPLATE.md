---
title: worklogテンプレート
type: log
description: worklog作成時にコピーして使うテンプレートファイル
tags: [worklog, template]
keywords: [worklog, 計画, 試したこと, うまくいったこと, ダメだったこと, 次の一歩]
---

<!--
  worklogテンプレート。
  新規worklog作成時はこのファイルをコピーし、
  `worklog/日付_<全体計画名>_<個別計画名>_push<N>.md`
  （例: worklog/20260815_fancy-painting-prism_【調査】既存運用の棚卸し_push1.md）に
  リネームしてから中身を埋めること。配置・運用ルールは .claude/rules/docs-workflow.md,
  .claude/rules/git-workflow.md を参照。
-->

# worklog: <個別計画名>

対象: <タスクの概要>（<日付>）。
全体作業計画: `plans/<自動命名>.md`
個別作業計画: `plans/【種別】タスク内容.md`
push回数: N

## 試したこと

- <調査・実装で試した内容を書き足していく>

## うまくいったこと

- <採用した方針・解決した内容>

## ダメだったこと

- <試したが不採用/失敗だった内容。無ければ「特になし。」>

## 次の一歩

- <未完了のタスク・次回セッションでやること。完了していれば「特になし（完了）。」>

---
