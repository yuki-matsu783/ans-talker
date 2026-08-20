---
title: worklog 20260820 answer-talkerスキルの設計調査 push2
type: log
description: issue #1（answer-talkerスキル追加）のフェーズ2〈調査〉の実施ログ。6論点の調査で試したこと・実機確認の詳細。push2。
tags: [worklog, answer-talker, 調査]
keywords: [worklog, answer-talker, 調査実施, gh api, pulls files, shallow clone, ネタバレ検査, 対応付け, 実機確認]
---

# worklog: 【調査】answer-talkerスキルの設計調査

対象: issue #1 の answer-talker スキルを設計するための調査の実施（2026-08-20）。
全体作業計画: `plans/bubbly-exploring-biscuit.md`
個別作業計画: `plans/【調査】answer-talkerスキルの設計調査.md`
push回数: 2

## 試したこと

### 論点1（既存スキルからの再利用範囲）

- `.claude/agents/adversarial-reviewer.md` を読み、findings JSONのキー定義
  （`path`/`line`/`old_line`/`side`/`severity`/`confidence`/`category`/`title`/`body`）と
  「行の種類ごとの指定」（追加行は `line` のみ、削除行は `old_line` のみ、コンテキスト行は両方）を確認した。
- `Github.sh` の `github_add_mr_inline_comments`（331行目〜）を読み、投稿処理が
  `github_valid_ranges_from_files_json` → `github_filter_findings_by_valid_lines` →
  `github_build_review_payload` の順に組み立てられていることを確認した。
- `adversarial-review-count.sh` の冒頭コメントで、上限機構の目的が
  「非対話モードで人間の介在なくレビューが回りうること」への対策だと明示されているのを確認した。

### 論点2（MR番号起点のdiff取得）

- `gh pr view 2 --json files` / `gh pr diff 2` / `gh api repos/{owner}/{repo}/pulls/2/files --paginate`
  の3経路をすべて本PR #2 に対して実行し、返る情報を比較した。
- `gh pr view 2 --json headRefName,baseRefName,headRefOid` で base/head/SHA が1回で取れることを確認した。
- patchのバイト数を `jq -r '.[] | "\(.filename)\tpatch_bytes=\(.patch // "" | length)"'` で測り、
  4ファイル合計で約21.9KBだった。

### 論点3（正解ソースの取得方式）

- スクラッチパッドで3通りのcloneを実際に実行した。
  1. ローカルパスから `--depth 1` 付きclone
  2. URLから `--depth 1 --single-branch --no-tags` clone
  3. gitリポジトリでないただのディレクトリをclone
- 既存スクリプトの `mktemp` / `trap` の使い方を `grep -n "mktemp\|trap\|MSYS_NO_PATHCONV"` で横断的に調べた。

### 論点4・5・6

- 机上の検討（実機確認の対象ではない）。誤検知・見逃しの具体例は、Goの定型コードとこのリポジトリの
  既存スクリプトの語彙から具体化した。

## うまくいったこと

- **`pulls/<n>/files` が求めていた情報をすべて持っていた**（filename / status / patch /
  additions / deletions / blob_url）。しかも既存の投稿処理が同じエンドポイントを叩いているため、
  「レビュー時に見た行」と「投稿できる行」の情報源を一致させられる。当初は
  `gh pr diff` のテキストをパースする想定だったが、その必要が無くなった。
- **日本語を含むパスが、どの経路でもエスケープされずに返った。** `git ls-files` のような
  8進エスケープ（`.claude/rules/shell-script-style.md` の既知の罠）を心配していたが、
  `gh` のJSON出力では起きない。
- **`adversarial-review` との構造的な違いを1つの軸で説明できた**——「自分のブランチのMR」対
  「引数で受けた他人のMR」。この違いから、diff取得関数が無いこと・上限機構が合わないこと・
  観点表を使わないことが、すべて同じ理由で導ける。

## ダメだったこと

- **ローカルパスの shallow clone は成立しなかった。** `--depth 1` を付けても
  `warning: --depth is ignored in local clones; use file:// instead.` が出て全履歴（4コミット）が
  コピーされた。`file://` を付ければ浅くできるが、そもそもローカルは clone せずそのまま読めばよい
  （かつ、正解が素のディレクトリの場合は clone 自体が `fatal: repository does not exist` で失敗する）
  ため、方針を「ローカルは clone しない」へ変えた。
- **cloneの失敗を取りこぼしかけた。** 検証で `git clone ... 2>&1 | tail -3` と書いたところ、
  cloneが `fatal:` で終わっているのに `echo "exit=$?"` が `exit=0` を表示した。パイプの終了コードが
  `tail` のものになるため。実装では失敗判定をパイプで潰さないよう注意する（reportの
  「実装前に分かっている落とし穴」へ記録した）。
- `glab` が無いため **GitLab経路は一切実機確認できなかった**。APIの形についての理解はあるが
  裏取りしていないので、reportでは「確かめられなかったこと」として分離し、対応方針自体を
  未決定事項へ送った。

## 次の一歩

- flow-id 2-7: `commit` スキル経由でコミットし、リモートへ反映してレビュー依頼を出す。
- レビューで確認したい点（結果mdの「未決定事項」6件のうち、とくに次の2つ）。
  - GitLab対応を未検証のまま実装するか、対象外と明示するか
  - 実例確認で実際にMRへ投稿するか、投稿直前で止めるか
- 合意後、flow-id 2-10 でMR descriptionを更新し、フェーズ3（個別作業計画）へ進む。
