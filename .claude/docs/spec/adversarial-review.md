---
title: 敵対的レビュー
type: spec
description: 独立コンテキストの専任サブエージェントが意図的に欠陥を探し、指摘をMRへインラインコメントとして投稿する敵対的レビュー機構の仕様
tags: [adversarial-review, review, issue-mr-flow, spec]
keywords: [敵対的レビュー, インラインコメント, findings, 実施回数, REVIEW-POINTS, 有効行, new_line, old_line, 確度, 重大度, スレッド, discussions, サマリ]
---

# 敵対的レビュー

対象: `.claude/skills/adversarial-review/SKILL.md`, `.claude/skills/review-points/SKILL.md`,
`.claude/agents/adversarial-reviewer.md`, `.claude/scripts/src/adversarial-review-count.sh`,
`.claude/scripts/src/collect-review-points.sh`, `.claude/scripts/src/vcs/`（`add_mr_inline_comments`
とプロバイダ実装）, 各ディレクトリの `REVIEW-POINTS.md`

## 背景・目的

issue #77。実装・計画・設計反映の各レビュー（flow-id 2-3/2-8/3-3/3-8/4-3/4-8）は、人間の負荷に
全面的に依存している。一方でAIエージェント自身の確認は、**自分が書いたものを追認する方向へ働き
やすく**、独立した検証にならない。

組み込みの `/code-review` は汎用のバグ探しであり、このリポジトリ固有の落とし穴
（`plans/` の粒度、spec/DDR/rules の二重管理、point-in-time記録の破壊、DDR番号の衝突、
shellの既知の罠）は対象外である。本issue以前、このリポジトリにはレビューを担うスキルも
サブエージェントも存在しなかった（`.claude/agents/` は読み取り専用の `issue-mr-resume` のみ）。

そこで、**独立コンテキストの専任サブエージェントが意図的に穴を探す「敵対的レビュー」**を機構化し、
指摘をMRへインラインコメントとして投稿できるようにした。人間のレビューを置き換えるものではなく、
その**前**に挟む任意の補助である。

## 仕様

### 全体像（責務分離）

```
人間 → /adversarial-review（スキル）
          ├ 手順1 実施回数の上限確認（adversarial-review-count.sh）
          ├ 手順2 対象の判別と観点表の収集（collect-review-points.sh）
          ├ 手順3 投稿可否の確認（AskUserQuestion、1回だけ）
          ├ 手順4 サブエージェント起動 ─→ adversarial-reviewer（読み取り専用）
          │                                 └ findings JSON を返すだけ
          ├ 手順5 実施回数の加算
          ├ 手順6 確度×重大度で投稿／報告を振り分け
          ├ 手順7 add_mr_inline_comments（Provider.sh）で投稿
          └ 手順8 報告
```

**サブエージェントは投稿しない。** 投稿は呼び出し元（スキル）の責務とし、承認の所在を1箇所へ
寄せている。サブエージェントには `Read, Grep, Glob, Bash` しか与えず、Write/Editを持たせない。

**サブエージェントへ「なぜそう実装したか」の経緯を渡さない。** 渡すのはレビュー対象（diffまたは
ファイルパス一覧）・マージ済みの観点表・フェーズ番号の3つだけである。経緯を渡すと実装者の文脈に
引きずられ、追認するレビューになる。サブエージェント側から観点表を探しに行かせないのも同じ理由で、
対象範囲の判断を呼び出し元へ集約している。`git log` 等でコミットメッセージや過去の議論を読むことも
禁じている。

モデルは `model: opus`。浅い確認では敵対的レビューにならないため、`issue-mr-resume` の `sonnet` とは
役割が異なる。

### 全体フローにおける位置づけ

**`issue-mr-flow` の全体フロー表には含まれない。** flow-idを持たず、
commit・pushの直後（flow-id 2-2/2-7/3-2/3-7/4-2/4-7）から人間のレビュー（2-3/2-8/3-3/3-8/4-3/4-8）
までの間に挟む任意の手順として位置づける。実施しても `HANDOFF.md` の進捗表は動かさず、実施した
事実は「やったこと」へ文章で残す。

### 起動ポリシー

| 実行モード | 判定 | AIエージェントからの自律起動 |
|---|---|---|
| 非対話モード | 人間のレビュー往復が成立しない実行環境 | **許す** |
| 対話モード | 上記以外、または判断に迷う場合 | **禁止**。人間が `/adversarial-review` を呼んだときだけ実行する |

