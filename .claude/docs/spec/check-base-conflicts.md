---
title: defaultブランチとのコンフリクト検知（check-base-conflicts.sh）
type: spec
description: マージ依頼前にdefaultブランチとのコンフリクト有無を作業ツリーを変更せずに判定するスクリプトの仕様。テキストコンフリクトに加え、gitが検知できないDDR番号の重複も調べる
tags: [conflict, script, workflow, spec]
keywords: [check-base-conflicts, merge-tree, DDR番号, semantic conflict, defaultブランチ, hasConflict, resolve-conflict, flow-id-5-2, 追従監視, check-base-sync, 判定軸]
---

# defaultブランチとのコンフリクト検知（check-base-conflicts.sh）

## 背景・目的

issue #46「マージ依頼前にdefaultブランチとのコンフリクトを検知・解消するフローを整備する」。

`.claude/skills/issue-mr-flow/SKILL.md` のマージ依頼フローには、defaultブランチとの
コンフリクト有無を確認するステップが無かった。コンフリクトの存在に気づくのは人間がマージ操作を
試みた後になりがちで、解消手順も定義されていなかったため、都度その場の判断で解消されていた。

**とくに問題だったのは、gitが「コンフリクト無し」と報告する種類の衝突があること**である。
両ブランチがそれぞれ新しいDDRを追加すると、`0027-A.md` と `0027-B.md` のようにファイル名が
異なるため、gitは何も報告せず両方をマージする。結果として同じ連番のDDRが2つ並ぶ。
`git merge` / `git merge-tree` に頼るだけでは、この衝突は永久に検知できない。

過去の発生実績（本スクリプトで再現確認済み）:

| PR | issue | 重複した番号 | テキストコンフリクト |
|---|---|---|---|
| #29 | #13 | あり | — |
| #37 | #36 | `0024` | `index.jsonl` 7件（deleted by us）・`docs-workflow.md`・`README.md`・`HANDOFF.md` |
| #49 | #48 | `0026` | — |
| #52 | #45 | `0027` | `.claude/docs/README.md`・`tests/test_vcs_provider.sh` |

## 仕様

### 呼び出し

```bash
bash .claude/scripts/src/check-base-conflicts.sh [--base <branch>] [--head <ref>] [--no-fetch]
```

| オプション | 既定 | 意味 |
|---|---|---|
| `--base <branch>` | `.mrworkflow.json` の `defaultBaseBranch`（既定 `main`） | 比較対象のdefaultブランチ名。実際には `origin/<branch>` を参照する |
| `--head <ref>` | `HEAD` | 比較元。任意のコミットを指定できる（過去事例の再現・テストに使う） |
| `--no-fetch` | （fetchする） | `git fetch origin <base>` を省略する。ネットワークが無い環境や、直前にfetch済みの場合に使う |

`.mrworkflow.json` が無い場合は `defaultBaseBranch=main` / `ddrDirs=[".claude/docs/ddr"]` を既定とする。

### 出力

判定結果のJSONをstdoutへ1つ出力する（`Provider.sh` の各関数と同じ規約）。

```json
{
  "base": "main",
  "baseRef": "origin/main",
  "baseSha": "3e3ee03...",
  "headRef": "HEAD",
  "headSha": "abc1234...",
  "ddrDirs": [".claude/docs/ddr"],
  "textualConflictFiles": [".claude/docs/README.md"],
  "duplicateDdrNumbers": [
    { "number": "0027", "files": [".claude/docs/ddr/0027-A.md", ".claude/docs/ddr/0027-B.md"] }
  ],
  "hasTextualConflict": true,
  "hasDuplicateDdrNumber": true,
  "hasConflict": true
}
```

### 終了コード

**検査が完了すれば常に0**。コンフリクトの有無は終了コードではなく `hasConflict` で表す。
`origin/<base>` が見つからない・`git merge-tree` が異常終了した等、検査自体が失敗した場合のみ非0。

呼び出し側（スキルの手順・hook）は `set -euo pipefail` 配下で動くため、「コンフリクトがある」
という**正常な検査結果**で呼び出し元のスクリプトが停止してしまう設計を避けた
（`.claude/rules/shell-script-style.md`「テスト」節の、終了コードを状態の表現に使わない方針と同じ）。

