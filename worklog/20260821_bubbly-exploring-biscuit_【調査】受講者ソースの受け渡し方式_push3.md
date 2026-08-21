---
title: worklog 【調査】受講者ソースの受け渡し方式 push3
type: log
description: issue #6 のflow-id 2-6（調査実施）の試行錯誤ログ。案A・案Bの実測、archive API の発見、git bash 固有の罠。
tags: [worklog, answer-talker, 調査, 実測]
keywords: [GIT_ASKPASS, credential.helper, ハング, tarball, archive, force-local, restore, ポート欠落, drop, 17パターン]
---

# worklog: 【調査】受講者ソースの受け渡し方式（push3）

対象: issue #6 のflow-id 2-6（調査実施）（2026-08-21）。
結果の正文: `reports/20260821_bubbly-exploring-biscuit_受講者ソースの受け渡し方式の調査結果.md`
push回数: 4（worklogの連番は push3。push2 の時点で1つずれている）

## 試したこと・どう辿り着いたか

### 論点6から始めた（計画どおり）

**演習環境を作り直す前に、まず残っていないかを確認したのが当たりだった。**
`glab api 'projects?membership=true'` を叩いたところ、issue #1 の2プロジェクトが
`-deletion_scheduled-<id>` にリネームされた状態で残っていた。GitLabの遅延削除は猶予期間中は
実体を保持するため、`POST /projects/:id/restore` で名前ごと元に戻せた。

**もし「削除済みだから作り直す」と決め打ちしていたら、9つのMR（＝17パターンの大部分）を
失ったまま作り直すことになっていた。** 計画の論点6が「復元できるか」を先に問う形になっていたのが
効いた。

### 論点1: 3回試して3回目で通った

1. **認証なし** → `could not read Username`（issue #1 の失敗を再現）。
2. **`git -c 'credential.helper=!f() { … }; f'`** → **2分でタイムアウト（ハング）**。
   git bash 上でヘルパのシェル関数が期待どおり起動しない。原因追及はしていないが、
   **この方式は使わない**という結論だけ得た。
3. **`GIT_ASKPASS` にスクリプトを渡す** → 成功。第1引数に `Username` が含まれるかで
   出し分ける、よくある形。トークンは環境変数経由で渡すのでコマンド文字列に載らない。

**成立条件を `headSha` との一致にしておいたのが効いた。** 2周目のレビューで
「cwdで実行すると自分のリポジトリのPR headを取って誤結論する」と指摘され、条件を
「参照が取れる」から「`headSha` と一致する」へ変えていた。実際に `c3c0fa6d…` の一致を
確認できたので、取り違えの余地なく成立と言える。

### `use_target_repo` のJSONだけを見ていたら詰んでいた

`.host` が `localhost` で返り、ポート `8929` が落ちていた。ここで「案Aは成立しない」と
結論づけそうになったが、**export された `GITLAB_HOST` を確認したら `http://localhost:8929` と
ポート込みだった**。`split_remote_url` は `REPLY_PORT` を別に持っており、JSON化のときに
落ちているだけだった。

**教訓**: 関数の「返り値のJSON」と「副作用としてexportされる環境変数」が別の情報量を持つ
ことがある。片方だけ見て結論を出さない。

### 論点2で計画に無い選択肢が出た（最大の収穫）

ファイル単位APIの所要時間を測ったところ **672ms（GitHub）/ 1027ms（GitLab）** で、
「ファイル数に比例させたら使い物にならない」と分かった。そこで**1回で全体を取る手段**を
探して `tarball` / `archive.tar.gz` に行き着いた。

- **計画にはこの選択肢が無かった**（候補a/b/cはすべてファイル単位API前提だった）。
  調査の途中で選択肢そのものが増えた形で、計画の候補表を鵜呑みにしなかったのがよかった。
- `.git` を含まないため、案Aの「コミットメッセージが読める」問題も同時に解ける。

### ダメだったこと

- **`tar tzf "C:/…"` が `Cannot connect to C: resolve failed` で失敗した。**
  Windows版 tar がドライブレターを**リモートホスト名**と解釈する。`--force-local` を付けるか
  MSYS形式パス（`/c/Users/…`）を使う。**`.claude/rules/shell-script-style.md` へ追記する候補**
  （フェーズ4のAIアセット反映）。
- **`$TMPDIR` が git bash では未定義**で `unbound variable` になった（`set -u` 配下）。
  スクラッチディレクトリのパスは変数へ明示的に入れる。
- **`… | head -5; echo "exit=$?"` は head の終了コードを見てしまう。** `PIPESTATUS[0]` を使う。
  最初の到達不可の確認で `exit=0` と出て一瞬混乱した（実際には fetch は失敗していた）。

## うまくいったこと

- **論点5の実測が、2周目のレビュー指摘をそのまま裏付けた。** 正解の識別子 `read_lines` を
  含む finding だけが drop され、受講者側の語（`take_lines`）や識別子を含まない指摘は残った。
  `{"kept":2,"dropped":1,"drops":[{"words":["read_lines"]}]}`。
  **「hunk外ファイルに書かれた語も同じく drop される」ことは、`main` が `.files[]` からしか
  材料を作らないというコードの構造から確定できる**ため、追加の実験は不要と判断した。
- **グローバルgit設定を汚さずに済んだ。** 2周目の指摘で「`gh auth setup-git` は検証環境そのものを
  変えてしまう」と言われていたため、最初から `GIT_ASKPASS` の一時利用に倒した。前後で
  `git config --global --get-regexp '^credential'` の出力が同一であることを確認済み。
- **GitHub側の環境構築を Contents API で行った。** `git` のコミット・リモート反映を一切使わずに
  済むため、このリポジトリのフック（コミット・push検知）と無関係に進められた。

## 次にやること

- flow-id 2-7: commit・リモートへ反映してレビュー依頼。
- flow-id 2-8: レビュー（敵対的レビューで代替する場合、**フェーズ2の残りは1回**）。