非対話かどうかは環境変数ではなく、**AIエージェント自身が実行環境の性質（人間とのレビュー往復が
成立するか）から判断する。** 判断はスキル本文の起動ポリシー（他のどの手順よりも先に適用される）
として扱う。

判断に迷う場合は対話モード（起動禁止）を既定とする。判定を誤ったときに「勝手に動く」側では
なく「動かない」側へ倒れるようにするためである。

対話モードで自律起動を禁じるのは、**レビューの主体が人間であるという前提を崩さないため**である。
AIが自分で書いて自分でレビューを起動し自分で直すと、人間がレビューする対象が「AIが既に納得した
もの」になり、レビューの独立性が失われる。AIから「敵対的レビューを実施しましょうか」と持ちかける
ことは構わないが、返事を待たずに実行してはならない。

### 実施回数の上限

非対話モードでは「レビュー → 修正 → 再レビュー」が人間の介在なく回りうるため、実施回数を
**各フェーズ最大3回**で機械的に打ち切る。AIエージェントの自制ではなくスクリプトで強制する。

```bash
bash .claude/scripts/src/adversarial-review-count.sh get <phase>        # 残回数の確認
bash .claude/scripts/src/adversarial-review-count.sh increment <phase>  # 加算（上限なら終了コード1）
bash .claude/scripts/src/adversarial-review-count.sh reset              # 人間の判断でのみ実行
```

- `<phase>` は issue-mr-flow のフェーズ番号（2/3/4）。
- 状態は `.claude/state/adversarial-review/<ブランチ名>.json` に `{"2":N,"3":N,"4":N}` で持つ。
  ブランチ名の `/` は `__` へ置換する。`.claude/state/` は `.gitignore` 対象のローカル作業状態で、
  ブランチ単位のため、ブランチを削除すれば自然に消える（`usage/` とは責務が異なるため混ぜない）。
- **加算は「レビュー実行の直後・投稿の前」に、投稿の成否に関わらず行う**（失敗を口実に無限
  リトライできないようにするため）。
- 状態ファイルが空・壊れたJSONの場合は「状態なし」（`{}`）へフォールバックする。空文字列の判定を
  `jq -e .` より先に行うのは、空入力に対して `jq -e .` が終了コード0を返すことがあるため
  （`.claude/rules/shell-script-style.md`）。
- **上限を環境変数等で緩める口は用意しない。** 緩められる上限は上限ではないため。

### レビュー観点（REVIEW-POINTS.md）

**観点はスキル本文にもサブエージェント定義にも書かない。** 各ディレクトリ直下に置いた
`REVIEW-POINTS.md`（frontmatterの `type: review-points`）が持つ。

- **1つの `REVIEW-POINTS.md` は、そのディレクトリ配下すべて（孫以下を含む）に適用される。**
- 収集は、レビュー対象ファイルのあるディレクトリからリポジトリルートまで**祖先を遡って**行い、
  1つへマージする。
- 出力順は**浅い → 深い**（一般 → 具体）。由来が分かるよう `## <観点表のパス>` の見出しを挟む。
- 複数ファイルを渡した場合は各祖先チェーンの**和集合**を取り、同じ観点表は1回だけ出力する。
  そのため**対象ファイルは1回の呼び出しへまとめて渡す**。
- パス解決は `..` を打ち消す形で行い、**リポジトリルートより上へは決して出ない**。
- 観点表が1つも見つからない場合は、何も出力せず終了コード0で終わる（観点表が無くてもレビュー
  自体は一般的な観点で行えるため、エラーにしない）。その事実は手順9で報告する。

```bash
bash .claude/scripts/src/collect-review-points.sh <対象ファイルパス...>
```

現在の配置は `REVIEW-POINTS.md`（リポジトリ全体）・`.claude/REVIEW-POINTS.md`・
`plans/REVIEW-POINTS.md`・`reports/REVIEW-POINTS.md` の4つ。
単独でも使えるよう `review-points` スキル（`.claude/skills/review-points/SKILL.md`）として
切り出しており、人間のレビュー・`/code-review` の補助にも使える。

### レビュー対象の判別

現在のflow-idから自動判別する。曖昧なら `AskUserQuestion` で選ばせる（非対話モードでは既定として
「diff全体」を採る）。削除されたファイルは対象から外す。

