---
title: worklog 20260820 answer-talkerスキルの構成とインターフェース push7
type: log
description: issue #1 のフェーズ3〈設計〉の実施ログ。対象リポジトリの解決がcwd依存であることの発見と、D1〜D7の決定過程。push7。
tags: [worklog, answer-talker, 設計]
keywords: [worklog, GH_REPO, GITLAB_REPO, cwd, 対象リポジトリ, get_mr_changed_files, 除外語, 検証環境, 訂正]
---

# worklog: 【設計】answer-talkerスキルの構成とインターフェース

対象: D1〜D7の設計の実施（2026-08-20）。
全体作業計画: `plans/bubbly-exploring-biscuit.md`
個別作業計画: `plans/【設計】answer-talkerスキルの構成とインターフェース.md`
push回数: 7

## 試したこと

- D2の設計中に「投稿は `add_mr_inline_comments` をそのまま使う」と書こうとして、
  `Gitlab.sh` の実装を読み返したところ `glab api "projects/:id/..."` という書き方に気づいた。
  **`:id` はどこから解決されるのか**を確かめるため、次を実行した。
  - `gh api "repos/{owner}/{repo}"` → cwdのリポジトリ（`yuki-matsu783/ans-talker`）が返る
  - `glab api "projects/:id"`（cwdはGitHubリポジトリ）→
    `Unable to expand placeholder in path: none of the git remotes configured...` で失敗
  - `glab api "projects/root%2Fissue45-verify/merge_requests/3/diffs"` → URLエンコードした
    完全パスなら別プロジェクトを直接叩ける
  - `glab api --help` のフラグ一覧 → **`-R/--repo` は無い**（`gh` と違う）
  - `GH_REPO="cli/cli" gh api "repos/{owner}/{repo}"` → `cli/cli` が返る
  - `GITLAB_REPO="root/issue45-verify" glab api "projects/:id"` → 該当プロジェクトが返る。
    別の値（`root/issue127-verify`）でも切り替わることを確認
- `get_provider` の実装を読み、`_PROVIDER_CACHE` が遅延初期化のグローバルであることを確認した
  （先に値を入れておけば `git remote` を見に行かない）。
- 除外語リストの持ち方（未決定事項#5）を、スクリプト内定数／外部ファイル／言語ごとの3案で比較した。
- 検証環境の題材を、言語の知識が評価に混ざらないよう極小のbash CLIに決めた。

## うまくいったこと

- **環境変数（`GH_REPO` / `GITLAB_REPO`）で解決できると分かったのが最大の収穫。**
  これなら `Provider.sh` / `Github.sh` / `Gitlab.sh` を1行も変えずに別リポジトリを対象にできる。
  引数を足す案だと `adversarial-review` の呼び出しまで全部直すことになっていた。
  **既存の共通コードに触らずに済む解が見つかったので、リグレッションのリスクがほぼ無い。**
- `_PROVIDER_CACHE` が遅延初期化だったおかげで、プロバイダの上書きも既存コードに手を入れずにできる。
  「先に代入しておく」だけで済む。
- 除外語を**スクリプト内の定数**に決めた理由が、比較して初めてはっきりした。除外語は
  「言語のキーワード＋ごく一般的な英単語」で**演習課題ごとに変わらない**。外部ファイルにすると
  「利用者がファイルを用意しないと動かない」という失敗経路が増えるだけだった。
- D4の観点表で、「指摘しない」を**各行の列**にできた。当初は見出しの下に注意書きとして書こうと
  していたが、それだと読み飛ばされる。行ごとに並べると、指摘と非指摘が必ず対で目に入る。
- 識別子を `snake_case` で分割しない、と決められた。分割すると `user` のような一般語が禁止語に
  入り、誤検知に倒す方針と相まって**指摘が全滅する**。D5は「厳しく倒す」方針だが、
  どこを厳しくしないかも同時に決める必要があると気づけた。

## ダメだったこと

- **調査結果（論点1）に誤りがあった。**「`add_mr_inline_comments` はMR番号を引数で取る設計なので、
  他人のMRにもそのまま使える」と書いていたが、リポジトリはcwdから解決されるため、MR番号だけでは
  対象が決まらない。関数のシグネチャ（引数に何を取るか）だけを見て「他人のMRにも使える」と
  判断したのが原因で、**その関数が内部で何に依存しているかを読んでいなかった**。
  設計の段階で気づけたので実装への影響は無いが、調査結果のほうを訂正した
  （report冒頭に「0. 調査結果の訂正」節を新設）。
- この誤りは、**issueの「現状」に書かれていた「`get_mr_for_branch` はブランチ→MR番号の逆方向」と
  いう記述に引きずられた**面もある。逆方向の関数を足せば済むと考えてしまい、
  「そもそもリポジトリはどう決まるのか」を問わなかった。

## 次の一歩

- flow-id 3-7: `commit` スキル経由でコミットし、リモートへ反映してレビュー依頼を出す。
- 合意後、`plans/【実装】【テスト】〜.md` を作成してフェーズ3の2セット目へ入る。
- 新たな未決定事項3件（`use_target_repo` の置き場所／除外語の初期内容／検証セットアップを
  `.claude/` に残すか）は、実装時と flow-id 4-1 で決める。
