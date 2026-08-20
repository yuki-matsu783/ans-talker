---
alwaysApply: true
title: Git運用（ブランチ・命名規則）
type: rule
description: featureブランチの命名規則・worklog配置・PR/マージ運用と、ベースブランチ追従確認・取り込み方針（mergeを使いrebaseは使わない）を定めたルール
tags: [git, branch, rule]
keywords: [featureブランチ, ブランチ命名, worklog, squash-merge, draft-pr, issue-mr-flow, マージ運用, ベースブランチ, 追従確認, rebase, check-base-sync, always-apply]
---

# Git運用（ブランチ・命名規則）

開発フロー全体（issue起票〜マージ、worklog・設計反映・PR・マージの手順を含む）は
`.claude/skills/issue-mr-flow/SKILL.md` を参照する（唯一の実装フロー定義）。本ファイルは
ブランチ運用に関する参照情報のみを記載する。

## 適用範囲

適用要否の判定基準は `AGENTS.md` を参照する。フロー対象外と判定された変更は、mainへの
直接コミットも許容する（本節は判定基準そのものではなく、フロー対象外時のブランチ運用上の
帰結のみを記載する）。

## ブランチ運用

- フロー対象のタスクは、着手前に必ずfeatureブランチを作成する（mainへの直接コミットはしない）。
- ブランチ名は `.mrworkflow.json` の `branchPrefixTemplate`（既定 `feature-<issue番号>-<slug>`）に従う。
- **作業を開始・再開するときは、ベースブランチの最新を取り込めているかを確認する**（issue #67）。
  対象は `start`（既存ブランチを検出した場合）・`resume`・`sync` の3地点で、
  `bash .claude/scripts/src/check-base-sync.sh` の `isBehind` を見る。**遅れがある場合は
  `AskUserQuestion` でユーザーの承認を得るまで取り込まない。** 手順・判定が信頼できない場合の
  扱いは `.claude/skills/issue-mr-flow/SKILL.md`「作業開始・再開時のベースブランチ追従確認」節が正
  （本ファイルは入口のみを示す。仕様: `.claude/docs/spec/check-base-sync.md`）。
- **取り込みは `git merge` で行い、`git rebase` は使わない。** 作業ブランチは既にリモートへ
  反映済みであり、履歴の書き換えは他の作業者のチェックアウトを壊すため。コンフリクトが出た場合の
  類型別の解消手順は `.claude/skills/resolve-conflict/SKILL.md` が正。

## コミット運用

- **すべてのコミットは `commit` スキル（`.claude/skills/commit/SKILL.md`）経由で行う**
  （issue #39）。ユーザーが明示的に `/commit` を呼ぶ場合だけでなく、`issue-mr-flow` の全体フロー
  flow-id 2-2/2-7/3-2/3-7/4-2/4-7/5-4でAIエージェントが自律的にコミットする場面も対象。
- ドキュメント上のルールだけでなく、技術的にも強制する。`git commit` の直接実行は
  `.claude/hooks/block-direct-git-commit.sh`（PreToolUse hook。`.claude/settings.json`の
  `hooks.PreToolUse`で登録）が、Bash/PowerShellのコマンド文字列に `git commit` を検知した時点で
  exit code 2でブロックする。`permissions.deny`にも`Bash(git commit*)` / `PowerShell(git commit*)`
  を追加しているが、複合コマンド（例: `cd src && git commit -m "fix"`）はprefixマッチをすり抜ける
  ため、実質的な強制はhook側が担う（多重防御）。
  - `commit`スキル自身は `.claude/scripts/src/create-commit.sh` というラッパースクリプト経由で
    `git add` / `git commit` を実行する。呼び出し文字列自体に `git commit` という部分文字列を
    含まないため、hookの対象にならず正規に実行できる。
  - 既知のトレードオフ: 部分文字列マッチのため、たまたま `git commit` という語を含む無関係な
    コマンド（該当文字列を検索する `grep` 等）も誤ってブロックされる。悪意ある回避への対策は
    行わない（既定動作を確実な方向へ倒す仕組みであり、敵対的な安全境界ではない）。
    **AIエージェント向け注記**: このトレードオフはissue #39対応時に実際に2回発生した
    （コミットメッセージ、およびMR description用heredocの説明文中に、それぞれ`git commit`という
    語句が地の文として含まれていたため）。コミットメッセージ・PR description・スクリプトの
    コメント等、このhookの仕組み自体を日本語で説明する文章を書く際は、`git` と `commit` を
    半角スペース区切りで連続させず（例:「gitのコミット操作」「直接コミットを実行する」のように
    言い換える）、同一Bash/PowerShellツール呼び出し文字列内で誤検知を避ける。
  - 経緯・却下案は
    `.claude/docs/ddr/0012-コミットはcommitスキル経由を機構的に強制する.md` を参照。
