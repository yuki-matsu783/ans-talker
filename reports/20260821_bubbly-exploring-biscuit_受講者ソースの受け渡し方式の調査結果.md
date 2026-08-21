---
title: 受講者ソースの受け渡し方式の調査結果
type: report
description: issue #6 で受講者のソースコード全体をサブエージェントへ渡す方式を決めるための調査結果。案A（shallow clone）・案B（API）はどちらも両プロバイダで成立し、新たに見つかったアーカイブ一括取得（案B-d）が最有力である。
tags: [answer-talker, 調査結果, report]
keywords: [案A, 案B, tarball, archive, GIT_ASKPASS, headSha, 禁止語, drop, mapping, 17パターン, 復元]
---

# 調査結果: 受講者ソースの受け渡し方式（issue #6・フェーズ2）

- 計画: `plans/【調査】受講者ソースの受け渡し方式.md`（6論点）
- 実施日: 2026-08-21 / 実行環境: Windows 10 + git bash、GitHub（`gh` 認証済み）、
  ローカルGitLab（docker `gitlab`、`localhost:8929`、`glab` 認証済み）

## 結論（3行）

1. **案A（shallow clone）は両プロバイダで成立した。** issue #1 の「ローカルGitLabへ `git` で
   到達できない」は**環境の制約ではなく、資格情報の供給方法の問題**だった。
2. **新たに見つかった「アーカイブ一括取得」（案B-d）が最有力。** 両プロバイダとも**API 1回**で
   全ファイルが取れ、**ファイル数に依存せず**、**`.git` を含まない**。
3. **禁止語の材料を広げることは必須である**（2周目のレビュー指摘を実測で裏付け）。
   広げなければ、issue #6 の目的である「hunk外ファイルに基づく指摘」だけが選択的に落ちる。

## 論点6: 検証環境の再構築（論点1・2の前提）

### issue #1 の演習環境が残っていた

ローカルGitLabに、issue #1 の演習プロジェクトが**削除予定の状態で残っていた**
（`answer-talker-answer-deletion_scheduled-6` / `answer-talker-verify-deletion_scheduled-7`、
`marked_for_deletion_on: 2026-08-20`）。**ユーザー承認のうえ `POST /projects/:id/restore` で
削除予定を解除**し、名前も元に戻した（`answer-talker-answer` / `answer-talker-verify`）。

### 17パターンの内訳は「specからは復元できない」が「実環境からは復元できた」

**specの記述だけでは復元できないことが確定した**（issue #1 の「再現に必要な情報はspecで足りる」
という判断は誤りだった）。specにあるのは5軸（受講者の実装5値／正解ソースの形態3値／diffの内容3値／
ネタバレ検査2値／投稿2値）だけで、全組み合わせは 5×3×3×2×2 = 180 通りある。**そのうちどの17個を
選んだかは軸からは一意に決まらない。**

一方、**残っていた実環境から大部分を復元できた**（受講者側リポジトリの10ブランチ・9MR）。

| ブランチ | MR | 変更ファイル | 対応する軸 |
|---|---|---|---|
| `p1-monolith` | !1 | M `main.sh` | 実装: 分割不足 |
| `p2-alt-split` | !2 | A `io.sh` / A `transform.sh` / M `main.sh` | 実装: 別解（2分割） |
| `p2b-single-file` | !9 | M `main.sh` | **判別用**: 責務は3分割だがファイルは1つ |
| `p3-duplication` | !3 | M `main.sh` | 実装: 重複 |
| `p4-overabstraction` | !4 | M `main.sh` | 実装: 余分な抽象化 |
| `p5-near-answer` | !5 | A `input.sh` / A `select.sh` / A `render.sh` / M `main.sh` | 実装: ほぼ正解 |
| `p9-delete` | !6 | D `README.md` / A `USAGE.md` | diff: 削除 |
| `p10-rename` | !7 | R `main.sh`→`cli.sh` | diff: リネーム |
| `p11-addonly` | !8 | A `filter.sh` | diff: 新規追加 |

欠番（p6〜p8）は、ブランチを増やさず**実行条件だけ変えた軸**（正解ソースの形態3種、ネタバレ検査、
投稿の有無）と考えられる。**この表をspecへ残すこと**がフェーズ4の反映候補になる。

題材は spec の記述どおりだった。正解は `read.sh` / `filter.sh` / `format.sh` / `main.sh` の
4ファイル（合計660バイト）、受講者の初期状態は `README.md` + `main.sh`（313バイト）。