| 対象 | 判別 | ファイルの列挙 |
|---|---|---|
| diff全体 | flow-id 3-7 / 4-7 の直後 | `git diff --name-only origin/<base>...HEAD` |
| `plans/` の個別計画 | flow-id 2-2 / 3-2 / 4-2 の直後 | 該当する `plans/【*.md` |
| 設計反映 | flow-id 4-7 の直後 | `.claude/docs/spec/` `.claude/docs/ddr/` `.claude/rules/` の変更ファイル |

### findings JSONスキーマ

サブエージェントは findings JSON **だけ**を返す（散文の講評・要約は返さない）。指摘が0件なら
`{"findings":[]}` を返すのが正しい結果であり、水増しのために `nit` を並べてはならない。

```json
{"findings":[
  {"path":".claude/scripts/src/x.sh","line":42,"side":"RIGHT",
   "severity":"major","confidence":"high","category":"shell-pitfall",
   "title":"ループ内でjqを起動している","body":"..."}
]}
```

| キー | 必須 | 内容 |
|---|---|---|
| `path` | 必須 | リポジトリルートからの相対パス |
| `line` | 任意 | 新ファイル側の行番号。**ファイル全体にかかる指摘では省略する** |
| `old_line` / `old_path` | 任意 | 旧ファイル側の行番号・パス |
| `side` | 任意 | 既定は `RIGHT` |
| `severity` | 必須 | `blocker` / `major` / `minor` / `nit` |
| `confidence` | 必須 | `high` / `medium` / `low` |
| `category` | 必須 | 指摘の種類を表す短いkebab-caseの語（例: `shell-pitfall` `doc-inconsistency`） |
| `title` | 必須 | 1行の要約 |
| `body` | 必須 | 何が問題か・どういう入力/状況で壊れるか・どう直すか の3点 |

サブエージェントは各指摘について**反証を1回試みる**ことを求められる。これを行わないと確度の
自己申告が意味を失うため。

### 投稿／報告の振り分け

| 確度 \ 重大度 | blocker | major | minor | nit |
|---|---|---|---|---|
| high | 投稿 | 投稿 | 投稿 | 報告 |
| medium | 投稿 | 投稿 | 報告 | 報告 |
| low | 報告 | 報告 | 報告 | 報告 |

- **投稿** = インラインコメントとしてMRへ出す。**報告** = 会話（非対話モードではworklog）にのみ
  書き、MRへは出さない。
- **1回あたりの投稿上限は10件**。超える場合は重大度の高い順に10件へ絞り、残りは報告へ回す
  （レビュアーが一度に扱える量を超えると、結局どれも読まれないため）。
- この振り分けは**シェル関数ではなくスキルの手順7**に置いている。「技術的に投稿可能か」（有効行か
  どうか）はコードの責務だが、「人間に見せる価値があるか」は判断であり、運用しながら調整できる
  場所に置くほうがよいと判断した。

### 承認モデル

投稿の可否は、レビューを実行する**前**に `AskUserQuestion` で**1回だけ**確認する。承認後は指摘
ごとの個別承認を求めない。GitHubの提出済みレビューは削除できないため、「投稿してから取り消す」
前提の設計にできないからこそ、承認を投稿前の1点へ集約している。

非対話モードでは確認できないため、既定は「報告するだけ」ではなく**「投稿する」**とする
（非対話環境では会話への報告が誰にも読まれないため）。

### 投稿インターフェイス

```bash
source .claude/scripts/src/vcs/Provider.sh
add_mr_inline_comments <MR番号> <findings JSONファイル>   # → {"posted":N,"summarized":M}
```

既存の `add_mr_thread_reply` / `add_mr_comment` と同じディスパッチ形式で、
`github_add_mr_inline_comments` / `gitlab_add_mr_inline_comments` へ振り分ける。

**findingsは必ずファイル経由で渡す。** jqの引数長上限（`jq: Argument list too long`）と、
コマンド文字列へのhook誤検知語の混入の両方を避けるため（`.claude/rules/shell-script-style.md`）。

`summarized` は、対象がdiffに含まれず行を指定できなかったためサマリへ回った件数。サマリの出し方は
プロバイダで異なり、GitHubは**レビュー本文**へ載せ、GitLabは**別コメント**として投稿する
（指摘を含むならスレッドとして。後述「インライン以外のコメントもスレッドで投稿する」）。

### GitHubの投稿

