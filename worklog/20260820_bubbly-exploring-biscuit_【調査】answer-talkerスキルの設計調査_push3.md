---
title: worklog 20260820 answer-talkerスキルの設計調査 push3
type: log
description: issue #1 のフェーズ2〈調査〉レビュー1周目の反映ログ。GitLab経路をローカルのGitLab CEコンテナで実機検証した記録。push3。
tags: [worklog, answer-talker, 調査, gitlab]
keywords: [worklog, GitLab, glab, changes, diffs, overflow, too_large, 正規化, additions, ページング]
---

# worklog: 【調査】answer-talkerスキルの設計調査

対象: レビュー指摘（GitLabのdockerコンテナがあるので検証できるはず）の反映（2026-08-20）。
全体作業計画: `plans/bubbly-exploring-biscuit.md`
個別作業計画: `plans/【調査】answer-talkerスキルの設計調査.md`
push回数: 3

## 試したこと

- `docker ps` でGitLab CE **18.5.4-ce.0** が `localhost:8929` で21時間稼働（healthy）していること、
  `glab --version` で **1.114.0** が入っていることを確認した。
- `glab auth status` で `localhost:8929` に `root` としてログイン済みであることを確認した
  （`gitlab.com` 側は401だが、こちらは使わない）。
- `glab api "projects?membership=true"` でプロジェクトを列挙し、`root/issue45-verify`（id=1）に
  検証用MRが3件（`!1` `!2` `!3`）残っていることを確認した。過去のissue検証で作られたもの。
- `!3`（`issue77-inline-test` → `main`、1ファイル変更）を対象に、次を実行して比較した。
  - `GET projects/1/merge_requests/3/changes`（旧API）
  - `GET projects/1/merge_requests/3/diffs`（新API）
  - `glab mr diff 3 -R root/issue45-verify`
- `glab api -i` でレスポンスヘッダを見て、ページングヘッダの有無と非推奨告知の有無を確認した。
- GitHub（PR #2）とGitLab（`!3`）の実データから、reportで提案した共通形のJSONを
  それぞれ `jq` で組み立て、キー集合が一致するかを確かめた。

## うまくいったこと

- **共通形への正規化が両プロバイダで成立した。** トップレベル `base,files,head,headSha`、
  ファイル単位 `additions,deletions,oldPath,patch,path,status,truncated` がそのまま一致した。
  論点2で机上で提案していたインターフェースが、実データで裏付けられた。
- **`/diffs`（新API）を採る根拠が実測で出た。** `/changes` はMRメタ情報を同じ応答に含む点だけが
  有利で、切り捨ての表現（`overflow` はMR全体、`too_large`/`collapsed` はファイル単位）と
  ページングの有無（`X-Total` 等が返るのは `/diffs` だけ）で `/diffs` が明確に優る。
- **`additions`/`deletions` の算出を検算できた。** GitLabはファイル単位の増減行数を返さないので
  diff本文の行頭を数える実装になるが、`sample.txt` で算出値 `+2/-2` が
  `glab mr diff` の実際の内容（`+line02-modified` `+line11-added` / `-line02` `-line04`）と
  一致することを確認した。
- 副産物として、`too_large` だけでなく **`collapsed`** も見ないと「折りたたまれて `diff` が空の
  ファイル」を差分なしと誤読することに気づけた。正規化の `truncated` は両者の論理和にする。

## ダメだったこと

- **`glab --hostname localhost:8929` が使えなかった。** `Error parsing --hostname: invalid hostname.`
  で失敗する（ポート付きを受け付けない）。`GITLAB_HOST=http://localhost:8929` の環境変数で解決した。
  実装時に同じ罠を踏まないよう、reportへ書き残した。
- **`/changes` の非推奨を実機で裏取りできなかった。** レスポンスヘッダは `HTTP/1.1 200 OK` のみで、
  Deprecation / Sunset / Warning のいずれも返らなかった。公式ドキュメント上の非推奨と、実機の挙動は
  別物なので、reportでは「確かめられなかったこと」へ分離した。
- **`jq` のフィルタに書いた `\.` がツール経由で1つに潰れ**、`Invalid escape at line 1, column 4` で
  失敗した。`.claude/rules/shell-script-style.md`「AIエージェント向け注記」に書かれているとおりの
  現象。キー集合の比較は複雑な正規表現を使わず `keys|join(",")` の単純な形へ書き換えて回避した。
- リネームを含むMRが検証用インスタンスに無く、**改名時の `old_path`/`previous_filename` の挙動は
  未確認のまま**残った（reportの「確かめられなかったこと」へ記載）。

## 次の一歩

- flow-id 2-7（2周目相当）: `commit` スキル経由でコミットし、リモートへ反映して再レビューを依頼する。
- 残る未決定事項は5件（diff関数の返却形と関数名、正解ソースの後始末の置き場所、一般語の除外リストの
  持ち方、実例確認で実投稿するか）。うち人間の判断が要るのは「実例確認で実投稿するか」の1件。
- 合意後、flow-id 2-10 でMR descriptionを更新し、フェーズ3（flow-id 3-1）へ進む。
