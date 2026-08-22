---
title: worklog 【実装】【テスト】受講者ソースの受け渡し push4
type: log
description: issue #6 のフェーズ3の2周目の記録の続き。flow-id 3-9 のレビュー対応として、line無し指摘の扱いのプロバイダ差をGitLab側の有効行算出で解消した。
tags: [worklog, answer-talker, レビュー対応, 実機検証]
keywords: [有効行, プロバイダ差, valid_ranges_from_patches, filter_findings_by_valid_lines, old_line, 対照実験, 過剰修正, position, 共通化]
---

# worklog: 【実装】【テスト】受講者ソースの受け渡し（push4）

対象: issue #6 のフェーズ3の**2周目**（2026-08-23）。
全体作業計画: `plans/bubbly-exploring-biscuit.md`
個別作業計画: `plans/【実装】【テスト】受講者ソースの受け渡し.md`
push1（取得側）: `worklog/20260821_…_push1.md` / push2（受け取り側）: `worklog/20260822_…_push2.md`
push3（検証）: `worklog/20260823_…_push3.md`
push回数: 13

## 試したこと

flow-id 3-9。レビューコメントは**1件**だった。push3 の worklog の

> 記述を直すか実装を揃えるかの判断が要る。

という行に対して、**「実装をそろえるようにしてほしい」**。GitLab側に有効行の算出を実装した。

## うまくいったこと

### hunkヘッダの解釈を1箇所へ寄せた（写経しなかった）

最初に思いついたのは「GitHubの `github_valid_ranges_from_files_json` と
`github_filter_findings_by_valid_lines` をGitLab用に複製する」だったが、それをやると
**同じ正規表現が2箇所に増え、片方だけが直る余地**が残る。「そろえる」と言いながら、
次にずれる仕込みを作ることになる。

分けたのは次の線である。

| | 置き場所 |
|---|---|
| **APIの返却形の違い**（`filename`/`patch` 対 `new_path`/`diff`、ページングの束ね方） | 各プロバイダ |
| **hunkヘッダの解釈と、findingsの振り分け** | `Provider.sh`（共通） |

結果として、GitHub側の関数は**正規化1行だけに縮んだ**（既存テストは1つも書き換えずに通った）。

### `side` を共通関数から追い出した

`github_filter_findings_by_valid_lines` は `side: "RIGHT"` の既定値付与も担っていたが、
**GitLabの `position` は `side` を持たない**。共通の判定ロジックへ残すとGitHub固有のキーが
漏れる。`github_build_review_payload` が既に `(.side // "RIGHT")` を持っていたので、
そちらへ寄せるだけで挙動は変わらなかった。テストは「フィルタがsideを付ける」検査を
「ペイロード組み立てがsideを付ける」検査へ移した。

### 修正前後を同じMR・同じ指摘で比べた

push3 で学んだ「片側だけでは『たまたま』と区別できない」をそのまま適用した。

| | line無し・diff内 | 結果 |
|---|---|---|
| 修正前 | `400 Bad request … :position=>["is incomplete"]` | `posted:0, summarized:3` |
| 修正後 | `new_line: 1` へ寄せて投稿 | **`posted:1, summarized:2`** |

**修正前の失敗を、実際にPOSTして再現したのが効いた。** push3 の実測（MR !7 で
`posted:0, summarized:3`）は `patch` が空という別の理由も重なっており、
「有効行を持つファイルなのに行が無いだけで拒否される」ことの証拠としては弱かった。
!8（`filter.sh` の有効行が 1〜4）でやり直して初めて原因が一意に決まった。

### 過剰修正になっていないことも確かめた

「出るようになった」だけを見ると、**出てはいけないものまで出る**変更を通してしまう。

- **MR !7（リネームのみ・`patch` 空）**: 有効行マップは `{"cli.sh":[]}`、指摘2件は
  `post:0, summary:2`。**引き続きサマリへ回る。**
- **GitHub（このPR #7 の実データ）**: 投稿せず組み立てまで実行。line無しは最小有効行(14)へ
  寄り、diff外はサマリ、`side` は RIGHT。**挙動は変わっていない。**
- 単体テストへ**「GitHub版とGitLab版が同じdiffに対して同じ範囲マップを返す」**検査を入れた。
  揃えたことそのものを固定するアサーションで、片方だけを直すと落ちる。

## 危なかったこと

### 空の範囲マップは「全件サマリ行き」を意味する

`filter_findings_by_valid_lines` は「有効行を持たないファイルの指摘はサマリ」という設計なので、
**範囲マップが `{}` だと全件がサマリへ落ちる。** 差分の取得に失敗したときに素朴に `{}` を
渡すと、**接続断のたびに全指摘がサマリへ回る**という、直そうとしていた症状より悪い状態になる。

push3 で「ローカルGitLabの接続断は段2に限らず、MRメタ情報の取得でも起きる」と実測していたので、
これは例外ではなく通常経路として扱う必要があると分かった。差分を取れなければ**振り分けを行わず
全件の投稿を試みる**（従来の挙動）分岐を置き、警告を標準エラーへ出している。

### `old_line` を持つ指摘を落としかけた

範囲マップは**新ファイル側**しか持たない。純粋な削除hunkのファイルでは新側の有効行が空になる
ため、素直に書くと「削除行への指摘」が全部サマリへ落ちる。`gitlab_build_discussion_body` は
`old_line` を受け付ける作りになっており、**GitLabが受け付けられる指摘を捨てる**ところだった。
`old_line` を持つfindingは判定せずそのまま投稿へ通す分岐を入れ、単体テストを2件足した。

GitHub側は `old_line` を使っていないため、この分岐は無害である（現状のfindingsスキーマにも無い）。

## 気づいたこと（フェーズ4の反映候補）

- **`.claude/docs/spec/adversarial-review.md` の関数一覧が実装と食い違った。**
  `github_filter_findings_by_valid_lines` を挙げているが、この関数は削除して共通の
  `filter_findings_by_valid_lines` へ統合した。`valid_ranges_from_patches` /
  `gitlab_valid_ranges_from_diffs_json` も一覧に無い。**flow-id 4-6 で必ず直す**
  （specは「現在の正史」であり、今この瞬間は誤っている状態である）。
- **`.claude/docs/ddr/0047-*.md` の本文は変更しない。** 当時の関数名で書かれているのが正しい
  （point-in-timeの記録）。今回の統合を新規DDRとして残すかは flow-id 4-1 で判断する。
- **`adversarial-review/SKILL.md` 手順7の記述は、これで両プロバイダについて正しくなった。**
  ただし「有効行を持たないファイルではサマリへ回る」という限定は足したほうがよい。
- **検証で作ったスレッドは削除して片付けた**（`【検証用】` の残存0件）。演習用リポジトリとはいえ、
  検証の副産物を残すと次の検証で「前回の投稿」と混ざる。実際、!8 には前回の実レビューの
  サマリスレッドが残っており、作成時刻で区別する必要があった。
