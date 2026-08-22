---
title: 受講者ソースの受け渡しの実装結果
type: report
description: issue #6 の実装・検証結果。6ファイルへ受講者ソースの取得・受け渡しを実装し、3段の縮退と10パターンの実機検証をGitHub・GitLab両方で完了した。hunk外ファイルの指摘は差分のみなら0件・全体を渡すと4件。レビュー対応でline無し指摘のプロバイダ差もGitLab側の有効行算出で解消した。単体テストは全16スイート NG=0。
tags: [answer-talker, 実装結果, report]
keywords: [submission, 縮退, degraded, materialScope, forbiddenCount, subtractedBySubmission, scope, 単体テスト, 実機確認, 受け入れ条件, 対照実験, 別解, 有効行, プロバイダ差]
---

# 実装結果: 受講者ソースの受け渡し（issue #6・フェーズ3の2周目）

- 計画: `plans/【実装】【テスト】受講者ソースの受け渡し.md`
- 前提の設計: `reports/20260821_bubbly-exploring-biscuit_受講者ソースの受け渡しの設計結果.md`
- 実施日: 2026-08-21〜2026-08-23
- worklog: `worklog/…_push1.md`（取得側）・`worklog/…_push2.md`（受け取り側）・
  `worklog/…_push3.md`（検証）・`worklog/…_push4.md`（レビュー対応）

## 結論（5行）

1. **6ファイルすべてを実装した。** 設計から変えたのは1点（`resolve` へ `--repo` を追加）で、
   理由は「`_PROVIDER_CACHE` はシェル変数であり別プロセスへ継承されない」ことの実測。
2. **3段の縮退は GitHub・GitLab の実MRで動いた。** 段2・段3は上限値を人工的に0にして到達させた。
3. **サブエージェントを起動する検証3項目（受け入れ条件1・3・7）も完了した。**
   **hunk外ファイルにのみ現れる指摘が、差分だけなら0件・受講者ソース全体を渡すと4件**という
   対照実験で効果を確認し、10パターンの再検証で回帰が無いことも確かめた。
4. **flow-id 3-9 のレビュー対応として、`line` 無し指摘のプロバイダ差を実装で解消した**（検証10）。
   hunkヘッダの解釈を `Provider.sh` の共通純粋関数へ寄せ、GitLabにも有効行の算出を持たせた。
   実機で `posted:0→1` を確認している。**issue #1 から存在した欠陥であり、issue #6 が
   作ったものではない。**
5. **敵対的レビュー（フェーズ3の3回目・上限到達）の指摘9件を全件修正した**（検証11）。
   **最も重い1件は、直前の 4 で自分が入れた分岐がGitHub経路を壊すというもの**で、
   push4のworklogに書いた「GitHubでは無害」という前提そのものが誤っていた。
   引数長の境界（500件×パス長65文字で `Argument list too long`）と、修正後に
   `line:null` が0件であることは**実測で確認**している。

## 実装した6ファイル

| # | 対象 | 実装した内容 |
|---|---|---|
| 1 | `.claude/scripts/src/vcs/Github.sh` / `Gitlab.sh` / `Provider.sh` | `get_mr_head_repo` / `get_repo_size_kb` / `get_repo_tree` / `get_repo_file` / `fetch_repo_archive` の5関数と、head側リポジトリへ一時的に切り替える `with_mr_head_repo` |
| 2 | `.claude/scripts/src/answer-talker-submission.sh`（新規） | `resolve` / `cleanup`。3段の縮退・上限・タイムアウト・除外 |
| 3 | `.claude/scripts/src/answer-talker-map.sh` | `--submission-root` と出力の `scope` |
| 4 | `.claude/scripts/src/answer-talker-spoiler-check.sh` | `--submission-root` と出力の `materialScope` / `forbiddenCount` / `subtractedBySubmission` |
| 5 | `.claude/agents/answer-talker-reviewer.md` | 入力仕様に `submission` と `mapping.scope`、「読んでよいもの」の是正、読む手順、`degraded` の分岐 |
| 6 | `.claude/skills/answer-talker/SKILL.md` | 手順3bの新設（採番は繰り下げず）、手順4・6・7・10・11・読み替え表・してはいけないこと |

### 設計から変えた点

