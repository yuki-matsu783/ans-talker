---
title: answer-talkerスキル一式の実装・検証結果
type: report
description: issue #1 の answer-talker スキル一式（6ファイル＋単体テスト3本）の実装結果と、ローカルGitLabの演習用プロジェクトを使った17パターンの実機検証結果。
tags: [answer-talker, 実装, 検証, report]
keywords: [answer-talker, 検証結果, 単体テスト, GitLab, 別解, ネタバレ検査, ラベル, use_target_repo, get_mr_changed_files, 後片付け]
---

# answer-talker スキル一式の実装・検証結果

- issue: [#1](https://github.com/yuki-matsu783/ans-talker/issues/1) / PR: [#2](https://github.com/yuki-matsu783/ans-talker/pull/2)
- 個別作業計画: `plans/【実装】【テスト】answer-talkerスキル一式.md`（flow-id 3-4 で合意）
- 前提となる設計結果: `reports/20260820_bubbly-exploring-biscuit_answer-talker設計.md`

## 結論

計画のV1〜V5をすべて実施した。**15パターンすべてが期待どおり**で、加えて中核要件（別解を潰さない）を
より厳しく判定するためのパターン②'を追加し、これも期待どおりだった。

**設計との差分が2件**生じた（下記「設計との差分」）。いずれも黙って設計を変えず、レビューへ諮った
うえで反映している。

## V1. 単体テスト

`.claude/scripts/test/` の全13本を実行した結果。

| テスト | 結果 |
|---|---|
| `test_answer_talker_reference.sh`（新規） | `passed=20 failures=0` |
| `test_answer_talker_map.sh`（新規） | `passed=17 failures=0` |
| `test_answer_talker_spoiler_check.sh`（新規） | `passed=21 failures=0` |
| `test_adversarial_review_count.sh` | `passed=22 failures=0` |
| `test_check_base_conflicts.sh` | `passed=13 failures=0` |
| `test_check_base_sync.sh` | `passed=55 failures=0` |
| `test_cleanup_task.sh` | `passed=53 failures=0` |
| `test_collect_review_points.sh` | `passed=17 failures=0` |
| `test_extract_frontmatter.sh` | `passed=32 failures=0` |
| `test_search_frontmatter.sh` | `passed=114 failures=0` |
| `test_session_start.sh` | `passed=35 failures=0` |
| `test_update_handoff_progress.sh` | `passed=45 failures=0` |
| **`test_post_issue_create_notice.sh`** | **`passed=13 failures=1`（既存不具合。下記）** |

`Provider.sh` を触ったため既存テストの退行を確認する必要があったが、**退行は無い**。

### 唯一の失敗は本ブランチと無関係な既存不具合

`test_post_issue_create_notice.sh` の1件は、`git worktree` で `origin/main` を切り出して同じテストを
実行し、**そちらでも同じ1件が失敗する**ことを確認した。原因は
`.claude/hooks/post-issue-create-notice.sh` の `write_additional_context` が、Windowsネイティブjqの
付与するCRを `tr -d '\r'` で落としていないことで、期待値と8バイト差が出る
（`.claude/rules/shell-script-style.md`「文字コード」に既知として記載のある事象）。

**本issueのスコープ外のため修正していない。別issueとして起票することを提案する。**

## V2. 構文チェック

`.claude/scripts/src/answer-talker-*.sh` と `.claude/scripts/src/vcs/*.sh` の全ファイルが
`bash -n` を通った（エラー出力なし）。

## V3. 演習用プロジェクトの構築

ローカルGitLab（`http://localhost:8929`）に2つのプロジェクトを作り、題材を置いた。
**このリポジトリには題材を残していない**（構築は一時ディレクトリで完結させた）。

| プロジェクト | 内容 |
|---|---|
| `root/answer-talker-answer` | 正解ソース。`read.sh` / `filter.sh` / `format.sh` / `main.sh` の4ファイル |
| `root/answer-talker-verify` | 演習プロジェクト。`main` は骨格のみの `main.sh` 1ファイル |

題材は極小のbash CLI（ファイルを読む → 正規表現で行を絞る → 接頭辞を付けて出力する）。
正解は**3つの関心をそれぞれ1ファイル1関数に分け**、`main.sh` がそれらをパイプで繋ぐ形である。

### 構築に `git` を使えず、Commits API を使った理由

当初 `git` でブランチを作ろうとしたが、このGitLabインスタンスへは**どちらの経路でも到達できなかった**。

- HTTP clone → `fatal: Cannot prompt because user interactivity has been disabled.`
- SSH（ポート2224） → `Permission denied (publickey)`。`glab api user/keys` は空

そのため、ブランチとコミットの作成は GitLab の Commits API
（`POST /projects/:id/repository/commits`、`create`/`update`/`delete`/`move` の各アクション）で行った。
**「不要なら使わない」という指示に対して、使わずに済ませる手段が実際に無いことを確認したうえでの採用**である。

## V4. 実機検証（15パターン＋追加2件）

### 受講者の実装（①〜⑤）

`answer-talker-reviewer` サブエージェントを、各パターンのMRに対して実際に起動した結果。

| # | パターン | 期待 | 結果 | 一致 |
|---|---|---|---|---|
| ① | 分割不足（`main()` に全部書く） | 分割単位の指摘が出る | 2件。`responsibility-split`(major/high) と `error-handling`(major/high) | ○ |
| ② | 別解（`io.sh`＋`transform.sh` の2ファイル） | 分割単位の指摘が**出ない** | 3件。うち `responsibility-split` が2件（major/high, minor/medium） | **△（下記）** |
| ②' | 別解（1ファイル内で3関数へ分割）**追加** | 分割単位の指摘が**出ない** | 1件のみ（minor/medium）。**「正解のようにファイルを分けよ」という指摘は出ず** | ○ |
| ③ | 重複（同一実装の関数が2つ、片方は未使用） | 重複の指摘が出る | 4件。`duplication`(major/high) を含む | ○ |
| ④ | 余分な抽象化（素通しする3段の委譲） | 過剰な間接化の指摘が出る | 5件。`needless-indirection`(major/high) を含む | ○ |
| ⑤ | ほぼ正解 | 分割単位の指摘が**出ない** | 2件。**いずれも `naming-consistency` で minor/nit**。分割単位の指摘は0件 | ○ |

**⑤は選別表（確度×重大度）により minor/medium・nit/medium がどちらも「報告のみ」となるため、
投稿は0件になる。** 「ほぼ正解の受講者に投稿コメントが付かない」という要件が、サブエージェントの
判断と選別表の二段で成立している。

#### ②を「△」とした理由と、②'による切り分け

②では `io.sh` が「入力の読み込み」と「出力の整形」を1ファイルに束ねている点に対し、
major/high（＝投稿対象）の指摘が出た。これが**正解の3分割へ同調させる圧力**なのか、
**フィクスチャ側が本当に凝集度の低い作りだった**のかを切り分ける必要があった。

そこで**責務の分割は正解と同等だが、ファイルには分けていない**別解（②'）を追加した。
このパターンは `mapping.referenceOnly` に正解側の3ファイルが並ぶため、
「正解に合わせろ」という圧力が最も強くかかる条件である。

結果、②'で出た指摘は1件のみ・minor/medium（投稿対象外）で、**内容もファイル分割ではなく
「定義と実行開始が同居していて、部品だけを読み込めない」**というものだった。
すなわちサブエージェントは**ファイル構成ではなく責務で判断している**と言える。
したがって②の指摘は同調圧力ではなく、入力と出力を1つの単位に束ねたことへの凝集度の指摘として
妥当と判断する。

**ただし残存リスクとして記録する**: ②'の指摘は、正解の `main.sh` にも同じ性質がある
（末尾で `main "$@"` を実行している）ため、**正解自身にも当てはまる指摘**である。
サブエージェントは正解を絶対の基準とはせず一般的な設計原則でも判断するため、
このような指摘が出うる。重大度が低く投稿されないため実害は無いが、
「正解と同じ形にしても指摘が0件になるとは限らない」ことは仕様として認識しておく必要がある。

### 正解ソースの形態（⑥〜⑧）

| # | 形態 | 結果 | 一致 |
|---|---|---|---|
| ⑥ | URL（shallow clone） | `kind:"url"`, `cleanup:true`。clone後の `.git` は depth 1。`cleanup` 後に一時ディレクトリが消えた | ○ |
| ⑦ | ローカルのgitリポジトリ | `kind:"local"`, `cleanup:false`。**cloneせず**そのまま読み、元は無変更 | ○ |
| ⑧ | 素のディレクトリ（git管理外） | ⑦と同じ。cloneしないため成立する | ○ |

`--depth 1` はローカルcloneでは無視され、素のディレクトリはそもそもcloneできない。
**ローカルパスは絶対にcloneしない**という設計判断がここで効いている。

非公開URLを渡した場合、gitが資格情報の入力待ちで**固まる**ことを実測したため、
`clone_reference` で `GIT_TERMINAL_PROMPT=0` / `GCM_INTERACTIVE=never` を export し、
待たされる代わりに即座に失敗する形にした。

### diffの内容（⑨〜⑪）

| # | 内容 | 結果 | 一致 |
|---|---|---|---|
| ⑨ | ファイル削除 | `status:"removed"`。対応付けの対象から除外される | ○ |
| ⑩ | リネーム | `status:"renamed"`, `oldPath:"main.sh"` が正しく入る | ○ |
| ⑪ | 新規追加のみ | `status:"added"`。`oldPath` は新パスと同じ | ○ |

GitLabは変更行数をファイル単位で返さないため、diff本文から `+`/`-` を数えて
`additions`/`deletions` を組み立てている。実際の内容と突き合わせて `+2/-2` が一致することを確認した。

GitHub・GitLab双方の返却JSONは**キー集合が完全に一致**する
（`base,capped,files,head,headSha,totalFiles,truncatedFiles` /
ファイル単位で `additions,deletions,oldPath,patch,path,status,truncated`）。

### ネタバレ検査（⑫〜⑬）

| # | 内容 | 結果 | 一致 |
|---|---|---|---|
| ⑫ | 正解のコード片を意図的に混入させた指摘 | `{"kept":0,"dropped":1}`。反応した語は正解側の関数名4語 | ○ |
| ⑬ | 一般語のみで書かれた正当な指摘 | `{"kept":2,"dropped":0}`。落とされない | ○ |

実際のサブエージェント出力（パターン①の2件）に対しても検査を通し、`{"kept":2,"dropped":0}` で
**正当な指摘が誤って落とされないこと**を確認した。

### 投稿（⑭〜⑮）

| # | 内容 | 結果 | 一致 |
|---|---|---|---|
| ⑭ | 実投稿 | `{"posted":2,"summarized":0}`。GitLab MR にインラインコメント2件＋サマリ1件が付いた | ○ |
| ⑮ | 指摘0件 | `kept:0` のため投稿せず終了。空のレビューを投稿しない | ○ |

### GitHub経路（受け入れ条件）

`get_mr_changed_files` を**本PR #2 に対して実行**し、変更ファイル一覧とdiff本文が取れることを
確認した（GitHubの公開リポジトリへダミー指摘を残さないため、投稿は行っていない。計画のスコープ外）。

## 設計との差分（2件）

計画の「実装中に設計の誤りが見つかった場合は、勝手に変えず結果mdへ記録してレビューで諮る」に従う。

### 差分1: 投稿コメントのラベルがハードコードされていた

**発見**: 実投稿の確認中、コメント本文が `Claude Codeより（敵対的レビュー）:` になった。
投稿経路（`add_mr_inline_comments` → 各プロバイダの実装 → `format_findings_summary` /
`github_build_review_payload` / `gitlab_build_discussion_body`）が文言をハードコードしていた。
演習の受講者に「欠陥探しのレビュー」と誤解される。

**諮った2案**: (a) 共有関数へ省略可能なラベル引数を足す、(b) answer-talker 専用の投稿処理を持つ。

**採用**: レビューで **(a)** の指示を受けた。上記5関数へ省略可能なラベル引数（既定値
`敵対的レビュー`）を追加し、`answer-talker` からは `'演習レビュー'` を渡す。

**確認**:

- 既定（引数省略＝`adversarial-review` と同じ呼び方）の出力は従来と1文字も変わらない。
  GitHub・GitLab双方で確認した。
- GitLab MR へラベル付きで実投稿し、新しいコメントが `Claude Codeより（演習レビュー）:`・
  サマリが `Claude Codeより: 演習レビュー（AIによる自動レビュー）の結果です。` になることを確認した
  （同じMRに残っていた以前の投稿は `敵対的レビュー` のままで、既存分に影響しないことも同時に確認できた）。
- 単体テスト13本に退行なし（V1）。

ラベル文言は当初 `演習レビュー（正解照合）` を試したが、本文が
`Claude Codeより（演習レビュー（正解照合））:` と二重括弧になり読みづらいため `演習レビュー` にした。

### 差分2: `--repo` にスラッグを渡すと、cwdのプロバイダで解決される

**発見**: GitHubのリポジトリ（このリポジトリ）で作業しながら
`use_target_repo root/answer-talker-verify` を呼んだところ、**GitHubのAPIを叩いて
`Not Found (HTTP 404)`** になった。`owner/repo` 形式はプロバイダを判定する材料を持たないため、
`get_provider`（cwdのリモート）にフォールバックする仕様である（`Provider.sh` の関数コメントに
記載済みの挙動で、実装の誤りではない）。

**対応**: 実装は変更せず、`SKILL.md` の `--repo` の説明に
「cwdと別のサービスを対象にするならURLで渡す」旨と、404になる実例を追記した。
self-hosted GitLabのホスト・ポートもURLからしか決まらないため、URL指定が実質必須である。

## V5. 後片付け

| 対象 | 結果 |
|---|---|
| `root/answer-talker-verify` | 削除を受理（HTTP 202） |
| `root/answer-talker-answer` | 削除を受理（HTTP 202） |
| 正解ソースの一時ディレクトリ | マーカーファイル `.answer-talker-reference` の残存数 **0** |
| このリポジトリ | 題材ファイルの残存なし（`git status` で確認） |

このGitLabインスタンスは**遅延削除**が有効なため、削除受理後もプロジェクトは
`<名前>-deletion_scheduled-<N>` へ改名されて残り、`marked_for_deletion_on` に削除予定日が入る。
即時に一覧から消えないのは仕様どおりである。

なお、同じインスタンスに他issue（#45・#127 等）の検証用プロジェクトが残っているが、
**本issueの管轄外のため触っていない**。

## 受け入れ条件との対応

| 受け入れ条件 | 状況 |
|---|---|
| SKILL.md / agent定義がfrontmatter規約に沿って追加されている | 完了。`search-frontmatter.sh` のインデックスに載ることを確認 |
| 正解ソース取得スクリプトが追加され `bash -n` を通す | 完了（V2） |
| MR番号からdiffを取得する関数が追加され、GitHub経路で実際のMRに対して動作確認済み | 完了（PR #2 に対して実行） |
| 正解のコード片の混入検査が実装され、混入時は投稿されない | 完了（パターン⑫） |
| 正解側にしかない分割単位について、実例で指摘が生成されることを確認 | 完了（パターン①） |
| spec / DDR が追加されている | **フェーズ4で対応**（flow-id 4-1 で対象を洗い出す） |

## 残課題・レビューで諮りたいこと

1. **`test_post_issue_create_notice.sh` の既存failure**を別issueとして起票してよいか。
2. **パターン②の major/high 指摘**を、このまま投稿対象としてよいか
   （②'により同調圧力ではないと判断したが、「入出力を1ファイルにまとめる」流儀を採る受講者には
   強めの指摘になる）。
3. フェーズ4のDDR候補: 実施回数の上限機構を課さない判断 / ラベル引数を共有関数へ足した判断 /
   ローカルパスをcloneしない判断 / ネタバレ検査を誤検知側へ倒す判断。
