---
name: answer-talker
description: 開発演習で、受講者が初期状態から実装を進めたMR/PRを、別途用意された「正解ソース」と照合してレビューし、指摘をMRへインラインコメントとして投稿するために使う。正解のコードをそのまま提示するのではなく、分割方針・責務の置き方・命名やルールの考え方が正解と同じ方向へ向かうような**概念的な指摘**を返す。`/answer-talker <MR番号> --reference <URL|パス> [--repo <対象>]` の形で起動する。正解ソースは別リポジトリのURL（shallow cloneする）とローカルディレクトリの2形態を受け付ける。正解のコード片が指摘へ混入していないかを投稿直前に機械的に検査する。
title: 演習MRの正解照合レビュー（answer-talker）
type: skill
tags: [review, answer-talker, 演習]
keywords: [演習, 正解ソース, インラインコメント, ネタバレ検査, 別解, findings, use_target_repo, get_mr_changed_files, 後始末]
---

# answer-talker スキル

開発演習のMRを、**正解ソースを参照できる専任サブエージェント**
（`.claude/agents/answer-talker-reviewer.md`）にレビューさせ、指摘をMRへインラインコメントとして
投稿する（issue #1）。

正解をそのまま見せると演習にならない。かといって正解を見ずにレビューすると、指摘の粒度が
毎回変わる。**正解を見て、正解を書かない**——この非対称を機構として固定するのがこのスキルである。

## `adversarial-review` との違い

| | `adversarial-review` | 本スキル |
|---|---|---|
| 対象 | **自分のブランチ**のMR（`get_mr_for_branch`） | **引数で受けた他人のMR番号**（別リポジトリでもよい） |
| 観点の出どころ | `REVIEW-POINTS.md`（`collect-review-points.sh`） | **正解ソースそのもの** |
| 探すもの | 「この変更が壊れるとしたらどこか」 | 「設計の考え方が正解と同じ方向を向いているか」 |
| 投稿前の検査 | なし | **ネタバレ検査**（正解の転記を落とす） |
| 実施回数の上限 | 各フェーズ最大3回（機械的に強制） | **なし**（人間が明示的に呼ぶため。下記） |

**実施回数の上限を設けないのは**、`adversarial-review` の上限が「非対話モードでAIが人間の介在なく
レビュー→修正→再レビューを回しうる」ことへの対策であり、本スキルはその前提を満たさないため
（人間が引数付きで明示的に呼ぶ／issue-mr-flowのフェーズ番号を持たない／対象が実行者のブランチと
無関係なのでブランチ単位の状態が対象MRと結びつかない）。投稿の埋め尽くしは、**投稿前の承認1回**と
**1回10件の上限**で抑える。

## 起動

```
/answer-talker <MR番号> --reference <URL|パス> [--ref <ブランチ/タグ>] [--repo <対象>]
```

| 引数 | 内容 |
|---|---|
| `<MR番号>` | レビュー対象のMR/PR番号（GitLabはiid） |
| `--reference` | 正解ソース。**URL**（shallow cloneする）または**ローカルディレクトリ**（cloneしない） |
| `--ref` | URLを指定した場合のブランチ・タグ（省略時はdefault） |
| `--repo` | 対象MRのあるリポジトリ（`owner/repo` またはURL）。**省略時はカレントディレクトリのリポジトリ** |

**`--repo` は、cwdと別のサービス（GitHub↔GitLab）を対象にするならURLで渡す。** `owner/repo`
形式はプロバイダを判定する材料を持たないため、**cwdのリモートのプロバイダが使われる**
（`use_target_repo` の仕様）。GitHubのリポジトリから作業しながらGitLabのMRをスラッグで指定すると、
GitHubのAPIを叩いて `Not Found (HTTP 404)` になる（検証中に実際に踏んだ）。self-hosted GitLabの
ホスト・ポートもURLからしか決まらない。

## 手順0: 経路を確認する

```bash
source .claude/scripts/src/vcs/Provider.sh
get_vcs_access_mode   # → cli / mcp
```

`mcp` の場合は下記「CLI不在時の読み替え」に従う。