**`resolve` へ `--repo` を追加した**（設計時には無かった引数）。`use_target_repo` が設定する
`_PROVIDER_CACHE` はシェル変数であり、`bash answer-talker-submission.sh …` で起動した別プロセスへ
継承されない。呼び出し側が先に `use_target_repo` を呼んでいても、プロバイダの判定がcwd基準へ
戻ってしまう（実測で `gh: Not Found (HTTP 404)` が出た）。

これは設計の見落としではなく、**設計時には「同じシェルで動く」という前提を明示していなかった**
ことによる。SKILL.md の手順3bにも理由付きで明記した（スクリプト側のコメントだけでは、
呼び出し手順を書く人に届かないため）。

## 検証1: 3段の縮退（受け入れ条件2）

**両プロバイダの実MRに対して実行した。** 段2・段3は、上限値を人工的に0にして到達させている。

### GitHub（`yuki-matsu783/test-repo` PR #1）

```
段1（通常）              {"stage":1,"fileCount":2,"truncated":false,"degraded":false,"reason":"stage-1"}
段2（--max-size-kb 0）   {"stage":2,"fileCount":2,"truncated":false,"degraded":false,"reason":"stage-2/size-over-limit"}
段3（+ --max-fetch-files 0）{"stage":3,"root":null,"tmpdir":null,"degraded":true,"reason":"size-over-limit"}
```

### GitLab（`root/answer-talker-verify` MR !1、self-hosted `localhost:8929`）

```
段1（通常）              {"stage":1,"fileCount":2,"truncated":false,"degraded":false,"reason":"stage-1"}
段2（--max-size-kb 0）   {"stage":2,"fileCount":2,"truncated":false,"degraded":false,"reason":"stage-2/size-over-limit"}
段3（+ --max-fetch-files 0）{"stage":3,"root":null,"degraded":true,"reason":"size-over-limit"}
```

段1では `README.md` と `main.sh` の2ファイルが展開された。**`README.md` は今回のMRで
変更していない**（diffには `main.sh` しか無い）——これが issue #6 が取りに行った対象そのものである。

### 副産物: 段2は一過性の失敗に弱い

GitLab の段2を測る過程で、**3回中2回、段2が失敗して段3へ落ちた**。

```
試行1  {"stage":3,...,"reason":"head-sha-unavailable"}   ← MRメタ情報の取得が失敗
試行2  {"stage":3,...,"reason":"size-over-limit"}        ← tree列挙かファイル取得が失敗
試行3  {"stage":2,...,"reason":"stage-2/size-over-limit"} ← 成功
```

原因はローカルGitLabが接続を切ったこと（`wsarecv: An existing connection was forcibly closed`）で、
実装の欠陥ではない。**縮退そのものは設計どおりに働いた**（エラーを握りつぶさず、
`degraded:true` と理由を返して終了コード0で続行した）。

ただし**段2はファイル数に比例してAPIを呼ぶため、段1（1回）に比べて一過性の失敗を踏む確率が
構造的に高い**という性質が実測で見えた。現在の実装は1回でも失敗すると段3へ落ちる。
リトライを持たせるかは**フェーズ4で扱うか、別issueとするかを判断する**（この計画のスコープ外）。

## 検証2: `mapping` の意味の切り替え

`yuki-matsu783/test-repo` PR #1 の実データで、`--submission-root` の有無を比較した。

```
なし  {"scope":"diff","matched":["main.sh"],"referenceOnly":["io.sh"],"submissionOnly":[]}
あり  {"scope":"full","matched":["main.sh"],"referenceOnly":["io.sh"],"submissionOnly":["README.md"]}
```

**`README.md`（hunk外のファイル）が対応付けの視野に入った。** `scope` が `diff` → `full` へ
変わり、`submissionOnly` の意味の違いが機械的に判別できる。

## 検証3: ネタバレ検査の回帰が消えたこと

設計時に「差し引く材料が差分だけだと、hunkに現れない受講者ファイルに基づく指摘**だけ**が
選択的に落ちる」ことを実測していた。今回その逆を確かめた。

正解に `read_lines` / `write_lines` があり、受講者は `read_lines` を**diffに現れないファイル**に
書いている、という状況を作った。

| | `kept` | `dropped` | `materialScope` | `forbiddenCount` | `subtractedBySubmission` |
|---|---|---|---|---|---|
| `--submission-root` なし | 2 | **1**（`read_lines`） | `diff` | 2 | 0 |
| `--submission-root` あり | **3** | 0 | `full` | 1 | 1 |

