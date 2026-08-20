---
name: commit
description: 'Generate a Japanese commit message with Conventional Commits prefix and create one or more atomic commits. Use whenever a commit needs to be made in this repository — both when the user explicitly invokes /commit AND whenever an AI agent commits autonomously as part of the issue-mr-flow (flow-id 2-2/2-7/3-2/3-7/4-2/4-7/5-4). All commits in this repo MUST go through this skill; direct git commit is blocked by a PreToolUse hook. Flow: git status → analyze diff → filter sensitive/junk files → .claude/scripts/src/create-commit.sh (NO Claude footer, no confirmation; multiple mixed prefixes are auto-split into separate commits)'
title: git commit標準化
type: skill
tags: [issue-mr-flow, workflow, skill]
keywords: [commit, コミット]
---

# /commit スキル

`/commit` が呼ばれた時、変更内容を分析して日本語のコミットメッセージを自動生成し、確認を挟まずコミット作成まで進める。

## 呼び出しタイミング

このスキルは以下の2パターンいずれでも使う（issue #39: 「すべてのコミットがスキルを利用して
行われる」が受け入れ条件）。

- ユーザーが明示的に `/commit` と入力した場合
- AIエージェントが本リポジトリでコミットを作成する場面全般
  （`.claude/skills/issue-mr-flow/SKILL.md` の全体フローflow-id 2-2/2-7/3-2/3-7/4-2/4-7/5-4
  「commit, push してレビュー依頼を行う」等）

`git commit` の直接実行は `.claude/hooks/block-direct-git-commit.sh`（PreToolUse hook）により
機構的にブロックされる（`.claude/rules/git-workflow.md` の「コミット運用」節参照）。このスキルの
Step 4は `.claude/scripts/src/create-commit.sh` というラッパースクリプト経由でコミットするため、
hookの対象にならず正規に実行できる。

## 絶対ルール

- **`Co-Authored-By: Claude` などのフッターは絶対に付けない**
- **`git add .` / `git add -A` は使わない** — 必ず個別ファイル指定
- **`--no-verify` は使わない**（フックが失敗したら原因を直す）
- **`git commit --amend` は使わない**（常に新規コミット）
- **失敗時に `git reset` などで自動ロールバックしない** — 状況を報告してユーザに判断を仰ぐ
- **ステージングされていない変更（unstaged / untracked）はコミット対象に含めない** — ユーザに質問せず自動的に除外する。コミット対象は `git diff --cached` で確認できるステージング済み変更のみ

**削除したファイルのパスは、他のファイルと同じように `--` の後ろへ並べてよい**（issue #60）。
追跡済みファイルを削除しただけのパスは、ラッパーがそのまま「削除」としてステージする。
**先に削除をステージしてから残りをラッパーへ渡す2段構えは不要**であり、むしろそれを行うと
当該パスがindexから消えるため、後続の処理がpathspec不一致で失敗する。既に削除がステージ済みの
パスを渡した場合は、冪等にスキップして通知するだけになる
（仕様: `.claude/docs/spec/create-commit.md`、経緯: `.claude/docs/ddr/0030-create-commitは削除ステージ済みパスをgit-addの失敗時分類で吸収する.md`）。

## 実行フロー

### Step 1: 現状把握

並列で以下を実行：

- `git status`（`-uall` フラグは使わない）— ステージング状態の確認用
- `git diff --cached`（**staged のみ**。unstaged は対象外なので見ない）
- `git log --oneline -10`（リポジトリのコミットスタイル参考用）

**ステージング済みの変更が1つもない場合**は「ステージング済みの変更がありません。`git add` でコミット対象をステージングしてください」と伝えて終了する。unstaged/untracked のファイルが残っていても**ユーザに質問しない**（自動的にコミット対象外として扱う）。

### Step 2: 変更内容を分析

取得した diff から以下を判定：

**(a) prefix判定** — 各変更ファイル群に対して以下から選ぶ：

