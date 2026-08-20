---
title: 0009. Planモードre-entry時はgit checkout復元でなくarchiveスクリプトで対処する
type: ddr
status: superseded
superseded_by: "0019"
description: 同一セッション内でPlanモードへ複数回re-entryする際の計画ファイル衝突対策を、一時上書き+git checkout復元からcp/mvによるarchiveスクリプトへ切り替えた経緯を記録したDDR
tags: [plan-mode, claude-code, ddr]
keywords: [exitplanmode, archive-reentrant-plan, act1, git checkout, plan-mode-safety, issue-26]
---

# 0009. Planモードre-entry時はgit checkout復元でなくarchiveスクリプトで対処する

## 背景

`ExitPlanMode` は `plan` 引数を取らず、ハーネスが「今回のplanファイル」として提示するパスから
内容を読む仕様になっている。issue #7対応時、**同一セッション内でPlanモードへ2回目以降
re-entryすると、ハーネスは1回目のre-entryで使ったplanファイルパスをそのまま提示し続け、
新しいパスは割り当てられない**という制約が判明した。これは`.claude/rules/plan-mode-safety.md`
規則2「計画ごとに新しいplanファイル名を使う」と単純には両立しない。

issue #7対応時点での回避策（規則6）は次の手順だった。

1. `plans/<新しい名前>.md` を別途作成し、そちらへ本当の計画内容を書く。
2. ハーネス提示パス（1回目のplanファイル、既にgit管理下でcommit済み）へ同じ内容を一時的に書き込む。
3. `ExitPlanMode` を呼ぶ（ハーネスはこのパスからしか読まないため）。
4. 承認後、`git checkout -- <ハーネス提示パス>` で直前のcommit内容へ復元する。

issue #26で、この手順自体が「変な挙動」であると指摘された。復元忘れ・タイミングミスが起きると
1回目のplan内容が破壊されるリスクを持つ。実際、過去のcommit（`3c75b50`）を調査したところ、
ハーネス提示パス側のファイルはdiffに一切現れておらず、一時上書き分がgit履歴に全く残らない
（＝一時的に存在した内容がgit管理外で消える）運用になっていたことを確認した。

## 決定

**re-entry時にハーネス提示パスへ新しい計画を書き込む前に、そこに残っている1つ前の計画（および
対応するworklog）を`_actN`サフィックス付きの別名へ退避し、ハーネス提示パスへは直接新しい計画を
書き込む。** 「一時的に上書きしてgit checkoutで復元する」手順は廃止する。

- 新規スクリプト `dev-tools/src/archive-reentrant-plan.sh` を追加。
  - planファイル: `cp` で `plans/<base>_actN.md` へ退避（元のパスは残し、ハーネスが直接
    上書きできるようにする）。
  - 対応するworklogファイル（`worklog/日付_<base>.md`）: `mv` で退避（新しい計画が同じ`base`名を
    再利用してworklogファイル名が衝突するのを避けるため、元の名前を明け渡す）。
  - `_actN`のNは、既存の`_act1`, `_act2`, ... を避けて自動採番する（1回限りの固定値にしない）。
  - git操作（add/commit）は行わない。ファイル操作のみとし、commitは通常のissue-mr-flowの
    手順（flow-id 6/12）に委ねる。
- `.claude/rules/plan-mode-safety.md` 規則6を、このスクリプトを使う手順へ全面改訂した。
- 規則2「計画ごとに新しいplanファイル名を使う」も「既存の承認済み計画の内容を失わない」へ改題した。
  ハーネス提示パスのファイル名自体は前回と同じものを使い回すことになるため、規則2の目的が
  「同一ファイル名を使わない」ことそのものではなく「既存計画の内容を失わない」ことにあると
  明確化し、archiveスクリプトによる退避がこの目的を満たす例外であることを規則2側にも明記した。

この方式により、旧内容は必ずgit管理下のファイルとして残る（一時的にしか存在しない状態が無くなる）
ため、復元忘れによる事故が構造的に起きなくなる。

`tests/test_archive_reentrant_plan.sh` で、初回re-entry（no-op）・2回目（`_act1`）・
3回目相当（既に`_act1`がある状態から`_act2`）・worklog有無の各ケースを検証済み（19アサーション）。

## 却下した案

- **`EnterPlanMode`/`ExitPlanMode`をhookで自動的にフックし、archiveスクリプトを自動実行する**:
  ハーネスが提示するplanファイルパスは、ツールが実際に実行された後（またはPlanモード突入時の
  システムメッセージ経由）にしか判明せず、`PreToolUse`/`PostToolUse`フックの入出力から
  確実に取得できる保証がない。規則6は引き続き「エージェントが手順として読んで実行する」運用の
  ままとした。
- **`.mrworkflow.json`にworklogDir等の設定を追加し、スクリプトから読み込む**:
  スクリプトの利用対象を`dev-tools/src/vcs/Provider.sh`（issue-mr-flow用）から独立させ、
  余分な結合を持ち込まないため見送った。スクリプトは`worklog`ディレクトリを既定値とし、
  第2引数で上書き可能にするに留めた。