**`forbiddenCount` が 2 → 1 で止まっている点が重要**である。受講者が書いていない `write_lines` は
禁止語のまま残っており、「差し引きすぎて禁止語が空になり検査が実質無効になる」という逆方向の
壊れ方をしていない。この値を出力へ足したのは、まさにその区別のためである
（`dropped: 0` だけでは「転記が無かった」のか「禁止語が空だった」のかが分からない）。

**検出力が落ちていないことも実データで確かめた。** `test-repo` PR #1 に対し、正解にしか無い
識別子（受講者は別名を使っている）を含む指摘を投入したところ、**`--submission-root` を渡しても
落ちた**（`forbiddenCount:1`）。材料を広げても、本来落とすべきものは落ちる。

## 検証4: 単体テスト

**全16スイート `NG=0`（合計 `passed=762 failures=0`）。**

| スイート | 変更前 | 変更後 |
|---|---|---|
| `test_answer_talker_submission.sh`（新規） | — | 37（検証11の +7 を含む） |
| `test_answer_talker_map.sh` | 16 | 27 |
| `test_answer_talker_spoiler_check.sh` | 21 | 32 |
| `test_vcs_provider.sh` | 143 | 156（検証10の +8・検証11の +5 を含む） |

新規のアサーションは、いずれも**「渡さないと落ちる／渡すと残る」を両側から押さえる**形にした。
片側だけだと「常に落とさない実装」も合格してしまうため。終了コードの検査は
`"$(func; echo $?)"` を使わず `if` で受けている（`set -e` 配下で空文字が返るため。
`.claude/rules/shell-script-style.md`「テスト」）。

## 検証5: 受け入れ条件1（hunk外ファイルの指摘が出て、かつ届く）— **達成**

対象は `root/answer-talker-verify` の MR !8（`p11-addonly`）。**ツリーには `main.sh` があるのに、
diffには `filter.sh` しか無い**——issue #6 が狙った形そのものである。

| | 指摘 | 内訳 |
|---|---|---|
| **受講者ソースあり**（`degraded:false`） | **4件** | blocker/high ×2、major/medium ×1、minor/medium ×1 |
| **縮退**（`degraded:true`。issue #6 以前と同じ状態） | **0件** | — |

**同じMRで、差分だけなら0件、受講者ソース全体を渡すと4件。** うち3件は hunk外の `main.sh` を
読まなければ書けない内容である（`main.sh` が `filter.sh` を読み込んでおらず、追加した
`filter_lines` が実行経路に載っていない、等）。

**「届く」も確認した。**

```
add_mr_inline_comments 8 … '演習レビュー'  →  {"posted":1,"summarized":2}
```

`posted:1` は diff内の `filter.sh`。**`summarized:2` が hunk外の `main.sh` 2件**で、MRのスレッドへ
本文込みで投稿されていることをAPIで確認した（「対象がdiffに含まれないため、行を指定できません
でした」という理由付きで出る）。**出るだけでなく受講者に届く**ところまで到達している。

## 検証6: 受け入れ条件7（17パターン相当の再検証）— **回帰なし**

正解はローカルディレクトリ形態、受講者は全パターン段1で取得（`scope:"full"`）。

| MR | パターン | 指摘 | 投稿 | サマリ |
|---|---|---|---|---|
| !1 `p1-monolith` | ①分割不足 | 2（major/high ×2） | 2 | 0 |
| !2 `p2-alt-split` | ②別解（凝集度が低い） | 3（major/high ×1、minor/medium ×2） | 1 | 0 |
| !3 `p3-duplication` | ③重複 | 3（major/high ×3） | 3 | 0 |
| !4 `p4-overabstraction` | ④余分な抽象化 | 5（major/high ×4、minor/medium ×1） | 4 | 0 |
| !5 `p5-near-answer` | **⑤ほぼ正解** | **1（minor/medium のみ）** | **0** | 0 |
| !6 `p9-delete` | 削除 | 3 | 1 | 2 |
| !7 `p10-rename` | リネーム | 3 | 0 | 3 |
| !8 `p11-addonly` | 新規追加 | 4 | 1 | 2 |
| !9 `p2b-single-file` | **②別解（責務は分割、ファイルは1つ）** | **1（major/medium）** | 0 | 1 |
| GH #1 `p2b-single-file` | 同上（**GitHub**） | 1（major/medium） | 1 | 0 |