| prefix | 意味 |
|---|---|
| `feat` | 新機能の追加 |
| `fix` | バグ修正 |
| `docs` | ドキュメントのみの変更 |
| `ai-asset` | AIアセットの変更 |
| `style` | コードの意味に影響しない変更（空白・フォーマット等） |
| `refactor` | バグ修正でも機能追加でもないコード変更 |
| `test` | テストの追加・修正 |
| `chore` | ビルド補助ツール・雑務（`build` 以外） |
| `perf` | パフォーマンス改善 |
| `ci` | CI設定の変更 |
| `build` | ビルドシステム・外部依存の変更 |
| `revert` | 以前のコミットの取り消し |

**(b) 論理的まとまり判定** — 内容（prefixが変わるか）+ ファイルパスの両方を見て、複数のスコープに分かれるかを判定。

### Step 3: ファイルフィルタ

`git add` 対象から以下を**自動除外**：

**クレデンシャル系（絶対除外）**
- `.env`, `.env.*`
- `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.ppk`
- `credentials.json`, `service-account*.json`
- `id_rsa`, `id_ed25519`, `id_ecdsa`
- `.aws/credentials`, `.netrc`
- `secrets.yml`, `secrets.yaml`

**開発環境の副産物**
- `.DS_Store`, `Thumbs.db`, `desktop.ini`
- `*.swp`, `*.swo`, `*~`
- `node_modules/`, `vendor/`, `__pycache__/`
- `dist/`, `build/`, `out/`, `target/`
- `*.pyc`, `*.class`, `*.o`
- `*.log`, `logs/`
- `tmp/`, `temp/`, `*.tmp`, `*.bak`, `*.orig`

**削除されたファイルは除外対象ではない**（issue #60）。`git status` の `D`（deleted）で
表れているパスも、通常の変更と同じようにコミット対象へ含めてよい。

**除外したファイルがあれば**、コミット実行前にチャットに明示：
```
以下は自動除外しました（コミットには含めません）：
- .DS_Store
- node_modules/...
```

### Step 4: コミット実行

**確認は挟まず、そのままコミットを作成する。** ユーザへの承認待ち（AskUserQuestion等）は行わない。

**単一スコープの場合：** 提案するコミットメッセージをチャット本文に表示したうえで、そのまま
コミットを実行する。除外予定のファイル（クレデンシャル系・副産物）があれば合わせて明示する。

**複数prefix混在の場合：** 確認を挟まず、prefixごとに複数コミットへ自動的に分割して順次実行する。
実行前に、分割案をチャット本文に明示する（透明性のため。承認待ちはしない）：
```
コミット1: feat: ○○機能を追加
  - src/feature.ts
  - src/feature.test.ts
コミット2: docs: READMEを更新
  - README.md
```

`git commit` を直接実行せず、`.claude/scripts/src/create-commit.sh` を使う
（`git commit` の直接実行は `.claude/hooks/block-direct-git-commit.sh` によりブロックされる）。

```
bash .claude/scripts/src/create-commit.sh --message "<prefix>: <日本語説明>" -- <file1> [file2 ...]
```

**コミットメッセージ形式：**
- `<prefix>: <日本語説明>` の **1行のみ**
- 本文・フッター・Co-Authored-By など一切付けない

複数コミットの場合は順番に Step 3-4 を繰り返す。途中で失敗したら**そこで停止**して状況を報告（自動 reset しない）。

## 備考
<レビュアーが知っておくべきこと、未対応事項。なければセクション省略>
```

**条件付きで以下を追加（該当時のみセクション追加、なければ省略）：**

- **関連Issue**：コミットメッセージや diff コメントに `#123` などの参照があれば
  ```markdown
  ## 関連
  - Closes #123
  ```

- **破壊的変更**：API・公開インターフェイスの非互換変更を検知したら
  ```markdown
  ## 破壊的変更
  - <何が変わったか・移行方法>
  ```

**変更内容の列挙ルール：**
- 主要ファイルのみ列挙（大量にある場合はディレクトリ単位で要約）
- 自動除外したファイルは含めない

## エラー時の対応

- **pre-commitフック失敗** → エラーを表示し、原因を修正してから新規コミットを作る（amend禁止）
- **複数コミット中に失敗** → そこで停止、`git status` で現状を表示してユーザに判断を仰ぐ
- **コミット対象がない** → 「コミットする変更がありません」と伝えて終了

## してはいけないこと

- TodoWrite / Agent ツールの使用
