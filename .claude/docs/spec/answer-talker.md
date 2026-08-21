---
title: 演習MRの正解照合レビュー（answer-talker）
type: spec
description: 開発演習のMRを別途用意された正解ソースと照合し、正解を転記せずに概念的な指摘だけを返してMRへ投稿する answer-talker 機構の仕様
tags: [answer-talker, review, 演習, spec]
keywords: [正解ソース, ネタバレ検査, 別解, findings, use_target_repo, get_mr_changed_files, 対応付け, 投稿ラベル, shallow clone, 選別表]
---

# 演習MRの正解照合レビュー（answer-talker）

対象: `.claude/skills/answer-talker/SKILL.md`, `.claude/agents/answer-talker-reviewer.md`,
`.claude/scripts/src/answer-talker-reference.sh`, `.claude/scripts/src/answer-talker-map.sh`,
`.claude/scripts/src/answer-talker-spoiler-check.sh`,
`.claude/scripts/src/vcs/`（`use_target_repo` / `get_mr_changed_files` と、投稿系関数のラベル引数）

## 背景・目的

issue #1。開発演習では、受講者が初期状態から実装を進めたMRを講師がレビューする。このとき手元には
別途「正解ソース」があるが、**正解をそのまま提示してしまうと演習にならない**。求められているのは、
分割方針・責務の置き方・命名やルールの考え方が正解と同じ方向へ向かうような**概念的な指摘**である。

本issue以前、これを支える仕組みは無かった。

- `adversarial-review` は「壊れるとしたらどこか」を探すレビューで、**参照実装との照合という観点を
  持たない**。サブエージェントにも正解ソースは渡されない。
- レビュー観点の出どころである `REVIEW-POINTS.md` は本リポジトリの運用規約向けで、演習課題ごとの
  設計方針は表現できない。
- `Provider.sh` に **MR/PR番号を起点にdiffを取得する関数が無かった**（`get_mr_for_branch` は
  ブランチ→MR番号の逆方向、`get_mr_diff_url` はURLを組み立てるだけ）。
- 正解ソースを別リポジトリのcloneやローカルディレクトリから取り込む手段が無かった。

結果として演習MRのレビューは毎回その場の判断になり、指摘の粒度とネタバレの度合いが実行ごとに
ぶれていた。**正解を見て、正解を書かない**——この非対称を機構として固定するのが本仕様である。

## 仕様

### 全体像（責務分離）

```
人間 → /answer-talker <MR番号> --reference <URL|パス>（スキル）
          ├ 手順0  経路確認（get_vcs_access_mode）
          ├ 手順1  引数解釈と対象の明示
          ├ 手順2  use_target_repo → get_mr_changed_files（Provider.sh）
          ├ 手順3  正解ソースの取得（answer-talker-reference.sh resolve）
          ├ 手順4  受講者と正解のファイル対応付け（answer-talker-map.sh）
          ├ 手順5  投稿可否の確認（AskUserQuestion、1回だけ）
          ├ 手順6  サブエージェント起動 ─→ answer-talker-reviewer（読み取り専用）
          │                                  └ findings JSON を返すだけ
          ├ 手順7  ネタバレ検査（answer-talker-spoiler-check.sh）
          ├ 手順8  確度×重大度で投稿／報告を振り分け
          ├ 手順9  add_mr_inline_comments（Provider.sh）で投稿。**ラベルは `演習レビュー`**
          ├ 手順10 後始末（answer-talker-reference.sh cleanup。失敗経路でも通す）
          └ 手順11 報告
```

`adversarial-review` と同じく、**サブエージェントは投稿しない**。投稿は呼び出し元（スキル）の
責務とし、承認の所在を1箇所へ寄せる。サブエージェントには `Read, Grep, Glob, Bash` しか与えない。

### 起動

```
/answer-talker <MR番号> --reference <URL|パス> [--ref <ブランチ/タグ>] [--repo <対象>]
```

| 引数 | 内容 |
|---|---|
| `<MR番号>` | レビュー対象のMR/PR番号（GitLabはiid） |
| `--reference` | 正解ソース。**URL**（shallow cloneする）または**ローカルディレクトリ**（cloneしない） |
| `--ref` | URLを指定した場合のブランチ・タグ（省略時はdefault） |
| `--repo` | 対象MRのあるリポジトリ。**省略時はカレントディレクトリのリポジトリ** |

