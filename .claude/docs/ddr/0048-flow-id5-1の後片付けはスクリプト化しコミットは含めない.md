---
title: 0048. flow-id 5-1の後片付けはスクリプト化しコミットは含めない
type: ddr
description: flow-id 5-1（次タスクのための片付け）をcleanup-task.shへ委譲するにあたり、残すパスを明示リストで持つ・HANDOFF.mdのテンプレートをスクリプトへ埋め込む・コミットは行わない、と決めた経緯を記録したDDR
tags: [workflow, script, cleanup, ddr]
keywords: [cleanup-task, flow-id-5-1, HANDOFF, TEMPLATE.md, REVIEW-POINTS.md, KEEP_PATHS, dry-run, commitスキル, 却下案, DDR]
---

# 0048. flow-id 5-1の後片付けはスクリプト化しコミットは含めない

## 背景

issue #28「flow-id 5-1 後片付けタスク自動化スクリプト（cleanup-task.sh）の実装」。

flow-id 5-1 は「`plans/` `worklog/` `reports/` を削除し、`HANDOFF.md` をリセットする」という
毎回同じ4操作からなるが、`.claude/skills/issue-mr-flow/SKILL.md` の手順として書かれているだけで、
実行はAIエージェントの手作業だった。手作業である限り、**消し忘れ**（`reports/` のhtmlだけ残る）と
**消しすぎ**（`worklog/TEMPLATE.md` まで消す）の両方が起こりうる。実際、リポジトリのスケルトンで
`worklog/` に残っている追跡対象ファイルは `TEMPLATE.md` だけであり、「`worklog/` を削除する」と
書かれた手順を素直に読むとこれも消える。

進捗記号（`update-handoff-progress.sh`）・コンフリクト検知（`check-base-conflicts.sh`）で既に
採っている「手順書に書くのではなくスクリプトへ委譲する」方針を、片付けにも適用する。

## 決定

1. **`.claude/scripts/src/cleanup-task.sh` を新設し、flow-id 5-1 の4操作を1コマンドにまとめる。**
   対象ディレクトリは `.mrworkflow.json` から読み、設定値がリポジトリルート配下の相対パスで
   なければエラーにする（設定由来の値をそのまま `rm -rf` へ渡さない）。
2. **残すものは、スクリプト内の明示リストで持つ。** パス完全一致の `KEEP_PATHS`
   （`worklog/TEMPLATE.md`）と、階層を問わないファイル名一致の `KEEP_BASENAMES`
   （`REVIEW-POINTS.md`。issue #77）の2種類を用意する。残すものを1つも含まないディレクトリは
   ディレクトリごと削除し、含むディレクトリは中のファイルだけを消す。
3. **`HANDOFF.md` のリセット後の内容は、スクリプトへ埋め込んだテンプレートで表す。**
   別ファイルとして持たない。
4. **スクリプトはコミットしない。** ワーキングツリーを変更するところまでを担当し、
   ステージングもコミットも行わない。
5. **`extract-frontmatter.sh` の失敗は警告に留め、終了コードは0のままにする。**
6. `--dry-run` を用意し、削除対象・リセット要否だけを同じ形のJSONで出力する。

仕様の詳細は `.claude/docs/spec/cleanup-task.md` が正。

## 却下案

### (a) 削除対象を `get_branch_work_files` で決める

`Provider.sh` には、defaultブランチとの差分とワーキングツリーの状態から「このブランチ固有の
plans/worklog/reportsファイル」を列挙する関数が既にある。これを使えば「このブランチが作った
ものだけを消す」という精密な削除ができる。

採らなかった理由は2つある。第一に、**残したいものと消したいものの境界は、ブランチ差分ではなく
ファイルの役割で決まる**。`worklog/TEMPLATE.md` は永続する雛形であり、仮に何らかの理由で
ブランチ差分に現れても消してはいけない。第二に、`plans/` `worklog/` `reports/` に残る非追跡
ファイル（`index.jsonl`・`reports/*.html` を後から手で追加した場合など）がブランチ差分から
漏れることがあり、「消し忘れを無くす」という目的を満たさない。役割で決めるなら、明示リストの
方が読んで確認できる。

### (b) HANDOFF.mdのテンプレートを別ファイル（`HANDOFF.template.md` 等）として持つ

`worklog/TEMPLATE.md` に倣う案。しかしこのテンプレートは**人間が編集して使う雛形ではなく、
スクリプトが書き出す出力そのもの**である。別ファイルにすると、(1) リポジトリ直下にほぼ同じ内容の
markdownが2つ並び、frontmatterの `type` をどう与えるか（`handoff` か否か）という新しい判断が
増える、(2) `index.jsonl` にテンプレート自身が載る、(3) スクリプトからの相対パス解決が要る、と
副作用の方が大きい。埋め込みにしたうえで、単体テストで見出し構成を検証する形にした。

### (c) 片付けからコミットまでをスクリプトが行う

flow-id 5-1 の直後は必ずコミットするため、一体にすれば手順が1つ減る。しかしこのリポジトリの
コミットは `commit` スキル経由に限る決定（DDR 0012）があり、スキルを介さないコミットは
PreToolUse hookがブロックする。スクリプトの中でラッパー（`create-commit.sh`）を呼べば技術的には
通るが、「どのタイミングでどの粒度のコミットを作るか」の判断を `commit` スキルから引き剥がす
ことになる。片付けはワーキングツリーの変更まで、コミットは従来どおり `commit` スキル、と
責務を分けた。

### (d) `extract-frontmatter.sh` の失敗でスクリプト全体を失敗させる

素直な `set -e` の挙動だが、**削除と `HANDOFF.md` のリセットは既に成功している**状態で終了コード
1を返すことになり、呼び出し側からは「片付けが失敗した」と読めてしまう（実際にやり直すべきことは
何も無い）。`index.jsonl` は `.gitignore` 対象の生成物で、SessionStart hookが毎セッション再生成
する（DDR 0025）ため、ここでの失敗は次のセッションで自然に回復する。警告＋JSONの
`frontmatterIndex.exitCode` で失敗を可視化したうえで、終了コードは成功のままにした。

### (e) 削除前に確認プロンプトを出す

`rm -rf` を含む以上、対話的な確認を挟む案。しかし本スクリプトの主な呼び出し元はAIエージェントで
あり、非対話的な実行環境（Claude Code on the web 等）では確認に応答できない。代わりに
`--dry-run` を用意し、**確認したい場合は先に `--dry-run` で見る**という形にした（`--dry-run` と
本実行で同じ形のJSONを返すため、同じ `jq` フィルタで突き合わせられる）。
