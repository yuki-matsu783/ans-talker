---
title: 0025. frontmatterのindex.jsonlをGit管理から外しSessionStart hookで生成する
type: ddr
description: index.jsonlのGit管理除外とSessionStart hookでの自動再生成方式を採用し、create-commit.sh組み込み・専用hook新設・DDR0021却下案4の再評価を検討した理由
tags: [ddr, extract-frontmatter, index-jsonl, session-start, gitignore]
keywords: [index.jsonl, gitignore, SessionStart, create-commit, git-rm-cached, mtime, flow-id5-1, fail-open]
---

# 0025. frontmatterのindex.jsonlをGit管理から外しSessionStart hookで生成する

issue #36。仕様は [.claude/docs/spec/extract-frontmatter.md](../spec/extract-frontmatter.md) を参照。

## 背景

`.claude/scripts/src/extract-frontmatter.sh` が生成する `index.jsonl`（frontmatterの機械可読
インデックス、リポジトリ内15箇所）は、これまでGit管理下に置かれ「frontmatterを更新したら手動で
再生成しコミットに含める」運用に依存していた。`.claude/docs/spec/extract-frontmatter.md` の
未決定事項にも既知の課題として記載済みだったとおり、この運用には2つの構造的問題があった。

1. **マージconflict**: 複数ブランチが並行して別々のmarkdownのfrontmatterを編集すると、生成物
   である `index.jsonl` の近接行同士が競合する。
2. **流し忘れ事故**: 再生成をcommit前に手動で実行し忘れると、後から「`index.jsonl` だけを直す
   追加コミット」が発生する。issue #11対応時にも「HANDOFF更新 → index再生成 → `index.jsonl`
   だけを直す追加コミット」が複数回発生していた。加えて `.claude/skills/issue-mr-flow/SKILL.md`
   の flow-id 5-1 では `plans/index.jsonl` を個別削除して再生成する特殊対応まで運用に組み込まれて
   いた（`extract-frontmatter.sh` は「markdownが直下に存在するディレクトリ」のみを出力対象にする
   ため、`plans/*.md` を全削除しても `plans/index.jsonl` 自体は再生成の対象から外れ、削除済みの
   計画ファイルを指したまま陳腐化して残ってしまうため）。

## 決定

**`index.jsonl` を `.gitignore` 対象化してGit管理から外し、生成物として扱う。** 自動再生成は
`.claude/hooks/session-start.sh`（SessionStart hook）でセッション開始のたびに実行する。

1. **`.gitignore` に `**/index.jsonl` を追加**し、既存15箇所の `index.jsonl` を
   `git rm --cached` でGit管理から除外する（ワーキングツリー上のファイル自体は削除しない）。
   これにより、マージconflict・流し忘れという本issueの核心問題は、`index.jsonl` がGitの差分・
   マージ対象から完全に外れることで構造的に解消される。
2. **自動再生成は `.claude/hooks/session-start.sh` に独立した関数
   （`regenerate_frontmatter_index`）として実装し、セッション開始のたびに
   `extract-frontmatter.sh` をリポジトリルートに対して1回実行する。** 標準出力・標準エラー出力は
   `/dev/null` へ捨て、hookの標準出力契約（SessionStart用のJSON1行のみ）を壊さない。失敗しても
   セッション開始・既存のコンテキスト注入（issue/PR情報）をブロックしない、非侵襲的・fail-open
   設計とする（`session-start.sh` が既に持つ設計方針をそのまま踏襲する）。
3. Git管理から外れたことで、flow-id 5-1の「`plans/index.jsonl` を個別削除し再生成する」という
   特殊対応は完全に不要になる。SKILL.md・docs-workflow.mdから該当記述を除去する。

**トレードオフ**: Git管理から外れた時点で本issueの核心問題は解消済みであり、以降の自動再生成は
「ローカルの `index.jsonl` を検索・参照用途で妥当に新鮮に保つ」ための利便性機能に過ぎない。
同一セッション内で複数回frontmatterを編集した場合、次のセッション開始まで `index.jsonl` は
更新されない。ただしこれはGit管理外の派生ファイルの鮮度の問題に過ぎず、必要なら
`bash .claude/scripts/src/extract-frontmatter.sh .` を手動実行すればよい。

## 却下した案

### 1. `create-commit.sh`（全commitが経由する中核スクリプト）への組み込み

commitのたびに再生成すれば「`index.jsonl` の内容がcommit時点のmarkdownと一致している」という
より強い保証が得られる。しかし、`create-commit.sh` は「`git add`/`git commit` のみを行う薄い
ラッパー」という既存方針を持ち、これを変更すると全commitの実行時間に影響を与える
（`extract-frontmatter.sh` は差分が無ければ2秒未満だが、全commitで毎回発生する遅延になる）。
何より、Git管理から外れた時点でマージconflict・流し忘れという核心問題は既に解消されており、
commit経路のような機構的強制までは不要と判断した。

### 2. 新規の独立pre-commit hookとしての実装

`create-commit.sh` 自体は変更せずに済むが、`.claude/hooks/session-start.sh` が既に
「非侵襲的（失敗してもブロックしない）」という設計方針を持っており、同じ方針をそのまま踏襲できる
`session-start.sh` への追記のほうが、新規hookファイルを増やすより実装・レビューコストが小さい。

### 3. DDR 0021却下案4（markdownが無くなったディレクトリの `index.jsonl` をスクリプトが自動削除する）の再評価

却下を維持する。0021時点の却下理由は「`index.jsonl` がGit管理下にあるため、誤ってスコープ外まで
削除するとGit履歴からの復旧に頼ることになり被害が大きい」という趣旨だったが、本issueでGit管理から
外れたことで「誤削除してもGit履歴に戻れない」という前提も変わった。それでもなお却下を維持する
理由は以下の2点。

- 自動削除は、スクリプトの実行のたびに「意図しないディレクトリの `index.jsonl` を静かに消す」
  副作用を持ち込むことに変わりはなく、Git管理の有無に関わらず「スコープ外のファイルを触らない」
  という走査スクリプトの安全設計原則に反する。
- Git管理から外れたことで flow-id 5-1 の特殊対応（`plans/index.jsonl` の個別削除）自体が
  不要になったため、却下案4が本来解決しようとしていた問題（`plans/index.jsonl` の陳腐化放置）の
  実害自体がなくなっている。

## 補足: 反映計画の分割（同issue内フォローアップ）

本issueの反映（flow-id 4系）では、当初「設計反映」（本DDRの作成・spec更新）と「AIアセット反映」
（SKILL.md・docs-workflow.mdの更新）を1つの計画ファイルに併記していたが、レビューで
「タスクの種類や人間の認知の種類が大きく異なるため、基本的に別タイミングで進めてほしい」との
指摘を受けた。`.claude/skills/issue-mr-flow/SKILL.md`「種別を複数併記する場合／分ける場合」の
判断基準（フェーズごとに個別の合意・レビューを挟みたい場合は分ける）に従い、計画ファイルを
`plans/【設計反映】〜.md` / `plans/【AIアセット反映】〜.md` の2つへ分割し、実施タイミングも
分離した（設計反映を先に完了・レビューしてからAIアセット反映へ着手）。
