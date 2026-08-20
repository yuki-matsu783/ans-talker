---
title: 作業開始・再開時のベースブランチ追従確認（check-base-sync.sh）
type: spec
description: 作業ブランチがベースブランチの最新を取り込めているか（何コミット遅れているか）を、作業ツリーを変更せずに判定するスクリプトの仕様。コンフリクト検知（check-base-conflicts.sh）とは判定軸が異なる
tags: [base-branch, script, workflow, spec]
keywords: [check-base-sync, behind, ahead, rev-list, left-right, 3ドット記法, merge-base, fetchOk, isShallow, isBehind, 追従確認]
---

# 作業開始・再開時のベースブランチ追従確認（check-base-sync.sh）

## 背景・目的

issue #67「作業開始・再開時にベースブランチの最新を取り込めているか確認するステップをフローへ
追加する」。

featureブランチで作業を開始・再開する時点で、ベースブランチ（既定 `main`）の最新がその
ブランチへ取り込まれているかを確認する手段が無かった。`sync_branch()`（`Provider.sh`）は
`git fetch origin` と作業ブランチの `pull --ff-only` のみで、ベースブランチとの差を見ない。

実例（issue #67 本文）: issue #60 対応中のセッションで、ローカルの `origin/main` が10コミット
古いまま作業していた。未取得分には `.claude/rules/shell-script-style.md` へのルール追記が
含まれており、作業中のルール判断に影響しうる状態だった。

### 「衝突しないこと」と「最新であること」は別である

このリポジトリには既にdefaultブランチとの関係を見る機構が2つあるが、**どちらも判定軸が
`hasConflict`** であり、本スクリプトが埋める空白とは別のものを見ている。

PR作成後の追従監視（issue #88）と flow-id 5-2（issue #46）はどちらも `check-base-conflicts.sh` で
`hasConflict` を見る。ベースブランチ側でルール・仕様**だけ**が追記された場合、テキスト
コンフリクトもDDR番号の重複も起きないため両者の `hasConflict` は偽のままだが、作業ブランチは
その追記を知らないまま実装・レビューを進めることになる。**3つは代替関係ではなく補完関係**である。

3機構の対比表（いつ・判定軸・検知手段）は
`.claude/skills/issue-mr-flow/SKILL.md`「作業開始・再開時のベースブランチ追従確認」節の
「既存2機構との役割の違い」が正であり、ここへは再掲しない（同じ表を2箇所で管理すると片方が
古くなる。`.claude/REVIEW-POINTS.md`）。

## 仕様

### 呼び出し

```bash
bash .claude/scripts/src/check-base-sync.sh [--base <branch>] [--head <ref>] [--no-fetch]
```

| 引数 | 既定 | 意味 |
|---|---|---|
| `--base <branch>` | `.mrworkflow.json` の `defaultBaseBranch`（無ければ `main`） | 比較対象のベースブランチ |
| `--head <ref>` | `HEAD` | 比較元 |
| `--no-fetch` | （fetchする） | fetchを行わない。`fetchOk` は `null` になる |
| `-h` / `--help` | — | 先頭のコメントを表示する |

引数・規約は姉妹スクリプト `check-base-conflicts.sh`（`.claude/docs/spec/check-base-conflicts.md`）
にそろえている。

### 出力

判定結果のJSONを1つstdoutへ出力する（`Provider.sh` の各関数と同じ規約）。

```json
{
  "base": "main", "baseRef": "origin/main", "baseSha": "...",
  "headRef": "HEAD", "headSha": "...", "mergeBase": "...",
  "behind": 4, "ahead": 1,
  "changedFiles": ["..."], "changedFilesTotal": 4, "changedFilesTruncated": false,
  "hasCommonHistory": true, "isShallow": false, "fetchOk": true, "isBehind": true
}
```