### GitHub側の演習環境（specに手順が無かった箇所）

**specの再現手順はGitLab前提（Commits API）で書かれており、GitHub側の手順が無かった。**
今回、**ユーザーが用意した `yuki-matsu783/test-repo`（公開・空）**へ、GitLabから吸い出した題材を
**Contents API で投入**して確立した（GitLabのCommits APIと対称の位置づけ）。**AIエージェントは
リポジトリを作成していない。**

```bash
# 初期状態（空リポジトリへの最初のコミットでデフォルトブランチが作られる）
gh api --method PUT "repos/$R/contents/README.md" -f message='…' -f content="$(base64 -w0 …)"
# 受講者ブランチ
gh api --method POST "repos/$R/git/refs" -f ref='refs/heads/p2b-single-file' -f sha="$base_sha"
# 既存ファイルの更新には現在の blob sha が要る
cur="$(gh api "repos/$R/contents/main.sh?ref=p2b-single-file" --jq '.sha')"
gh api --method PUT "repos/$R/contents/main.sh" … -f branch='p2b-single-file' -f sha="$cur"
gh api --method POST "repos/$R/pulls" -f title='…' -f head='p2b-single-file' -f base='main'
```

結果: `https://github.com/yuki-matsu783/test-repo/pull/1`（head `864dbcfd`）。

## 論点1: 案A（MRのheadを shallow clone）

### 成立した（両プロバイダ）

| 確認項目 | GitHub（test-repo・公開） | GitLab（`localhost:8929`・**private**） |
|---|---|---|
| MR head の取得 | **成功** | **成功**（資格情報を供給した場合） |
| 取得した head | `864dbcfd…` | `c3c0fa6d…` |
| **`headSha` との一致** | **一致** | **一致** |
| ツリーの取得 | `README.md` `main.sh` | `README.md` `main.sh` |

参照名はプロバイダで異なる（GitHub `refs/pull/<n>/head` ／ GitLab
`refs/merge-requests/<iid>/head`）。**GitLabでもこの参照は取得できた**（サーバ設定で取れない
可能性を懸念していたが、今回の環境では問題なし）。

### issue #1 の「git到達不可」は環境の制約ではなかった

認証なしでは、issue #1 と同じ失敗を再現できる。

```
fatal: could not read Username for 'http://localhost:8929': terminal prompts disabled
```

原因は**資格情報ヘルパの構成**である。システムスコープに `credential.helper=manager`
（Git Credential Manager）があり、非対話環境ではプロンプトを出せずに失敗していた。

```
file:C:/Program Files/Git/etc/gitconfig	credential.helper=manager
file:C:/Users/taniyama/.gitconfig	credential.http://localhost:8929.provider=generic
```

**`GIT_ASKPASS` でCLIのトークンを供給すると成功する。** グローバル設定は一切変更していない
（確認の前後で `git config --global --get-regexp '^credential'` が同一であることを確認済み）。

```bash
# askpass.sh: 第1引数が Username を含むなら oauth2、そうでなければ $GL_TOKEN を出す
export GL_TOKEN="$(glab config get token --host localhost:8929)"
GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$SP/askpass.sh" \
  git -C "$t" -c credential.helper= fetch --depth 1 origin \
  'refs/merge-requests/9/head:refs/heads/atr-head'
```

- **`credential.helper` にシェル関数を渡す方式（`-c 'credential.helper=!f() { … }; f'`）は
  git bashでハングした**（2分でタイムアウト）。`GIT_ASKPASS` を使うこと。
- トークンは**環境変数経由でのみ渡す**。URLにもコマンド文字列にも埋め込まない。

### clone URL は `use_target_repo` のJSONからは組み立てられない

**JSONの `.host` はポートを落とす。**

| 入力形式 | 返り値 | 判定 |
|---|---|---|
| URL `http://localhost:8929/root/answer-talker-verify` | `{"provider":"gitlab","path":"root/answer-talker-verify","host":"localhost"}` | **ポート `8929` が欠落** |
| `owner/repo` 形式 `root/answer-talker-verify` | `{"provider":"github","path":"…","host":""}` | providerがcwd由来（GitHub）になる |
| 省略 | `use_target_repo: 対象リポジトリが空です`（エラー） | 呼び出し側で既定を決める必要がある |

**ただし export される環境変数はポートを保持している**（`GITLAB_HOST=http://localhost:8929`、
`GITLAB_REPO=root/answer-talker-verify`）。clone URLはこちらから組み立てる。
`split_remote_url` は `REPLY_PORT` を別に持っており、JSON化の際に落ちているだけである。

