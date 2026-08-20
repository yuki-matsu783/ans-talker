---
title: flow-id 5-1 後片付けの自動化（cleanup-task.sh）
type: spec
description: flow-id 5-1（次タスクのための片付け）の4操作――plans/ reports/ の削除、worklog/のTEMPLATE.md以外の削除、frontmatterインデックスの再生成、HANDOFF.mdのリセット――を1コマンドへまとめたスクリプトの仕様
tags: [script, workflow, cleanup, spec]
keywords: [cleanup-task, flow-id-5-1, HANDOFF, plans, worklog, reports, index.jsonl, dry-run, TEMPLATE.md, 後片付け]
---

# flow-id 5-1 後片付けの自動化（cleanup-task.sh）

## 背景・目的

issue #28「flow-id 5-1 後片付けタスク自動化スクリプト（cleanup-task.sh）の実装」。

flow-id 5-1（次タスクのための片付け）は、`.claude/skills/issue-mr-flow/SKILL.md` に手順として
書かれているだけで、実行はAIエージェントの手作業だった。実際に行う操作は毎回同じ4つである。

1. `plans/` `reports/` を削除する（md・htmlの両方）
2. `worklog/` のタスク固有ファイルを削除する（**`worklog/TEMPLATE.md` は残す**）。どの階層に
   あっても **`REVIEW-POINTS.md` は残す**（`plans/` `reports/` 配下を含む）
3. frontmatterの機械可読インデックス（`index.jsonl`）を再生成する
4. `HANDOFF.md` を次タスク向けのテンプレートへリセットする

手作業である限り、**消し忘れ**（`reports/` のhtmlだけ残る等）と**消しすぎ**（`worklog/TEMPLATE.md`
まで消す）の両方が起こりうる。とくに後者は、次のタスクでworklogを書き起こす雛形が失われるため、
気づかれないまま次のissueへ持ち越される。`.claude/scripts/src/update-handoff-progress.sh`（進捗記号）
`.claude/scripts/src/check-base-conflicts.sh`（コンフリクト検知）と同じく、**手順書に書くのではなく
スクリプトへ委譲する**方針でこの4操作をまとめる。

## 仕様

### 呼び出し

```bash
bash .claude/scripts/src/cleanup-task.sh [--dry-run] [--skip-index]
```

| オプション | 既定 | 意味 |
|---|---|---|
| `--dry-run` | （実行する） | 何も変更せず、削除対象・リセット要否だけを出力する |
| `--skip-index` | （再生成する） | frontmatterインデックス（`index.jsonl`）の再生成を行わない |
| `-h` / `--help` | — | 使い方をstderrへ出して終了する |

作業ディレクトリはどこでもよい（`git rev-parse --show-toplevel` でリポジトリルートへ移動してから
処理する）。gitリポジトリの外で実行した場合はエラーで終了する。

### 削除対象の決め方

対象ディレクトリは `.mrworkflow.json` の `plansDir` / `worklogDir` / `reportsDir` から読む
（既定 `plans` / `worklog` / `reports`）。設定値は**リポジトリルート配下の相対パスでなければ
エラーにする**（絶対パス・`..` を含むパス・Windowsのドライブ表記・バックスラッシュ区切りを拒否する。
設定ファイル由来の値をそのまま `rm -rf` へ渡さないためのガード）。

各ディレクトリ配下の**ファイルをすべて**削除対象とし、次のものだけを残す。

| 残すもの | 判定 | 理由 |
|---|---|---|
| `worklog/TEMPLATE.md` | パス完全一致（`KEEP_PATHS`） | worklogを書き起こすときの雛形であり、タスクごとの成果物ではない（`.claude/rules/directory-structure.md`） |
| `REVIEW-POINTS.md` | ファイル名一致（`KEEP_BASENAMES`）。階層は問わない | `plans/REVIEW-POINTS.md` `reports/REVIEW-POINTS.md` は、そのディレクトリに対する永続のレビュー観点であってタスク単位の成果物ではない（issue #77。`.claude/rules/docs-workflow.md`「ドキュメント運用」表・`.claude/docs/spec/adversarial-review.md`） |

- 残すものを1つも含まないディレクトリは、**ディレクトリごと削除する**。残すものがある
  ディレクトリ（`worklog/` や、`REVIEW-POINTS.md` を置いた `plans/` `reports/`）は
  ディレクトリ自体を残し、中の空になったサブディレクトリだけを畳む。
