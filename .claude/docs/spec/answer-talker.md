---
title: 演習MRの正解照合レビュー（answer-talker）
type: spec
description: 開発演習のMRを別途用意された正解ソースと照合し、正解を転記せずに概念的な指摘だけを返してMRへ投稿する answer-talker 機構の仕様
tags: [answer-talker, review, 演習, spec]
keywords: [正解ソース, 受講者ソース, ネタバレ検査, 別解, findings, use_target_repo, get_mr_changed_files, 3段の縮退, degraded, 対応付け, 投稿ラベル, 選別表]
---

# 演習MRの正解照合レビュー（answer-talker）

対象: `.claude/skills/answer-talker/SKILL.md`, `.claude/agents/answer-talker-reviewer.md`,
`.claude/scripts/src/answer-talker-reference.sh`,
`.claude/scripts/src/answer-talker-submission.sh`, `.claude/scripts/src/answer-talker-map.sh`,
`.claude/scripts/src/answer-talker-spoiler-check.sh`,
`.claude/scripts/src/vcs/`（`use_target_repo` / `get_mr_changed_files` / 受講者ソース取得の5関数と、
投稿系関数のラベル引数）

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

issue #6 で、**もう1つの非対称**を解消した。issue #1 の実装では、正解ソースは `reference.root`
配下を全ファイル読めるのに対し、**受講者側は差分のhunkしか渡していなかった**。このスキルが観る
「責務の分割単位」「層と依存の向き」はリポジトリ全体の構造に関する判断であり、hunkだけでは
(1) 今回変更していないファイルに責務が置かれている場合、(2) 既存ファイルを一部だけ変更したMR、
のいずれも見えない。issue #1 の検証でパターン②（別解）を判定できたのは、対象ファイルが新規追加で
hunkに全文が入っていたためであり、**たまたま成立していた**。

加えて `.claude/agents/answer-talker-reviewer.md` の「読んでよいもの」には「受講者の変更ファイルの
中身」と書かれていたが、それは渡していなかった。**渡していないものを「読んでよい」と書いている**
定義と実装の食い違いであり、次に読む人を確実に誤解させる状態だった。受講者ソース全体を渡すことで
実態を定義へ合わせ、渡せなかった場合は `degraded` フラグで定義側の記述を機械的に切り替える。

## 仕様

### 全体像（責務分離）

```
人間 → /answer-talker <MR番号> --reference <URL|パス>（スキル）
          ├ 手順0  経路確認（get_vcs_access_mode）
          ├ 手順1  引数解釈と対象の明示
          ├ 手順2  use_target_repo → get_mr_changed_files（Provider.sh）
          ├ 手順3  正解ソースの取得（answer-talker-reference.sh resolve）
          ├ 手順3b 受講者ソースの取得（answer-talker-submission.sh resolve）─→ 3段の縮退
          ├ 手順4  受講者と正解のファイル対応付け（answer-talker-map.sh）
          ├ 手順5  投稿可否の確認（AskUserQuestion、1回だけ）
          ├ 手順6  サブエージェント起動 ─→ answer-talker-reviewer（読み取り専用）
          │                                  └ findings JSON を返すだけ
          ├ 手順7  ネタバレ検査（answer-talker-spoiler-check.sh）
          ├ 手順8  確度×重大度で投稿／報告を振り分け
          ├ 手順9  add_mr_inline_comments（Provider.sh）で投稿。**ラベルは `演習レビュー`**
          ├ 手順10 後始末（reference.sh cleanup / submission.sh cleanup。失敗経路でも通す）
          └ 手順11 報告
```

**issue #6 で追加した受講者ソースの取得は `手順3b` とし、既存の手順番号をずらしていない。**
番号をずらすと、issue #1 以来の記述・worklog・レビューコメントが指す手順番号が全て1つ分
食い違う。`3b` は正解ソースの取得（手順3）と対になる位置にあることも表す。

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

### 受講者ソースの取得（`answer-talker-submission.sh`）

issue #6 で追加した。`resolve` / `cleanup` の2サブコマンドを持ち、`answer-talker-reference.sh`
と同じ形（マーカーファイルによる安全弁つきの冪等な `cleanup`）にしてある。