### `.git` の同梱は実害がある（1周目の指摘を実証）

clone後、`git log` で**そのMRのコミットメッセージが読める**。

```
c3c0fa6 1ファイル内で3つの関心へ分ける
```

`.claude/agents/answer-talker-reviewer.md` は「受講者リポジトリのコミットメッセージ・issue・
MRの説明文を読んではいけない」と規定しており、案Aを採るなら**`.git` の除去が必須**である
（`--depth 1` でも直近1件は読める。サイズは71KB）。

### 到達不可は人工的に作れる

```
fatal: unable to access 'https://no-such-host.invalid/x/y.git/': Could not resolve host
exit=128
```

**残る制約**: `test-repo` が公開のため、**GitHub側の「非公開リポジトリで資格情報が要る場合」は
未確認**である。GitLab側（private）で成功していることから同様に通ると見込めるが、実測はしていない。

## 論点2: 案B（APIでファイル取得）

### ファイル単位のAPIは両プロバイダで揃う

| | GitHub `contents` | GitLab `files` |
|---|---|---|
| `encoding` | `base64` | `base64` |
| `size` | あり（511） | あり（511） |
| `content` | あり | あり |
| キー数 | 12 | 11 |
| tree API | `truncated` フラグあり・`size` を持つ | `truncated` 無し・**`size` を持たない** |

**`get_mr_changed_files` と同じ「キー集合を一致させる」流儀は踏襲できる。** 差はtree側の
`size` の有無程度である。

**GitLabのfiles APIはパス中の `/` を `%2F` へエンコードする必要がある**（生パスでは404）。

### 【最重要】アーカイブ一括取得（案B-d）— 計画に無かった選択肢

| 手段 | 呼び出し回数 | 実測 |
|---|---|---|
| ファイル単位API（GitHub） | **ファイル数分** | **672ms/回** |
| ファイル単位API（GitLab） | **ファイル数分** | **1027ms/回** |
| **`repos/{owner}/{repo}/tarball/{ref}`（GitHub）** | **1回** | **1122ms** |
| **`projects/:id/repository/archive.tar.gz?sha=<sha>`（GitLab）** | **1回** | **2044ms** |

ファイル単位APIは**ファイル数に比例**するため、50ファイルで34秒（GitHub）／51秒（GitLab）に
なる。`.claude/rules/shell-script-style.md`「外部プロセス起動のコスト」が想定する95ms/回よりも
桁で重い（ネットワーク往復を含むため）。

一方**アーカイブ取得は1回で済み、ファイル数に依存しない**。さらに:

- **`.git` を含まない**（案Aの `.git` 除去問題が発生しない）
- **CLIの認証をそのまま使える**（`gh`/`glab` 経由のため、gitの資格情報供給が要らない）
- 展開時に**ディレクトリ名のprefixを剥がす**必要がある
  （`yuki-matsu783-test-repo-864dbcf/` → `tar --strip-components=1`）

**Windows版 `tar` の罠**: `tar tzf "C:/…"` はドライブレターをホスト名と解釈して
`Cannot connect to C: resolve failed` で失敗する。**`--force-local` を付ける**か、MSYS形式パス
（`/c/Users/…`）を使う。

## 論点3: どこまで取得するか

**アーカイブ一括取得（案B-d）が使えるため、「取得範囲を絞る」という設計課題自体が消える。**

| 候補 | 評価 |
|---|---|
| a: `mapping.matched` のみ | **目的未達**（変更していないファイルが入らない）。issue本文の案Bはこれ |
| b: ツリー全体（ファイル単位API） | 目的は満たすが**ファイル数×672〜1027ms**。50ファイルで34〜51秒 |
| c: 拡張子・サイズで絞る | 絞り込み条件の設計・保守コストが乗る。除外したファイルは見えないまま |
| **d: アーカイブ一括取得** | **1回・ファイル数非依存・`.git` 無し。最有力** |
| 案A: shallow clone | 1回で全体が手に入るが、**`.git` の除去**と**gitの資格情報供給**が要る |

サイズ上限・バイナリの扱いは、アーカイブ方式では**個別ファイルの上限に当たらない**（リポジトリ
全体のアーカイブサイズの問題に変わる）。極端に大きいリポジトリでの挙動は未確認である。

## 論点4: `answer-talker-map.sh` の対応付け範囲

現在の出力（MR !9、正解4ファイルに対して）:

