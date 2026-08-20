---
name: resolve-conflict
description: 'Detect and resolve conflicts between the current feature branch and the default branch (main) before requesting a merge. Use whenever a merge/PR is about to be requested — both when the user explicitly invokes /resolve-conflict AND at issue-mr-flow flow-id 5-2, which requires this check before undrafting the PR. Covers the repo-specific hazards: DDR number collisions that git silently merges as clean, "deleted by us" conflicts on files that were untracked from Git (index.jsonl), and doc lines edited on both branches. Also used for the continuous base-branch follow-up after a PR is opened (issue-mr-flow "PR作成後のdefaultブランチ追従（監視）"), where categories with a single determined resolution (A/B/C/D) are resolved without waiting for approval and category E stops for the human. Flow: check-base-conflicts.sh -> AskUserQuestion -> git merge (never rebase) -> per-category resolution -> verify -> commit skill.'
title: defaultブランチとのコンフリクト解消
type: skill
tags: [issue-mr-flow, workflow, skill, conflict]
keywords: [コンフリクト, merge, DDR番号, 改番, deleted by us, index.jsonl, merge-tree, defaultブランチ, main追従, 追従監視, 監視モード]
---

# /resolve-conflict スキル

現在のfeatureブランチとdefaultブランチ（`.mrworkflow.json` の `defaultBaseBranch`。既定 `main`）の
間のコンフリクトを、**検知 → ユーザー確認 → 類型別の解消 → 検証 → コミット**という決まった順序で
処理する。マージ依頼のたびに同じ手順へ収束させ、その場の判断で解消方法が変わることを防ぐ
（issue #46。経緯・却下案: `.claude/docs/ddr/0029-defaultブランチとのコンフリクトは検知を機構化し解消手順をスキル化する.md`）。

## 呼び出しタイミング

- **`issue-mr-flow` の flow-id 5-2**（Draft解除の直前）。このステップはAIエージェントが必ず通る。
- ユーザーが明示的に `/resolve-conflict` と入力した場合（フェーズを問わず、任意のタイミングで
  defaultブランチへ追従したいとき）。
- **PR作成後の追従監視でコンフリクトを検知したとき**（issue #88。PRイベント・定期チェックイン・
  各pushの直後。位置づけ:
  `.claude/skills/issue-mr-flow/SKILL.md`「PR作成後のdefaultブランチ追従（監視）」節）。この
  呼び出しは**監視モード**として扱い、Step 2 の承認の取り方だけが変わる（下記）。

## 絶対ルール

- **`git rebase` は使わない。`git merge` で取り込む。** 作業ブランチは既にリモートへ反映済みで、
  MR/PRのレビューコメントが特定のコミットSHA・diffに紐づいている。履歴を書き換えると、レビュアーの
  ローカルチェックアウトとMR上の参照リンクの両方が壊れる。squash mergeでmainへ入るのは1コミット
  なので、途中のmergeコミットがmainの履歴を汚すこともない
  （`.claude/rules/git-workflow.md`「PR・マージ」）。
- **`--force` / `--force-with-lease` でのリモート反映は行わない**（上と同じ理由）。
- **`git checkout --ours` / `--theirs` でファイル単位に片側を丸ごと採用しない。** 過去の事例は
  いずれも「両ブランチの変更をどちらも残す必要がある」ものだった。片側採用は、もう一方の
  ブランチの変更を無言で捨てる。
- **`git merge --abort` による撤退は、ユーザーへ報告してから行う。** 自動で元に戻さない
  （`commit` スキルの「失敗時に自動ロールバックしない」と同じ方針）。
- **コミットは `commit` スキル経由で行う**（gitの直接のコミット実行はPreToolUse hookでブロック
  される。`.claude/rules/git-workflow.md`「コミット運用」）。

## 実行フロー

### Step 1: 検知

作業ツリーを一切変更せずに、コンフリクトの有無を調べる。

```bash
bash .claude/scripts/src/check-base-conflicts.sh
```

判定結果のJSONが返る（仕様: `.claude/docs/spec/check-base-conflicts.md`）。