`gh api repos/{owner}/{repo}/pulls/<n>/reviews` に `event=COMMENT` と `comments[]` を渡す形で、
**複数の指摘を1回のレビューにまとめて**投稿する（レビュアーへの通知が1回で済む）。

- **投稿はアトミックである。** 1件でも不正な行を指定すると、レビュー全体が422で失敗する。
  そのため投稿前に有効行を検証し、範囲外の指摘をサマリへ振り分ける。
- **有効行は `pulls/<n>/files` の `.patch` のhunkヘッダから求める。** `@@ -a,b +c,d @@` の
  `+c,d` が新ファイル側の範囲で、コメントを付けられるのはこの範囲内の行（追加行・コンテキスト行）
  に限られる。`d` を省略した `@@ -a,b +c @@` は1行を意味し、純粋な削除hunk（`d` が0）は新ファイル
  側に行を持たないため除外する。
- **行を1つずつ列挙せず「範囲」（`[開始, 終了]`）で保持する。** jqへ渡すデータ量を差分の大きさ
  ではなく hunk 数に比例させるため。
- **`line` 未指定のfinding（ファイル全体にかかる指摘）は、そのファイルの有効行の最小値へ寄せる。**
  新規追加ファイルはhunkが `@@ -0,0 +1,N @@` になるため、これは1行目に一致する。
- 有効行を持たないファイル（diffに現れない・`patch` が省略された）の指摘はサマリへ回る。
  これは特別扱いのコードではなく、有効行が空であることから自動的にそうなる。
- **提出済みのレビューは削除できない**（個々のコメントは削除できる）。

### GitLabの投稿

`projects/:id/merge_requests/<iid>/discussions` へ、finding 1件につき1回POSTする。

- `position` の必須項目（`base_sha` / `start_sha` / `head_sha` / `position_type` / `old_path` /
  `new_path`）は、MR JSONの **`diff_refs`** だけで揃う。`old_path` / `new_path` はGitLabが常に
  要求するため、片方しか無い場合は同じ値で埋める。
- **`-H "Content-Type: application/json"` を明示的に付ける必要がある**（`--input` だけでは
  足りない）。
- **行の種類ごとに、指定するキーが決まっている。**

  | 指摘したい行 | 指定するキー |
  |---|---|
  | 追加行（diffの `+`） | `new_line` のみ |
  | 削除行（diffの `-`） | `old_line` のみ |
  | 変更のない行（コンテキスト行） | `new_line` と `old_line` の**両方** |
  | ファイル全体 | どちらも指定しない |

  違反すると `400 Bad request - Note {:line_code=>["must be a valid line code"]}` となり、
  その指摘だけが投稿されずサマリへ回る。
- **MR作成直後は `diff_refs` が `null` のことがある**（実機確認）。1回だけ待って再取得し、
  それでも取れなければ終了コード1で失敗する。
- 1件ごとにHTTPリクエストが発生する経路のため、findingごとに `jq` を起動しても起動コストは
  無視できる（`.claude/rules/shell-script-style.md`「外部プロセス起動のコスト」は、ファイル数に
  比例して外部コマンドを起動するホットパスを対象とした指針である）。
- GitHubと違い**まとめ役のレビュー本文が存在しない**ため、投稿できなかった指摘のサマリは
  別の1コメントとして投稿する。**このサマリが指摘を1件でも含む場合は、単発noteではなく
  `discussions`（スレッド）で投稿する**（下記）。

#### インライン以外のコメントもスレッドで投稿する（issue #121）

サマリの投稿先は `gitlab_summary_post_kind` が件数から決める（`thread` / `note`）。

| サマリに含まれる指摘 | 投稿先 | 理由 |
|---|---|---|
| 1件以上 | `discussions`（`gitlab_add_mr_thread`） | インラインの指摘と同じく**対応を求める内容**であり、レビュアーが解決でき、`add_mr_thread_reply` で返信できる形にする必要がある |
| 0件 | `notes`（`gitlab_add_mr_comment`） | 本文が「すべての指摘をインラインコメントで示しています」という通知でしかなく、スレッドにすると誰も解決しないまま未解決一覧に残り続ける |

`notes` APIで作ったnoteはGitLab上で `individual_note: true` / `resolvable: false` になる。
`gitlab_format_discussion_notes` は**resolvable でないnoteを常に「未解決」として出力する**ため
（解決しようが無いので当然そうなる）、対応を求めるコメントを単発noteで投稿すると、対応済みに
なっても `comments` サブコマンドの未解決一覧に残り続け、レビュー往復の完了判定を濁す。
`discussions` APIで投稿すればレビュアーが解決でき、この問題が起きない。