```
resolve --mr <MR番号> [--repo <対象>]
        [--max-size-kb N] [--max-fetch-files N] [--max-list-files N] [--timeout-sec N]
cleanup --tmpdir <パス>
```

返却は**成功・縮退のどちらでもキー集合が同じ**である。

| キー | 内容 |
|---|---|
| `stage` | `1`（アーカイブ一括）/ `2`（ファイル単位API）/ `3`（hunkのみ＝縮退） |
| `root` | 展開先の絶対パス。段3では `null` |
| `tmpdir` | 後始末に渡すパス。段3では `null`（一時ディレクトリを作らずに終わった場合） |
| `fileCount` / `files` | 除外後のファイル一覧と件数。段3では `0` / `[]` |
| `truncated` | `--max-list-files` で一覧を切り詰めたか |
| `degraded` | 段3なら真 |
| `reason` | `stage-1` / `stage-2/size-unknown` / `fetch-failed/size-over-limit` / `head-sha-unavailable` 等。**成功時も入る**（どの段で取れたかを表す） |

#### 3段の縮退

| 段 | 手段 | 呼び出し回数 |
|---|---|---|
| 1 | **アーカイブ一括取得**（GitHub `tarball/{ref}` / GitLab `repository/archive.tar.gz?sha=`） | **1回**（ファイル数に依存しない） |
| 2 | ファイル単位API（`get_repo_tree` → `get_repo_file`） | ファイル数分（`--max-fetch-files` で上限） |
| 3 | 取得しない（hunkのみ。issue #6 以前の状態） | 0回 |

- **`git clone` は採らない**（DDR 0062）。アーカイブは `.git` を含まないため、「コミット
  メッセージから正解が読めてしまう」問題と `.git` 除去の手間が同時に消える。実測でも
  ファイル単位API（50ファイルで34〜51秒）に対し1〜2秒で済む。
- **段2を `git clone` ではなく同じAPI基盤にした**ことで、`GIT_ASKPASS` による資格情報の供給・
  `.git` の除去・clone URLの組み立て・非対話化の4つが設計から消えた。`mcp` 経路の受け皿も兼ねる。
- **段3は失敗ではない。** 終了コード0で `degraded:true` を返し、呼び出し側は処理を続ける。
- **リポジトリサイズが取得できない場合は段1を試す**（`reason` に `size-unknown` を併記）。
  取得できない環境で常に段2へ落ちると、上限のためにある判定が可用性を下げる方向に働く。
- **縮退したときの `reason` は「直接の原因」を主にする。** 段1・段2の両方が失敗した場合に
  `size-unknown` をそのまま返すと、報告（手順11）へ「サイズ不明」と出て調査が別方向を向く。
  `fetch-failed/size-unknown` のように、原因を先に置いて経緯を併記する。

#### 除外と一覧

- **除外は展開直後にツリーから実際に削除する形で一度だけ行う。** フィルタを各コンポーネントへ
  持たせると、一覧・`mapping`・禁止語のどれか1つが取りこぼしたときに気づけない。
- 除外対象は生成物・依存ディレクトリ（`ATR_EXCLUDE_DIRS`。`.git` を含む）と、**バイナリ**
  （NULバイトの有無で判定する）。
- 一覧は `--max-list-files`（既定500）で切り詰め、切り詰めたら `truncated` を真にする。
  **一覧を `jq --args` の位置引数で渡さない**（件数×パス長でコマンドライン長の上限に達し、
  jqの起動自体が `Argument list too long` で失敗する）。一時ファイルへ書き出して
  `--rawfile` で読ませる。この失敗は**展開が終わった後に起きるため `tmpdir` を返せず**、
  後始末の呼び先が失われる形になる。

### ファイルの対応付け（`answer-talker-map.sh`）

受講者側ファイルと正解側ファイルを、**同一パス → ファイル名（basename）が一意に一致**の順で
突き合わせ、`matched` / `referenceOnly` / `submissionOnly` の3分類を返す。
`status == "removed"` のファイルは対象から除外する。