**`--repo` は、cwdと別のサービス（GitHub↔GitLab）を対象にするならURLで渡す。** `owner/repo`
形式はプロバイダを判定する材料を持たないため、`use_target_repo` は cwd のリモートのプロバイダへ
フォールバックする。GitHubのリポジトリから作業しながらGitLabのMRをスラッグで指定すると、
GitHubのAPIを叩いて `Not Found (HTTP 404)` になる（検証中に実際に踏んだ）。self-hosted GitLabの
ホスト・ポートもURLからしか決まらない。

### `adversarial-review` との違い

| | `adversarial-review` | `answer-talker` |
|---|---|---|
| 対象 | **自分のブランチ**のMR（`get_mr_for_branch`） | **引数で受けた他人のMR番号**（別リポジトリでもよい） |
| 観点の出どころ | `REVIEW-POINTS.md` | **正解ソースそのもの** |
| 探すもの | 「この変更が壊れるとしたらどこか」 | 「設計の考え方が正解と同じ方向を向いているか」 |
| 投稿前の検査 | なし | **ネタバレ検査**（正解の転記を落とす） |
| 実施回数の上限 | 各フェーズ最大3回（機械的に強制） | **なし**（DDR 0058） |
| 投稿ラベル | `敵対的レビュー`（既定値） | `演習レビュー`（第3引数で指定） |

**両者は投稿経路を共有する**（`add_mr_inline_comments` とプロバイダ実装）。文言だけが違うため、
共有関数へ省略可能なラベル引数を足して切り替える（DDR 0059）。

### 対象リポジトリの切り替え（`use_target_repo`）

`gh` / `glab` は対象リポジトリを**cwdのgitリモートから解決する**ため、MR番号だけでは
「どのリポジトリのMRか」が決まらない。`use_target_repo` は `_PROVIDER_CACHE` を設定し、
`GH_REPO` / `GITLAB_REPO`（必要なら `GITLAB_HOST`）を export することでこれを上書きする。

**環境変数方式を採ったことで、既存のProvider関数を1つも変更せずに別リポジトリを対象にできる。**
引数を足す方式だと `adversarial-review` の呼び出しまで波及する。

- **プロセス内の状態（グローバル変数と環境変数）を変える関数である。** 1回の実行で1つのMRしか
  扱わない前提のため、解除・切り戻しは用意しない。
- `glab --hostname` はポート付きホストを受け付けない（`invalid hostname` で失敗する）。
  環境変数 `GITLAB_HOST` なら self-hosted + ポートの構成でも通る。

### 差分の取得（`get_mr_changed_files`）

MR/PR番号から、変更ファイルの一覧と差分本文を1つのJSONで返す。GitHubは `pulls/<n>/files`、
GitLabは `/merge_requests/:iid/diffs`（新API）を使う。

**両プロバイダの返却はキー集合が完全に一致する。**

| 階層 | キー |
|---|---|
| トップ | `base`, `head`, `headSha`, `totalFiles`, `truncatedFiles`, `capped`, `files` |
| `files[]` | `path`, `oldPath`, `status`, `additions`, `deletions`, `patch`, `truncated` |

- `status` は `added` / `removed` / `renamed` / `modified` の4語へ正規化する。
- **GitLabはファイル単位の変更行数を返さない**ため、diff本文の行頭を数えて
  `additions` / `deletions` を算出する。
- `truncatedFiles`（差分を読めなかったファイル数）と `capped`（GitHubの3000ファイル上限）は、
  **無言で切り捨てず必ず報告する**。GitLab側は各ファイルの `too_large` / `collapsed` から立てる。
- 名前を `get_mr_diff` にしない。既存の `get_mr_diff_url` / `get_mr_diff_since_url` と
  「似た名前で中身が違う3兄弟」になるため、実体に合わせて `changed_files` とした。
- **呼び出し側は必ずファイルへリダイレクトし、コマンド置換 `$(...)` で受けない。** 差分のサイズは
  対象MRの規模に比例して無制限に大きくなり、Windowsのコマンドライン長上限（実測で約32KB）に
  容易に達する（`.claude/rules/shell-script-style.md`）。

`/changes`（旧API）を使わないのは、切り捨てがMR全体単位（`overflow`）でページングも無いため。

### 正解ソースの取得（`answer-talker-reference.sh`）

`resolve` / `cleanup` の2サブコマンドを持つ。後始末を手順の明示的な1ステップにできるため、
`trap` だけに頼らない形にしている。