以下は採らなかった。

- **サマリの指摘を1件ずつ別スレッドにする。** 解決の粒度は細かくなるが、`posted`（インラインで
  示せた件数）と `summarized`（示せずサマリへ回った件数）という戻り値の意味が曖昧になる。
  行を指定できなかった指摘は、そもそもレビュアーが「どこの話か」を本文から読み取る必要があり、
  1つのスレッドにまとめて示すほうが読みやすい。
- **`gitlab_add_mr_comment` 自体を `discussions` へ切り替える。** 同関数は対応工数レポート
  （`post-push-usage-report.sh`）も使っており、そちらは**対応を求めない通知**である。
  スレッド化すると上記と同じ理由で未解決一覧を汚す。用途が違うため関数を分けた。

GitHub側は、インラインで示せなかった指摘を**レビュー本文**へ載せる形が既にまとめ役として
機能しているため変更しない（GitLabにその受け皿が無いことが、この分岐の出発点である）。

### AIの署名

インラインコメント本文の先頭に `Claude Codeより（敵対的レビュー）:` を付ける。`gh`/`glab` CLIは
人間のアカウントで認証されているため、投稿者名では誰が書いたか判別できない。これは
`issue-mr-flow/SKILL.md` の `reply` サブコマンド手順2が返信本文へ `Claude Codeより:` を必須と
しているのと同じ理由である。

**GitLabでは特に重要**で、1件ずつ独立したdiscussionになりまとめ役のレビュー本文が存在しないため、
署名が無いと人間の指摘と区別できない。

### 投稿されたスレッドの取得

投稿したスレッドは、既存の `comments` サブコマンド（`get_mr_unresolved_comments`）から
`unresolved` として位置つきで取得できる。

```
[review unresolved threadId=PRRT_... .claude/scripts/src/vcs/Gitlab.sh:117] ...
```

GitLab側も同様に、`position` を持つnoteは `path:line` を出力する（削除行への指摘は `new_line` が
無く `old_line` のみを持つため `old_path:old_line` を使う）。**敵対的レビューのために新しい取得
経路を作る必要はない。**

スレッドの解決（resolve）はレビュアー側の操作であり、本機構では行わない。

### `gh`/`glab` CLI不在時（MCP経路）

`get_vcs_access_mode` が `mcp` を返す環境では、投稿を
`mcp__github__pull_request_review_write` の3段構成へ読み替える（GitHubのみ。GitLabは対象外）。

1. `method="create"` で pending review を作る。
2. 指摘ごとに `method="add_comment_to_pending_review"`（`path` / `line` / `side` / `body`）。
3. **必ず `method="submit_pending"`（`event="COMMENT"`）まで実行する。** pending のまま放置すると
   次回の `create` が失敗し続ける。途中で失敗した場合は `method="delete_pending"` で片付ける。

CLI版と違い有効行の事前検証が入らないため、diffに含まれない行を指定すると個別に失敗する。
WebFetchツール・curlへはフォールバックしない（DDR 0020, DDR 0027）。

## 影響範囲

issue #77 で追加・変更したもの。

| ファイル | 内容 |
|---|---|
| `.claude/scripts/src/vcs/Provider.sh` | `add_mr_inline_comments` のディスパッチ、`format_findings_summary` |
| `.claude/scripts/src/vcs/Github.sh` | `github_valid_ranges_from_files_json` / `github_filter_findings_by_valid_lines` / `github_build_review_payload` / `github_add_mr_inline_comments` |
| `.claude/scripts/src/vcs/Gitlab.sh` | `gitlab_build_discussion_body` / `gitlab_add_mr_inline_comments`、`gitlab_format_discussion_notes` の位置出力 |
| `.claude/scripts/src/adversarial-review-count.sh` | 実施回数カウンタ（`get` / `increment` / `reset`） |
| `.claude/scripts/src/collect-review-points.sh` | 観点表の収集・マージ |
| `REVIEW-POINTS.md` / `.claude/REVIEW-POINTS.md` / `plans/REVIEW-POINTS.md` / `reports/REVIEW-POINTS.md` | レビュー観点表（`type: review-points`） |
| `.claude/agents/adversarial-reviewer.md` | 専任サブエージェント（読み取り専用・`model: opus`） |
| `.claude/skills/adversarial-review/SKILL.md` | 本機構のスキル（手順1〜9） |
| `.claude/skills/review-points/SKILL.md` | 観点表の収集・適用を単独でも使えるようにしたスキル |
| `.claude/skills/issue-mr-flow/SKILL.md` | 「敵対的レビューの位置づけ」節、MCP対応表への `add_mr_inline_comments` 行 |
| `.claude/scripts/test/test_vcs_provider.sh` | 純粋関数のテストを追加 |
| `.claude/scripts/test/test_adversarial_review_count.sh` | 新規（22件） |
| `.claude/scripts/test/test_collect_review_points.sh` | 新規（17件） |