- **削除したファイルのパスは、変更したファイルと同じように `commit` スキルへ渡してよい**
  （issue #60）。ラッパー（`create-commit.sh`）が「削除」としてそのままステージする。
  **先に削除をステージしてから残りを渡す2段構えは不要**であり、むしろそれを行うと当該パスが
  indexから消えて後続がpathspec不一致で失敗する。既に削除がステージ済みのパスを渡した場合は、
  冪等にスキップして通知するだけになる。仕様は
  `.claude/docs/spec/create-commit.md`、経緯は
  `.claude/docs/ddr/0030-create-commitは削除ステージ済みパスをgit-addの失敗時分類で吸収する.md` を参照。

## push検知hookの誤検知（AIエージェント向け注記）

上記コミットhookと同じ「コマンド文字列の部分文字列マッチ」に起因する問題が、**push検知側にも
ある**（issue #23で判明）。`.claude/settings.json` の `hooks.PostToolUse` に登録された
`post-push-usage-report.sh` / `post-push-compact-prompt.sh` は、Bash/PowerShellツールへ渡された
コマンド文字列に `git` と `push` が連続して現れると発火する。**前方一致ではなく部分一致**であり、
実際にpushしたかどうかは確認されない。

issue #23の作業中、次のようなケースで計3回、pushしていないのに発火した。

- `cd /c/Users/... && ...` のように、コマンドが該当語で**始まっていない**場合
- issue本文・MR descriptionをheredocで渡す際、その**地の文**に該当語が含まれていた場合

発火すると対応工数の集計・カーソル前進・`/compact` の促しが走る（実害は限定的だが、
意図しない状態変化が起きる）。

**対策**: コミット側と同じく、`git` と `push` を半角スペース区切りで連続させない書き方に
言い換える（例:「プッシュする」「リモートへ反映する」）。**長文を渡す場合は、コマンド文字列へ
直接埋め込まずファイル経由にする**のが確実で、実機で発火しないことを確認済み。

```bash
# 悪い例（本文中の語でhookが発火する）
gh issue comment 23 --body "$(cat <<'EOF'
... git push のたびに ...
EOF
)"
# 良い例（ファイル経由なら本文の中身はコマンド文字列に現れない）
gh issue comment 23 --body-file /path/to/body.md
```

`Provider.sh` の `set_mr_description <n> <file>` も同じ理由でファイルパスを受け取る設計になっている。
制約の詳細は `.claude/docs/spec/issue-mr-workflow.md`
「制約: 検知は`tool_input.command`の文字列マッチに依存する」を参照。

## worklogの配置・命名

`worklog/日付_<全体計画名>_<個別計画名>_push<N>.md` に記録する（配置・命名は `directory-structure.md`、ライフサイクルは
`docs-workflow.md` の「ドキュメント運用」表、作成・削除のタイミングは `.claude/skills/issue-mr-flow/SKILL.md`
の全体フローを参照）。

## PR・マージ

担当の切り分けは「**PR/MRの作成・更新はAIエージェントが実施してよい／マージのみユーザーの明示指示が
必須**」で統一する（issue #41。理由・却下案は
[.claude/docs/ddr/0035-PR_MR作成はAIエージェントに委ねマージのみ明示指示を必須にする.md](../docs/ddr/0035-PR_MR作成はAIエージェントに委ねマージのみ明示指示を必須にする.md)）。

| 操作 | 担当 | 補足 |
|---|---|---|
| Draft PR/MRの作成（flow-id 1-3） | **AIエージェント**（都度の明示指示は不要） | `start` サブコマンドが `new_draft_merge_request` で作成する |
| MR descriptionの更新（flow-id 2-5等）・レビュー依頼・レビューコメントへの返信 | **AIエージェント**（同上） | `describe` / `reply` サブコマンド |
| 関連issueへのマージ前通知（flow-id 5-3） | **AIエージェント**（ただし**投稿前に`AskUserQuestion`での承認が必須**） | `add_issue_comment` で行う。詳細: `.claude/skills/issue-mr-flow/SKILL.md`「マージ前の関連issue通知」 |
| Draft解除（flow-id 5-4） | **AIエージェント**（同上） | `set_mr_ready` で行う |
| レビュー（コメント・承認） | 人間 | flow-id 2-3/2-8/3-3/3-8/4-3/4-8 |
| **マージ**（squash merge・マージ後のブランチ削除）（flow-id 5-5） | **人間** | AIエージェントは、**ユーザーから明示的に指示された場合に限り**実行してよい |