**⑤ほぼ正解では分割単位の指摘が出ていない。** 出たのは命名の揺れ1件（minor/medium）だけで、
選別の結果**投稿は0件**になった。最大の回帰リスクとしていた箇所は問題ない。

**②別解については、!9（責務は分割済みだがファイルは1つ）で major/medium が1件出た。**
specが「別解を潰していないかの判定に最も有効」としているパターンであるため、**回帰かどうかを
対照実験で切り分けた。**

| !9 の実行条件 | 指摘 |
|---|---|
| 受講者ソースあり（`scope:"full"`） | 1件 major/medium `responsibility-split` |
| **縮退**（`scope:"diff"`。issue #6 以前と同じ） | **1件 major/medium `responsibility-split`（同内容）** |

**縮退させても同じ指摘が同じ重大度・確度で出る。** つまりこの指摘は差分そのものから出ており、
**受講者ソース全体を渡したことが原因ではない。回帰ではない**と判断する
（specの未決定事項「凝集度の低い別解には強めの指摘が出る」と同じ既知の性質である）。

**GitHubでも同じパターンで同じ重大度・確度・カテゴリの指摘が1件**出ており、
プロバイダによって判定がぶれていない。

### 差分だけでは何も見えなかったパターン

**!7（リネーム）は `patch` が空文字列**である（GitLabはリネームのみの変更に差分本文を返さない）。
issue #6 以前は**レビューする材料が1文字も無かった**が、今回は3件の指摘が出た。うち1件は
hunk外の `README.md`（リネーム後も `main.sh` を案内したまま）に対するもので、これも
受講者ソース全体を渡して初めて書けるものである。

**!6（削除）も3件中2件が hunk外の `main.sh`** であり、`summarized:2` として届いた。

## 検証7: 受け入れ条件3（`degraded: true` の入力JSONと定義の突き合わせ）— **一致**

段3を人工的に作り、サブエージェントへ次を渡した。

```json
"submission": {"root": null, "files": [], "degraded": true, "truncated": false},
"mapping": {"scope": "diff", …}
```

`.claude/agents/answer-talker-reviewer.md` の記述と突き合わせた結果は次のとおり。

| 定義の記述 | 実際 |
|---|---|
| `degraded:true` のとき `root` は `null` | 一致 |
| `degraded:true` のとき読めるのは `diff` の `patch` だけ | 一致（`root` が `null` なのでReadする先が無い） |
| `mapping.scope` は `full`/`diff` | 一致（縮退時は `diff`） |
| **不在を根拠にした指摘を書かない** | **一致。** !8 の縮退実行は `findings: []` を返し、`referenceOnly` に並ぶ正解側ファイルを「作っていない」と断定しなかった |
| **責務の分割に関する指摘の `confidence` を `high` にしない** | **一致。** !9 の縮退実行の `responsibility-split` は `confidence: medium` |

## 検証8: ネタバレ検査（全パターン）

| MR | `kept` | `dropped` | `forbiddenCount` | `subtractedBySubmission` |
|---|---|---|---|---|
| !1 | 2 | 0 | 6 | 0 |
| !2 | 3 | 0 | 5 | 0 |
| !3 | 3 | 0 | 7 | 0 |
| !4 | 5 | 0 | 9 | 0 |
| !5 | 1 | 0 | 5 | 0 |
| !6 | 3 | 0 | 10 | 2 |
| !7 | 3 | 0 | 10 | 2 |
| !8 | 4 | 0 | 7 | 1 |
| !9 | 1 | 0 | 6 | 0 |
| GH #1 | 1 | 0 | 6 | 0 |

**`forbiddenCount` はどのパターンでも5〜10で、空になっていない。** 材料を広げたことで
「差し引きすぎて検査が実質無効になる」状態には至っていない（`subtractedBySubmission` も最大2）。

**転記ありのケースも確認した。** 正解にしか無い識別子を含む指摘を !7 へ人工的に投入したところ、
`--submission-root` を渡した状態でも落ちた。

```
{"kept":3,"dropped":1,"forbiddenCount":10,
 "drops":[{"title":"読み取りの関心を切り出す","words":["read_lines","format_lines"]}]}
```

