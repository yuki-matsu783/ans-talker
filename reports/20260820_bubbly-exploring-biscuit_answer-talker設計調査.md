---
title: answer-talker スキルの設計調査 結果
type: report
description: issue #1 の answer-talker スキルを設計するための調査結果。既存adversarial-reviewからの再利用範囲、MR番号起点のdiff取得、正解ソースの取得方式、ファイル対応付け、ネタバレ検査の粒度、実例確認の題材の6論点。
tags: [answer-talker, 調査結果, report, issue-mr-flow]
keywords: [answer-talker, adversarial-review, Provider.sh, get_mr_diff, shallow clone, ネタバレ検査, 対応付け, findings, 実機確認, 未決定事項]
---

# answer-talker スキルの設計調査 結果

- issue: [#1](https://github.com/yuki-matsu783/ans-talker/issues/1) / PR: [#2](https://github.com/yuki-matsu783/ans-talker/pull/2)
- 個別調査計画: `plans/【調査】answer-talkerスキルの設計調査.md`（flow-id 2-4で合意）
- 実施: 2026-08-20（flow-id 2-6）

## 結論の要約

| 論点 | 結論 |
|---|---|
| 1. `adversarial-review` からの再利用 | findings JSONスキーマ・承認モデル・選別表・投稿関数は**そのまま再利用**。観点の出どころと入力（正解ソース）が固有。**実施回数の上限機構は課さない** |
| 2. MR番号起点のdiff取得 | `gh api repos/{owner}/{repo}/pulls/<n>/files` を採る（`gh pr diff` ではない）。返却は `{base, head, files:[{path,status,additions,deletions,patch}]}`。**GitLabでは `/merge_requests/:iid/diffs` ＋ MRメタ情報の2回**で同じ形へ正規化できることを実機で確認した |
| 3. 正解ソースの取得 | **ローカルパスはcloneせず読み取り専用でそのまま使う**（`--depth` が効かないことを実機で確認）。URLのみ shallow clone し `trap` で後始末 |
| 4. ファイル対応付け | 機械的に決めるのは「同一パス」「ファイル名一致」まで。対応が付かない要素の**意味づけはサブエージェントに委ねる** |
| 5. ネタバレ検査 | 「正解にしか現れない識別子」を主、正規化後の行一致を補助にする。**1語でも混入したらその finding を落とす** |
| 6. 実例確認の題材 | 使い捨ての最小フィクスチャを実装時に作る。**投稿直前まで**を確認範囲とする案を提案（要合意） |

**この調査で確かめられなかったこと**（詳細は各論点と末尾「未決定事項」）:
3000ファイル超・巨大ファイルでの `pulls/<n>/files` の挙動、GitLab側で差分が
truncate/collapse される規模での挙動、実際の演習リポジトリでの動作。

> **追記（flow-id 2-9・レビュー1周目）**: 当初「GitLab経路は `glab` が無いため未検証」としていたが、
> ローカルにGitLab CE 18.5.4のdockerコンテナ（`localhost:8929`）と `glab` 1.114.0 があるとの
> 指摘を受け、**実機で検証した**。結果は論点2「GitLab経路の実機確認」に記載し、
> 未決定事項#1（GitLab対応の扱い）は解消した。

---

## 論点1: 既存 `adversarial-review` からの再利用範囲

### 決定的な構造の違い

読んだファイル: `.claude/skills/adversarial-review/SKILL.md`、
`.claude/agents/adversarial-reviewer.md`、`.claude/scripts/src/adversarial-review-count.sh`、
`.claude/scripts/src/vcs/Provider.sh`、`.claude/scripts/src/vcs/Github.sh`。

**`adversarial-review` は「自分のブランチのMR」を対象にする。** SKILL.md 手順7は
`get_mr_for_branch "$(git branch --show-current)"` でMR番号を得ており、対象ファイルの列挙も
`git diff --name-only origin/<base>...HEAD`、実施回数の状態も
`.claude/state/adversarial-review/<ブランチ名>.json`（`adversarial-review-count.sh:29`）と、
**すべてローカルの作業ツリー・現在のブランチに紐づいている**。

**`answer-talker` は「他人（受講者）のMR番号」を引数で受ける。** 現在のブランチとは無関係であり、
そもそも受講者のブランチをローカルにチェックアウトしていない。

これが、issueの「現状」が挙げていた **`Provider.sh` にMR番号起点のdiff取得関数が無い**という
問題の根本原因である。既存機構がブランチ起点で組まれているため、MR番号起点の入口が存在しない。

### 再利用するもの

| 要素 | 場所 | 再利用できる理由 |
|---|---|---|
| findings JSONスキーマ | `.claude/agents/adversarial-reviewer.md`「出力」 | `github_filter_findings_by_valid_lines` / `format_findings_summary` / `github_build_review_payload`（`Github.sh:284,307`, `Provider.sh:787`）が**このスキーマ前提で実装済み**。変えると投稿経路を作り直すことになる |
| インライン投稿 | `add_mr_inline_comments <MR番号> <findingsファイル>`（`Provider.sh:811`） | **MR番号を引数で取る設計**のため、他人のMRにもそのまま使える。有効行の検証・サマリへの振り分け・GitHub/GitLab差異の吸収を内包している |
| 承認モデル | SKILL.md 手順3 | 「GitHubの提出済みレビューは削除できないので、承認は投稿前に1回へ集約する」という理由が、演習レビューにもそのまま当てはまる |
| 確度×重大度の選別表と1回10件の上限 | SKILL.md 手順6 | 同上。レビュアー（講師）が一度に扱える量の問題は同じ |
| サブエージェントを読み取り専用にする方針 | `adversarial-reviewer.md` frontmatter（`tools: Read, Grep, Glob, Bash`） | 投稿・修正は呼び出し元の責務、という責務分離は維持すべき |
| `gh`/`glab` 不在時のMCP読み替え | SKILL.md「CLI不在時」 | 同じ投稿経路を使うため、そのまま流用できる |

### 固有にするもの

| 要素 | `adversarial-review` | `answer-talker` |
|---|---|---|
| レビュー対象の決め方 | 現在のflow-idから自動判別 | **引数のMR番号** |
| 観点の出どころ | `REVIEW-POINTS.md`（`collect-review-points.sh`） | **正解ソースそのもの**。`collect-review-points.sh` は使わない（演習リポジトリの構造は本リポジトリの観点表と無関係） |
| サブエージェントへの入力 | 「渡されたもの以外を探しに行くな」 | **正解ディレクトリを読ませる必要がある**ため、許可する読み取り範囲を明示的に定義し直す |
| 検査段 | 無し | **ネタバレ検査**が投稿の直前に挟まる |
| 実施回数の上限 | 各フェーズ最大3回（機械的に強制） | **課さない**（下記） |

### 実施回数の上限機構を課さない判断

`adversarial-review-count.sh` の冒頭コメントが、上限の目的を明示している。

> 非対話モードでは「レビュー → 修正 → 再レビュー」が人間の介在なく回りうるため、実施回数を
> 機械的に記録し、各フェーズ最大3回で打ち切る。

`answer-talker` はこの前提を3点で満たさない。

1. **人間（講師）が明示的に引数付きで呼ぶ**。AIが自律的に再実行するループが存在しない。
2. **フェーズ番号を持たない**。カウンタのキーは issue-mr-flow のフェーズ 2/3/4 であり、
   フローの外にある `answer-talker` には対応する値がない。
3. **状態の単位が合わない**。状態はブランチ名で分かれるが、`answer-talker` の対象は他人のMRで
   あり、実行者のブランチとは無関係。同じMRを別ブランチから2回レビューしても別カウントになり、
   逆に別のMRを同じブランチから何度レビューしても同一カウントになる。

「同じMRへ何度も投稿して埋め尽くす」リスクは残るが、**投稿前の承認1回**と**1回10件の上限**で
足りると判断した。**この判断はDDR候補**（flow-id 4-1で洗い出す）。

### issue-mr-flow との位置づけ

`adversarial-review` は「flow-idを増やさない**並行手順**」として定義されている
（`issue-mr-flow/SKILL.md`「敵対的レビューの位置づけ」）。`answer-talker` はさらに外側で、
**このリポジトリのフローの中で使うものではない**（別リポジトリの受講者MRをレビューする
スタンドアロンのスキル）。したがって issue-mr-flow への追記は最小限で足りる見込み。

**設計への反映**: SKILL.md の骨格は `adversarial-review` を踏襲しつつ、手順2（対象の判別）を
「引数の解釈と正解ソースの取得」へ、手順1（実施回数）を削除し、投稿直前に「ネタバレ検査」を
挿入した構成にする。

---

## 論点2: MR番号起点のdiff取得（`Provider.sh` への追加関数）

### 実機確認（GitHub経路・PR #2 に対して実行）

```bash
$ gh pr view 2 --json files --jq '.files[] | "\(.path)\tadditions=\(.additions)\tdeletions=\(.deletions)"'
HANDOFF.md	additions=80	deletions=76
plans/bubbly-exploring-biscuit.md	additions=154	deletions=0
plans/【調査】answer-talkerスキルの設計調査.md	additions=162	deletions=0
worklog/20260820_bubbly-exploring-biscuit_【調査】answer-talkerスキルの設計調査_push1.md	additions=51	deletions=0

$ gh pr diff 2 | wc -l
565

$ gh pr view 2 --json headRefName,baseRefName,headRefOid --jq '.'
{"baseRefName":"main","headRefName":"feature-1-add-answer-talker-review-skill","headRefOid":"1aa1c3a89aba867858ae682ccad2a7a63decf49a"}

$ gh api "repos/{owner}/{repo}/pulls/2/files" --paginate | jq -r '.[0] | keys | join(", ")'
additions, blob_url, changes, contents_url, deletions, filename, patch, raw_url, sha, status

$ gh api "repos/{owner}/{repo}/pulls/2/files" --paginate | jq -r '.[] | "\(.filename)\tstatus=\(.status)\tpatch_bytes=\(.patch // "" | length)"'
HANDOFF.md	status=modified	patch_bytes=7969
plans/bubbly-exploring-biscuit.md	status=added	patch_bytes=6198
plans/【調査】answer-talkerスキルの設計調査.md	status=added	patch_bytes=5746
worklog/...push1.md	status=added	patch_bytes=1950
```

日本語を含むパスが、いずれの経路でもエスケープされずそのまま返ることを確認した。

### 採用する取得経路: `pulls/<n>/files`

`gh pr diff`（unified diff のテキスト）ではなく **`gh api repos/{owner}/{repo}/pulls/<n>/files`**
を採る。理由は3点。

1. **投稿時の有効行判定と情報源が一致する。** `github_add_mr_inline_comments`（`Github.sh:331`）は
   まさにこのエンドポイントを叩き、`github_valid_ranges_from_files_json` で有効行を算出している。
   `gh pr diff` の出力を自前でパースすると、**レビュー時に見た行と投稿可能な行がズレる**余地が
   生まれる。
2. **`status` が取れる**（`added` / `modified` / `removed` / `renamed`）。受講者側で削除された
   ファイル・新規追加されたファイルの区別は、正解との対応付け（論点4）に必要。
3. **ファイル単位に構造化されている。** 対応付け（論点4）とネタバレ検査（論点5）へそのまま
   渡せる。unified diff のテキストからファイル境界を切り出す処理を自前で持たずに済む。

### 差分の基準

`pulls/<n>/files` は **マージベースからの差分**（`base...head` の three-dot）を返す。受講者が
初期状態（defaultブランチ）から進めた分だけが対象になり、**演習の意図と一致する**。
base側がその後進んでいても、受講者が書いていない変更が混ざらない。

### 関数のインターフェース案

```bash
get_mr_diff <MR番号>
# → {"base":"main","head":"feature-...","headSha":"...",
#    "files":[{"path":"...","oldPath":"...","status":"modified",
#              "additions":80,"deletions":76,"patch":"...","truncated":false}]}
```

**この形は、GitHub（PR #2）とGitLab（`root/issue45-verify!3`）の実データから実際に組み立てて
キー集合の一致を確認済み**（下記「GitLab経路の実機確認」）。`status` は
`added`/`modified`/`removed`/`renamed` の4語彙に統一し、`truncated` は「差分本文を取得できな
かった／切り捨てられた」ことを表す。

- **返却はstdoutへのJSON1つ**（`Provider.sh` の全関数と同じ規約）。ただし**呼び出し側は
  必ずファイルへリダイレクトし、コマンド置換 `$(...)` で受けない**ことをSKILL.md側の規約として
  明記する。diffのサイズは受講者の実装規模に比例して無制限に大きくなり、
  `.claude/rules/shell-script-style.md`「大きなJSONを`--argjson`等で渡さない」（実測で
  Windowsのコマンドライン長上限は約32KB）に容易に達するため。
  - 参考値: PR #2（4ファイル）で patch 合計 **約21.9KB**。演習の実装はこれより大きくなりうる。
- `base` / `head` / `headSha` を同じJSONに含める。`gh pr view --json headRefName,baseRefName,headRefOid`
  で取得できることを確認済み（上記）。別関数に分けると呼び出しが2回になり、その間にMRが更新
  されると不整合が起きる。
- 命名は既存の `get_mr_diff_url` / `get_mr_diff_since_url`（URLを組み立てるだけの関数）と
  紛らわしいため、**`get_mr_changed_files` 等への改名も検討する**（設計フェーズで決める）。

### GitLab経路の実機確認（flow-id 2-9で追加）

**環境**: ローカルのGitLab CE **18.5.4-ce.0**（dockerコンテナ `gitlab`、`http://localhost:8929`）、
`glab` **1.114.0**（`root` として認証済み）。対象は既存の検証用MR
`root/issue45-verify` の `!3`。`glab` はホスト指定に `--hostname` ではなく
`GITLAB_HOST=http://localhost:8929` の環境変数を使う（`--hostname localhost:8929` は
`Error parsing --hostname: invalid hostname.` で失敗した。ポート付きを受け付けない）。

**2つのエンドポイントを比較した。**

| | `GET …/merge_requests/:iid/changes`（旧） | `GET …/merge_requests/:iid/diffs`（新） |
|---|---|---|
| 返る形 | MRオブジェクト全体＋`changes[]` | **差分の配列のみ** |
| ファイル単位のキー | `old_path` `new_path` `new_file` `deleted_file` `renamed_file` `diff` | 左記＋ **`too_large`** `collapsed` `generated_file` `a_mode` `b_mode` |
| MRメタ情報 | `source_branch` `target_branch` `sha` `diff_refs`(base/head/start_sha) `changes_count` を**同じ応答に含む** | **含まない**（別途 `GET …/merge_requests/:iid` が要る） |
| 切り捨ての表現 | トップレベルの **`overflow`**（今回は `false`） | **ファイル単位**の `too_large` / `collapsed` |
| ページング | **無し**（`per_page` を付けてもページングヘッダが返らない） | **有り**（`X-Total: 1` `X-Page: 1` `X-Per-Page: 1` `X-Total-Pages: 1` を確認） |

**採用: `/diffs` ＋ `GET …/merge_requests/:iid`（2回）。** 理由は、(a) 切り捨てを**ファイル単位**で
把握できる（`overflow` だとどのファイルが欠けたか分からない）、(b) ページングがあるため大きなMRでも
全件取れる、(c) `/changes` は公式に非推奨とされている。**ただし今回のGitLab 18.5.4-ce.0 では、
`/changes` のレスポンスヘッダに非推奨・Sunsetの告知は返らなかった**（`glab api -i` で確認。
`HTTP/1.1 200 OK` のみ）ので、非推奨であること自体はこの実機確認では裏取りできていない。

**共通形への正規化が両プロバイダで成立することを確認した。** 論点2で提案した返却JSONの形を、
GitHub（PR #2）とGitLab（`root/issue45-verify!3`）の実データからそれぞれ組み立て、キー集合が
一致することを確かめた。

```bash
$ jq -r 'keys|join(",")' gh-normalized.json ; jq -r 'keys|join(",")' gl-normalized.json
base,files,head,headSha
base,files,head,headSha
$ jq -r '.files[0]|keys|join(",")' gh-normalized.json ; jq -r '.files[0]|keys|join(",")' gl-normalized.json
additions,deletions,oldPath,patch,path,status,truncated
additions,deletions,oldPath,patch,path,status,truncated
```

**プロバイダ間で埋める必要がある差は2つだけだった。**

1. **`status`**。GitHubは `added`/`modified`/`removed`/`renamed` を直接返す。GitLabは真偽値
   （`new_file` / `deleted_file` / `renamed_file`）なので、この順で判定して同じ語彙へ変換する。
2. **`additions` / `deletions`**。**GitLabはファイル単位の増減行数を返さない**（キー自体が無い）。
   `diff` 本文の行頭 `+` / `-`（`+++` / `---` を除く）を数えて算出する。実データで検算した:
   `sample.txt` は算出値 `+2/-2` で、`glab mr diff` の出力（`+line02-modified` `+line11-added` /
   `-line02` `-line04`）と一致した。

**`glab mr diff` は使わない。** 出力が `--- path` / `+++ path` から始まる形で、
`diff --git` ヘッダを持たない独自形式だった（15行）。API経由の構造化データのほうが扱いやすい。

### 確かめられなかったこと・制約

- **`patch` が省略されるケース**（GitHub）。巨大ファイル・バイナリで `patch` キーが返らない。
  今回のPRは全ファイルで `patch` が存在したため**未確認**。実装では「差分を読めなかったファイル」
  として名前と `status` だけをサブエージェントへ渡す扱いにする。
- **3000ファイル上限**（GitHub）。`pulls/<n>/files` は1PRあたり最大3000ファイルまで。
  演習規模では到達しない見込みだが、**到達したことを検知して報告する**（無言で切り捨てない）。
- **GitLab側で `too_large` / `collapsed` が真になる規模**は未確認（今回のMRは1ファイル129バイト）。
  正規化の `truncated` は **`too_large` と `collapsed` の論理和**で立てる（片方だけを見ると、
  折りたたまれて `diff` が空のファイルを「差分なし」と誤って扱う）。
- **リネームされたファイル**の挙動は両プロバイダとも未確認（今回のMRに改名が含まれない）。
  GitHubは `previous_filename`、GitLabは `old_path` を旧パスとして使う想定。

---

## 論点3: 正解ソースの取得方式

### 実機確認

```bash
$ git clone --depth 1 --no-tags "c:/Users/taniyama/Desktop/git/ans-talker" local-clone
Cloning into 'local-clone'...
warning: --depth is ignored in local clones; use file:// instead.
done.
real 0m1.626s
$ git -C local-clone rev-list --count HEAD
4                      # ← 全履歴がコピーされている（浅くなっていない）

$ git clone --depth 1 --no-tags --single-branch https://github.com/yuki-matsu783/ans-talker.git url-clone
real 0m2.007s
$ git -C url-clone rev-list --count HEAD
1                      # ← 1コミットのみ
$ du -sh url-clone/.git
744K

$ git clone --depth 1 plaindir plain-clone
fatal: repository 'plaindir' does not exist      # ← gitリポジトリでないディレクトリは clone できない
```

### 設計への反映

**ローカルパスは clone しない。読み取り専用でそのまま使う。** 理由は3点。

1. `--depth 1` が**局所cloneでは無視される**（gitが警告を出す）。浅くする利点が得られない。
2. **正解が必ずしもgitリポジトリとは限らない。** ただのディレクトリで配布される可能性があり、
   cloneを強制するとその形態を受け付けられなくなる（3番目の実行結果）。
3. コピーの分だけ時間とディスクを使う。

副作用として「実行中に正解ディレクトリを書き換えない」保証が必要になる。サブエージェントに
Write/Edit ツールを持たせないこと（`adversarial-reviewer` と同じ）で担保する。

**URLのみ shallow clone する。** `--depth 1 --single-branch --no-tags`。特定のブランチ・タグを
指定できるよう `--branch <ref>` を受け付ける。

**後始末は `trap` で行う。**

- 既存の `github_add_mr_inline_comments`（`Github.sh:334`）は `tmpdir="$(mktemp -d)"` の後、
  **末尾の `rm -rf "$tmpdir"` だけ**で後始末しており、途中で失敗すると一時ディレクトリが残る。
  新規スクリプトはこれを踏襲せず、`extract-frontmatter.sh:317` の
  `trap cleanup_tmp_files EXIT INT TERM` の形に倣う。
- **cloneしなかった場合（ローカルパス指定）は絶対に消してはいけない。** 後始末の対象は
  「自分が作った一時ディレクトリだけ」であることを、返却JSONの `cleanup` フラグで明示する。

### 実装時に踏むと分かっている落とし穴

- **cloneの失敗をパイプで潰さない。** 検証中に `git clone ... 2>&1 | tail -3` と書いたところ、
  cloneが `fatal:` で失敗しているのに `$?` が **0** になった（パイプの終了コードは `tail` のもの）。
  `set -euo pipefail` 配下でも、明示的に終了コードを見る場合は注意する。
- **`MSYS_NO_PATHCONV` は不要**。`git` はMSYSネイティブのためパス変換の恩恵を受ける側であり、
  止めると逆に壊れる（`.claude/rules/shell-script-style.md`「git bashのパス変換の落とし穴」の
  後半、jqの事例と同じ）。docker等を呼ばないこのスクリプトでは `export` しない。
- **認証は扱わない。** 非公開リポジトリのcloneはgitの資格情報ヘルパに依存し、`gh auth` とは
  別系統である。スキル側で資格情報を要求・保存しない（**対象外と明記する**）。

### インターフェース案

```bash
bash .claude/scripts/src/resolve-reference-source.sh --reference <URL|パス> [--ref <ブランチ/タグ>]
# → {"kind":"url"|"local","root":"<正解ルートの絶対パス>","cleanup":true|false,"tmpdir":"..."}
```

後始末を呼び出し側（SKILL.md の手順）に委ねるか、スクリプトに `--cleanup <tmpdir>` サブコマンドを
持たせるかは**未決定**（末尾参照）。AIエージェントが手順を飛ばしうることを考えると、後者のほうが
「明示的な後始末ステップ」として手順書に書きやすい。

---

## 論点4: 受講者の変更ファイルと正解側ファイルの対応付け

### パス一致だけでは、最も指摘したいケースで必ず失敗する

演習では、受講者が正解と同じファイル名・同じ構成を作るとは限らない。むしろ
**「分割単位が違う」こと自体が指摘対象**である（issue「期待する動作」4の第1項）。
受講者が1ファイルに詰め込んでいる場合、正解側の3ファイルはどれもパス一致しない。
**パス一致のみの対応付けは、最も指摘したいケースでちょうど機能しなくなる。**

### 採用する段階

| 段階 | 判定 | 機械/AI |
|---|---|---|
| 1 | 同一パス（完全一致） | 機械 |
| 2 | ファイル名一致（ディレクトリが違う） | 機械 |
| 3 | 1・2で対応が付かない**正解側だけのファイル** | 機械（列挙まで） |
| 4 | 1・2で対応が付かない**受講者側だけのファイル** | 機械（列挙まで） |

**3・4の意味づけは機械で決めない。** 「正解側にしかない」ことが
「受講者がまだ作っていない分割単位」なのか「別解として妥当な構成の違い」なのかは、
中身を読まなければ決まらない。issueの要件「**正解と実装が違っていても、方針として妥当なら
指摘しない**（別解を潰さない）」を機械判定で満たすことは不可能であり、ここはサブエージェントの
判断に委ねる。

### サブエージェントへ渡す入力の形（案）

```json
{
  "diff": {"base":"main","head":"...","files":[{"path":"...","status":"...","patch":"..."}]},
  "reference": {"root":"<正解ルートの絶対パス>","files":["...","..."]},
  "mapping": {
    "matched":[{"submission":"internal/handler.go","reference":"internal/handler.go","by":"path"}],
    "referenceOnly":["internal/repository.go","internal/usecase.go"],
    "submissionOnly":["main.go"]
  }
}
```

**正解ファイルの中身はプロンプトへ載せず、サブエージェントに Read で読ませる。** 理由は2点。

1. 正解の規模が未知であり、全文を載せるとコンテキストに収まらない。
2. **プロンプトへ載せるほど転記のリスクが上がる。** 読ませる範囲を必要最小限に絞れる形にする。

ただしこれは「サブエージェントが正解を読める」＝ネタバレの源泉でもある。だから論点5の機械的検査を
**投稿の直前**に置く必要がある（issueの要件が求める二重化は、この構造から必然的に導かれる）。

---

## 論点5: ネタバレ防止の機械的検査

### 粒度の候補と評価

| 候補 | 捕まえられるもの | 問題 |
|---|---|---|
| (a) 行単位の完全一致 | 正解の行をそのまま貼った場合 | **誤検知が多すぎる**（定型行が正解にも存在する） |
| (b) 正規化後の一致（空白畳み込み等） | 空白・改行だけ変えた転記 | (a)の誤検知がさらに悪化する |
| (c) 正解にしか現れない識別子 | 正解固有の型名・関数名・定数名の羅列 | 抽出の質に依存する |

**(c)を主、(b)を補助**とする。issueの要件が「正解のコード片・**正解にしか存在しない識別子の
羅列**を含めない」と、まさに(c)の語彙で書かれている点とも一致する。

### 誤検知しやすい例（実際に問題になる3件）

1. `if err != nil {` / `return nil, err` — Goの定型。正解にも必ず存在するが、指摘本文で
   エラー処理の一般論として書いても何もネタバレしていない。
2. `func main() {` / `package main` — 言語の構文そのもの。
3. **一般語**（`repository` `handler` `service` `config`）— 設計原則を説明する言葉として
   指摘本文に必要であり、正解にも当然出てくる。

→ 識別子の抽出時に、**(i) 受講者側diffにも現れる語、(ii) 一般的な英単語・言語のキーワード、
(iii) 短すぎる語**を除外する必要がある。除外しないと、検査が指摘をほぼ全滅させる。

### 見逃しやすい例（3件）

1. **変数名だけ変えた転記**（`userRepository` → `repo`）。行単位一致では捕まらない。
2. **空白・改行を変えた転記**。→ 正規化(b)を補助に置く理由。
3. **構造そのものの転記**（「`X` を `A`/`B`/`C` の3ファイルに分け、`A` が `B` を呼ぶ」）。
   コード片ではないが**ネタバレそのもの**。**機械検査では原理的に捕まえられない。**

→ 3番目があるため、**サブエージェント側の規約（「正解ではこうなっている」と書かない）は
検査では代替できない**。issueが二重化を求めているのは正しい。

### 閾値と混入時の挙動

- **「正解にしか現れない識別子が finding 本文に1つでも現れたら、その finding を落とす」。**
  演習でのネタバレは一度起きたら取り返しがつかず（投稿は取り消せない）、一方で指摘を1件落として
  も他の指摘は残る。**損失が非対称なので、厳しい側へ倒す。**
- **混入を検知した finding のみを落とし、落とした件数を報告する。** 全体を中止しない理由は、
  1件の誤検知で全部落ちる設計だと、運用上「検査を緩める」圧力がかかるため。
- ただし **落とした結果0件になったら投稿自体を行わない**（空のレビューを投稿しない）。

### 単体テストの骨子（純粋関数へ切る）

`.claude/scripts/test/` の既存流儀（`passed=N failures=N` を出力し、失敗時に終了コード1）に
合わせる。純粋関数として切るのは次の2つ。

1. **禁止語の抽出**: (正解側の語) − (受講者側diffの語) − (一般語・キーワード) → 禁止語集合
2. **混入判定**: (finding本文, 禁止語集合) → 混入した語のリスト

境界値として必ず含めるケース:

- findings 0件 / 正解ファイル0件 / finding本文が日本語のみ
- **部分文字列**（禁止語 `repo` が本文中の `repository` に含まれる場合）→ **単語境界で判定する**
- マルチバイト文字を含む識別子・本文（`.claude/rules/shell-script-style.md` の
  「日本語を `${var:0:N}` で切らない」に該当しない実装にする）
- 大文字小文字の違い（`UserRepo` と `userrepo`）をどう扱うか

---

## 論点6: 実例確認に使う演習MR・正解ソースの題材

### 本リポジトリのPRは代用できない

PR #2 を「受講者のMR」に見立てることは可能だが、**それに対応する「正解」が存在しない**。
正解側にしかない分割単位を検出できるかの確認にならないため、代用は不可。

### 最小の題材を使い捨てで作る

「1ファイルに詰め込んだ実装」対「同じ機能を3ファイルへ分割した正解」という、
**分割単位の差だけを持つ最小の題材**があれば、受け入れ条件
「正解側にしか存在しない分割単位について……実例で確認している」を満たせる。

置き場所については、`.claude/skills/answer-talker/` 配下に演習用のダミーコードを恒久的に
同梱することは避けたい（plugin配布物にサンプルアプリが混ざる）。受け入れ条件も
「実例で確認している」であって恒久的な同梱を求めていない。
→ **フェーズ3の実装時に使い捨てで作り、確認結果を `reports/` へ記録する**方式を推奨する。

### 投稿までやるかどうか（要合意）

実際にMRへ投稿して確認しようとすると、演習用リポジトリが無い現状では**本PR #2 しか対象が無く、
そこへダミーの指摘を投稿することになる**。これは不適切と考える。

→ **「findings確定・ネタバレ検査通過」までを確認範囲とし、投稿は行わない**という線引きを
提案する。投稿経路（`add_mr_inline_comments`）は `adversarial-review` で実績のある既存関数を
そのまま使うため、ここを実行しないことによる未検証リスクは小さい。
**この線引きは人間の合意が必要**（flow-id 3-1 で諮る）。

---

## 未決定事項

| # | 論点 | 内容 |
|---|---|---|
| ~~1~~ | 2 | ~~**GitLab対応の扱い**~~ → **解消**（flow-id 2-9）。ローカルのGitLab CE 18.5.4 と `glab` 1.114.0 で実機検証できたため、**GitLabも対象に含めて実装する**。エンドポイントは `/diffs` ＋ MRメタ情報の2回 |
| 2 | 2 | `get_mr_diff` の返却をstdoutにするか、出力ファイルパスを引数で受けるか（既存規約 対 サイズの実務） |
| 3 | 2 | 関数名（`get_mr_diff` は既存の `get_mr_diff_url` と紛らわしい） |
| 4 | 3 | 正解ソースの後始末を、呼び出し側の手順に委ねるか、スクリプトの `--cleanup` サブコマンドにするか |
| 5 | 5 | 「一般語・言語キーワード」の除外リストをどこに持つか（スクリプト内の定数 / 外部ファイル / 言語ごと） |
| 6 | 6 | 実例確認で実際にMRへ投稿するか、投稿直前で止めるか（上記の提案の可否） |

## 設計（フェーズ3）へ引き渡す項目

フェーズ3の `【設計】` 計画には、少なくとも次を書けるだけの材料が揃った。

- 追加するファイル: `.claude/skills/answer-talker/SKILL.md`、
  `.claude/agents/answer-talker-reviewer.md`、`.claude/scripts/src/resolve-reference-source.sh`、
  ネタバレ検査スクリプト、`.claude/scripts/test/test_*.sh`
- `Provider.sh` へ追加する関数のシグネチャと返却JSONの形（論点2）
- 正解ソース取得スクリプトの引数・返却・後始末の方式（論点3）
- サブエージェントへ渡す入力JSONの形（論点4）
- ネタバレ検査のアルゴリズムとテストケース骨子（論点5）
- SKILL.md の手順構成（`adversarial-review` の手順1を削除、手順2を差し替え、投稿直前に検査を挿入）
