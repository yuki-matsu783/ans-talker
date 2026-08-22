---
title: 受講者ソースの受け渡しの実装結果
type: report
description: issue #6 の実装・検証結果。6ファイルへ受講者ソースの取得・受け渡しを実装し、3段の縮退と10パターンの実機検証をGitHub・GitLab両方で完了した。hunk外ファイルの指摘は差分のみなら0件・全体を渡すと4件。単体テストは全16スイート NG=0。
tags: [answer-talker, 実装結果, report]
keywords: [submission, 縮退, degraded, materialScope, forbiddenCount, subtractedBySubmission, scope, 単体テスト, 実機確認, 受け入れ条件, 対照実験, 別解]
---

# 実装結果: 受講者ソースの受け渡し（issue #6・フェーズ3の2周目）

- 計画: `plans/【実装】【テスト】受講者ソースの受け渡し.md`
- 前提の設計: `reports/20260821_bubbly-exploring-biscuit_受講者ソースの受け渡しの設計結果.md`
- 実施日: 2026-08-21〜2026-08-22
- worklog: `worklog/…_push1.md`（取得側）・`worklog/…_push2.md`（受け取り側）

## 結論（3行）

1. **6ファイルすべてを実装した。** 設計から変えたのは1点（`resolve` へ `--repo` を追加）で、
   理由は「`_PROVIDER_CACHE` はシェル変数であり別プロセスへ継承されない」ことの実測。
2. **3段の縮退は GitHub・GitLab の実MRで動いた。** 段2・段3は上限値を人工的に0にして到達させた。
3. **サブエージェントを起動する検証3項目（受け入れ条件1・3・7）も完了した。**
   **hunk外ファイルにのみ現れる指摘が、差分だけなら0件・受講者ソース全体を渡すと4件**という
   対照実験で効果を確認し、10パターンの再検証で回帰が無いことも確かめた。

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

**全16スイート `NG=0`（合計 `passed=742 failures=0`）。**

| スイート | 変更前 | 変更後 |
|---|---|---|
| `test_answer_talker_submission.sh`（新規） | — | 30 |
| `test_answer_talker_map.sh` | 16 | 27 |
| `test_answer_talker_spoiler_check.sh` | 21 | 32 |
| `test_vcs_provider.sh` | （既存） | 143 |

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
フェーズ4の反映候補とする（記述をプロバイダ別に直すか、GitLab側へ寄せ替えを実装するか）。

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
2. **`line` を持たない指摘の扱いのプロバイダ差**（同 1）。記述を直すか実装を揃えるかの判断が要る。
3. **エージェント定義へ「本文はmarkdownとして投稿される」旨を明記する**（同 2）。
4. **空行2連続の機械的検査**（`awk 'prev=="" && $0==""'`）を `docs-workflow.md` へ足す。
5. **17パターンの内訳をspecへ残す。** 今回 `root/answer-talker-verify` の9MRから復元したが、
   これも flow-id 5-1 で消える性質のものではない（GitLab上に残る）ため、spec側に
   「どのブランチがどのパターンか」の対応を書いておくと次回の復元が要らない。

## 次の一手

flow-id 3-8（敵対的レビューのフェーズ3・3回目＝最後）へ進む。