**`--submission-root` を渡すと、左辺が「受講者の変更ファイル」から「受講者の全ファイル」へ広がる**
（issue #6）。これに伴い `submissionOnly` の意味が変わるため、**どちらで動いたかを `scope`
（`full` / `diff`）で返す**。

| `scope` | 左辺 | `submissionOnly` の意味 |
|---|---|---|
| `full` | 受講者の全ファイル | **正解に無いファイル** |
| `diff` | 受講者の変更ファイル | 今回のMRで追加したファイル |

サブエージェント定義はこの値を見て読み方を変える。**渡した／渡さないを自然言語で伝え直さない**
（伝達経路が2つあると食い違う）。

**意味づけはここでは行わない。** `referenceOnly`（正解側にしかないファイル）は「受講者がまだ
作っていない分割単位」の候補になるが、**別解の可能性がある**ため、判断はサブエージェントに委ねる。

### レビューの観点（`answer-talker-reviewer`）

観点表は**「指摘する」「指摘しない」の2列**を各行に併記する。「正解と違う」だけでは指摘の理由に
ならないことを、表の構造そのもので示すためである。

観点は4つ: 責務の分割単位／層と依存の向き／命名・配置・エラー処理・設定の持ち方の一貫性／
正解が避けている作り。

**出力規約（絶対）**: 正解のコード片・正解にしか存在しない識別子を指摘本文へ書かない。
「正解ではこうなっている」ではなく「この処理はどういう単位で分けられるか」の形で書く。

**受講者ソースは、渡すだけでは読まれない。** `reference.root` と同じくReadで任意に読む設計の
ため、定義側に**読む手順**を持たせている（手順1で全体像を掴み、`mapping.scope` が `full` の
ときは変更規模ではなくリポジトリ規模に比例して読む量が決まる、等）。呼び出し側がファイル一覧
（`submission.files`）を渡すことと**両方**行う。

#### `degraded` による分岐

**定義は `submission.degraded` の値だけで読み方を決める**（サブエージェント側で「渡されたか
どうか」を推測しない）。issue #6 が問題にしたのは「渡していないものを読んでよいと書いてある」
という定義と実態の不一致であり、**縮退時に同型の不一致を新たに作らないための機構**である。

| `degraded` | 読めるもの | 制限 |
|---|---|---|
| `false` | 受講者ソース全体＋`diff` の `patch` | なし |
| `true` | `diff` の `patch` のみ | **不在を根拠にした指摘を書かない**（「〜が無い」「どこにも定義されていない」）／責務の分割単位の指摘を `confidence: high` にしない／**指摘が減るのは正しい結果**であり、見えない分を推測で埋めない |

`degraded: true` のときに**受講者ソースを別の手段で取りに行くことを禁じる**（サブエージェントは
読み取り専用であり、取得の可否は呼び出し側が既に判定している）。

### ネタバレ検査（`answer-talker-spoiler-check.sh`）

サブエージェント側の規約だけでは、構造の転記（「A/B/Cの3つに分ける」）を防げない。
**二段構えで初めて機能する**ため、この手順は飛ばさない。

禁止語 = 正解の識別子 − **受講者側に現れる語** − 除外語（スクリプト内の定数）− 3文字以下。
findings本文を `[^A-Za-z0-9_]` で区切ってトークン化し、禁止語との一致を見る。

**差し引く材料は `--submission-root` の有無で変わる**（issue #6）。どちらで動いたかは
`materialScope`（`full` / `diff`）で返る。

| `materialScope` | 差し引く材料 |
|---|---|
| `full` | 受講者ソース**全体**に現れる語 |
| `diff` | 受講者**diff**に現れる語（issue #6 以前の挙動） |

- **材料の拡張は必須である**（実測で確定）。材料が diff からしか作られないと、**受講者が
  hunk外で同じ関数を既に持っていても、その識別子を含む指摘は禁止語に当たって drop される**。
  issue #6 が可視化しようとした「hunk外の責務」についての指摘が、まさに落ちる向きに働く。
- **DDR 0061 の「誤検知の側へ倒す」方針は反転していない。** 材料を広げることは差し引く量を
  増やすだけなので、**禁止語は減りこそすれ増えない**——つまり効くのは誤検知が減る方向のみで、
  転記の見逃しは増えない。