正規の3件は残り、注入した1件だけが落ちている。**材料を広げても検出力は落ちていない。**

## 検証9: 正解ソースの形態

| 形態 | 結果 |
|---|---|
| 素のディレクトリ | 全10パターンで使用。`{"kind":"local","cleanup":false}` |
| **URL（shallow clone）** | `{"kind":"url","cleanup":true}`。履歴の深さ1（shallowになっている）。`cleanup` で削除されることも確認 |
| ローカルgit | **未実施**（`kind` の判定は「ディレクトリか否か」であり、`.git` の有無で経路が分かれないため、素のディレクトリと同一経路になる） |

## 検証10: `line` 無し指摘のプロバイダ差を解消した（flow-id 3-9 のレビュー対応）— **解消**

「記述を直すか実装を揃えるか」という判断について、レビューで**「実装をそろえる」**という指示を
受けた。GitLab側に有効行の算出を実装した。

### 何を変えたか

**hunkヘッダの解釈は1箇所にまとめ、APIの返却形の違いだけを各プロバイダが吸収する形にした。**
GitHub側にあったロジックをそのままGitLabへ写すと、同じ正規表現が2箇所に増えて片方だけが直る
余地を残すためである。

| ファイル | 変更 |
|---|---|
| `Provider.sh` | **`valid_ranges_from_patches`**（`[{path, patch}]` → `{path: [[start,end],…]}`）と **`filter_findings_by_valid_lines`**（findings → `{post, summary}`）を新設。どちらも `path`/`line`/`old_line` しか見ないプロバイダ非依存の純粋関数 |
| `Github.sh` | `github_valid_ranges_from_files_json` を `filename`/`patch` → `path`/`patch` の正規化だけに縮小し、共通関数へ委譲。`github_filter_findings_by_valid_lines` は削除し共通関数へ統合 |
| `Gitlab.sh` | **`gitlab_valid_ranges_from_diffs_json`** を新設（`new_path`/`diff` の正規化＋`jq -s` でページ束ね）。`gitlab_add_mr_inline_comments` が投稿前に振り分けるようにした |

**`side`（"RIGHT"）の既定値付与は共通関数から外し、`github_build_review_payload` へ寄せた。**
GitLabの `position` は `side` を持たないため、共通の判定ロジックへ残すとGitHub固有のキーが
漏れ出す。

### 壊さないために置いた分岐が2つある

1. **差分を取得できなかった場合は、振り分けを行わず全件の投稿を試みる**（従来の挙動）。
   ここで空の範囲マップを渡すと、**全件が「有効行なし」と判定されてサマリへ落ちる**。
   ローカルGitLabの接続断は実測で頻発しており（検証で新たに判明したこと 3）、この分岐は
   例外処理ではなく通常経路として扱う必要がある。
2. **`old_line` を持つ指摘（削除行への指摘）は判定せず投稿へ通す。** 範囲マップは新ファイル側
   しか持たないため判定できず、純粋な削除hunkのファイルでは新側の有効行がそもそも空になる。
   ここでサマリへ落とすと、**GitLabが受け付けられる指摘まで捨てる**ことになる。

なお、振り分けたあとも**POST失敗時のサマリ行きは残している**。GitLabは失敗理由を区別して
返さないため、有効行では拾えない理由（一過性の接続断など）が残るからである。

### 実機で確認した（MR !8。`filter.sh` の有効行は 1〜4）

**同じMR・同じ指摘で修正前後を比べた。**

| | `line` 無し・diff内（`filter.sh`） | `line` 無し・diff外（`main.sh`） | 有効行外（`filter.sh:99`） | 結果 |
|---|---|---|---|---|
| **修正前** | POSTが `400 ... position is incomplete` で失敗 | 同左 | 同左 | `posted:0, summarized:3` |
| **修正後** | **`new_line: 1` へ寄せてインライン投稿** | サマリ | サマリ | **`posted:1, summarized:2`** |

修正前の失敗は、`gitlab_build_discussion_body` の出力を直接POSTして再現した。返ってきたのは
`400 Bad request - Note {:line_code=>["can't be blank", "must be a valid line code"],
:position=>["is incomplete"]}` である。**「有効行を持つファイルなのに、行が無いというだけで
拒否されていた」**ことがこれで確定した（!7 での実測は `patch` が空という別の理由も重なって
いたため、原因の切り分けとしては弱かった）。