| キー | 意味 |
|---|---|
| `hasConflict` | 下2つのいずれかが真 |
| `hasTextualConflict` | `git merge-tree` が報告する通常のコンフリクト |
| `textualConflictFiles` | その対象ファイル一覧 |
| `hasDuplicateDdrNumber` | **DDR番号の重複**（gitはコンフリクトと見なさない。下記「類型A」） |
| `duplicateDdrNumbers` | 重複した番号と、その番号を持つファイル一覧 |

**`hasConflict` が `false` なら、このスキルはここで終了する**（マージやコミットは行わない。
呼び出し元の flow-id 5-2 はそのまま 5-3（関連issue通知）へ進む）。

**`git status` や `git merge` の結果だけで「コンフリクト無し」と判断しない。** 類型Aは
ファイル名が異なるためgitが無言でマージを成功させる。必ずこのスクリプトの `hasConflict` で判断する。

### Step 2: ユーザーへの確認（AskUserQuestion）

`hasConflict` が `true` の場合、**解消作業に入る前に必ず `AskUserQuestion` でユーザーの承認を取る**。
質問文には、検知した内容（類型・対象ファイル・重複したDDR番号）を具体的に含める。

選択肢は次の3つを標準とする。

| 選択肢 | 挙動 |
|---|---|
| `解消する (Recommended)` | Step 3へ進む |
| `内容だけ見たい` | 解消は行わず、Step 3以降の「解消方針」だけを提示して終了する |
| `今回は解消しない` | 何もせず終了する。呼び出し元へ「コンフリクトが残ったままマージ依頼へ進む」旨を伝える |

#### 監視モードでの例外（issue #88）

PR作成後の追従監視から呼ばれた場合に限り、**解消方法が一意に決まる（どちらの意図も失われない）
類型については、この承認を待たずに Step 3 へ進んでよい**。レビュー待ちの間に人間の応答を待つと、
待っている間にdefaultブランチがさらに進み、同じ解消をやり直すことになるためである。

| 類型 | 監視モードでの扱い |
|---|---|
| A: DDR番号の衝突 | **承認を待たず解消**（「defaultブランチ側を正とし作業ブランチ側を繰り下げる」と規則が確定している） |
| B: 管理外にした生成物の "deleted by us" | **承認を待たず解消**（「管理外にした側を採用する」と規則が確定している） |
| C: 同じドキュメントの近接行 | **承認を待たず解消**（両方を残す）。ただし散文が両側で書き換わり内容が矛盾する場合は類型Eとして扱う |
| D: spec/DDRの過去changelog | **承認を待たず解消**（時系列順に両方残す） |
| E: 同じロジックの競合 | **`AskUserQuestion` で確認する**。解消せずに止め、両側の意図を要約して判断を仰ぐ |

- **省略してよいのは Step 2 の承認だけである。** Step 5 の検証と Step 6 の `commit` スキル経由の
  コミットは、監視モードでも一切省略しない。
- 検知結果に類型Eが1つでも含まれる場合は、**他の類型も解消せずに止めて確認を取る**（同じマージの
  途中で一部だけ解消すると、作業ツリーがマージ途中のまま人間の応答を待つことになるため）。
- ユーザーが対話可能な通常の呼び出し（`/resolve-conflict`・flow-id 5-2）では、この例外は使わない。
  従来どおり Step 2 の承認を取る（DDR 0029 の決定6）。

### Step 3: マージの開始

```bash
source .claude/scripts/src/vcs/Provider.sh
base="$(get_workflow_config | jq -r '.defaultBaseBranch')"
git fetch origin "$base"
git merge --no-ff --no-commit "origin/$base"
```

`--no-commit` を付けるのは、コンフリクトが無い箇所も含めてコミットを `commit` スキルへ委ねるため
（gitが自動生成する `Merge branch ...` ではなく、何をどう解消したかが分かる日本語メッセージを付ける。
実績: `chore: mainをマージしDDR番号を0028へ繰り下げてissue #45の変更と統合`）。

`git status` で unmerged なパスを確認し、以下の類型に振り分けて解消する。

### Step 4: 類型別の解消

