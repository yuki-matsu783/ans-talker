---
title: HANDOFF
type: handoff
description: セッション間・作業者間の引継ぎメモ（現在地・次回やること等）
tags: [handoff, workflow]
keywords: [フロー進捗, worklog, 引き継ぎ, plan, レビュー]
---

# HANDOFF

<!--
AI⇔AI/AI⇔人間の状況引継ぎメモ。常に「このブランチの現状」を表現する
-->

## フロー進捗状況

- issue: #117
- ブランチ: `claude/cleanup-task-frontmatter-index-8wjloa`
- PR: #124（https://github.com/yuki-matsu783/MR-driven-workflow/pull/124 ）
- push回数: 3
- 現在のループ: なし
- 追従監視: 購読あり（web。subscribe_pr_activity + 定期チェックイン）

（進捗表は次タスク着手時に記入する）

<!--
本ブランチは Claude Code on the web の非対話セッションで進めたため、人間担当のレビュー往復
（flow-id 2-3/2-8, 3-3/3-8, 4-3/4-8）を待てない。`.claude/rules/docs-workflow.md` の規定に従い、
該当ループ範囲の記号は付けず、実施内容は下記「やったこと」に文章で残す。
-->

## やったこと

issue #117（`cleanup-task.sh` のfrontmatterインデックス再生成が、削除がステージされていないため
必ず失敗する）に対応した。

- **原因の確認**: 使い捨てリポジトリで再現した。`extract-frontmatter.sh` は
  `git ls-files --cached` で対象を列挙するが、`--cached` はgitのindexの内容を返すため
  **削除済みだが未ステージの追跡ファイル**も含む。`cleanup-task.sh` はコミットしない（DDR 0048）
  ので、再生成の時点で必ずこの状態になる。
- **issueの記述より影響が大きいことが分かった**: 警告1つでは済まず、**走査全体が中断**していた。
  `xargs -0 stat` が失敗して件数が合わなくなり、フォールバックの1件ずつ取り直すループが
  `set -e` 配下で倒れるため、削除と無関係なディレクトリの `index.jsonl` まで再生成されない。
- **対処**: issueが挙げた2案のうち **`extract-frontmatter.sh` 側でスキップする**案を採った
  （DDR 0057）。列挙ループで `[[ -f "$f" ]]`（bash組み込みなのでforkは増えない）を判定し、
  実体の無いパスを対象から外す。スキップ件数は警告とサマリ行の `skipped=` で可視化する。
  `cleanup-task.sh` の手順・順序・コミットしない方針は変えていない。
- **検証**: 使い捨てリポジトリで `cleanup-task.sh` を通常実行し、`frontmatterIndex.exitCode` が
  `0` になること・削除したファイルがインデックスから消えること・残った行が変わらないこと・
  `--dry-run` / `--skip-index` の挙動が変わらないことを確認した。
  修正前のスクリプトへ戻すと新規テストが失敗する（`test_extract_frontmatter.sh` で7件、
  `test_cleanup_task.sh` で4件）ことも確認済み。
- **変更したファイル**:
  - `.claude/scripts/src/extract-frontmatter.sh`（列挙時のスキップ、サマリへ `skipped=` 追加）
  - `.claude/scripts/test/test_extract_frontmatter.sh`（23→32ケース、`passed=32 failures=0`）
  - `.claude/scripts/test/test_cleanup_task.sh`（37→53ケース、`passed=53 failures=0`。
    `main` の結合テストを常設した）
  - `.claude/docs/spec/extract-frontmatter.md` / `.claude/docs/spec/cleanup-task.md`
  - `.claude/docs/ddr/0057-削除済み追跡ファイルの除外はextract-frontmatter側で行う.md`（新規）
  - `.claude/docs/README.md`（DDR一覧）/ `.claude/rules/shell-script-style.md`（教訓を追記）
- `.claude/scripts/test/` の全12スクリプトが `failures=0`（mainのマージ後、合計633ケース）。