- **`--submission-root` に存在しないパスを渡された場合は黙って無視しない。** 無視すると
  `materialScope` が `diff` へ戻り、**広げたつもりで広がっていない状態が正常応答として返る**。
- **識別子は分割しない**。分割すると一般語に当たって誤検知が爆発する。
- 返却は `{"kept":N,"dropped":M,"materialScope":…,"forbiddenCount":K,"drops":[{"title":…,"words":[…]}]}`。
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
| 手順3b | `answer-talker-submission.sh` は内部で `gh`/`glab` を呼ぶため**そのままでは動かない**。`mcp__github__get_file_contents` で取得し、同じ形のJSONを自分で組み立てる。取得できない場合は**段3として `degraded:true` で続行する**（スキル自体を中止しない） |
| 手順9 | `add_mr_inline_comments` → `mcp__github__pull_request_review_write`（`create` → `add_comment_to_pending_review` → **必ず `submit_pending`**） |
| 手順3・4・7 | 読み替え不要（ローカルのスクリプトのみ） |

**段2をファイル単位APIにしたことが、ここでも効いている。** 段1・段2はいずれもAPI経由の取得で
あり、`mcp` 経路でも同じ考え方で組み立て直せる（`git clone` を主経路にしていたら、この経路に
対応する手段が無かった）。

## 影響範囲

- **既存の呼び出しは変わらない。** `Provider.sh` / `Github.sh` / `Gitlab.sh` の投稿系5関数へ
  **省略可能な**ラベル引数を足しただけで、既定値は従来の `敵対的レビュー` のままである
  （GitHub・GitLab双方で既定の出力が従来と一致することを確認済み）。
- `Provider.sh` へ `use_target_repo` / `get_mr_changed_files` を**追加**した。既存関数の変更は無い。
- `HANDOFF.md` の進捗表・flow-idは**増えない**。`adversarial-review` と同じく、フローに載らない
  並行手順である（`.claude/skills/issue-mr-flow/SKILL.md`）。

### 追記: 受講者ソース全体の受け渡し（issue #6）

| ファイル | 変更 |
|---|---|
| `Provider.sh` / `Github.sh` / `Gitlab.sh` | 受講者ソース取得の**5関数を追加**（`get_mr_head_repo` / `get_repo_size_kb` / `get_repo_tree` / `get_repo_file` / `fetch_repo_archive`）。既存関数の変更は無い |
| `answer-talker-submission.sh` | **新規**（3段の縮退・除外・一覧・後始末） |
| `answer-talker-map.sh` | `--submission-root` を追加し、返却へ `scope` を追加 |
| `answer-talker-spoiler-check.sh` | `--submission-root` を追加し、返却へ `materialScope` / `forbiddenCount` を追加 |
| `answer-talker-reviewer.md` | `submission` の入力仕様・`degraded` による分岐・受講者ソースを読む手順 |
| `answer-talker/SKILL.md` | 手順3b を追加、手順4・7・10・11 と `mcp` 読み替え表を更新 |

- **既存の手順番号は変えていない**（追加分を `手順3b` とした）。
- `answer-talker-map.sh` / `answer-talker-spoiler-check.sh` の新引数は**いずれも省略可能**で、
  省略時は issue #1 当時の挙動（`scope: "diff"` / `materialScope: "diff"`）に一致する。
  段3（`degraded:true`）で通るのがこの経路である。

## 設定項目

専用の設定ファイルは持たない。**いずれもスクリプト内の定数であり、環境変数ではない**
（値を変えるにはスクリプトを編集するか、下表のコマンドラインオプションを使う）。

| 定数 | 置き場所 | 内容 |
|---|---|---|
| `ATR_STOPWORDS` | `answer-talker-spoiler-check.sh` | ネタバレ検査の除外語リスト |
| `ATR_MARKER` | `answer-talker-reference.sh` | 正解ソースの一時ディレクトリのマーカー名 |
| `ATR_SUBMISSION_MARKER` | `answer-talker-submission.sh` | 受講者ソースの一時ディレクトリのマーカー名 |
| `ATR_EXCLUDE_DIRS` | 同上 | 展開直後にツリーから削除する生成物・依存ディレクトリ |
| `ATR_DEFAULT_MAX_SIZE_KB` ほか3件 | 同上 | 下表のオプションの既定値 |