### 検知1: テキストコンフリクト

```bash
git -c core.quotepath=false merge-tree --write-tree --name-only --no-messages <head> <base>
```

- **作業ツリー・インデックスを一切変更しない**（`git merge` を試して `git merge --abort` する方式と
  異なり、中断された場合でもリポジトリが壊れた状態に残らない）。
- 終了コード0＝コンフリクト無し、1＝コンフリクト有り、2以上＝エラー。
- 標準出力の1行目は書き出されたツリーのOIDなので落とし、2行目以降をコンフリクトファイル一覧とする。
- `-c core.quotepath=false` は、日本語ファイル名（DDR等）が8進エスケープされるのを防ぐため
  （`Provider.sh` の `get_branch_work_files` と同じ理由）。
- git 2.38以降が必要（`merge-tree --write-tree`）。実機確認は git 2.43.0。

### 検知2: DDR番号の重複（semantic conflict）

`ddrDirs` 配下のmarkdownを `<head>` 側と `<base>` 側の両ツリーから列挙し（`git ls-tree -r`）、
和集合を取ってファイル名先頭4桁の連番でグルーピングする。**同じ番号に相異なるパスが2つ以上
属していれば重複**とする。

- 番号の抽出は `^([0-9]{4})-` にマッチする場合のみ。`index.jsonl` のような非DDRファイル、
  3桁以下の番号は対象外。
- 作業ツリーではなく**両ブランチのツリー**を見るため、まだマージしていない段階で判定できる。
- 実装は外部コマンドを呼ばない純粋関数（`ddr_number_to_reply` / `find_duplicate_ddr_numbers`）へ
  分離し、`.claude/scripts/test/test_check_base_conflicts.sh` で単体テストしている
  （`.claude/rules/shell-script-style.md`「外部プロセス起動のコスト」に従い、ループ内で
  `jq` 等を起動しない）。

### 実装上の注意

- **JSONの組み立ては `jq` 1回**。可変長のファイル一覧は `--arg` / `--argjson` ではなく標準入力から
  読ませる（`.claude/rules/shell-script-style.md`「大きなJSONを`--argjson`/`--arg`等の
  コマンドライン引数としてjqへ渡さない」）。2種類のリストは `@@CBC-SPLIT@@` という区切り行で
  1本の入力に連結する（制御文字を使うと、シェルのコマンド文字列へ混ざったとき目視できないため）。
- **`if ! cmd; then ... $? ...` の形で終了コードを読まない**。bashは `!` で反転済みの値を返すため、
  `merge-tree` の「1＝コンフリクト有り」が0として読まれる（issue #46の実装中に実際に踏み、
  検知が常に「コンフリクト無し」になった）。`cmd || status=$?` の形で受ける。
- 出力は最後に `tr -d '\r'` を通す（Windowsネイティブjqが行末へCRを付与する。
  `.claude/rules/shell-script-style.md`「文字コード」）。
- 単体テストから純粋関数だけをsourceで再利用できるよう、`main` の呼び出しは
  `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` でガードする（`update-handoff-progress.sh` と同じパターン）。

## 影響範囲

### issue #46（新規追加）

| ファイル | 変更内容 |
|---|---|
| `.claude/scripts/src/check-base-conflicts.sh` | 新規。本仕様の実装 |
| `tests/test_check_base_conflicts.sh` | 新規。純粋関数（`ddr_number_to_reply` / `find_duplicate_ddr_numbers`）の単体テスト |
| `.claude/skills/resolve-conflict/SKILL.md` | 新規。本スクリプトの結果を受けてコンフリクトを解消する手順 |
| `.claude/skills/issue-mr-flow/SKILL.md` | flow-id 5-2として検知・解消ステップを新設（旧5-2→5-3、旧5-3→5-4。全39→40ステップ）。「defaultブランチとのコンフリクト検知・解消」節を追加 |
| `.claude/skills/commit/SKILL.md` / `.claude/rules/git-workflow.md` / `.claude/rules/docs-workflow.md` | コミットを行うflow-idの一覧を `5-2` → `5-3` へ更新。ステップ数を40へ更新 |
| `.claude/docs/spec/issue-mr-workflow.md` | ステップ数を40へ更新 |
| `.gitignore` | `index.jsonl` の除外理由コメントが参照するDDR番号を `0024` → `0025` へ修正（issue #36の改番時に更新漏れしていた。本issueが対象とする「改番時の参照更新漏れ」の実例） |