- **`gh pr merge` / `glab mr merge` 等のマージ操作は、ユーザーから明示的に指示されない限り実行しない。**
  「レビューが終わった」「Draftを解除した」「コンフリクトを解消した」はいずれもマージの指示ではない。
  フロー上マージが次の一手であっても、AIエージェントは flow-id 5-4 まででいったん止まる。
- 判断の根拠は「**取り消せるか**」である。PR/MRの作成・Draft解除・description更新は、Draftへ戻す・
  クローズする・本文を書き直すことでいつでも取り消せ、`main` は1バイトも変わらない。一方マージは
  `main` の正史を書き換える不可逆な操作であり、squash mergeでは元のコミット粒度も失われる。
- マージはsquash mergeを用いる。flow-id 5-1で`plans/` `worklog/` `reports/`を削除しておくことで、squash後にmainへ反映される内容は「コード＋spec/ddr」のみになり、試行錯誤の詳細はブランチ上のコミット履歴（PRのコミット一覧）としてのみ残る。
- マージ後、作業ブランチは削除してよい。

### PR作成後のdefaultブランチ追従（issue #88）

PR作成からマージまでの間にdefaultブランチが進むと、レビューを待っている間にコンフリクトが生まれる。
この追従は**flow-id 5-2（マージ依頼の直前の検知）だけでは間に合わない**ため、PR作成後は継続的に
監視する。手順・実行環境別の手段（Claude Code on the web ではPRイベントの購読と定期チェックイン、
ローカルでは `/resolve-conflict` の手動実行）・自動解消してよい類型の線引き・停止条件は、
`.claude/skills/issue-mr-flow/SKILL.md`「PR作成後のdefaultブランチ追従（監視）」節が正である
（本ファイルは入口のみを示す）。

- 監視の状態（購読の有無・手段）は `HANDOFF.md` のヘッダ `- 追従監視:` 行へ記録する。購読と
  定期チェックインはセッションに紐づき、セッション終了とともに止まるため、次のセッションは
  `resume` で取り直す。
- 監視中に自動解消してよいのは**解消方法が一意に決まる類型**に限る。同じロジックを両ブランチが
  変更した競合は、解消せずに人間の判断を仰ぐ。
- 自動解消した場合も、コミットは `commit` スキル経由で行い、検証（コンフリクトマーカー・単体
  テスト・DDR番号の重複）を省略しない。

### ハーネスがPR作成を制限する環境での扱い

Claude Code on the web のリモート実行環境等では、**ハーネス（実行基盤）のシステムプロンプトに
「ユーザーが明示的に依頼しない限りPRを作成しない」旨の指示が含まれる**ことがある。この場合は
**ハーネス側の指示を優先する**。リポジトリ内のドキュメントでハーネスのシステムプロンプトを
上書きすることはできず、リポジトリ方針を優先させると衝突の解釈をAIが都度行うことになって、
issue #41が問題にした「セッションごとに判断が変わる」状態へ逆戻りするためである。

ただし、**優先した先の振る舞いは決め打ちにする**（再現性の要点は「必ず作る」ことではなく
「毎回同じ判断になる」ことにある）。そのような環境では flow-id 1-3 を次の順で行う。

1. featureブランチの作成とリモートへの反映までは、通常どおり行う。
2. Draft PR/MRを作成する直前に、`AskUserQuestion` で可否を**1回だけ**確認する
   （例:「issue #NN のDraft PRを作成してよいか」）。承認されたら、以降は通常の flow-id 1-3 と
   まったく同じ手順で作成する。
3. ユーザーの応答を待てない非対話的セッション（スケジュール実行等）では、**PRを作成せずに止め、
   「PRを作成していないこと」「作成するには明示指示が必要なこと」を最終応答へ明示する**。
   黙ってリモートへ反映しただけで終わらない。

flow-id 5-4（Draft解除）・`describe`・`reply` はPRの新規作成ではないため、この確認の対象外である
（ハーネスの指示が制限しているのはPRの作成であり、既存PRの更新ではない）。
