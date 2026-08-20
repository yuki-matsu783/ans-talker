---
name: apply-mr-workflow-to-project
description: あらゆるプロジェクトに対して、Issue/MR駆動開発プロセス（mr-driven-develop）のAI資産（.claude, .gemini, テンプレート, 共通ルール）を自動展開・適用します。ターゲットプロジェクトがGoの場合、Goに特化したルールを自動的に統合・適用します。Gitリポジトリでこのフレームワークをセットアップしたい時に使用します。
---

# Apply mr-driven-develop Workflow to Projects

## 概要 (Overview)

このスキルは、あらゆるソフトウェア開発プロジェクトのリポジトリに対して、本プロジェクトで確立された強力なIssue/MR駆動開発フレームワーク（`mr-driven-develop`）の各種AI資産（ルール、スクリプト、フック、テンプレートなど）を一挙に展開・適用します。

セットアップは完全に自律化されており、インストール対象がGoプロジェクトである場合（ルートに `go.mod` が存在する場合）は、自動検知によってGo言語特化ルール（`go test ./...` や `golangci-lint`、Go特有のコーディング規約）を追加で統合適用します。それ以外の言語では、極めて洗練された言語ニュートラルなAI協調開発資産が展開され、即座に `/issue-mr-flow` を稼働可能にします。

## 前提条件 (Prerequisites)

対象のプロジェクトが以下の条件を満たしていることを自動または手動で確認してください：
1. **Gitリポジトリであること**: ルートディレクトリに `.git` ディレクトリが存在すること（Issue/MR駆動フローにはVCS操作が不可欠なため）。

## セットアップ手順 (Setup Workflow)

このスキルが呼び出された際、AIエージェントは以下の手順を自律的に実行してセットアップを完了させます。

### Step 1: 環境の検証とインストーラの実行
対象プロジェクトのパスを指定して、スキルに同梱されたインストールスクリプト `install-to-project.sh` を実行します（指定がない場合はカレントディレクトリ `.` が対象となります）。

デフォルトでは、すでに存在するファイルとテンプレートの間に差分がある場合、ファイルを上書きする前に既存のファイルを `.bak` という拡張子でバックアップ退避し、警告を表示します。これにより、以前にカスタマイズした内容を安全にマージ・輸入できます。

一律で強制上書き（アップデート）したい場合は、`-f` または `--force` オプションを付与してください。

```bash
# 対象リポジトリが現在のディレクトリの場合（安全マージモード）
bash .claude/skills/apply-mr-workflow-to-project/scripts/install-to-project.sh

# 強制上書きモードで実行する場合
bash .claude/skills/apply-mr-workflow-to-project/scripts/install-to-project.sh --force

# 対象リポジトリのパスを個別に指定する場合
bash .claude/skills/apply-mr-workflow-to-project/scripts/install-to-project.sh /path/to/project

# パス指定と強制上書きを併用する場合（順不同）
bash .claude/skills/apply-mr-workflow-to-project/scripts/install-to-project.sh /path/to/project --force
```

### Step 2: 適用されたファイルの整合性確認
セットアップ完了後、対象プロジェクト内に以下のファイルが正しく配置され、設定されているかを確認します。
- `[DEST]/.mrworkflow.json`（ワークフロー基本設定）
- `[DEST]/AGENTS.md` / `[DEST]/CLAUDE.md` / `[DEST]/GEMINI.md` / `[DEST]/HANDOFF.md` / `[DEST]/index.md`（各種基本ルール・引き継ぎ・インデックスポインタ）
- `[DEST]/.gitignore`（各種一時状態ディレクトリ `/usage-state/`, `/session-logs/` が追記されているか）

### Step 3: 動作検証
対象プロジェクトにて、VCS連携等の動作を確認します。
- 一般のプロジェクトの場合：対象プロジェクトにエラーが起きず正常に動作することを確認します。

## 適用される主要なAI資産

セットアップによって展開される資産とその役割は以下の通りです：

### 1. 共通ルール・ガイドライン
- `AGENTS.md` / `CLAUDE.md` / `GEMINI.md` / `HANDOFF.md` / `index.md`：AIアシスタントが遵守すべき最重要ルール、引き継ぎ情報、ポインタ。
- `.claude/rules/` 内の各共通規約（Goプロジェクトの場合は、さらに `go-applications.md` 特化ルールも有効化されます）。

### 2. コアスクリプト群（`.claude/scripts/`, `.gemini/scripts/`）
- `create-issue.sh` / `create-commit.sh` / `extract-frontmatter.sh`：VCS、コミット、フロントマター処理の自動化。
- `check-base-conflicts.sh`：defaultブランチとのコンフリクト（テキスト＋DDR番号の重複）を作業ツリーを変更せずに検知。
- `check-base-sync.sh`：作業開始・再開時に、ベースブランチの最新を取り込めているか（behindコミット数・未取り込みの変更ファイル）を作業ツリーを変更せずに判定。
- `search-frontmatter.sh`：frontmatterの`index.jsonl`を結合し、type/tags/keywords/パス/フリーテキストでドキュメントを横断検索。
- `vcs/Provider.sh`（および `Github.sh`, `Gitlab.sh`）：GitHubやGitLabのAPI差異を吸収し、ブランチやDraft MR/PR作成を自動化するラッパー。

### 3. フック群（`.claude/hooks/`, `.gemini/hooks/`）
- `block-direct-git-commit.sh`：コミット時、安全に `commit` スキルを経由させるためのブロックフック。
- `session-start.sh` / `post-push-usage-report.sh` / `post-push-compact-prompt.sh`：セッション開始時やプッシュ時の自動的なユーセージ追跡とコンテキスト最適化。

### 4. 組み込みスキル群（`.claude/skills/`, `.gemini/skills/`）
- `commit`：Conventional Commitsに準拠したコミットの自動生成・分割コミット支援。
- `issue-create`：対話的なIssueの自動作成。
- `issue-mr-flow`：起票からマージまでを完全ガイド・自律実行するメインワークフロー。
- `resolve-conflict`：マージ依頼前のdefaultブランチとのコンフリクト検知・解消。
- `doc-search`：ドキュメント探索をgrep/findの全文探索ではなくfrontmatterインデックス検索で行う。

---

## 既存プロジェクトへの再適用とマージ相談フロー (Interactive Merging)

すでに本フレームワークを展開済みのリポジトリに対して再適用を行う場合、または本リポジトリのアップデートを追従したい場合、デフォルト（`--force`なし）でスクリプトを実行すると、衝突したファイルは安全に退避され、マージするための警告が通知されます。

### AIと人間での共同マージフロー
1. **スクリプトの実行**：`install-to-project.sh` を通常実行（`--force` なし）。
2. **バックアップの作成**：既存のカスタマイズされていたファイル（例：`CLAUDE.md`）は `CLAUDE.md.bak` として退避され、最新のテンプレートが `CLAUDE.md` に配置されます。
3. **AIへの指示とマージの相談**：
   人間からAIエージェントに対して以下のように呼びかけ、以前のカスタマイズ部分を相談しながら適用（輸入）します。
   > 「CLAUDE.md.bak と新しく展開された CLAUDE.md の差分を比較して、以前のプロジェクト固有の設定（例：計画モードの個別ルールなど）を新しい CLAUDE.md にマージして取り込んでください。」
4. **自律的マージ**：AIエージェントは両者のファイルを読み込んで差分を検証し、最新のテンプレート構造を崩すことなく、プロジェクト固有の設定部分のみをスマートに移植します。
5. **クリーンアップ**：マージが成功し動作確認ができたら、不要になった `.bak` ファイルを削除し、コミットを作成します。