### issue #88（PR作成後の追従監視からの繰り返し実行）

| ファイル | 変更内容 |
|---|---|
| （本スクリプト） | 変更なし。監視から繰り返し呼ばれる用途に既存の設計がそのまま使えることを確認した |
| `.claude/docs/spec/check-base-conflicts.md` | 本ファイル。「未決定事項・懸念点」のhookに関する記述を、監視での繰り返し実行と整合する形へ更新し、本エントリを追加 |

### issue #67（判定軸の違うスクリプトの並存）

| ファイル | 変更内容 |
|---|---|
| （本スクリプト） | **変更なし。** 「衝突するか」という判定軸も、fetchの失敗を `git fetch origin "$base" >/dev/null 2>&1 \|\| true` で握りつぶす扱いも維持する |
| `.claude/docs/spec/check-base-conflicts.md` | 本ファイル。本エントリと、下記の相互参照を追加 |

**「衝突しないこと」と「最新であること」は別である。** 本スクリプトの `hasConflict` が偽でも、
ベースブランチ側でルール・仕様**だけ**が追記された場合は衝突もDDR番号の重複も起きないため、
作業ブランチが遅れている事実は検知できない。この空白は、作業の開始・再開時に「遅れているか」
（behindコミット数）を見る `check-base-sync.sh`（`.claude/docs/spec/check-base-sync.md`）が
埋める。**本スクリプトの結果だけを見て「最新である」と判断しないこと。**

**本スクリプトが fetch の失敗を `|| true` で握りつぶしているのは意図的であり、バグではない。**
本スクリプトによるコンフリクト検知は flow-id 5-2 で必ずもう一度通るため、fetch漏れによる
取りこぼしは後段で拾われる。一方 `check-base-sync.sh` は検知そのものが目的で後段に同じ検知が
無いため、あちらだけは終了コードを `fetchOk` としてJSONへ出している（差を付けた理由の詳細:
`.claude/docs/ddr/0056-作業開始時のベースブランチ追従確認は専用スクリプトで検知しユーザー確認を挟む.md`）。
**どちらかへ揃えようとする前に、このDDRを読むこと。**

## 未決定事項・懸念点

- **DDR以外の連番リソースは対象外**。現状このリポジトリで連番を持つのはDDRのみのため。
  将来 `docs/adr/` 等を追加した場合は `ddrDirs` へ加えれば同じ判定が効く。
- **「両ブランチが同じ内容の変更を別の書き方で行った」種類のsemantic conflictは検知できない**
  （例: 同じルールを別の節へ書いた）。これは機械的に判定できないため、`resolve-conflict`
  スキルの類型C・Eとして人間の判断へ委ねる。
- **hookによる自動実行はしていない**。push検知hookで毎回走らせる案もあったが、pushのたびに
  `git fetch` を伴う判定を挟むのはコストに見合わず、push検知hookはコマンド文字列の部分一致で
  誤発火する既知の問題も抱えている（`.claude/rules/git-workflow.md`「push検知hookの誤検知」）。
  実行タイミングは**手順として明示する**方式を採る（flow-id 5-2、およびPR作成後の追従監視。
  下記）。
- **本スクリプトはPR作成後の追従監視から繰り返し呼ばれる**（issue #88）。作業ツリーを変更せず、
  引数なしで何度でも実行でき、結果を終了コードではなく `hasConflict` で返す設計は、この繰り返し
  実行にそのまま使える（スクリプト側の変更は不要だった）。監視の手順・自動解消の線引き・停止条件は
  `.claude/skills/issue-mr-flow/SKILL.md`「PR作成後のdefaultブランチ追従（監視）」節、
  経緯は `.claude/docs/ddr/0039-PR作成後のdefaultブランチ追従は並行手順として定義し自動解消は一意に決まる類型に限る.md` を参照。