| キー | 意味 |
|---|---|
| `behind` | ベース側にあって作業ブランチに無いコミット数 |
| `ahead` | 作業ブランチ側にあってベースに無いコミット数（**遅れの判定には使わない**。誤解を避けるために返す） |
| `changedFiles` | **未取り込みの**変更ファイル（merge-base から見たベース側の変更）。先頭50件 |
| `changedFilesTotal` | 切り詰め前の全件数 |
| `changedFilesTruncated` | 切り詰めたか |
| `mergeBase` | merge-base のSHA。取れなければ `null` |
| `hasCommonHistory` | merge-base が取れたか。偽なら `changedFiles` は空 |
| `isShallow` | `git rev-parse --is-shallow-repository` の結果 |
| `fetchOk` | fetchに成功したか。`--no-fetch` 指定時は `null` |
| `isBehind` | `behind > 0`。**呼び出し側はこれを見る** |

**変更ファイルの上限50件は暫定値**である（実測や前例に基づくものではない）。件数そのものは
`changedFilesTotal` で失わないため、切り詰めが黙って起きることはない。

### 終了コード

検査が完了すれば0（遅れの有無は終了コードではなく `isBehind` で表す）。検査自体が失敗した場合
のみ非0。呼び出し側が `set -e` 配下でも、遅れの存在によってスクリプト全体が止まらないようにする
ため（`check-base-conflicts.sh` と同じ）。

非0になる代表ケースは次のとおり。

| 状況 | 終了コード | 出力 |
|---|---|---|
| `--base` / `--head` に値が無い、または空文字列 | 1 | `--base には値が必要です`（stderr） |
| 不明な引数 | 1 | `不明な引数です: <引数>`（stderr） |
| `origin/<base>` が解決できない | 1 | 復旧コマンド（refspec形の `git fetch`）入りのメッセージ（stderr） |
| `--head` に存在しないrefを渡した | 128 | `git rev-parse` の生の fatal（**このスクリプトは `--head` を検証していない**） |
| `rev-list --left-right --count` の出力を解釈できない | 1 | 解釈できなかった文字列を添えたメッセージ（stderr） |

**非0で終了した場合、呼び出し側は「判定できなかった」として扱い、`isBehind` を偽（＝追従済み）
として扱わない。** JSONが1つも返らないため、`fetchOk` 等による識別もできない。読み取り専用の
`issue-mr-resume` サブエージェントは、この場合に `behind` を報告せず「判定できなかった
（<stderrの1行目>）」として報告する（`.claude/agents/issue-mr-resume.md` 手順7）。

### 判定順序（入れ替えない）

1. 引数と `.mrworkflow.json` から `base` を決める。
2. `--no-fetch` でなければ `git fetch origin "+<base>:refs/remotes/origin/<base>"`。
   **終了コードを捨てず `fetchOk` に記録する**（後述）。
3. `git rev-parse --verify --quiet "origin/<base>"` で参照の存在を確認する。無ければ
   復旧コマンド入りのメッセージをstderrへ出して終了コード1。
4. `git rev-list --left-right --count "origin/<base>...<head>"` で `behind<TAB>ahead` を取る。
   **1回の起動で両方取れる**（`rev-list --count` を2回起動しない。
   `.claude/rules/shell-script-style.md`「外部プロセス起動のコスト」）。
5. **`git merge-base` の成否を先に判定する。** 成功したときだけ
   `git -c core.quotepath=false diff --name-only "<head>...origin/<base>"`（3ドット記法）を実行する。
6. jq 1回でJSONを組み立て、`tr -d '\r'` を通して出力する。可変長のファイル一覧は
   `--arg` ではなく標準入力から渡す。

### 実装上の注意（実測に基づく）

- **未取り込みファイルは3ドット記法（`<head>...origin/<base>`）で取る。** 2ドット（`..`）だと
  作業ブランチ自身の変更が混ざり、「自分が今書いたファイルを取り込め」と表示してしまう。