- **Git管理下かどうかは問わない。** `index.jsonl`（`.gitignore` 対象の生成物）や `reports/*.html`
  のような未追跡ファイルも同じ扱いで消える。`plans/index.jsonl` を個別に指定する必要はない。
- 非ASCIIのファイル名（`plans/【調査】〜.md` 等）を正しく扱うため、走査は `find -print0` で受ける。

### HANDOFF.mdのリセット

`HANDOFF.md` を、スクリプトへ埋め込んだテンプレート（frontmatter＋6つの見出しだけを持ち、本文は
`（無し）`／`（次タスク着手時に記入する）`）で上書きする。見出し構成は
`.claude/rules/docs-workflow.md`「ドキュメント運用」表の `HANDOFF.md` 行に対応する。

- 既にテンプレートと同じ内容なら書き込まない（JSONの `handoff.alreadyTemplate` が `true` になる）。
  末尾の改行の個数だけの差は同一とみなす。
- `HANDOFF.md` が存在しない場合はテンプレートから新規作成し、警告を1行出す
  （`handoff.created` が `true`）。
- リセット後の内容は、過去に手作業で実施した flow-id 5-1（コミット `6dd6627`）の結果と
  **バイト単位で一致する**ことを確認済み。

### frontmatterインデックスの再生成

`bash .claude/scripts/src/extract-frontmatter.sh .` をリポジトリルートで1回実行する
（削除したファイルの行が `index.jsonl` に残らないようにするため）。`--dry-run` / `--skip-index`
のときは実行しない。

このステップは本スクリプトが**コミットする前**（下記「コミットはしない」）に走るため、削除は
ワーキングツリーにしか反映されていない。`extract-frontmatter.sh` は `git ls-files --cached` で
対象を列挙するので、**削除済みだが追跡されたままのファイル**が列挙結果に混じる。この状態で
実体の無いパスを `stat` しようとして、issue #117 以前は**追跡ファイルを1件でも削除した時点で
必ず失敗していた**（`frontmatterIndex.exitCode: 1`。issue #97 の flow-id 5-1 で実際に発生）。

対処は `extract-frontmatter.sh` 側で行った。列挙結果のうちワーキングツリーに実体が無いパスを
スキップするため、本スクリプトの手順・順序は変えていない（詳細:
[.claude/docs/spec/extract-frontmatter.md](extract-frontmatter.md)「削除済みの追跡ファイルの扱い」、
[.claude/docs/ddr/0057-削除済み追跡ファイルの除外はextract-frontmatter側で行う.md](../ddr/0057-削除済み追跡ファイルの除外はextract-frontmatter側で行う.md)）。

### コミットはしない

このリポジトリのコミットは `commit` スキル経由に限られる（`.claude/rules/git-workflow.md`
「コミット運用」。スキルを介さないコミットの直接実行はPreToolUse hookがブロックする）。本スクリプトは
ワーキングツリーを変更するところまでを担当し、**ステージングもコミットもしない**。削除された
パスは、変更したファイルと同じように `commit` スキルへ渡せる（`.claude/docs/spec/create-commit.md`）。

### 出力

実行内容のJSONをstdoutへ1つ出力する（`check-base-conflicts.sh`・`Provider.sh` と同じ規約）。
人間向けの進捗ログはstderrへ出す（stdoutを機械可読なJSONだけに保つため）。

```json
{
  "dryRun": false,
  "repoRoot": "/path/to/repo",
  "targetDirs": ["plans", "worklog", "reports"],
  "keptPaths": ["worklog/TEMPLATE.md"],
  "keptBasenames": ["REVIEW-POINTS.md"],
  "removedDirs": ["plans", "reports"],
  "deletedFiles": ["plans/【調査】〜.md", "worklog/2026-08-19_〜_push1.md"],
  "handoff": { "path": "HANDOFF.md", "reset": true, "alreadyTemplate": false, "created": false },
  "frontmatterIndex": { "ran": true, "exitCode": 0 }
}
```

`--dry-run` のときは `removedDirs` / `deletedFiles` / `handoff.reset` が「そうなる予定」を表す
（キーの形は同じなので、実行前後で同じ `jq` フィルタが使える）。

### 終了コード

| 終了コード | 条件 |
|---|---|
| 0 | 成功（削除対象が1件も無い場合も成功。**冪等**であり、続けて2回実行しても2回目は何もしない） |
| 1 | 不明な引数、gitリポジトリ外での実行、`.mrworkflow.json` のディレクトリ設定が不正、`HANDOFF.md` の書き込み失敗 |