投稿後は `discussions` APIで `new_path: "filter.sh"` / `new_line: 1` を確認した。
**検証のために作った2スレッドは削除済み**（`【検証用】` を含むスレッドの残存 0件）。

### 過剰修正になっていないことも確認した

- **MR !7（リネームのみ・`patch` が空）** — 有効行マップは `{"cli.sh":[]}` で、指摘2件は
  `post:0, summary:2`。**引き続きサマリへ回る。** 有効行が存在しないのだから正しい。
- **GitHub（このPR #7 の実データ）** — 投稿はせず組み立てまで実行。`line` 無しの指摘は
  最小有効行（14）へ寄り、diff外はサマリ、`side` は `RIGHT` が付いた。**挙動は変わっていない。**
- **単体テストは全16スイート `failures=0`**（`passed=750`。+8件）。新規は、GitLab側の範囲算出5件・
  `old_line` の素通し2件・`side` の既定値をペイロード側で検査する1件。
  **「GitHub版とGitLab版が同じdiffに対して同じ範囲マップを返す」検査も入れた**（揃えたこと
  そのものを固定するため）。

### スコープの扱い

**これは issue #1 から存在する欠陥であり、issue #6 が作ったものではない。** 別issueへ切り出す
選択肢もあったが、レビューでの指示は「実装をそろえる」であり、対象が `add_mr_inline_comments`
という**このissueで実際に使い倒した経路**であること、変更が3ファイル・純粋関数中心で
テストしやすいことから、このMRに含めた。

## 検証11: 敵対的レビュー（フェーズ3の3回目）の指摘9件を全件修正した — **完了**

flow-id 3-8 として実施した敵対的レビュー（3/3回目・上限到達）で9件の指摘を受け、**ユーザーの
指示によりこのMRで全件を修正した**（7件はPR #7へ投稿済み、2件は選別表により報告のみ）。

### 最も重い指摘は、直前の flow-id 3-9 で自分が入れた分岐だった

`filter_findings_by_valid_lines` の `old_line` 素通しは**GitHub経路を壊していた**。共通関数に
置いたためGitHubからも通り、`github_build_review_payload` が `line: null` のコメントを作る。
**GitHubのレビュー投稿は原子的で、1件でも不正な行が混ざるとそのMRのインライン投稿が全件失敗する。**

push4のworklogには「GitHub側は `old_line` を使っていないため無害（現状のfindingsスキーマにも
無い）」と書いていたが、`.claude/agents/*.md` は「削除行は `old_line` のみ」と**明示的に指示して
いる**。前提そのものが誤っていた。

修正は、判定を第2引数 `allow_old_line` で切り替える形にした。**「判定できないものをどちらへ倒すか」
の答えがプロバイダで正反対**だからである。

| `allow_old_line` | 呼び出し元 | `old_line` を持つ指摘の扱い |
|---|---|---|
| `true` | GitLab | postへ通す。新側の `line` が有効行に無ければ**その `line` を落とし**、`old_line` だけで位置を決めさせる |
| `false`（既定） | GitHub | 新側の有効行が決まらない限り**サマリへ回す** |

修正後、`old_line` のみの指摘を含むfindingsをGitHub経路へ流し、**組み立てたペイロードに
`line: null` が0件**であることを確認した（修正前は1件混入していた）。

### 引数長の境界は、実測で再現してから直した

`answer-talker-submission.sh` が一覧を `jq --args` の位置引数で渡していた件は、**指摘された境界を
実際に踏んでから**修正した。

```
件数=500 平均パス長=65
旧実装（--args）  : FAIL(exit=126) /c/Program Files/jq/jq: Argument list too long
新実装（--rawfile）: OK 500件
0件のとき         : {"files":[]}
```

`--max-list-files` の既定が500なので、**平均パス長が約64文字を超えると必ず失敗する**。
`packages/app/src/main/java/...` のような構成では珍しくない。しかも失敗するのは展開が終わった
後であり、`set -e` で落ちて**stdoutへ何も出ない**ため、`tmpdir` を返せず後始末の呼び先が失われる。

### 修正した9件