- **merge-base が無いと3ドットdiffは `fatal: no merge base` で終了コード128になる。**
  一方 `rev-list --left-right --count` は**成功してしまう**（両側の全コミット数を返す）ため、
  「rev-list が通ったから安全」と考えて3ドットdiffを実行すると `set -euo pipefail` 配下で
  スクリプトごと落ちる。手順5の分岐は必須である。
- **`core.quotepath=false` が必要。** このリポジトリは `plans/【調査】〜.md` のような日本語を
  含むパスを持ち、既定では8進エスケープされる。
- **fetchはrefspec形 `+<base>:refs/remotes/origin/<base>` を使う。** `git clone --branch <b>` 等の
  single-branch cloneでは `git fetch origin <base>` を実行しても `origin/<base>` の
  リモート追跡参照が作られないが、refspec形なら作られる（通常のcloneでも同じ結果になることを
  実測で確認）。先頭の `+` は、ベースブランチがforce-pushで巻き戻ったとき non-fast-forward で
  拒否されないため。
- **fetchの失敗を `|| true` で握りつぶさない。** 理由は下記「判定が信頼できないことを示す3つのキー」。
- 純粋関数（`parse_left_right_to_reply` / `truncate_file_list`）は `BASH_SOURCE` ガードで `main` と
  分離し、`.claude/scripts/test/test_check_base_sync.sh` から `source` して単体テストする。
  どちらも標準出力ではなくグローバル変数（`REPLY_BEHIND` / `REPLY_AHEAD` / `REPLY_FILES` /
  `REPLY_TOTAL`）へ返し、コマンド置換によるforkを発生させない。

### 判定が信頼できないことを示す3つのキー

`isBehind` が `false` でも「追従済み」と断定できない状況がある。呼び出し側が識別できるよう、
すべてJSONへ出す。**この表は各キーの意味（何を表しているか）の正であり、遭遇したときに何をするか
（ユーザーへどう伝え、取り込みを提案するか）は `.claude/skills/issue-mr-flow/SKILL.md`
「作業開始・再開時のベースブランチ追従確認」節が正**である。同じ判断を2箇所で管理しないための
切り分けであり、片方だけを読んで運用しない。

| キー | 値 | 意味と対応 |
|---|---|---|
| `fetchOk` | `false` | fetchに失敗している（ネットワーク・認証・リモート名不一致）。古いリモート追跡参照を見ているため `behind` を過小評価しうる。`null` は `--no-fetch` で試していないことを表す |
| `isShallow` | `true` | shallow clone。merge-base が取得済みの深さの外にあると、遅れているのに `behind` が0と出うる。ただし **Claude Code on the web のリモート実行環境では常に真**であり（実測。`hasCommonHistory: true` かつ `behind` は正しい値が出る）、**単体では判定の不確かさを示さない**。`hasCommonHistory` が偽のとき、または `mergeBase` が `.git/shallow` に列挙されたSHAと一致するときに限り深さ不足を疑い、`git fetch --unshallow origin` してから再実行する |
| `hasCommonHistory` | `false` | merge-base が無い。`changedFiles` は空になり `behind` も参考値でしかない |

**`fetchOk` を持つのは本スクリプトだけで、`check-base-conflicts.sh` は fetch の失敗を
`|| true` で握りつぶしている。** 差を付けているのは、あちらのコンフリクト検知は flow-id 5-2 で
必ずもう一度通るため取りこぼしても後段で拾われるのに対し、**本スクリプトは検知そのものが目的で
あり、fetch失敗が「遅れていない」という誤報告になって誰にも拾われない**ためである
（DDR 0056）。

## 影響範囲

### issue #67（新規追加）