`answer-talker-submission.sh resolve` は、上限を**コマンドラインオプションで**上書きできる。

| オプション | 既定値 | 意味 |
|---|---|---|
| `--max-size-kb` | `102400`（100MB相当） | これを超えるリポジトリでは段1を試さない。**サイズ不明時は段1を試す** |
| `--max-fetch-files` | `50` | 段2で取得するファイル数の上限（50 × 約672ms ≒ 34秒） |
| `--max-list-files` | `500` | サブエージェントへ渡す一覧の件数。超えたら `truncated` |
| `--timeout-sec` | `60` | HTTP1回あたりのタイムアウト |

**`ATR_HTTP_TIMEOUT_SEC` だけは環境変数である**が、これは `--timeout-sec` の値を子プロセスへ
渡すための内部的な受け渡しであり、利用者が設定する項目ではない。

## 検証の再現手順の要点

**演習の題材はこのリポジトリに置かない**（plugin配布単位である `.claude/` にサンプルを混ぜない）。
検証用のセットアップスクリプトも残していない。再現に必要な情報を以下に記す。

- **題材**: 極小のbash CLI（ファイルを読む → 正規表現で行を絞る → 接頭辞を付けて出力する）。
  正解は3つの関心をそれぞれ1ファイル1関数に分け、`main.sh` がパイプで繋ぐ。
  演習側の初期状態は骨格のみの `main.sh` 1ファイル。
- **ブランチ・コミットの作成には GitLab の Commits API を使う**
  （`POST /projects/:id/repository/commits`。`create`/`update`/`delete`/`move` のアクション）。
  issue #1 の時点でローカルGitLabへ `git` で到達できなかったため（HTTP cloneは
  `Cannot prompt because user interactivity has been disabled.`、SSHは `Permission denied
  (publickey)` で、`glab api user/keys` も空）。**代替手段が無いことを確認したうえでの採用**である。
  - **追記（issue #6）: この「到達できない」は環境の制約ではなく、資格情報の供給方法の問題だった。**
    `GIT_ASKPASS` にCLIのトークンを渡す小さなスクリプトを指定すると、非公開リポジトリからでも
    MR head を取得でき、`headSha` と一致した（グローバルなgit設定は変更していない）。
    **ただしCommits APIを採った判断自体は今も有効である**——題材の投入に必要なのはブランチと
    コミットの作成だけで、そこにcloneと資格情報の供給を持ち込む理由が無い。GitHub側も同じ理由で
    Contents API を使っている（下記）。
- **GitHub側の題材は Contents API で投入する**（GitLabのCommits APIと対称。issue #6 で追加）。
  空リポジトリへの最初の `PUT repos/:owner/:repo/contents/:path` でdefaultブランチが作られ、
  以降は `POST git/refs` でブランチ、`PUT contents`（既存ファイルは `sha` 必須）で変更、
  `POST pulls` でPRを作る。**リポジトリそのものは人間が用意する**（AIエージェントは作成しない）。
- **検証パターンは5軸**: 受講者の実装（分割不足／別解／重複／余分な抽象化／ほぼ正解）／
  正解ソースの形態（URL／ローカルgit／素のディレクトリ）／diffの内容（削除／リネーム／新規追加）／
  ネタバレ検査（転記あり／一般語のみ）／投稿（実投稿／0件）。
- **「指摘しないことを確かめる」パターンを必ず含める。** 指摘が出ることだけを確かめる検証は、
  過剰に指摘するスキルを合格させてしまう。
- **別解を潰していないかの判定には、「責務の分割は正解と同等だが、ファイルには分けていない」
  パターンが有効である。** `referenceOnly` に正解側の全ファイルが並ぶため、正解へ同調する圧力が
  最も強くかかる条件になる。ここでファイル分割を促す指摘が出なければ、
  **ファイル構成ではなく責務で判断している**と言える。

### 検証パターンの内訳（issue #6 で追加）