| サブコマンド | 返却 |
|---|---|
| `resolve --reference <URL\|パス> [--ref <ブランチ/タグ>]` | `{"kind":"url"\|"local","root":"<絶対パス>","cleanup":true\|false,"tmpdir":"…"\|null}` |
| `cleanup --tmpdir <パス>` | `{"removed":true\|false,"reason":"…"}` |

- **ローカルパスはcloneしない**（DDR 0060）。読み取り専用でそのまま使い、`cleanup:false` を返す。
- URLのみ `git clone --depth 1 --single-branch --no-tags` する。
- `cleanup` は**冪等**で、`resolve` が一時ディレクトリ直下へ置いたマーカーファイル
  `.answer-talker-reference` がある場合しか削除しない。渡された任意のパスを削除しない安全弁。
- `clone_reference` は `GIT_TERMINAL_PROMPT=0` / `GCM_INTERACTIVE=never` を export する。
  **非公開リポジトリのURLを渡すとgitが資格情報の入力を待って固まる**ことを実測したため、
  待たされる代わりに即座に失敗させる。認証自体はこのスクリプトの責務ではない。
- cloneの失敗を**パイプで潰さない**（`git clone … | tail` はパイプ右辺の終了コードを返すため、
  cloneが fatal で終わっていても成功に見える）。

### ファイルの対応付け（`answer-talker-map.sh`）

受講者の変更ファイルと正解側ファイルを、**同一パス → ファイル名（basename）が一意に一致**の順で
突き合わせ、`matched` / `referenceOnly` / `submissionOnly` の3分類を返す。
`status == "removed"` のファイルは対象から除外する。

**意味づけはここでは行わない。** `referenceOnly`（正解側にしかないファイル）は「受講者がまだ
作っていない分割単位」の候補になるが、**別解の可能性がある**ため、判断はサブエージェントに委ねる。

### レビューの観点（`answer-talker-reviewer`）

観点表は**「指摘する」「指摘しない」の2列**を各行に併記する。「正解と違う」だけでは指摘の理由に
ならないことを、表の構造そのもので示すためである。

観点は4つ: 責務の分割単位／層と依存の向き／命名・配置・エラー処理・設定の持ち方の一貫性／
正解が避けている作り。

**出力規約（絶対）**: 正解のコード片・正解にしか存在しない識別子を指摘本文へ書かない。
「正解ではこうなっている」ではなく「この処理はどういう単位で分けられるか」の形で書く。

### ネタバレ検査（`answer-talker-spoiler-check.sh`）

サブエージェント側の規約だけでは、構造の転記（「A/B/Cの3つに分ける」）を防げない。
**二段構えで初めて機能する**ため、この手順は飛ばさない。

禁止語 = 正解の識別子 − 受講者diffに現れる語 − 除外語（スクリプト内の定数）− 3文字以下。
findings本文を `[^A-Za-z0-9_]` で区切ってトークン化し、禁止語との一致を見る。

- **識別子は分割しない**。分割すると一般語に当たって誤検知が爆発する。
- **誤検知の側へ倒す**（DDR 0061）。正当な指摘を落としてでも転記の見逃しを避ける。
- 返却は `{"kept":N,"dropped":M,"drops":[{"title":…,"words":[…]}]}`。
  **落とした件数と反応した語を必ず報告する。** この向きの失敗は「指摘が落ちすぎて実質何も
  出ない」形になるため、可視化しないと気づけない。
- `kept` が0なら投稿しない（空のレビューを投稿しない）。

### 投稿の選別と上限

`adversarial-review` と同じ確度×重大度の表で振り分ける。

| 確度 \ 重大度 | blocker | major | minor | nit |
|---|---|---|---|---|
| high | 投稿 | 投稿 | 投稿 | 報告 |
| medium | 投稿 | 投稿 | 報告 | 報告 |
| low | 報告 | 報告 | 報告 | 報告 |

**1回あたりの投稿上限は10件。** 受講者が一度に扱える量を超えると、結局どれも読まれない。

### 承認モデル

レビューを実行する**前**に `AskUserQuestion` で1回だけ確認する。**承認後は指摘ごとの個別承認を
求めない。** 提出済みレビューは削除できないため、「投稿してから取り消す」前提の設計にできない。
だからこそ承認は投稿前に1回へ集約する。

### CLI不在時（`get_vcs_access_mode` が `mcp`）