`extract-frontmatter.sh` の失敗は**警告に留め、終了コードは0のまま**にする。`index.jsonl` は
`.gitignore` 対象の生成物で、SessionStart hook（`.claude/hooks/session-start.sh`）が毎セッション
再生成するため、ここで異常終了させると成功済みの削除・リセットまで失敗に見えてしまう。失敗した
事実はstderrの警告と JSON の `frontmatterIndex.exitCode` で分かる。

### 実装上の注意

- `find` の起動は1ディレクトリにつき1回に抑える（`.claude/rules/shell-script-style.md`
  「外部プロセス起動のコスト」）。判定（残すパスか・安全な相対パスか）はすべてbash組み込みで行う。
- HANDOFF.mdのテンプレートはクォート付きヒアドキュメントから `IFS= read -r -d ''` で読む。
  `IFS=` を落とすと `read` が末尾の改行を削り、リセット後のファイルが末尾改行を失う。
- 単体テスト（`.claude/scripts/test/test_cleanup_task.sh`）から `source` して純粋関数だけを
  再利用できるよう、`main` の呼び出しは `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` ガードの中に置く。

## 影響範囲

### issue #28（新規追加）

新規:
- `.claude/scripts/src/cleanup-task.sh`
- `.claude/scripts/test/test_cleanup_task.sh`（純粋関数 `is_safe_relative_dir` / `is_keep_path` /
  `is_handoff_template` と埋め込みテンプレートの内容を検証。実ファイルを削除する `main` は対象外）
- `.claude/docs/spec/cleanup-task.md`（本ファイル）
- `.claude/docs/ddr/0048-flow-id5-1の後片付けはスクリプト化しコミットは含めない.md`

変更:
- `.claude/skills/issue-mr-flow/SKILL.md`（flow-id 5-1 の手順を本スクリプトの実行へ差し替え）
- `.claude/rules/docs-workflow.md`（flow-id 5-1 でまとめて削除する旨の注記へ、本スクリプトへの参照を追加）
- `.claude/docs/README.md`（spec一覧・DDR一覧へ追記）

本ブランチの作業中に `main` 側で issue #77（レビュー観点 `REVIEW-POINTS.md`）がマージされたため、
`REVIEW-POINTS.md` を削除しない要件を `KEEP_BASENAMES` として取り込んだ（`plans/REVIEW-POINTS.md`
`reports/REVIEW-POINTS.md` は追跡対象として `main` に存在する）。

### issue #117（frontmatterインデックス再生成が必ず失敗する）

本スクリプト自体は変更していない。原因は `extract-frontmatter.sh` が `git ls-files --cached` の
列挙結果に含まれる削除済みファイルを `stat` していたことにあり、そちらで対処した（上記
「frontmatterインデックスの再生成」）。

変更:
- `.claude/scripts/src/extract-frontmatter.sh`（削除済みパスのスキップ。詳細は
  [.claude/docs/spec/extract-frontmatter.md](extract-frontmatter.md)「影響範囲」）
- `.claude/scripts/test/test_cleanup_task.sh`（`main` の結合テストを追加。下記「未決定事項」の
  該当項目が解消した）

新規:
- `.claude/docs/ddr/0057-削除済み追跡ファイルの除外はextract-frontmatter側で行う.md`

## 未決定事項・懸念点

- **残すものの一覧はスクリプト内の定数（`KEEP_PATHS`・`KEEP_BASENAMES`）である。** 現在の対象は
  `worklog/TEMPLATE.md` と `REVIEW-POINTS.md` の2件だけで、`.mrworkflow.json` からは読まない。
  他プロジェクトへ移植した際に残したいファイルが増えたら、設定ファイルへ逃がすか定数へ足すかを
  改めて判断する。
- **（解消）`main` の結合テストは持たない**: issue #117 で常設した。「実リポジトリを汚さない」方針は
  変えず、`mktemp -d` + `git init` の使い捨てリポジトリの中で実プロセスとして起動する
  （`test_search_frontmatter.sh` と同じ切り分け）。削除は実際に走るが対象はフィクスチャのみ。
  常設したのは、issue #117 の不具合が「手順の順序」に起因し、`main` を通さない純粋関数テストでは
  原理的に検出できなかったため。現在の対象は通常実行・`--dry-run`・`--skip-index` の3経路
  （`frontmatterIndex.exitCode`・削除結果・`index.jsonl` の内容・`HANDOFF.md` のリセット）。
  issue #28 対応時に手動確認していた 2回目の冪等性・`extract-frontmatter.sh` 不在・異常終了・
  不正な引数・不正な設定の各経路は、引き続き手動確認のままで常設していない。