| # | 対象 | 重大度 | 何を直したか |
|---|---|---|---|
| 1 | `Provider.sh` | major | `old_line` の扱いを `allow_old_line` で切り替え、GitHubでは `line:null` を作らない |
| 2 | `answer-talker-submission.sh` | major | 一覧を `--rawfile` 経由にし、件数に依存しない形へ |
| 3 | `answer-talker-submission.sh` | major | `find ... ! -empty` / `-empty` で**空ファイルをバイナリ扱いしない** |
| 4 | `Gitlab.sh` | major | `truncated` の説明を実装に合わせ、`fetch_stage2` が値を**参照する**ようにした |
| 5 | `Provider.sh` / `issue-mr-flow/SKILL.md` | minor | 新設5関数を `mcp_tool_hint` と対応表へ追加 |
| 6 | `answer-talker-submission.sh` | minor | 縮退理由を `fetch-failed/size-unknown` の併記形式へ |
| 7 | 5スクリプト | minor | コメントからの `reports/` 参照を issue番号・spec へ置き換え |
| 8 | `answer-talker-submission.sh` | minor（報告のみ） | 段1の展開失敗時に `$tmpdir/source` を消し、段2を空から始める |
| 9 | `answer-talker-reviewer.md` | minor（報告のみ） | 全文Readの対象を選ぶ手順・目安件数・打ち切りの注意を追加 |

3と4は**同じ形の欠陥**である。どちらも「取得できたものが全件である」と暗黙に仮定していて、
欠けたときに**エラーではなく `degraded:false` の正常応答として**下流へ流れる。結果は同じで、
**実在するファイルについて「作られていない」という指摘が出る**。

### 検証

- 単体テスト **全16スイート `passed=762 failures=0`**（750→762、+12件）。内訳は
  `test_vcs_provider.sh` +5（GitHub/GitLabで `old_line` の扱いが分かれることを両方向から固定）、
  `test_answer_talker_submission.sh` +7（空ファイル・段1の残骸・`truncated` の3系統）。
- **既存テスト1件は意図的に置き換えた**。「`old_line` を持つ指摘は判定せず投稿対象」は
  GitHubでは誤りになったため、プロバイダごとの2組へ分割した。
- 引数長・`line:null` は上記のとおり**実測で確認**した。

## 検証で新たに判明したこと

### 1. `line` を持たない指摘の扱いが、プロバイダで異なる

`.claude/skills/adversarial-review/SKILL.md` は次のように**無条件で**書いている。

> `line` を持たない finding（ファイル全体にかかる指摘）はサマリへ回らず、そのファイルの
> diff上で最初に現れる有効行へインラインで付く

**これはGitHub限定の挙動である。** 実測で確定した。

| | `line` 無しの指摘 | 結果 |
|---|---|---|
| GitHub（PR #1） | 1件 | `posted:1`（有効行へ寄せられた） |
| GitLab（MR !7） | 3件 | `posted:0, summarized:3`（全件サマリへ） |

原因は実装にある。GitHub側は `github_valid_ranges_from_files_json` /
`github_filter_findings_by_valid_lines` で有効行を算出して寄せているが、**GitLab側には対応する
ロジックが無い**。`gitlab_build_discussion_body` は `line` が無ければ `new_line` を落とすだけで、
GitLabのAPIは行の無いテキスト位置を受け付けないため投稿が失敗し、サマリへ回る
（`gitlab_add_mr_inline_comments` は「投稿を試して失敗したらサマリ」という作りである）。

**issue #6 で入れた変更が原因ではなく、issue #1 から存在する記述と実装の食い違いである。**

**→ flow-id 3-9 のレビューで「実装をそろえる」判断を受け、GitLab側へ実装した（検証10）。**
記述を直す案は採らなかった。

### 2. サブエージェントが指摘本文へHTMLエンティティを出すことがある

12回の起動のうち3回（!8・!7・!4）で、本文に `&lt;` `&gt;` `&amp;` が現れた。投稿本文はmarkdownと
して扱われるため、そのまま投稿すると `&lt;` という文字列が見えてしまう。**今回は投稿前に
実体参照を元の文字へ戻した。**

エージェント定義に「本文はmarkdownとして投稿される」旨の記述が無いことが原因と考えられる。
これもフェーズ4の反映候補とする。

### 3. ローカルGitLabの接続断は、段2に限らない