#### 類型A: DDR番号の衝突（最頻。過去4回すべてこれ）

両ブランチがそれぞれ新しいDDRを追加し、同じ連番になった状態。**ファイル名が異なるため
`git status` には何も出ない**（PR #29 / #37 / #49 / #52 のすべてがこの形）。

**解消ルール: defaultブランチ側の番号を正とし、作業ブランチ側を空き番号へ繰り下げる。**
mainは共有の正史であり、既にマージされた番号を動かすと他のブランチ・既存の相互参照が壊れるため。

改番の対象は**ファイル名だけではない**。以下をすべて更新する（漏れやすいので必ず全部確認する）。

| 更新対象 | 確認方法 |
|---|---|
| ファイル名 | `git mv .claude/docs/ddr/00NN-旧.md .claude/docs/ddr/00MM-旧.md` |
| frontmatterの `title` 先頭の番号 | `title: 00MM. ...` |
| 本文冒頭の見出し `# 00NN. ...` | `# 00MM. ...` |
| `.claude/docs/README.md` のDDR一覧 | リンクのファイル名とテキストの両方 |
| **他ファイルからの参照** | `grep -rn "00NN-" --include='*.md' --include='*.sh' --include='*.json' .` |

- **DDR本文は変更しないという原則（`.claude/rules/docs-workflow.md`）の適用外**。まだマージ
  されていない自分のDDRの、自分自身の番号表記を直すだけであり、確定した意思決定の書き換えではない。
- **`.gitignore` やスクリプトのコメントからの参照を忘れやすい。** 実際、issue #36で
  `0024-frontmatterのindex.jsonl...` が `0025-...` へ繰り下がった際に `.gitignore` のコメントが
  古い番号のまま残り、issue #46で修正するまで存在しないDDRを指していた。上表の `grep` を必ず流すこと。
- **改番後は `check-base-conflicts.sh` を再実行し、`hasDuplicateDdrNumber` が `false` になることを
  確認する。**

#### 類型B: Git管理外にした生成物の "deleted by us" / "deleted by them"

作業ブランチ側でGit管理から外したファイルを、defaultブランチ側がまだ管理下で更新している
（またはその逆）状態。issue #36（PR #37）で `index.jsonl` が7ファイル分この形になった。

**解消ルール: 「Git管理から外す」という決定が新しい側であれば、削除を採用する。**

```bash
git rm --cached -- <path>   # 管理から外す側の意図を採用（作業ツリーの生成物は残してよい）
```

- 併せて `.gitignore` に除外パターンが入っていることを確認する（入っていないと次のセッションで
  復活する）。
- **逆方向（defaultブランチ側が管理外にした）の場合も同じく「管理外にした側」を採用する。**
  管理外化は後戻りしない性質の決定であり、片方のブランチだけ管理下に戻すと同じ競合が再発する。
- 生成物そのものの中身をコンフリクトマーカー付きで手直ししない。生成スクリプト
  （`.claude/scripts/src/extract-frontmatter.sh` 等）を流し直せば正しい内容が得られる。

#### 類型C: 同じドキュメントの近接行を両ブランチが変更した

`.claude/docs/README.md` のDDR一覧末尾、`.claude/rules/docs-workflow.md` の運用表、
`.claude/skills/issue-mr-flow/SKILL.md` のフロー表など、**末尾や表へ追記していく形のファイル**で
起きる。過去の事例では `README.md` が毎回この形になっている。

**解消ルール: 両方の変更を残して統合する。片方を捨てない。**

- 一覧・連番（DDR一覧等）は**番号順**に並べ直す。
- 表への行追加は、両ブランチが追加した行を**どちらも**残す。
- 散文の段落が両側で書き換わっている場合は、機械的な連結ではなく**意味が通る1つの文章へ書き直す**
  （両側の主張が矛盾するなら、それはドキュメントの内容の食い違いであり、Step 7でユーザーへ報告する）。

#### 類型D: spec / DDR の過去changelogが絡む場合

