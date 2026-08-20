---
title: 開発者向けドキュメント
type: guide
description: このリポジトリの開発に参加する人向けの関連ドキュメントへの入り口をまとめたガイド
tags: [developers, guide]
keywords: [issue-mr-flow, ディレクトリ構成, mrworkflow, claude-code, gemini-cli]
---

# AIアセット開発者向けガイド

## 対象読者 (Intended Audience)

* AIエージェントのメンテナー (AI Agent Maintainers)
* AI関連スクリプトの開発者 (AI-related Script Developers)
* AIワークフローの改善担当者 (AI Workflow Improvement Specialists)

## 開発指針 (Development Principles)

* **慎重な変更 (Careful Modifications):** AIアシスタント（Claude, Gemini）の設定は、各自の環境で十分にテストし、変更は慎重に行ってください。AIの振る舞いに直接影響します。
* **テストの重視 (Emphasis on Testing):** 開発ツール（`/.claude/`）のスクリプトに機能追加や変更を行う際は、必ず対応するテストを追加または更新してください。
* **適切な配置とドキュメント (Proper Placement and Documentation):** 新しいAI関連資産を追加する際は、適切なディレクトリに配置し、関連する`README.md`やその他のドキュメントを更新してください。
* **規約の遵守 (Adherence to Conventions):** 変更を行う際は、[AGENTS.md](AGENTS.md)や`.claude/rules/`に記載されている共通ルールおよび規約を遵守してください。

## 主要なディレクトリと役割 (Key Directories and Roles)

各ディレクトリの役割説明は [index.md](index.md)（Repository Map）を正とする
（重複記載による陳腐化を避けるため、本ファイルでは個別のディレクトリ一覧を持たない。
詳細は [.claude/rules/directory-structure.md](.claude/rules/directory-structure.md) 参照）。

## 開発ワークフロー (Development Workflow)

* **issue-mr-flow:** 新機能開発や大きな変更を行う際は、[.claude/skills/issue-mr-flow/SKILL.md](.claude/skills/issue-mr-flow/SKILL.md)に記載されているフローに従って進めてください。
* **計画と合意形成:** 実装に入る前に必ず計画を立て、ユーザーや他の開発者と合意形成を行ってください。

## テストと品質保証 (Testing and Quality Assurance)

* **既存テストの確認:** コードに変更を加える際は、既存のテストが全てパスすることを確認してください。
* **新規テストの追加:** 必要に応じて、変更内容をカバーする新しいテストを追加してください。
* **AI動作確認:** AIアシスタントの設定変更は、実際の対話を通じてその動作が意図通りであることを確認してください。

## カスタムスキルの開発とパッケージング (Custom Skill Development & Packaging)

本リポジトリには、ワークフロー全体を他のリポジトリへ自動展開するための専用スキル `apply-mr-workflow-to-project` などが定義されています。これらのカスタムスキルはビルド（コンパイル）して配布用バイナリ `.skill` パッケージを生成する必要があります。

### 1. 同期とビルドの流れ (Sync & Build Flow)

開発時、本リポジトリのコアアセット（ルール、設定、フック等）を変更した後は、以下のコマンド群を用いてスキルにアセットを同期させ、配布パッケージをローカルビルドします。

```bash
# 1. 変更したコアアセットをスキル一時アセットディレクトリに同期（assets/ は .gitignore 対象）
bash .claude/skills/apply-mr-workflow-to-project/scripts/sync-assets.sh

# 2. スキルフォルダをビルドして .skill バイナリをコンパイル
node /usr/local/lib/node_modules/@google/gemini-cli/bundle/builtin/skill-creator/scripts/package_skill.cjs .claude/skills/apply-mr-workflow-to-project

# 3. ビルド成果物を出力ディレクトリに整理（build/ は .gitignore 対象）
mkdir -p build && mv apply-mr-workflow-to-project.skill build/
```

### 2. 配布と他リポジトリへの適用方法

ビルドした `.skill` パッケージを任意のリポジトリへ持ち運び、ワークフローを即座に自動展開することができます。

```bash
# 対象のリポジトリのルートで Gemini CLI を使い、ビルドしたパッケージファイルをインポートして発動
gemini skills install /path/to/apply-mr-workflow-to-project.skill
```

インポート完了後、AIエージェントが自律的に対象リポジトリへ `mr-driven-develop` のセットアップを完了させます。