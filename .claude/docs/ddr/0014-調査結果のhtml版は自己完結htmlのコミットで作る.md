---
title: 0014. 調査結果のHTML版はClaude Code Artifact機能ではなく自己完結HTMLのコミットで作る
type: ddr
description: issue-mr-flowの調査結果をHTMLでも残す仕組みを、Claude Code固有のArtifact公開機能ではなく外部リソース非依存の自己完結HTMLをリポジトリへ直接コミットする方式で実装した経緯を記録したDDR
tags: [reports, html, issue-mr-flow, ddr]
keywords: [Artifact, TailwindCSS, reports, worklog, 自己完結HTML, agents-md, claude-code固有機能, issue-48]
---

# 0014. 調査結果のHTML版はClaude Code Artifact機能ではなく自己完結HTMLのコミットで作る

## 背景

issue #48: issue-mr-flowの「調査を実施」ステップ（`.claude/skills/issue-mr-flow/SKILL.md`
flow-id 10〜14）で作成する調査結果は、`plans/<plan名>.md`の「調査」章と`worklog/`にmarkdownのみで
記録されており、表現力に限界があった。調査結果をmarkdownに加えて表現の拡張性が高いHTML
（インフォグラフィック的な見せ方）でも残すことで、視認性・理解を促進したいという要望があった。

生成方式の候補として、Claude Code（本プロジェクトで実際に使われているAIコーディングツールの1つ）
には、HTML/Markdownファイルをclaude.aiへ公開しURLを発行する組み込みの「Artifact」機能がある。
この機能を使えばリッチな表現のページを容易に作れるが、issue-mr-flowは`AGENTS.md`
（「エージェント共通ルール」を意味する、リポジトリのAI運用ルールの区分名）配下の仕組みであり、
Claude Code固有機能への依存は「Claude Code固有ルール」（`CLAUDE.md`が参照する
`.claude/rules/plan-mode-safety.md`のような区分）に置くべき事柄であって、issue-mr-flow本体の
必須要件にはできない。

## 決定

- **HTML版は、外部リソース非依存の自己完結HTMLをAIエージェント自身が執筆し、リポジトリへ直接
  コミットする方式を採用する。** Claude CodeのArtifact機能（claude.aiへの外部公開・URL発行）は
  使わない。
- 保存場所は`reports/<plan名>.html`（`plans/<plan名>.md`と同名・拡張子のみhtml）。
- ライフサイクルは`worklog/`と同一（flow-id 10で作成、10〜14で調査結果と同期更新、flow-id 31で
  worklogと一緒に削除。squash mergeによりmainには残らず、ブランチ／PRのコミット履歴にのみ残る）。
  `.gitignore`には加えない。
- スタイリングはTailwindCSS（CDN経由 `<script src="https://cdn.tailwindcss.com">`）を第一候補と
  する。ビルドステップ無しでユーティリティクラスによる整形ができ、出力トークン量と表現力の
  バランスが良いため。閲覧時にインターネット接続が必要になる点はトレードオフとして許容する
  （GitHub上でのPRレビュー自体が既にインターネット接続を前提とするため実害は小さいと判断）。
- `reports/<plan名>.html`のテンプレート化（雛形ファイル・生成スクリプトの新設）は行わない。
  当面は個別issueごとにAIエージェントが都度執筆する運用とし、複数件運用した実績を踏まえてから
  テンプレート化を判断する。

## 却下した案

- **Claude Code組み込みのArtifact機能で公開しURLを記録する**: リッチな表現が容易に作れる利点は
  あるが、issue-mr-flowはClaude Code以外のAIツールでも実行できる必要がある
  （`AGENTS.md`＝エージェント共通ルールの対象）ため、Claude Code固有機能への依存は避けた。
  加えて、公開先（claude.ai）はリポジトリ外部のホスティングであり、リポジトリのgit履歴だけでは
  再現できない（URLの失効・アクセス権限変更等のリスクがある）点も、`docs-workflow.md`が
  前提とする「そのままコミットして履歴に残す」というplans/worklog系ドキュメントの運用方針と
  相性が悪い。
- **HTML生成をmd→html変換スクリプト（pandoc等）で機械的に行う**: ビルド依存が増える
  （`.claude/scripts/docs/spec/shell-scripts.md`が定めるbash＋jq中心の軽量なスクリプト構成から
  外れる）うえ、issueの目的である「インフォグラフィック的な、表現力の高い見せ方」は
  機械的な変換では実現しにくく、AIエージェント自身が調査結果の性質に応じて構成・強調点を
  判断しながら執筆する方式のほうが目的に合致すると判断した。
- **TailwindCSSをビルドして静的CSSとして同梱する（CDN依存を排除する）**: 完全な
  オフライン再現性を得られる利点はあるが、Node等のビルドツールチェーンの導入が必要になり、
  本プロジェクトの軽量なbashスクリプト中心の開発補助ツール構成から大きく外れる。CDN依存による
  「閲覧時にインターネット接続が必要」という制約は、GitHub PRレビューというユースケース自体が
  既にインターネット接続を前提とするため実害が小さいと判断し、CDN方式を採用した。
- **`reports/<plan名>.html`を毎回固定フォーマットのテンプレートから生成する**: 一貫性は
  得られるが、issueごとに調査結果の分量・性質が大きく異なるため、初期段階でテンプレートを
  固定すると表現の柔軟性を損なう。複数件運用してから判断することとし、今回は方針レベルの
  指針（TailwindCSS CDN読み込み・調査章の見出し構造を目安にする等）に留めた。