`.claude/docs/spec/*.md` の「影響範囲」など、過去issueごとの point-in-time な記録が両側で
追記されている場合は、**時系列順に両方のエントリを残す**。過去のエントリの中身は書き換えない
（`.claude/rules/docs-workflow.md`「ファイル移動に伴うパス参照の一括置換は…過去changelogを対象に
含めない」と同じ理由）。

#### 類型E: 上記に当てはまらないコード上の競合

同じ関数・同じロジックを両ブランチが別々に変更した場合。**どちらを採るかで挙動が変わる**ため、
AIエージェントが単独で決めない。両側の意図を要約し、`AskUserQuestion` でユーザーの判断を仰ぐ。

### Step 5: 検証

コミット前に、以下をすべて実行して通ることを確認する（**1つでも落ちたらコミットしない**）。

```bash
# 1. コンフリクトマーカーの残存が無いこと
git diff --check
git grep -n -e '^<<<<<<< ' -e '^>>>>>>> ' -- . || echo "マーカー無し"

# 2. unmerged なパスが残っていないこと
git diff --name-only --diff-filter=U

# 3. 変更した .sh の構文チェック
bash -n <変更した.shファイル>

# 4. 単体テストの実行
for t in .claude/scripts/test/test_*.sh; do bash "$t"; done

# 5. DDR番号の重複が解消されたこと（類型Aを解消した場合は必須）
bash .claude/scripts/src/check-base-conflicts.sh --no-fetch | jq '.hasDuplicateDdrNumber'

# 6. frontmatterインデックスの再生成（生成物なのでコミット対象ではない）
bash .claude/scripts/src/extract-frontmatter.sh .
```

手順5は**マージの途中（作業ツリーにマージ結果が載っている状態）で実行する**。この状態では
`HEAD` はまだマージ前を指しているため、`--head` を省略した既定（`HEAD` とdefaultブランチの比較）
ではなく、作業ツリーの実ファイルを直接 `ls` して番号の重複が無いことを目視確認してもよい。

```bash
ls .claude/docs/ddr/ | grep -oE '^[0-9]{4}' | sort | uniq -d   # 何も出なければ重複なし
```

#### 「1つでも落ちたらコミットしない」の例外: defaultブランチ側に既存の失敗がある場合

手順4の単体テストが、**マージとは無関係にdefaultブランチ側で既に失敗している**ことがある
（issue #97対応時に実際に発生: `main` 上で `test_post_issue_create_notice.sh` が
`passed=13 failures=1` だった）。この場合、上の原則をそのまま適用するとマージを永久にコミット
できない。次の順で判断する。

1. **マージ由来かどうかを切り分ける。** `origin/<base>` を単体で取り出して同じテストを実行し、
   そこでも失敗するかを確認する（作業ツリーを汚さないよう、別ディレクトリへ `git worktree add`
   するか、テストスクリプトだけを `git show origin/<base>:<path>` で取り出して実行する）。
2. **defaultブランチ単体で再現するなら「既存の失敗」として続行してよい。** 再現しないなら
   マージ由来（semantic conflict）なので、テストが指す箇所を直してから同じマージコミットへ含める。
   **テストを無効化して通さない。**
3. **続行した場合は、どのテストがなぜ失敗しているかを Step 7 の報告に必ず含める。**
   関連するissueが既にあればその番号も添える。**黙って通さないこと**（次に見る人が、その失敗を
   このマージが持ち込んだものだと誤解する）。

#### 自動マージされて入った行も確認する

**コンフリクトした範囲だけを見て終わりにしない**（issue #97対応時に実際に踏んだ）。同じマージで
gitが**競合と見なさずに取り込んだ行**が、そのブランチの文脈では不適切なことがある。

- 実例: `main` をマージした際、`HANDOFF.md` の競合部分は解消したものの、**別タスクの記述を含む
  HTMLコメントがコンフリクトせずに自動マージで入り込んでいた**。`HANDOFF.md` は「このブランチの
  現在の状態」だけを表すファイルなので、これは残してはいけない。
- gitが競合と見なさない変更は `git status` にも `git diff --check` にも出ない。
  **`git diff HEAD -- <path>` で、そのファイルへ入った変更を通しで読む**こと。とくに
  `HANDOFF.md` のような「1ブランチ1状態」のファイルでは必ず行う。