GitHubのみ。GitLabは対象外（DDR 0027）。WebFetch・curlへはフォールバックしない。

| 手順 | 読み替え |
|---|---|
| 手順2 | `get_mr_changed_files` → `mcp__github__pull_request_read`（`method="get_files"` / `method="get"`） |
| 手順9 | `add_mr_inline_comments` → `mcp__github__pull_request_review_write`（`create` → `add_comment_to_pending_review` → **必ず `submit_pending`**） |
| 手順3・4・7 | 読み替え不要（ローカルのスクリプトのみ） |

## 影響範囲

- **既存の呼び出しは変わらない。** `Provider.sh` / `Github.sh` / `Gitlab.sh` の投稿系5関数へ
  **省略可能な**ラベル引数を足しただけで、既定値は従来の `敵対的レビュー` のままである
  （GitHub・GitLab双方で既定の出力が従来と一致することを確認済み）。
- `Provider.sh` へ `use_target_repo` / `get_mr_changed_files` を**追加**した。既存関数の変更は無い。
- `HANDOFF.md` の進捗表・flow-idは**増えない**。`adversarial-review` と同じく、フローに載らない
  並行手順である（`.claude/skills/issue-mr-flow/SKILL.md`）。

## 設定項目

専用の設定ファイルは持たない。除外語リストは `answer-talker-spoiler-check.sh` 内の定数
（`ATR_STOPWORDS`）、一時ディレクトリのマーカー名は `answer-talker-reference.sh` 内の定数
（`ATR_MARKER`）として持つ。

## 検証の再現手順の要点

**演習の題材はこのリポジトリに置かない**（plugin配布単位である `.claude/` にサンプルを混ぜない）。
検証用のセットアップスクリプトも残していない。再現に必要な情報を以下に記す。

- **題材**: 極小のbash CLI（ファイルを読む → 正規表現で行を絞る → 接頭辞を付けて出力する）。
  正解は3つの関心をそれぞれ1ファイル1関数に分け、`main.sh` がパイプで繋ぐ。
  演習側の初期状態は骨格のみの `main.sh` 1ファイル。
- **ブランチ・コミットの作成には GitLab の Commits API を使う**
  （`POST /projects/:id/repository/commits`。`create`/`update`/`delete`/`move` のアクション）。
  ローカルGitLabへは `git` で到達できなかったため（HTTP cloneは
  `Cannot prompt because user interactivity has been disabled.`、SSHは `Permission denied
  (publickey)` で、`glab api user/keys` も空）。**代替手段が無いことを確認したうえでの採用**である。
- **検証パターンは5軸**: 受講者の実装（分割不足／別解／重複／余分な抽象化／ほぼ正解）／
  正解ソースの形態（URL／ローカルgit／素のディレクトリ）／diffの内容（削除／リネーム／新規追加）／
  ネタバレ検査（転記あり／一般語のみ）／投稿（実投稿／0件）。
- **「指摘しないことを確かめる」パターンを必ず含める。** 指摘が出ることだけを確かめる検証は、
  過剰に指摘するスキルを合格させてしまう。
- **別解を潰していないかの判定には、「責務の分割は正解と同等だが、ファイルには分けていない」
  パターンが有効である。** `referenceOnly` に正解側の全ファイルが並ぶため、正解へ同調する圧力が
  最も強くかかる条件になる。ここでファイル分割を促す指摘が出なければ、
  **ファイル構成ではなく責務で判断している**と言える。

## 未決定事項・懸念点

- **上限到達時の挙動は実データで未確認**。GitHubの3000ファイル上限・`patch` 省略、GitLabの
  `too_large` / `collapsed` が立つ規模のMRは用意していない。いずれも「検知して報告する」形で
  実装済みだが、実際にその規模で動かした証跡は無い。
- **サブエージェントは正解を絶対の基準とせず、一般的な設計原則でも判断する。** そのため
  **正解と同じ形にしても指摘が0件になるとは限らない**（検証では、正解自身にも当てはまる性質の
  指摘が出た）。重大度が低く投稿されないため実害は無いが、「正解に一致させれば無指摘になる」
  という期待は成り立たない。
- **凝集度の低い別解には強めの指摘が出る。** 入力と出力を1ファイルに束ねる流儀を採った場合、
  major/high の指摘が投稿されうる。同調圧力ではなく凝集度への指摘として妥当と判断しているが
  （上記の切り分けによる）、受講者の流儀によっては厳しく映る。
