---
title: 【実装】【テスト】answer-talkerスキル一式
type: plan
description: issue #1 の answer-talker スキルについて、設計結果（D1〜D7）に沿って6ファイルを実装し、単体テストと15パターンの実機検証を行うための個別作業計画。
tags: [issue-mr-flow, answer-talker, 実装, テスト, plan]
keywords: [answer-talker, 実装, 単体テスト, 検証, GitLab, 演習用プロジェクト, ネタバレ検査, get_mr_changed_files, 15パターン]
---

# 【実装】【テスト】answer-talker スキル一式

- issue: [#1](https://github.com/yuki-matsu783/ans-talker/issues/1) / PR: [#2](https://github.com/yuki-matsu783/ans-talker/pull/2)
- 全体作業計画: `plans/bubbly-exploring-biscuit.md`
- 前提となる設計結果: `reports/20260820_bubbly-exploring-biscuit_answer-talker設計.md`（flow-id 3-8で合意）
- 対象フェーズ: フェーズ3〈作業〉の後半（flow-id 3-1〜3-10の2セット目）

## 目的

設計結果（D1〜D7）に沿って**6ファイルを実装し、動くことを確かめる**。実装と単体テストは同時に
書くため1つの計画にまとめる（**分けても合意の単位が変わらず、記述が重複するだけ**のため。
`.claude/skills/issue-mr-flow/SKILL.md`「種別を複数併記する場合／分ける場合」）。

**実施結果は `reports/日付_bubbly-exploring-biscuit_answer-talker実装.md` へ記録する。**
この計画には結果を書かない。

## 前提（合意済みの制約）

| 制約 | 合意した場所 |
|---|---|
| 対象リポジトリの切り替えは **`GH_REPO`/`GITLAB_REPO` の環境変数**で行い、既存の共通コードは変更しない | flow-id 3-8 |
| ネタバレ検査は**誤検知の側へ倒す**。ただし**識別子は分割しない** | flow-id 3-4 / 3-8 |
| 検証は**ローカルGitLabの演習用プロジェクト**で、**実投稿まで**行う | flow-id 2-9 |
| 検証は**15パターン**。うち4つは「**指摘しないことを確かめる**」パターン | flow-id 3-4 |
| 成果物は `.claude/` 配下に収める。**演習の題材はこのリポジトリに残さない** | flow-id 1-5 / 2-9 |

## 実装する範囲

### I1. `Provider.sh` への追加（D2）

- `use_target_repo <URL|slug>`: `_PROVIDER_CACHE` の設定と `GH_REPO`/`GITLAB_REPO`/`GITLAB_HOST` の
  export。**プロセス内の状態を変える関数であることを関数コメントに明記する。**
- `get_mr_changed_files <MR番号>`: 設計結果の返却JSONを stdout へ。
  `github_get_mr_changed_files` / `gitlab_get_mr_changed_files` へ振り分ける。
- **既存の関数・呼び出しには手を入れない**（`adversarial-review` への波及を避けるため）。

### I2. `answer-talker-reference.sh`（D3）

`resolve` / `cleanup` の2サブコマンド。ローカルはcloneせず、URLのみ shallow clone。
`trap` による保険と、`cleanup` の冪等性・パス検証を含む。

### I3. `answer-talker-map.sh`（D4の入力を作る）

同一パス → ファイル名一致の順に対応付け、`matched` / `referenceOnly` / `submissionOnly` を返す。
**意味づけは行わない。**

### I4. `answer-talker-spoiler-check.sh`（D5）

禁止語の抽出と混入判定。`--findings` `--reference-root` `--diff` `--out` を受け、
`{kept, dropped, drops}` を返す。除外語はスクリプト内の定数。

### I5. `.claude/agents/answer-talker-reviewer.md`（D4）

観点表（「指摘する」「指摘しない」の2列）・出力規約・findings JSONスキーマ。
frontmatterは `.claude/rules/markdown-frontmatter.md` に従う（`description` は既存キーとして
サブエージェント選択に使われるため、`title`/`type`/`tags`/`keywords` を追記する形）。

### I6. `.claude/skills/answer-talker/SKILL.md`（D6）

手順11段・引数・MCPフォールバック・してはいけないこと。frontmatterは I5 と同じ扱い。

### I7. 単体テスト

`.claude/scripts/test/` に3ファイル。既存の流儀（`passed=N failures=N` を出力し、失敗時に
終了コード1／外部プロセスを起動しない純粋関数を対象／`source` してもハングしない
`BASH_SOURCE` ガード）に合わせる。

| テスト | 対象 | ケース数の目安 |
|---|---|---|
| `test_answer_talker_reference.sh` | URL/ローカルの判別、パス正規化、`cleanup` の安全判定 | 8〜12 |
| `test_answer_talker_map.sh` | 対応付けの3分類、同名別ディレクトリ、0件 | 8〜12 |
| `test_answer_talker_spoiler_check.sh` | 設計結果の**12ケース**（部分文字列・境界・0件・日本語・大文字小文字） | 12以上 |

**既存12本のテストが `failures=0` のままであることも確認する**（`Provider.sh` を触るため）。

## テスト・検証の手順

### V1. 単体テスト

```bash
for f in .claude/scripts/test/test_*.sh; do bash "$f"; done
```

全ファイルが `failures=0` で終わること。**新規テストが、実装前のコードに対しては失敗する**ことも
確認する（テストが実際に対象を見ていることの確認）。

### V2. 構文チェック

```bash
for f in .claude/scripts/src/answer-talker-*.sh .claude/scripts/src/vcs/*.sh; do bash -n "$f"; done
```

### V3. 演習用プロジェクトの構築（D7）

ローカルGitLab（`localhost:8929`）に `root/answer-talker-verify` と
`root/answer-talker-answer` を作る。**構築は冪等なスクリプトで行い、一時ディレクトリで完結
させる**（題材をこのリポジトリに残さない）。題材は極小のbash CLI（`read`/`filter`/`format` の
3分割が正解、初期状態は `main.sh` に骨格のみ）。

### V4. 15パターンの実機確認

設計結果D7の表に沿って確認する。**期待する結果は設計時に決めてあるので、ここでは実行と
突き合わせのみ**を行う。

| 群 | パターン | 確認の要点 |
|---|---|---|
| 受講者の実装 | ①分割不足 ②別解 ③重複 ④余分な抽象化 ⑤ほぼ正解 | **②⑤で分割単位の指摘が出ないこと**が中核 |
| 正解の形態 | ⑥URL ⑦ローカルgit ⑧素のディレクトリ | ⑥で一時ディレクトリが残らない、⑦⑧で元を変更しない |
| diffの内容 | ⑨削除 ⑩リネーム ⑪新規追加のみ | `status`/`oldPath` が正しい |
| ネタバレ検査 | ⑫転記あり ⑬一般語のみ | ⑫が落ち、⑬が残る |
| 投稿 | ⑭実投稿 ⑮0件 | ⑭でインラインコメントが付く、⑮で投稿しない |

**結果は表の形で `reports/` へ記録する**（パターン番号・実行したコマンド・実際の結果・
期待との一致）。

### V5. 後片付け

演習用プロジェクト2つを削除し、一時ディレクトリが残っていないことを確認する。
**この手順自体も `reports/` に残す**（次に検証する人が同じ状態から始められるように）。

## この計画で決めないこと（スコープ外）

- **設計の変更**。D1〜D7は flow-id 3-8 で合意済み。実装中に設計の誤りが見つかった場合は、
  **勝手に変えず、結果mdへ「設計との差分」として記録し、レビューで諮る**。
- **spec/DDRの執筆**。フェーズ4（flow-id 4-1で対象を洗い出す）。
- **`adversarial-review` 側の変更**。今回の受け入れ条件に含まれない。
- **GitHub側での実投稿**。投稿経路の確認はGitLabで行う（GitHubの公開リポジトリへダミー指摘を
  残さないため。flow-id 2-9）。GitHub側は `get_mr_changed_files` の取得までを確認する。

## issueの受け入れ条件との対応

| 受け入れ条件 | 対応 |
|---|---|
| SKILL.md / agent定義がfrontmatter規約に沿って追加されている | I5・I6。`search-frontmatter.sh` でインデックスに載ることを確認 |
| 正解ソース取得スクリプトが `.claude/scripts/src/` に追加され、`bash -n` を通す | I2・V2 |
| MR番号からdiffを取得する関数が追加され、**GitHub経路で実際のMRに対して動作を確認済み** | I1・V4（PR #2 に対して実行） |
| 正解のコード片の混入検査が実装され、混入時は投稿されない | I4・V4のパターン⑫ |
| 正解側にしかない分割単位について、実例で指摘が生成されることを確認 | V4のパターン① |
| spec / DDR が追加されている | （フェーズ4） |

## 検証（この作業が完了したと言える条件）

1. 単体テストを含む `.claude/scripts/test/` の全ファイルが `failures=0`。
2. 15パターンすべてについて、実行結果と期待の一致（または不一致とその理由）が
   `reports/` に記録されている。
3. 受け入れ条件のうちフェーズ4担当の1件を除く5件に、**確認した証跡**（コマンドと出力）がある。
4. 演習用プロジェクトと一時ディレクトリが後片付け済みで、このリポジトリに題材が残っていない。
5. 設計との差分が生じた場合、**差分として明示**されている（黙って設計を変えない）。