## 次にやること

- PR #124 のレビュー待ち。マージはユーザーの明示指示があるまで行わない。
- defaultブランチの追従を監視中（本セッション中のみ有効。セッションが終わったら次のセッションの
  `resume` で取り直す）。作業中に main は3回進んだ（PR #107 → #122 → #123）。#107 とはDDR番号が
  衝突したため解消済み、#122・#123 は `HANDOFF.md` のみの競合で解消済み。

## 判断を迷った内容

- **修正箇所をどちらに置くか**（issueが2案を提示していた）。`cleanup-task.sh` から再生成を外して
  flow-id 5-4 へ移す案は、`extract-frontmatter.sh` に触れずに済む一方、コミット前に同スクリプトを
  呼ぶ**他の経路**（SessionStart hook、`search-frontmatter.sh` の自動更新、`resolve-conflict`
  スキルが案内する手動実行）に同じ失敗が残る。とくにSessionStart hookは「ファイルを消した直後の
  セッション開始」で日常的に踏みうるため、原因のある側で直す案を選んだ（DDR 0057に却下案を記録）。
- **スキップを無言で行うか**。削除済みファイルをインデックスから外すのは正しい結果だが、無言だと
  今度は本当の欠落を隠す（issue #66と同種）。件数を警告とサマリ行へ出す形にした。
- mainのマージ（PR #107がマージされたことによる追従）で、DDR番号がmain側の
  `0056-作業開始時のベースブランチ追従確認は…` と本ブランチ側の
  `0056-削除済み追跡ファイルの除外は…` で重複した（類型A）。**mainを正とし本ブランチ側を
  0056 → 0057 へ繰り下げた**。参照元（`.claude/docs/README.md`、
  `.claude/docs/spec/extract-frontmatter.md`、`.claude/docs/spec/cleanup-task.md`、
  本ファイル）もあわせて更新した。main側の 0056 とその参照元
  （`spec/check-base-sync.md` 等）には手を触れていない。
- `.claude/docs/README.md` のDDR一覧末尾で、両ブランチが別々のエントリを追記して競合した
  （類型C）。**両方を残し**、番号順（0056 → 0057）に並べた。
- `HANDOFF.md` は「このブランチの現状」だけを表すファイルのため、**main側の記述（PR #107 の
  コンフリクト解消記録・リセット済みの状態）は取り込まず、本ブランチ（issue #117）の内容を
  採用した**。コンフリクト部分だけでなく、自動マージで入り込む可能性のある箇所も
  `git diff HEAD -- HANDOFF.md` で通しで確認している。
- 2回目のmainのマージ（PR #122・#123 の追従）では、競合したのは `HANDOFF.md` の
  「判断を迷った内容」節のみだった（類型C）。main側はリセット済みの `（無し）`、本ブランチ側は
  上記の記録であり、**「1ブランチ1状態」の原則から本ブランチ側を採用した**。今回はDDR番号の
  衝突は無い（main側は0056までで、本ブランチの0057と重ならない）。

## 未解決の内容

- `test_cleanup_task.sh` に常設した `main` の結合テストは、通常実行・`--dry-run`・`--skip-index`
  の3経路のみを対象にしている。issue #28 対応時に手動確認していた2回目の冪等性・
  `extract-frontmatter.sh` 不在／異常終了・不正な引数／設定の各経路は手動確認のままで、
  常設していない（`.claude/docs/spec/cleanup-task.md`「未決定事項・懸念点」に記載）。

## 守るべき条件・触ってはいけない範囲

- **`cleanup-task.sh` がコミットしない方針（DDR 0048）は変えない**（issueの明示要件）。
- `extract-frontmatter.sh` の性能設計（1ファイル1回のjq呼び出し・ホットパスでforkしない。
  DDR 0021）を崩さない。列挙ループへ外部コマンドを持ち込まないこと。