### Step 6: コミット

`commit` スキル経由でコミットする。マージの途中（`MERGE_HEAD` が存在する状態）で
`create-commit.sh` を呼べば、gitが自動的にマージコミットとして記録する。

```bash
bash .claude/scripts/src/create-commit.sh --message "chore: <base>をマージし<解消内容>を統合" -- <解消したファイル...>
```

**コミットメッセージには「何を」「どう」解消したかを書く**（後から履歴だけで経緯を追えるようにする。
実績のある書き方）。

- `chore: mainをマージしDDR番号を0028へ繰り下げてissue #45の変更と統合`
- `chore: mainをマージしDDR番号を0026へ繰り下げてindex.jsonl生成物化との競合を解消`

その後 `git push -u origin <branch>` でリモートへ反映する。

**監視モード（issue #88）でも、この Step は一切変えない。** 承認を省略できるのは Step 2 だけで
あり、コミットは `commit` スキル経由、メッセージは「何を」「どう」解消したかを書く、という規約は
同じである（例: `chore: mainをマージしDDR番号を0039へ繰り下げてissue #88の変更と統合`）。

### Step 7: 報告

解消した内容を、類型ごとに箇条書きでユーザーへ報告する。以下は必ず含める。

- 改番したDDR（旧番号 → 新番号）と、それに伴い更新した参照元ファイル
- 判断に迷った箇所（類型C・Eで統合方針を決めた箇所）
- 検証（Step 5）の結果

**`HANDOFF.md` の「判断を迷った内容」へも同じ内容を書き残す**（レビュアーが差分だけを見ても、
なぜその統合になったか分からないため。実績: PR #29のコミット c2bb66f）。

**監視モードでは、報告先はPRのコメントも含める**（issue #88）。ユーザーが見ていない間に解消が
進むため、「いつ・何を・どう解消したか」がPR上に残っていないと、レビュアーは差分の出所を追えない。
一方で**空振り（`hasConflict` が偽だった回）は報告しない**。監視は静かに繰り返すものであり、
変化の無い通知でPRとチャットを埋めない。

## 想定される失敗と対処

| 症状 | 原因・対処 |
|---|---|
| `check-base-conflicts.sh` が `origin/<base> が見つかりません` で失敗する | `git fetch origin <base>` が届いていない。ネットワーク失敗時は指数バックオフ（2s/4s/8s/16s）で最大4回まで再試行する |
| `hasConflict` が `false` なのに、人間のマージ操作でコンフリクトが出た | defaultブランチが検知後に進んだ可能性がある。`--no-fetch` を付けずに再実行して最新で判定し直す |
| マージ後にテストが落ちる | 両ブランチの変更が**個別には正しいが組み合わせると壊れる**（semantic conflict）。テストが指す箇所を直してから同じマージコミットに含める。テストを無効化して通さない |
| `create-commit.sh` が「コミット対象ファイルを1件以上指定してください」で失敗する | マージで自動ステージされたファイルもパスとして明示的に渡す（`git diff --cached --name-only` で列挙できる） |

## 詳細ルールへのポインタ

- 全体フローにおける位置づけ（flow-id 5-2）: `.claude/skills/issue-mr-flow/SKILL.md`
- ブランチ運用・squash merge・コミット運用: `.claude/rules/git-workflow.md`
- DDRの番号・frontmatter運用: `.claude/rules/markdown-frontmatter.md`, `.claude/rules/docs-workflow.md`
- 検知スクリプトの仕様: `.claude/docs/spec/check-base-conflicts.md`
- 意思決定の経緯・却下案: `.claude/docs/ddr/0029-defaultブランチとのコンフリクトは検知を機構化し解消手順をスキル化する.md`
- 監視モード（PR作成後の追従・自動解消の線引き）の経緯・却下案:
  `.claude/docs/ddr/0039-PR作成後のdefaultブランチ追従は並行手順として定義し自動解消は一意に決まる類型に限る.md`
- 監視のフロー上の位置づけ: `.claude/skills/issue-mr-flow/SKILL.md`「PR作成後のdefaultブランチ追従（監視）」節