## 手順1: 引数を解釈し、対象を明示する

**`--repo` が省略された場合は、対象がカレントディレクトリのリポジトリであることを必ず表示する。**

```
対象: <owner/repo> の MR #<番号>（--repo 未指定のためカレントディレクトリのリポジトリ）
正解: <URL|パス>
```

`gh`/`glab` は対象リポジトリをcwdのgitリモートから解決するため、**別リポジトリのつもりで
自分のリポジトリのMRを読み、そこへ投稿してしまう**事故が起きうる。表示はその予防である。

## 手順2: 対象リポジトリを切り替え、差分を取得する

```bash
source .claude/scripts/src/vcs/Provider.sh
[ -n "$repo" ] && use_target_repo "$repo"
tmpdir="$(mktemp -d)"
get_mr_changed_files <MR番号> > "$tmpdir/diff.json"
```

- **`get_mr_changed_files` の結果は必ずファイルへリダイレクトする。** コマンド置換 `$(...)` で
  受けてはいけない（差分のサイズは対象MRの規模に比例して無制限に大きくなる）。
- 返却の `truncatedFiles` が0でない、または `capped` が真の場合は、**その事実を報告に含める**
  （差分を読めなかったファイルがあることを黙って伏せない）。

## 手順3: 正解ソースを取得する

```bash
ref_json="$(bash .claude/scripts/src/answer-talker-reference.sh resolve --reference "$reference" [--ref "$branch"])"
reference_root="$(printf '%s' "$ref_json" | jq -r '.root')"
reference_tmpdir="$(printf '%s' "$ref_json" | jq -r '.tmpdir')"
```

ローカルパスを指定した場合は**cloneせずそのまま読む**（`cleanup:false` が返る）。
その場合、**正解ディレクトリを書き換えてはいけない**（サブエージェントは読み取り専用）。

## 手順4: 受講者と正解のファイルを対応付ける

```bash
bash .claude/scripts/src/answer-talker-map.sh \
  --diff "$tmpdir/diff.json" --reference-root "$reference_root" > "$tmpdir/mapping.json"
```

`referenceOnly`（正解側にしかないファイル）が、**受講者がまだ作っていない分割単位**の候補になる。
ただし別解の可能性もあるため、**意味づけはここでは行わない**（サブエージェントの判断に委ねる）。

## 手順5: 投稿の可否を確認する（承認モデル）

レビューを実行する**前**に、`AskUserQuestion` で1回だけ確認する。

- `指摘をMRへインラインコメントとして投稿する (Recommended)`
- `投稿せず、この会話で報告するだけにする`
- `レビュー自体をやめる`

**承認後は、指摘ごとの個別承認を求めない。** 提出済みレビューは削除できないため、
「投稿してから取り消す」前提の設計にできない。だからこそ承認は投稿前に1回へ集約する。

## 手順6: サブエージェントへレビューさせる

Agentツールで `answer-talker-reviewer` を起動し、手順2〜4で作った3つを1つのJSONにまとめて渡す
（`diff` / `reference` / `mapping`）。

**正解ファイルの中身はプロンプトへ載せない。** サブエージェントに `reference.root` を渡し、
Readで必要な範囲だけ読ませる。載せるほど転記のリスクが上がり、正解の規模も未知のため。

サブエージェントは findings JSON を返す（スキーマは `.claude/agents/answer-talker-reviewer.md`）。
`$tmpdir/findings.json` へ保存する。

## 手順7: ネタバレ検査（**飛ばさない**）

```bash
bash .claude/scripts/src/answer-talker-spoiler-check.sh \
  --findings "$tmpdir/findings.json" --reference-root "$reference_root" \
  --diff "$tmpdir/diff.json" --out "$tmpdir/findings-checked.json"
```

- 戻り値は `{"kept":N,"dropped":M,"drops":[{"title":…,"words":[…]}]}`。
- **落とした件数と反応した語を必ず報告する。** この検査は誤検知の側へ倒してあるため、
  「指摘が落ちすぎて実質何も出ない」という壊れ方をする。可視化しないと気づけない。