```json
{"matched":[{"submission":"main.sh","reference":"main.sh","by":"path"}],
 "referenceOnly":["filter.sh","format.sh","read.sh"],
 "submissionOnly":[]}
```

**受講者の `README.md` はどこにも現れない**（今回変更していないため）。issue #6 が問題にした
非対称が、mapping の出力にもそのまま表れている。

範囲を「受講者の全ファイル」対「正解の全ファイル」へ広げると、`submissionOnly` の意味が
**「今回のMRで追加したファイル」から「正解に無いファイル」へ変わる**。サブエージェント定義の
手順1は `referenceOnly` を起点にしているため、`submissionOnly` の意味変更が観点表の読み方へ
どう影響するかは設計（フェーズ3）で決める。

- 案A・案B-dのどちらでも受講者の全ファイルが手に入るため、**方式によって答えは変わらない**。
- 候補a（matchedのみ）を採る場合に限り、mapping を広げても材料が無いため意味を持たない。

## 論点5: ネタバレ検査の禁止語（必須の追随であることを実測で確認）

**2周目のレビュー指摘は実測で裏付けられた。** MR !9 の実データ（`main.sh` のみ変更）と、
正解4ファイルを材料に、3件の finding で検査した。

| finding | 内容 | 結果 |
|---|---|---|
| A | 「読み込みの責務は **`read_lines`** のような単位で切り出せる」 | **drop**（反応語: `read_lines`） |
| B | 「**`take_lines`** と **`keep_lines`** は同じ関心を2つに分けている」 | 残る |
| C | 「入力・絞り込み・出力の3つの関心が1つの関数に同居している」 | 残る |

```json
{"kept":2,"dropped":1,"drops":[{"title":"A: …","words":["read_lines"]}]}
```

正解の識別子は `read_lines` / `filter_lines` / `format_lines` / `main`、受講者（p2b）は
`take_lines` / `keep_lines` / `label_lines` / `main`。`main` は差分に現れるため禁止語から外れる。

**この drop は正しい動作である**（現状の仕様では）。問題は、**受講者が hunk外のファイルで
`read_lines` を定義していた場合も同じく drop される**ことである。`main` 関数が差し引き集合の
材料を `.files[] | .patch, .path, .oldPath`（＝diff）からしか作らないため、受講者ソース全体を
渡しても材料は変わらない。

したがって **issue #6 の受け入れ条件1（hunk外ファイルに基づく指摘が出る）を満たすには、
禁止語の材料を受講者ソース全体へ広げることが必須**である。DDR 0061「誤検知の側へ倒す」との
関係では、**広げても見逃しは増えない**と言える——差し引かれるのは「受講者が自分のリポジトリに
実際に書いている語」であり、それが指摘本文に出ることは転記ではないため。

**経路依存は解消する。** 案A・案B-dのどちらでも受講者の全ファイルが材料になるため、
経路によって禁止語が変わらない（候補a/b/cを採った場合のみ経路依存が残る）。

## 検証条件の充足状況

| # | 条件 | 状況 |
|---|---|---|
| 1 | 論点1・2の実機結果（コマンドと出力）が残っている | **充足**（推測のみの記述は無い） |
| 2 | 案A・案Bの成立条件・取得範囲・`.git`・縮退方針が揃い、プロバイダ×経路の4マスが埋まる | **一部未充足**（GitHub×案Aの**非公開**リポジトリのみ未確認。`test-repo` が公開のため） |
| 3 | 論点3〜5が案A・案Bそれぞれについて整理されている | **充足** |
| 4 | 論点6の再構築を実際に試した（両プロバイダ・17パターンの復元可否） | **充足**（GitLabは復元、GitHubは新規投入） |
| 5 | 未決定事項が明示されている | **充足**（下記） |
| 6 | 全単体テストが `failures=0`（`NG=0`） | **充足**（15本すべて `failures=0`、`NG=0`） |

## 未決定のまま残す事項

1. **どの方式を採るか**（案A / 案B-d / 併用）はフェーズ3の `【設計】` で決める。本調査の
   評価では**案B-dが最有力**である。
2. **GitHub側の非公開リポジトリでの資格情報**は未確認（`test-repo` が公開のため）。
3. **極端に大きいリポジトリでのアーカイブ取得の挙動**は未確認。
4. **`submissionOnly` の意味変更をサブエージェント定義へどう反映するか**（論点4）。
5. **アーカイブ取得時のバイナリ・巨大ファイルの扱い**（サブエージェントへ渡す前に除外するか）。
