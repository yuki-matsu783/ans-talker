---
title: 0010. ブランチslugの意訳生成はAIエージェントが行い、Provider.shは翻訳APIを持たない
type: ddr
description: 日本語issueタイトルからのブランチslug生成をAIエージェントの意訳に委ね、Provider.shはサニタイズ専任のまま維持した経緯を記録したDDR
tags: [slug, branch-naming, ddr]
keywords: [to_slug, new_issue_branch, 意訳, 翻訳api, ローマ字変換, 非決定性, issue-22]
---

# 0010. ブランチslugの意訳生成はAIエージェントが行い、Provider.shは翻訳APIを持たない

## 背景

`dev-tools/src/vcs/Provider.sh` の `to_slug()` は、非ASCII文字を単純に除去するだけの機械的な
サニタイズ関数である。日本語タイトルのissueでは英単語を含まない限りslugが空文字になり
`"issue"` にフォールバックする（issue #3対応時に判明、`dev-tools/docs/spec/issue-mr-workflow.md`
「未決定事項・懸念点」節に記録され、「より説明的なスラッグが必要になった場合はローマ字変換等の
対応を別途検討する」と先送りされていた）。

issue #22で「日本語タイトルの英訳・意訳をslugに反映したい」という要望が実際に上がり対応した。

調査の結果、`to_slug()`は入力の言語やスペース区切りかどうかを問わず同じロジックで処理する
純粋なサニタイズ関数であり、**呼び出し側が渡す文字列の中身を変えるだけで意図した動作が実現できる**
ことを確認した（`to_slug`自体のロジック変更は不要）。

## 決定

- **翻訳・意訳はAIエージェント（`start`サブコマンドを実行するClaude Code自身）が行う。**
  issueタイトルの意味を汲んだ英語フレーズ（3〜6語程度）を生成し、`new_issue_branch()`の第2引数
  として渡す。`Provider.sh`側には翻訳ロジックを一切追加しない。
- `new_issue_branch()`の第2引数は「生issueタイトル」から「slug化対象のテキスト（英語推奨）」へ
  契約を変更した。ロジック自体は無変更（`to_slug()`をそのまま呼ぶだけ）のため、ローカル変数名を
  `title`→`slug_source`にリネームし、コメントで契約変更を明記するに留めた。
- slugがAI生成になると実行のたびに異なる文言になり得る（非決定的）ため、`.claude/skills/
  issue-mr-flow/SKILL.md`の`start`手順2「既にブランチがあるかの確認」を、slugまで含めた完全一致
  ではなく、**issue番号のprefixパターン一致**（既定`feature-<issue番号>-*`を`git branch --list`/
  `git ls-remote --heads origin`で検索）に変更した。これにより同一issueへの重複ブランチ・
  重複Draft PR作成を防ぐ。

## 却下した案

- **`Provider.sh`側で外部翻訳APIを呼ぶ**: `dev-tools/docs/spec/shell-scripts.md`が定める
  「git/jq/gh/glabのみに依存する自己完結設計」から外れ、ネットワーク依存・APIキー管理という
  新たな前提が発生するため見送った。AIエージェントは既に`start`実行時にissueタイトルを読んでおり
  翻訳能力を持つため、bash層に翻訳責務を持たせる必要がない。
- **ローマ字変換ライブラリの導入**: 機械的な音訳であり、ユーザーが求める「意味を汲んだ意訳」を
  満たさない。加えて変換辞書等の新規外部依存が必要になるため見送った。
- **`get_existing_branch_for_issue()`のような専用ヘルパー関数をProvider.shに新規追加する**:
  ロジックをテストで保証しやすくなる利点はあるが、本issueの主題（slugのリッチ化）に対して
  変更範囲が広がる。ユーザーに確認のうえ、`.claude/skills/issue-mr-flow/SKILL.md`の手順文修正
  （具体的なgit検索コマンドの記述）のみで対応する方式を採用した。
- **`Github.sh`/`Gitlab.sh`の`get_issue()`が返す未使用`slug`フィールド（機械的`to_slug(title)`）
  の削除・修正**: 元々どこからも参照されていない死んだ出力であり実害がないため、本issueの
  スコープ外として現状維持とした（将来的な整理は別issueで検討）。