実装結果の「副産物」節では段2の弱さとして記録したが、今回は**MRのメタ情報取得（段1の入口）でも
発生した**（!5 で1回、!7 で3回連続。いずれも `reason:"head-sha-unavailable"` で段3へ落ちた）。
リトライすると成功するため一過性である。**縮退は毎回設計どおり働いた**（終了コード0で
`degraded:true` を返し、処理を止めなかった）が、リトライを持たせるかの検討対象は段2だけではない。

## 受け入れ条件の充足状況

| # | 条件 | 状況 |
|---|---|---|
| 1 | 受講者のソースを**全体として**読める | **達成**（検証5。差分だけなら0件、全体を渡すと4件） |
| 2 | 縮退が両プロバイダで機能する | **達成**（検証1） |
| 3 | エージェント定義の「読んでよいもの」が実態と一致 | **達成**（検証7。`degraded:true` の場合を含む） |
| 4 | `mapping` の範囲の判断がspecに記録されている | **フェーズ4**（未着手） |
| 5 | ネタバレ検査の禁止語の判断が理由とともに記録されている | **フェーズ4**（未着手） |
| 6 | spec更新・必要ならDDR追加 | **フェーズ4**（未着手） |
| 7 | 17パターン相当の再検証 | **達成**（検証6。②別解・⑤ほぼ正解とも回帰なし） |

条件4〜6はフェーズ4〈反映〉の担当であり、この計画のスコープ外である。

## 計画のD（設計で未確認のまま残した項目）の扱い

| 項目 | 結果 |
|---|---|
| **GitHub非公開リポジトリでのアーカイブ取得** | **未確認。** ユーザーから `test-repo` を一時的に非公開へ切り替える承認は得たが、`gh repo edit --visibility private` の実行が**実行環境の権限分類器にブロックされた**（リポジトリの可視性変更が許可されていない）。**「確かめられなかった」であって「動かない」ではない** |
| **サイズが取得できない環境での挙動** | **コード上は確認済み・実環境では未確認。** 設計どおり「サイズ不明なら段1を試す」実装になっていることは読み取れるが、実際にサイズを返さないGitLabインスタンスは手元に無い |
| **上限値（100MB・50件・500件・60秒）の妥当性** | **未確認。** 今回の検証対象（最大5ファイル）では一度も上限に触れていない。**「妥当だと確認した」とは書けない** |

## フェーズ4の反映候補

実装・検証を通じて挙がったもの。**確定した反映内容ではなく、flow-id 4-1 で洗い出す際の候補**である。

1. **段1の入口（MRメタ情報取得）・段2のリトライ方針**（検証で新たに判明したこと 3）。
2. **`line` を持たない指摘の扱いのプロバイダ差は、実装で解消済み**（検証10）。フェーズ4へ残るのは
   **ドキュメント側の追随**である。
   - `.claude/docs/spec/adversarial-review.md` の関数一覧が `github_filter_findings_by_valid_lines`
     を挙げているが、**この関数は削除して共通の `filter_findings_by_valid_lines` へ統合した**。
     `valid_ranges_from_patches` / `gitlab_valid_ranges_from_diffs_json` も一覧に無い。
     **specの現在の記述が実装と食い違った状態のため、flow-id 4-6 で必ず直す。**
   - `.claude/skills/adversarial-review/SKILL.md` 手順7の「`line` を持たない finding は…
     有効行へインラインで付く」は、**これで両プロバイダの記述として正しくなった**（変更不要）。
     ただし「有効行を持たないファイルではサマリへ回る」という限定は、あったほうがよい。
   - `.claude/docs/ddr/0047-*.md` は**本文を変更しない**（point-in-timeの記録であり、当時の
     関数名で書かれているのが正しい）。今回の統合はDDRの新規追加で記録するかを 4-1 で判断する。
3. **エージェント定義へ「本文はmarkdownとして投稿される」旨を明記する**（同 2）。
4. **空行2連続の機械的検査**（`awk 'prev=="" && $0==""'`）を `docs-workflow.md` へ足す。
5. **17パターンの内訳をspecへ残す。** 今回 `root/answer-talker-verify` の9MRから復元したが、
   これも flow-id 5-1 で消える性質のものではない（GitLab上に残る）ため、spec側に
   「どのブランチがどのパターンか」の対応を書いておくと次回の復元が要らない。

## 次の一手

flow-id 3-8（敵対的レビューのフェーズ3・3回目＝最後）へ進む。**対話セッションではAIから
自律起動しない**ため、ユーザーの明示指示を待つ。