- **`kept` が0なら投稿しない**（空のレビューを投稿しない）。その旨を報告して手順10へ進む。

## 手順8: 投稿する指摘を選別する

確度（`confidence`）と重大度（`severity`）で振り分ける。

| 確度 \ 重大度 | blocker | major | minor | nit |
|---|---|---|---|---|
| high | 投稿 | 投稿 | 投稿 | 報告 |
| medium | 投稿 | 投稿 | 報告 | 報告 |
| low | 報告 | 報告 | 報告 | 報告 |

**1回あたりの投稿上限は10件。** 超える場合は重大度の高い順に10件へ絞り、残りは報告へ回す。
受講者が一度に扱える量を超えると、結局どれも読まれない。

## 手順9: MRへ投稿する

```bash
add_mr_inline_comments <MR番号> "$tmpdir/findings-post.json" '演習レビュー'
```

- findingsは**必ずファイル経由で渡す**。
- **第3引数のラベルを省略しない。** 省略すると本文が
  `Claude Codeより（敵対的レビュー）:` になり、受講者に「欠陥探しのレビュー」と誤解される
  （投稿経路を `adversarial-review` と共有しているため。既定値は互換のため従来の文言のまま）。
- 戻り値は `{"posted":N,"summarized":M}`。`summarized` は行を指定できずサマリへ回った件数。
- 手順2で `use_target_repo` を呼んでいれば、投稿先も対象リポジトリになる。

## 手順10: 後始末する（**失敗しても必ず通る**）

```bash
[ "$reference_tmpdir" != "null" ] && \
  bash .claude/scripts/src/answer-talker-reference.sh cleanup --tmpdir "$reference_tmpdir"
rm -rf "$tmpdir"
```

`cleanup` は冪等で、`resolve` が作った一時ディレクトリ以外は削除しない。
**手順6〜9のどこで失敗しても、この手順は実行する。**

## 手順11: 結果を報告する

- 投稿件数・サマリへ回った件数・**ネタバレ検査で落とした件数と反応した語**・報告のみに留めた件数。
- 報告のみの指摘は、この会話に**内容を書き出す**（MRを見ても残らないため）。
- `truncatedFiles` / `capped` が立っていた場合はその事実。
- 指摘が0件だった場合は、その旨（水増ししない）。

## CLI不在時（`get_vcs_access_mode` が `mcp`）の読み替え

GitHubのみ。GitLabは対象外（DDR 0027）。WebFetch・curlへはフォールバックしない。

| 手順 | 読み替え |
|---|---|
| 手順2 | `get_mr_changed_files` → `mcp__github__pull_request_read`（`method="get_files"` で変更ファイル、`method="get"` で base/head/headSha）。`owner`/`repo` は `--repo` の値、省略時は `get_repo_slug` |
| 手順9 | `add_mr_inline_comments` → `mcp__github__pull_request_review_write`（`method="create"` → 指摘ごとに `add_comment_to_pending_review` → **必ず `submit_pending`**。失敗したら `delete_pending`） |
| 手順3・4・7 | 読み替え不要（ローカルのスクリプトのみ） |

## してはいけないこと

- **手順7（ネタバレ検査）を飛ばすこと。** サブエージェント側の規約だけでは、構造の転記
  （「A/B/Cの3つに分ける」）を防げない。二段構えで初めて機能する。
- **正解のコード片・正解にしか存在しない識別子を、コメント本文や会話へのまとめへ書くこと。**
- **`--repo` を省略したまま、別リポジトリのつもりで実行すること**（手順1の表示を省略しない）。
- **手順9でラベル（第3引数）を省略すること**（「敵対的レビュー」として投稿されてしまう）。
- 正解ディレクトリ（ローカルパス指定時）を書き換えること。
- 手順10（後始末）を飛ばすこと。
- スレッドの解決（resolve）操作を行うこと（レビュアー側の操作）。
- 指摘が0件のときに、水増しして投稿すること。
- 受講者のコミットメッセージ・issueをサブエージェントへ渡すこと（実装者の意図が混入する）。