変更（issue #106）:
- `.claude/skills/adversarial-review/SKILL.md`（`AUTOMATION` 環境変数による判定を廃止し、
  AIエージェントの判断へ置き換え。手順番号を1〜8へ繰り上げ）
- `.claude/docs/spec/adversarial-review.md`（本ドキュメント。起動ポリシー節・設定項目表・
  未決定事項から `AUTOMATION` の記述を除去）
- `.claude/skills/issue-mr-flow/SKILL.md`（「敵対的レビューの位置づけ」表から `AUTOMATION=1` の
  記述を除去）

新規（issue #106）:
- `.claude/docs/ddr/0055-敵対的レビューの非対話判定は環境変数ではなくAIエージェントの判断に委ねる.md`

### 追記: GitLabのサマリをスレッドで投稿する（issue #121）

| ファイル | 内容 |
|---|---|
| `.claude/scripts/src/vcs/Gitlab.sh` | `gitlab_add_mr_thread`（`discussions` APIで非インラインのスレッドを立てる）／ `gitlab_summary_post_kind`（サマリの投稿先の判定）を追加、`gitlab_add_mr_inline_comments` のサマリ投稿を分岐 |
| `.claude/scripts/test/test_vcs_provider.sh` | `gitlab_summary_post_kind` のテストを追加（3件） |
| `.claude/docs/spec/adversarial-review.md` | 「インライン以外のコメントもスレッドで投稿する」節 |
| `.claude/docs/spec/issue-mr-workflow.md` | Provider関数一覧の `add_mr_inline_comments` 行 |
| `.claude/skills/adversarial-review/SKILL.md` | 手順7（issue #106以前は手順8）の戻り値の説明 |

## 設定項目

| 項目 | 既定 | 変更方法 |
|---|---|---|
| 実行モード | 対話モード（判断に迷う場合を含む） | AIエージェントが実行環境の性質（人間のレビュー往復が成立するか）から判断する。環境変数は使わない |
| 実施回数の上限 | 3回／フェーズ | `adversarial-review-count.sh` の `ADVERSARIAL_REVIEW_MAX_RUNS`（**緩める口は意図的に用意していない**） |
| 1回あたりの投稿上限 | 10件 | `adversarial-review/SKILL.md` 手順7 |
| 投稿／報告の振り分け | 確度×重大度の表 | 同上 |
| レビュー観点 | 各ディレクトリの `REVIEW-POINTS.md` | 該当ディレクトリの観点表を編集する（スキル本文は編集しない） |

## 未決定事項・懸念点

- **観点表が増えたときのマージ結果が肥大する可能性。** 現在は4ファイルで問題にならないが、
  深い階層に観点表が増えると、サブエージェントへ渡す観点表が長くなる。
- **`/code-review` との併用方針。** 併用してよいとしているが、同じ欠陥が両方から指摘されたときの
  扱い（重複コメント）は運用で吸収している。
- **サマリへ回った指摘の追跡（GitHub）。** レビュー本文に載るだけで、スレッドとして解決状態を
  持たない。件数が増えた場合の扱いは未定。GitLab側は `discussions` で1つのスレッドとして投稿する
  ようにしたため解決状態を持つ（上記「インライン以外のコメントもスレッドで投稿する」）が、
  スレッド内の指摘は個別には解決できない。
- **非インラインのスレッド投稿は未検証。** このリポジトリにGitLab remoteが無く、
  `gitlab_add_mr_thread` を実機で叩けていない（`position` を持たない `discussions` へのPOSTと、
  それがMR上で解決可能なスレッドになることの確認）。同ファイルの他のGitLab関数と同じ扱い。