| ファイル | 変更 |
|---|---|
| `.claude/scripts/src/check-base-sync.sh` | 新規 |
| `.claude/scripts/test/test_check_base_sync.sh` | 新規（純粋関数の単体テストと、使い捨てgitリポジトリに対する `main` の結合テスト。`passed=55 failures=0`） |
| `.claude/skills/issue-mr-flow/SKILL.md` | 「作業開始・再開時のベースブランチ追従確認」節を新設。`start`（既存ブランチ検出時）・`resume`・`sync` から参照。**flow-idは増やしていない**（DDR 0039 と同じ扱い） |
| `.claude/agents/issue-mr-resume.md` | 手順7を新設（旧7・8は8・9へ）。現在地サマリへ `- ベースブランチとの差分:` を追加 |
| `.claude/rules/git-workflow.md` | 追従確認の入口と、rebaseを使わない方針を追記（frontmatterの `description`・`keywords` にも語を追加。DDR 0049 の探索経路で引けるようにするため） |
| `.claude/docs/spec/issue-mr-workflow.md` | 「途中引き継ぎ対応（resume）」節の手順一覧へ追加（現在の状態を説明する節であり point-in-time の記録ではないため更新する）と、影響範囲エントリ |
| `.claude/docs/spec/check-base-conflicts.md` | 判定軸の違う本スクリプトが並存すること・あちらの `git fetch ... \|\| true` を意図的に維持することを相互参照として追記 |
| `.claude/docs/README.md` | spec一覧へ本ファイル、DDR一覧へ 0056 |
| `.claude/skills/apply-mr-workflow-to-project/SKILL.md` | 導入先向けのコアスクリプト一覧へ追加 |
| `.claude/docs/spec/check-base-sync.md` | 本ファイル（新規） |

`Provider.sh` は変更していない。判定軸の違う機能を低レベル関数へ混ぜず、
`check-base-conflicts.sh` と並ぶ独立したスクリプトとして切り出した（DDR 0056）。

### 呼び出し側の責務

- **遅れがあった場合に取り込むかどうかは `AskUserQuestion` でユーザーへ確認する。AIエージェントが
  無断でマージ・リベースしない。** 選択肢と手順は `.claude/skills/issue-mr-flow/SKILL.md`
  「作業開始・再開時のベースブランチ追従確認」節が正。
- **本スクリプトが非0で終了した場合は「判定できなかった」として扱い、追従済みとして扱わない**
  （上記「終了コード」節）。JSONが返らないため `fetchOk` 等での識別もできない。
- `issue-mr-resume` サブエージェントは**検知結果の報告のみ**を行い、確認も取り込みも行わない。
  同エージェントが `git fetch` を伴う本スクリプトを実行することは「読み取り専用」の規定に反しない
  （`git fetch` はリモート追跡参照を更新するだけで、作業ツリー・ローカルブランチ・コミット履歴を
  変更しないため）。むしろ fetch しないと古い参照を見て誤報告することになる。

## 設定項目

| 項目 | 場所 | 既定 |
|---|---|---|
| ベースブランチ | `.mrworkflow.json` の `defaultBaseBranch` | `main` |
| 変更ファイルの上限 | `check-base-sync.sh` の `CBS_CHANGED_FILES_LIMIT` | 50（暫定値） |

## 未決定事項・懸念点

- **git bash（MSYS）実機での動作は未確認。** 実装・検証はLinux上で行った。使っているのは
  `rev-list` / `diff` / `merge-base` / `rev-parse` のみで、MSYS特有のパス変換や
  Windows版jqのCR付与の影響を受ける箇所は無い見込み（`tr -d '\r'` は入れてある）。
- **merge-base が shallow の境界（grafted commit）の外にある場合の `behind` の値は未検証。**
  このリポジトリでは merge-base が保持範囲の内側にあり再現できなかった。理屈のうえでは
  過小評価になりうるため、`isShallow` を出力して呼び出し側が疑えるようにしている。
- **巨大なリポジトリでの所要時間は未実測。** `rev-list --count` は履歴の長さに比例する。
- **`--no-fetch` の有無による behind の実測差は未確認**（gitの仕様から述べているだけ）。
- **ヘッダコメントと `--help` の行範囲が結合している。** `-h` は `sed -n '2,35p'` で先頭コメントを
  表示するため、コメントを増減したら範囲も直す必要がある（`check-base-conflicts.sh` から
  引き継いだ形）。
