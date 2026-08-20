---
title: 0023. レビュー依頼メッセージの参照リンクは前回pushSHAをローカル状態で保持して組み立てる
type: ddr
description: post-push-compact-prompt.shがレビュー依頼メッセージへ付与する参照リンク（差分・コメント一覧）の設計判断を記録したDDR
tags: [review-links, github, hooks, ddr]
keywords: [参照リンク, レビュー依頼, 前回push, 差分, コメント一覧, 状態ファイル, issue13]
---

# 0023. レビュー依頼メッセージの参照リンクは前回pushSHAをローカル状態で保持して組み立てる

## 背景

issue #13「レビュー依頼にMRへのリンクをつける」。`post-push-compact-prompt.sh`
（`.claude/docs/spec/issue-mr-workflow.md`「/compact実施の呼びかけ」節）がレビュー依頼メッセージの
文面をAIエージェントに促す際、これまでは固定文のみで参照リンクを含んでいなかったため、
レビュアーがMRを見に行くまでに1段階ハードルがあるという指摘を受けた。受け入れ条件は
「defaultブランチとの差分リンク」「（レビュー指摘対応push時のみ）前回push時との差分リンク・
コメント一覧リンク」の付与。

「前回push時との差分」を計算するには、今回のpushより前のHEAD SHAをどこかに覚えておく必要がある。

## 決定

**pushのたびに`.claude/state/review-links/<safeBranch>.txt`へ現在のHEAD SHAを保存し、
次回push時にそのファイルを読んで「前回push時のSHA」として使う。** ファイルが存在しなければ
「このブランチでの初回push」とみなし、前回pushとの差分・コメント一覧の2リンクは省略する
（＝1回目のpushでは「MRへのリンク」「defaultとの差分リンク」の2つのみを含める）。

- 状態ファイルは`usage/`配下の対応工数レポート用状態と同じ「ブランチ横断・非コミット対象の
  ローカル作業状態」だが、`post-push-usage-report.sh`とは責務が異なる別ファイル
  （ヘッダコメントに明記済みの既存方針）であるため、状態の置き場所も混在させず
  `.claude/state/review-links/`という別ディレクトリに分離した。
- URL組み立てそのものは`Provider.sh`経由の`get_mr_diff_url` / `get_mr_diff_since_url`
  （GitHub: `github_get_mr_diff_url` / `github_get_mr_diff_since_url`、GitLab側も対称に実装）
  という純粋関数（`gh`/`glab`呼び出しを伴わない）に切り出し、`tests/test_vcs_provider.sh`で
  単体テストできるようにした。
- 「コメント一覧（MR画面）」へのリンクは、GitHubのPRデフォルトビュー（Conversationタブ）が
  そのままコメント一覧を兼ねるため、追加のURL組み立ては行わずMRへのリンクをそのまま再掲する形にした。

### 追記（同issue内フォローアップ: gh/glabでURLの正確性を担保する）

初版では`get_mr_diff_url`/`get_mr_diff_since_url`が、MR/PRのURL文字列（`get_mr_for_branch`の
`url`）へ`/files`（GitHub）・`/diffs`（GitLab）等のsuffixを推測で付け足す実装だった。レビューで
「gh/glabを使ってURLの正確性を担保できないか」という指摘を受け、以下へ変更した。

**`get_repo_url`（`gh repo view --json url` / `glab repo view --output json`の`.web_url`）で
取得したリポジトリの正規URLを土台に、GitHub/GitLabいずれも持つ汎用の「Compare」ページ
（`/compare/<from>...<to>` / `/-/compare/<from>...<to>`）を組み立てる方式に変更する。**
`from`/`to`にはブランチ名・SHAのどちらも指定できるため、「defaultブランチとの差分」
（`baseBranch`/`headBranch`というブランチ名同士）・「前回pushとの差分」（SHA同士）の両方を、
同じ`github_get_compare_url` / `gitlab_get_compare_url`という共通ヘルパーで組み立てられる
（`get_mr_diff_url`/`get_mr_diff_since_url`はこのヘルパーを呼ぶ薄いラッパーになった）。

「Compare」ページはPR/MR作成前から存在するリポジトリの汎用機能であり、PRの個別サブタブ
（当初案の「Files changed」タブが使う`/files/<from>..<to>`というコミット範囲URL）より
存在が安定していると考えられる。ただし、いずれの案もこのセッションではブラウザでの実地表示
確認まではできていない（「未決定事項・懸念点」に記載済み）。

## 却下した案

- **GitHub/GitLab APIでコミット履歴を都度取得し「前回pushの区切り」を推定する**:
  `gh api` でPRのコミット一覧を取得し、直近のpushイベントの境界を判定する方法も検討したが、
  GitHubのPRコミット一覧APIはpush単位の区切りを直接提供しない（force-pushやsquashで
  コミット数と実際のpush回数が一致しない）ため、ローカルで「前回この hook が処理したSHA」を
  素直に覚えておく方が確実でシンプルと判断した。対応工数レポート機能
  （`sinceLastPush`）も同種の「前回pushからの差分」をローカル状態で扱っており、設計として一貫する。
- **対応工数レポートの状態ファイル（`usage/state/<branch>.json`）に相乗りする**:
  同じ「前回pushからの差分」という性質を持つため一見自然に見えるが、
  `post-push-compact-prompt.sh`のヘッダコメントが「`post-push-usage-report.sh`と責務を分離した
  別スクリプト」と明記している設計方針と矛盾する。使用量集計の状態スキーマに
  無関係なフィールド（前回pushのSHA）を追加すると、対応工数レポート側のテスト・スキーマ変更の
  影響範囲が不必要に広がるため見送った。
- **毎回すべてのリンク（前回pushとの差分・コメント一覧を含む）を出す**:
  受け入れ条件が「レビュー指摘対応push時のみ」の追加を明示しているため踏襲しなかった。加えて、
  初回pushでは「前回pushとの差分」が意味を持たない（比較対象が無い）ため、常時表示は
  かえって紛らわしいと判断した。
- **（初版で採用したが同issue内フォローアップで撤回）MR/PRのURL文字列へsuffixを推測で付け足す**:
  `<mrUrl>/files`（GitHub）・`<mrUrl>/diffs`（GitLab）、コミット範囲は`<mrUrl>/files/<from>..<to>`
  （GitHub）・`<mrUrl>/diffs?start_sha=<from>`（GitLab）という実装だった。追加の`gh`/`glab`呼び出しが
  不要というシンプルさはあったが、「gh/glabでURLの正確性を担保したい」という指摘のとおり、
  PR個別のサブタブが使う内部的なURL形式への依存度が高く、確度の面で弱かった。上記「追記」の
  Compareページ方式へ変更した。