**上の5軸だけでは、実際に使った組み合わせを復元できない。** 全組み合わせは
5×3×3×2×2 = 180通りあり、そのうちどれを選んだかは軸からは一意に決まらない。issue #1 の反映時に
「再現に必要な情報はspecで足りる」と判断したのは誤りだった。**以下の内訳を正史として残す。**

受講者側リポジトリのブランチと、それに対応するMRは次のとおり。

| ブランチ | 変更ファイル | 対応する軸 |
|---|---|---|
| `p1-monolith` | M `main.sh` | 実装: 分割不足 |
| `p2-alt-split` | A `io.sh` / A `transform.sh` / M `main.sh` | 実装: 別解（2分割） |
| `p2b-single-file` | M `main.sh` | **判別用**: 責務は3分割だがファイルは1つ（上記「別解を潰していないか」） |
| `p3-duplication` | M `main.sh` | 実装: 重複 |
| `p4-overabstraction` | M `main.sh` | 実装: 余分な抽象化 |
| `p5-near-answer` | A `input.sh` / A `select.sh` / A `render.sh` / M `main.sh` | 実装: ほぼ正解 |
| `p9-delete` | D `README.md` / A `USAGE.md` | diff: 削除 |
| `p10-rename` | R `main.sh`→`cli.sh` | diff: リネーム |
| `p11-addonly` | A `filter.sh` | diff: 新規追加 |

**欠番（p6〜p8）はブランチを持たない。** 正解ソースの形態3種（URL／ローカルgit／素のディレクトリ）・
ネタバレ検査・投稿の有無は、**同じブランチに対して実行条件だけを変えた軸**である。
ブランチ数（9）と検証パターン数（17）が一致しないのはこのためである。

**題材の実体**: 正解は `read.sh` / `filter.sh` / `format.sh` / `main.sh` の4ファイル（合計660バイト）、
受講者の初期状態は `README.md` + `main.sh`（313バイト）。

## 未決定事項・懸念点

- **上限到達時の挙動は実データで未確認**。GitHubの3000ファイル上限・`patch` 省略、GitLabの
  `too_large` / `collapsed` が立つ規模のMRは用意していない。いずれも「検知して報告する」形で
  実装済みだが、実際にその規模で動かした証跡は無い。**issue #6 でも解消していない。**
- **GitHubの非公開リポジトリでのアーカイブ取得（段1）は未確認**（issue #6）。実測したのは
  公開リポジトリに対してのみである。検証用リポジトリを一時的に非公開へ変える案はユーザーの
  承認を得たが、実行が権限分類器にブロックされたため確かめられなかった。**「確かめられなかった」
  であって「動かない」ではない**（`gh api` は認証済みのため通ると見込んでいる）。
- **リポジトリサイズを返さない環境での挙動は、コード上は確認済みだが実環境では未確認**
  （issue #6）。`size-unknown` として段1を試す分岐は単体テストで通しているが、実際にサイズを
  返さないAPIレスポンスを返す環境では動かしていない。
- **上限値（100MB・50件・500件・60秒）の妥当性そのものが未検証**（issue #6）。検証に使った
  リポジトリは最大でも5ファイルで、**一度も上限に触れていない**。段2の50件は
  「50 × 約672ms ≒ 34秒」という実測からの逆算、一覧の500件は `jq --args` の引数長を踏んだ
  経験からの数字であり、いずれも**実際の演習リポジトリの規模分布に基づいていない**。
- **サブエージェントは正解を絶対の基準とせず、一般的な設計原則でも判断する。** そのため
  **正解と同じ形にしても指摘が0件になるとは限らない**（検証では、正解自身にも当てはまる性質の
  指摘が出た）。重大度が低く投稿されないため実害は無いが、「正解に一致させれば無指摘になる」
  という期待は成り立たない。
- **凝集度の低い別解には強めの指摘が出る。** 入力と出力を1ファイルに束ねる流儀を採った場合、
  major/high の指摘が投稿されうる。同調圧力ではなく凝集度への指摘として妥当と判断しているが
  （上記の切り分けによる）、受講者の流儀によっては厳しく映る。
