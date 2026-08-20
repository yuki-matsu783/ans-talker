---
title: 0005. Draft PR作成失敗時は空コミットで自動リトライする
type: ddr
description: Draft PR作成失敗時に空コミットで自動リトライする対応を記録したDDR
tags: [draft-pr, github, ddr]
keywords: [空コミット, 差分無し, 自動リトライ, ドラフトpr, lastexitcode]
---

# 0005. Draft PR作成失敗時は空コミットで自動リトライする

## 背景

`New-DraftMergeRequest`（`gh pr create` / `glab mr create`）は、`New-IssueBranch` 直後のように
baseブランチとの差分（コミット）が無い状態のブランチに対して呼ぶと失敗する
（`GraphQL: No commits between main and <branch>` 等）。この制約自体はissue #5対応時に発覚し、
その場では手動で空コミットを挟んで回避していたが、自動化はスコープ外として
`dev-tools/docs/spec/issue-mr-workflow.md` の未決定事項に記載するのみに留めていた。

issue #15対応で `feature-15-mr` ブランチを作成した直後、実際にこの失敗に再度遭遇した。
毎回手動回避が必要な既知の制約を放置し続けるコストの方が、自動化のコストより大きいと判断し、
今回あわせて解消することにした（ユーザー指示: 「toolを改修して、no commitエラーであれば
空コミットをするようにしてほしい」）。

## 決定

**`gh pr create` / `glab mr create` が失敗（`$LASTEXITCODE -ne 0`）した場合、空コミットを1つ積んで
pushし、1回だけ自動リトライする。** それでも失敗する場合はそのまま例外を投げる（無限リトライはしない）。

- 共通処理 `Add-EmptyCommitForDraftMr`（`dev-tools/src/vcs/Provider.ps1`、provider非依存）として
  切り出し、`GitHub-NewDraftMergeRequest` / `GitLab-NewDraftMergeRequest` の両方から呼ぶ。
- 失敗検知は `try`/`catch` ではなく `$LASTEXITCODE` を見る方式にした。Windows PowerShell 5.1では
  ネイティブexeの非0終了は既定で例外化されないため（`$ErrorActionPreference = "Stop"` は
  cmdletには効くがネイティブexeの終了コードには影響しない）、既存コード（`GitHub-GetMrForBranch`）
  と同じ判定方式に揃えた。

issue #15対応で、実際にこの状況にあった `feature-15-mr` ブランチで動作検証を行い、
空コミット経由でのDraft PR作成成功を実機確認済み（PR #17）。

## 却下した案

- **`New-IssueBranch` 側で無条件に空コミットを含める**: ブランチ作成のたびに常に1つ余分な
  コミットが増える。実際に差分が無いのは`New-IssueBranch`直後に即座に`New-DraftMergeRequest`を
  呼ぶ場合のみであり、常時空コミットを混ぜるのは不要なノイズになるため見送った。失敗時のみ
  リトライする方式の方が、通常ケース（既にコミットがある状態でPR作成する場合）に余分な副作用を
  持ち込まない。
- **リトライ回数を複数回にする／バックオフする**: 空コミット1つで解消する種類の失敗
  （baseとの差分が無い）であり、1回のリトライで解消しなければ別の原因（認証切れ・ネットワーク障害等）
  である可能性が高い。無限リトライやバックオフは原因不明のまま処理を継続させることになり、
  かえって問題を分かりにくくするため見送った。
