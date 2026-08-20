---
title: answer-talker スキルの設計 結果
type: report
description: issue #1 の answer-talker スキルについて、ファイル構成・Provider.shの追加関数・正解ソース取得・サブエージェント・ネタバレ検査・SKILL.mdの手順・検証環境（D1〜D7）を決めた結果。
tags: [answer-talker, 設計, report, issue-mr-flow]
keywords: [answer-talker, 設計, GH_REPO, GITLAB_REPO, get_mr_changed_files, ネタバレ検査, 禁止語, 対応付け, 検証環境, 単体テスト]
---

# answer-talker スキルの設計 結果

- issue: [#1](https://github.com/yuki-matsu783/ans-talker/issues/1) / PR: [#2](https://github.com/yuki-matsu783/ans-talker/pull/2)
- 個別作業計画: `plans/【設計】answer-talkerスキルの構成とインターフェース.md`（flow-id 3-4で合意）
- 前提の調査結果: `reports/20260820_bubbly-exploring-biscuit_answer-talker設計調査.md`
- 実施: 2026-08-20（flow-id 3-6）

## 0. 調査結果の訂正（設計に影響する）

**調査結果の論点1で「`add_mr_inline_comments` は MR番号を引数で取る設計なので、他人のMRにも
そのまま使える」と書いたが、これは誤りだった。**

`gh` / `glab` は**対象リポジトリをカレントディレクトリのgitリモートから解決する**。MR番号だけでは
「どのリポジトリのMRか」が決まらない。実機で確認した。

```bash
$ gh api "repos/{owner}/{repo}" --jq '.full_name'
yuki-matsu783/ans-talker          # ← cwd のリポジトリが使われる

$ glab api "projects/:id"          # cwd がGitLabプロジェクトでないと失敗する
ERROR Unable to expand placeholder in path: none of the git remotes configured
      for this repository correspond to the GitLab instance...
```

`answer-talker` は**別リポジトリ（受講者）のMR**を対象にするため、この解決が要る。放置すると
「自分のリポジトリのMRを読み、そこへ投稿する」という壊れ方をする。

### 解決策（実機で確認済み）

**両プロバイダとも、環境変数で解決先を上書きできる。**

```bash
$ GH_REPO="cli/cli" gh api "repos/{owner}/{repo}" --jq '.full_name'
cli/cli

$ GITLAB_REPO="root/issue45-verify" glab api "projects/:id" | jq -r '.path_with_namespace'
root/issue45-verify
$ GITLAB_REPO="root/issue127-verify" glab api "projects/:id" | jq -r '.path_with_namespace'
root/issue127-verify
```

**この方式なら、既存の `Provider.sh` / `Github.sh` / `Gitlab.sh` の関数を1行も変えずに、
別リポジトリを対象にできる。** `adversarial-review` が使っている共通コードに手を入れずに済む点で、
他の選択肢より優れる。

| 案 | 評価 |
|---|---|
| **A. 環境変数で解決先を上書きする（採用）** | 既存関数に変更なし。投稿（`add_mr_inline_comments`）にも同じ仕組みがそのまま効く |
| B. 各関数に対象リポジトリの引数を足す | `Provider.sh`・`Github.sh`・`Gitlab.sh` の広範囲に波及し、`adversarial-review` の呼び出しも全部直すことになる |
| C. 受講者リポジトリをcloneして、そこをcwdにして実行する | 投稿のためだけに受講者のリポジトリをcloneするのは重い。cwdを移動する副作用も大きい |
| D. URLエンコードした完全パスをAPIパスへ直接埋める | GitLabでは実機で動いたが（`projects/root%2Fissue45-verify/...`）、GitHub側と書き方が揃わず、既存関数も書き換えになる |

なお、`glab api` には `-R/--repo` フラグが**無い**（`gh` と違う点。フラグ一覧で確認）。
`glab mr view -R <project>` のような高レベルコマンドには効くが、`api` サブコマンドには無いため、
環境変数が唯一の統一的な手段である。

---

## D1. ファイル構成と責務の境界

`adversarial-review-count.sh` が「スキルが所有するスクリプトを `.claude/scripts/src/` 直下へ
フラットに置き、スキル名を接頭辞にする」という前例を作っているので、それに倣う
（`vcs/` のようなサブディレクトリは、複数スクリプトから使われる層のためのもの）。

| ファイル | 責務 | 責務**でない**もの |
|---|---|---|
| `.claude/skills/answer-talker/SKILL.md` | 手順の並び・引数の解釈・承認・後始末 | レビュー観点の中身、検査アルゴリズムの詳細 |
| `.claude/agents/answer-talker-reviewer.md` | レビュー観点・findingsの生成・出力規約 | 投稿、ファイル修正、対象の決定 |
| `.claude/scripts/src/answer-talker-reference.sh` | 正解ソースの取得と後始末 | 正解の中身の解釈 |
| `.claude/scripts/src/answer-talker-map.sh` | 受講者⇔正解の**機械的に決まる**対応付け | 「未作成の分割単位か別解か」の判断 |
| `.claude/scripts/src/answer-talker-spoiler-check.sh` | 禁止語の抽出とfindings本文の検査 | 指摘の良し悪しの判断 |
| `.claude/scripts/src/vcs/Provider.sh` ほか | MR番号起点の差分取得（`get_mr_changed_files`）・対象リポジトリの切り替え（`use_target_repo`） | answer-talker固有のロジック |
| `.claude/scripts/test/test_answer_talker_*.sh` | 上記3スクリプトの純粋関数の単体テスト | — |

**責務配分の原則**: 機械的に決まることはスクリプトが、決まらないことはサブエージェントが持つ。
`adversarial-review` から離れるのは「観点の出どころ」だけで、これは観点表（`REVIEW-POINTS.md`）が
このリポジトリの運用規約向けで、演習課題の設計方針を表現できないため（調査結果の論点1）。

---

## D2. `Provider.sh` へ追加する関数

### `use_target_repo <対象>` （新設）

対象リポジトリを、以降の全関数の解決先にする。**引数はURLでもスラッグでもよい。**

```bash
use_target_repo "https://gitlab.example.com/root/exercise-01"   # URL
use_target_repo "yuki-matsu783/ans-talker"                       # slug（プロバイダはcwdから）
```

行うことは3つ。

1. プロバイダを決める。URLが渡された場合は既存の `provider_from_remote_url` で判定し、
   グローバル `_PROVIDER_CACHE` へ入れる（`get_provider` は未設定のときだけ `git remote` を
   見る遅延初期化なので、先に入れておけば上書きできる。`Provider.sh:270`）。
2. `GH_REPO`（GitHub）または `GITLAB_REPO`（GitLab）を export する。
3. GitLabで自己ホストの場合は `GITLAB_HOST` も export する
   （**ポート付きホストは `--hostname` では渡せない**。`glab --hostname localhost:8929` は
   `Error parsing --hostname: invalid hostname.` になることを調査で確認済み）。

**プロセス内の状態を変える関数である**ことを関数コメントに明記する。`answer-talker` は
1回の実行で1つのMRしか扱わないため、解除・切り戻しは用意しない。

### `get_mr_changed_files <MR番号>` （新設）

**名前は `get_mr_diff` にしない**（未決定事項#3）。既存の `get_mr_diff_url` /
`get_mr_diff_since_url` は「URLを組み立てるだけ」の関数であり、`get_mr_diff` を足すと
「`get_mr_diff` は本文、`get_mr_diff_url` はURL」という**似た名前で中身が違う3兄弟**になる。
`changed_files` なら、GitHubの `pulls/<n>/files` / GitLabの `/diffs` という実体とも対応する。

**返却は stdout へJSON1つ**（未決定事項#2）。`Provider.sh` の全関数がこの規約であり、
ここだけ出力ファイル引数にすると呼び出し側の書き方が2種類になる。**サイズ対策は
「呼び出し側が必ずファイルへリダイレクトする」規約で担保**し、SKILL.md とこの関数の
コメントの両方へ書く。

```bash
# 良い例
get_mr_changed_files 42 > "$tmpdir/diff.json"
# 悪い例（コマンド置換のバッファとjqの引数長上限に当たる）
diff="$(get_mr_changed_files 42)"
```

返却JSON（**GitHub・GitLab双方の実データから組み立ててキー集合の一致を確認済み**。調査結果）:

```json
{
  "base": "main", "head": "feat-1", "headSha": "…",
  "totalFiles": 7, "truncatedFiles": 0, "capped": false,
  "files": [
    {"path": "…", "oldPath": "…", "status": "modified",
     "additions": 80, "deletions": 76, "patch": "…", "truncated": false}
  ]
}
```

| キー | 決めたこと |
|---|---|
| `status` | `added` / `modified` / `removed` / `renamed` の4語彙に統一。GitLabは `new_file` → `deleted_file` → `renamed_file` の順に真偽値を見て変換する |
| `additions` / `deletions` | **GitLabは返さない**ため、`diff` 本文の行頭 `+` / `-`（`+++` / `---` を除く）を数えて算出する。実データで `+2/-2` を検算済み |
| `oldPath` | GitHubは `previous_filename`、GitLabは `old_path`。無ければ `path` と同じ値を入れる |
| `truncated` | **GitHubは `patch` キーの欠落、GitLabは `too_large` と `collapsed` の論理和**。`collapsed` を見落とすと、折りたたまれて `diff` が空のファイルを「差分なし」と誤読する |
| `truncatedFiles` | `truncated` が真のファイル数。**0でなければSKILL.mdの手順で必ず報告する**（無言で切り捨てない） |
| `capped` | GitHubの3000ファイル上限に達したか。到達時は真にして報告する |

エラー方針は既存関数に合わせる。冒頭で `require_vcs_cli get_mr_changed_files` を呼び、
CLI不在時はMCPフォールバックのツール名を stderr へ出して失敗する。

---

## D3. 正解ソース取得スクリプト `answer-talker-reference.sh`

```bash
bash .claude/scripts/src/answer-talker-reference.sh resolve --reference <URL|パス> [--ref <ブランチ/タグ>]
# → {"kind":"url"|"local","root":"<絶対パス>","cleanup":true|false,"tmpdir":"…"|null}

bash .claude/scripts/src/answer-talker-reference.sh cleanup --tmpdir <パス>
```

**サブコマンド方式にする**（未決定事項#4）。後始末を呼び出し側の手順に暗黙に委ねると、
AIエージェントが手順を飛ばしたときに一時ディレクトリが残る。**手順書に明示的な1ステップとして
書ける形**にするほうが漏れにくい。

- `cleanup` は `--tmpdir` が空・存在しない・`resolve` が作ったものでない場合は**何もせずに正常終了**
  する（冪等）。**`cleanup` に渡された任意のパスを `rm -rf` しない**ため、削除前に
  「一時ディレクトリの親の下にあるか」を検証する。
- `kind` の判定: 引数が `://` を含む、または `git@` で始まるなら `url`、それ以外は `local`。
- `local` は**cloneしない**（`--depth 1` が局所cloneで無視されること、素のディレクトリは
  cloneできないことを調査で確認済み）。`root` は入力パスの絶対パス化のみを行い、
  `cleanup:false` / `tmpdir:null` を返す。
- `url` は `git clone --depth 1 --single-branch --no-tags [--branch <ref>]` を
  `mktemp -d` の下へ行い、`cleanup:true` を返す。
- **cloneの失敗をパイプで潰さない**（調査で実際に踏んだ。`git clone … | tail` は `tail` の
  終了コードを返す）。出力を捨てる場合もリダイレクトで行い、終了コードを直接見る。
- スクリプト自身の異常終了に備え、`trap 'cleanup_tmp EXIT INT TERM'` も併用する
  （`resolve` の途中で落ちた場合、まだ呼び出し側は `tmpdir` を知らないため）。
  正常終了時は `trap` の対象から外す。
- **`MSYS_NO_PATHCONV` は export しない**。`git` はMSYSのパス変換の恩恵を受ける側であり、
  止めると壊れる（`.claude/rules/shell-script-style.md`）。
- **認証は扱わない**。非公開リポジトリの clone はgitの資格情報ヘルパ任せとし、その旨をSKILL.mdへ明記する。

---

## D4. サブエージェント `answer-talker-reviewer`

`adversarial-reviewer` の構造（立場 → 入力 → 手順 → 出力 → してはいけないこと）を踏襲する。
**差分は次の4点。**

### (1) 入力に正解が加わり、読み取り範囲の規約が変わる

`adversarial-reviewer` は「渡されたもの以外を探しに行くな」と規定しているが、
`answer-talker-reviewer` は**正解ディレクトリを読む必要がある**。そこで規約を書き分ける。

- **読んでよい**: 正解ルート配下のファイル、受講者の変更ファイルの中身。
- **読んではいけない**: 受講者リポジトリのコミットメッセージ・issue・MR説明
  （実装者の意図が混入するため。`adversarial-reviewer` と同じ理由）。

正解の中身は**プロンプトへ載せず、Readで読ませる**。載せるほど転記のリスクが上がり、
正解の規模も未知のため（調査結果の論点4）。

渡す入力は次のJSON1つ（`mapping` は `answer-talker-map.sh` の出力）。

```json
{"diff": {...}, "reference": {"root": "…", "files": [...]},
 "mapping": {"matched": [...], "referenceOnly": [...], "submissionOnly": [...]}}
```

### (2) レビュー観点（正解との照合）

issueの「期待する動作」4をそのまま観点にする。**各観点に「指摘しない条件」を併記する**のが
`adversarial-reviewer` との最大の違いで、これが「別解を潰さない」を書き下した形になる。

| 観点 | 指摘する | **指摘しない** |
|---|---|---|
| 責務の分割単位 | 1ファイル/1関数が複数の役割を抱えている | 分け方が正解と違うだけで、役割は分かれている |
| 層・依存の向き | 依存が逆向き・循環している | 層の名前や粒度が正解と違うだけ |
| 命名・配置・エラー処理・設定の持ち方 | **一貫していない**（同じ種類のものが別々の流儀で書かれている） | 流儀が正解と違うが、内部で一貫している |
| 正解が避けている作り | 重複・密結合・ハードコードがある | 正解に無い作りだが、弊害が説明できない |

**「正解と違う」だけでは指摘の理由にならない**ことを、観点の見出しではなく**各行の
「指摘しない」列として**書く。見出しの注意書きにすると読み飛ばされる。

### (3) 出力の規約（ネタバレ防止の一段目）

指摘本文は**「何が問題か」「なぜそうすべきか（設計原則の言葉で）」「どの方向へ直すか」の3点**で
書く（issueの「期待する動作」5）。加えて禁止事項を明示する。

- **正解のコード片を引用しない。** 正解にしか存在しない識別子（型名・関数名・ファイル名）を
  書かない。
- **「正解では〜」「模範解答では〜」という書き方をしない。** 正解側にしかない構成要素を指摘する
  ときは、**「この処理はどういう単位で分けられるか」という問いの形**にする。
- 例（規約としてSKILL.mdではなくエージェント定義に置く）:
  - 悪い: 「`UserRepository` を切り出すべき」
  - 良い: 「このファイルはHTTPの受け口とデータ永続化の2つの役割を持っている。
    片方が変わるともう片方を読み直す必要があるので、永続化の関心を別の単位へ分けられないか」

**この規約だけでは構造の転記（「A/B/Cの3つに分ける」）を防げない**（調査結果の論点5）。
だから二段目の機械的検査（D5）が要る。

### (4) findings JSONは `adversarial-reviewer` と同一スキーマ

`github_filter_findings_by_valid_lines` / `format_findings_summary` /
`github_build_review_payload` / `gitlab_build_discussion_body` がこのスキーマ前提で実装済みのため、
**変えない**。`category` の語彙だけ演習向けにする
（`responsibility-split` / `dependency-direction` / `naming-consistency` / `duplication` /
`hardcoded-config`）。

---

## D5. ネタバレ検査 `answer-talker-spoiler-check.sh`

**方針: 誤検知の側へ倒す**（flow-id 3-4で合意）。正当な指摘を落としてでも、転記の見逃しを避ける。

### アルゴリズム

```
禁止語 = (正解ファイルの識別子) − (受講者diffに現れる語) − (除外語) − (短すぎる語)
混入 = findings本文に、禁止語のいずれかが単語境界で現れる
```

1. **識別子の抽出**: 正解ルート配下のテキストファイルから `[A-Za-z_][A-Za-z0-9_]*` を切り出す。
   `snake_case` / `camelCase` / `PascalCase` は**分割せず、そのままの形で**扱う
   （分割すると `user` のような一般語が禁止語に入り、誤検知の側へ倒す判断と噛み合っても
   実用にならないため。ここは「厳しくしすぎない」側の判断であり、理由を残す）。
2. **受講者diffに現れる語を引く**。受講者が自分で書いている語は、指摘本文に出てもネタバレでは
   ない。この差し引きが誤検知を減らす主な働きをする。
3. **除外語を引く**（未決定事項#5の決定）。**スクリプト内の定数として持つ**。
   - 理由: 除外語は「言語のキーワード＋ごく一般的な英単語」であり、**演習課題ごとに変わらない**。
     外部ファイルにすると、スキルの利用者がファイルを用意しないと動かない、という失敗経路が増える。
   - 言語ごとに分けない。全言語のキーワードを1つの集合に混ぜて持つ（`func` がGoでも
     JavaScriptでも予約語であることに違いはなく、混ざって困る場面が無い）。
   - 定数を編集しやすいよう、スクリプト冒頭に1つの配列として置く。
4. **短すぎる語を引く**: 3文字以下。`id` `db` `err` のような略語が禁止語に入ると、
   ほぼすべての指摘が落ちる。
5. **判定は単語境界で行う**。禁止語 `repo` が本文中の `repository` に含まれても混入としない。
   日本語の本文中では前後が非英数字になるので、`[^A-Za-z0-9_]` を境界として扱えばよい。
6. **大文字小文字は区別する**。`UserRepo` と `userrepo` を同一視すると、一般語との衝突が増える。

### インターフェースと出力

```bash
bash .claude/scripts/src/answer-talker-spoiler-check.sh \
  --findings <findings.json> --reference-root <正解ルート> --diff <diff.json> \
  --out <検査後findings.json>
# → {"kept":8,"dropped":2,"drops":[{"title":"…","words":["UserRepository"]}]}
```

- **落とした finding のみを除外し、残りは通す**（全体中止にしない）。1件の誤検知で全部落ちる
  設計だと、運用で検査を緩める圧力がかかるため。
- **落とした件数と、反応した語を必ず返す**（flow-id 3-4の合意事項）。誤検知の側へ倒す方針は
  「指摘が落ちすぎて実質何も出なくなる」という壊れ方をするため、可視化が無いと気づけない。
- **`kept` が0になったら投稿しない。** 空のレビューを投稿せず、その旨を報告する（D6の手順）。

### 性能

正解ファイル数に比例して外部コマンドを起動しない（`.claude/rules/shell-script-style.md`）。
識別子の抽出は**全ファイルをまとめて1回の `grep -oE`** に通し、集合演算は `sort -u` / `comm`、
または bash の連想配列で行う。findingsごとに `jq` を起動しない（findings本文はまとめて
1回の `jq` で取り出す）。

### 単体テストのケース（`test_answer_talker_spoiler_check.sh`）

純粋関数として切り出すのは「禁止語の抽出」と「混入判定」の2つ。

| # | ケース | 期待 |
|---|---|---|
| 1 | 正解にしかない識別子を含む本文 | 落とす |
| 2 | 受講者diffにも現れる識別子を含む本文 | 落とさない |
| 3 | 除外語（`func` `return` `class`）のみ | 落とさない |
| 4 | 3文字以下の語（`id` `db`） | 落とさない |
| 5 | 禁止語が別の語の部分文字列（`repo` in `repository`） | 落とさない（単語境界） |
| 6 | 禁止語が行頭・行末・日本語に隣接 | 落とす（境界の判定） |
| 7 | 大文字小文字だけ違う | 落とさない |
| 8 | findings 0件 | `kept=0 dropped=0`、エラーにしない |
| 9 | 正解ファイル0件 | 禁止語が空になり、全件通す（**エラーにしない**） |
| 10 | 日本語のみの本文 | 落とさない |
| 11 | 正解に日本語の識別子 | 境界判定が壊れない |
| 12 | 同じ禁止語が複数のfindingに出る | それぞれ落とす／`drops` に両方載る |

---

## D6. SKILL.md の手順構成

`adversarial-review` の手順1（実施回数の上限）を削除し、手順2を差し替え、投稿の直前に検査を挟む。

| 手順 | 内容 |
|---|---|
| 0 | 経路の確認（`get_vcs_access_mode`）。`mcp` ならフォールバック節へ読み替える |
| 1 | **引数の解釈**（`<MR番号>` `--reference <URL\|パス>` `[--ref <ブランチ/タグ>]` `[--repo <対象>]`）。`--repo` 省略時はcwdのリポジトリを対象とし、**その旨を必ず表示する**（別リポジトリのつもりで自分のMRを読む事故を防ぐ） |
| 2 | `use_target_repo` で対象を切り替え、`get_mr_changed_files <MR番号> > diff.json` |
| 3 | `answer-talker-reference.sh resolve` で正解ソースを取得 |
| 4 | `answer-talker-map.sh` で対応付け |
| 5 | **投稿の可否を `AskUserQuestion` で1回だけ確認**（`adversarial-review` と同じ承認モデル） |
| 6 | サブエージェント `answer-talker-reviewer` を起動し findings を得る |
| 7 | **`answer-talker-spoiler-check.sh` で検査**。落とした件数と反応した語を報告する |
| 8 | 確度×重大度で選別（`adversarial-review` の表をそのまま使う。1回10件まで） |
| 9 | `add_mr_inline_comments <MR番号> <検査後findings>` で投稿。**0件なら投稿しない** |
| 10 | **`answer-talker-reference.sh cleanup`** で後始末 |
| 11 | 結果の報告（投稿件数・サマリへ回った件数・**検査で落とした件数**・報告のみに留めた件数） |

- **承認（手順5）はサブエージェント起動の前に置く。** `adversarial-review` と同じ位置。
  レビュー自体をやめる選択肢がある以上、コストのかかる処理の前に聞く。
- **後始末（手順10）は失敗経路でも通す。** 手順6〜9のどこで失敗しても手順10を実行することを、
  手順の並びだけでなく「してはいけないこと」にも書く。
- 「してはいけないこと」に入れるもの: 正解のコード片をコメント本文へ書くこと／検査（手順7）を
  飛ばすこと／スレッドの解決操作／指摘0件のときに水増しすること／
  `--repo` を省略したまま別リポジトリのつもりで実行すること。

---

## D7. 検証環境（演習用プロジェクト）

**題材**: 「テキストを1行ずつ読み、条件で絞り、整形して出力する」だけの極小のCLI。
言語は **bash**（実行環境に既にあり、題材の複雑さが評価に混ざらない）。

| | 構成 |
|---|---|
| 正解 | `read.sh`（入力）/ `filter.sh`（選別）/ `format.sh`（整形）の**3ファイルに分割** |
| 初期状態（default） | `main.sh` に入出力の骨格だけがあり、選別・整形は未実装 |

正解にしか存在しない分割単位（選別・整形の分離）が確実に存在するため、受け入れ条件の中核を
確認できる。

### プロジェクトとブランチ

ローカルGitLab（`localhost:8929`）に**2プロジェクト**を作る。

- `root/answer-talker-verify`（演習用。受講者MRを複数持つ）
- `root/answer-talker-answer`（正解。**URL形態のclone元**。同じ内容をローカルにも展開して
  ローカルパス形態を試す）

### パターンと期待する結果

| # | パターン | 作り方 | 期待する結果 |
|---|---|---|---|
| ① | 分割不足 | `main.sh` に全部書いたMR | 「どういう単位で分けられるか」の形で指摘が出る |
| ② | 別解として妥当 | 2ファイルに分割（`io.sh` / `transform.sh`） | **分割単位についての指摘が出ない** |
| ③ | 正解が避けている作り | 同じ整形処理を2箇所へコピー | 重複の指摘が出る |
| ④ | 余分な抽象化 | 1関数のためだけに3層のラッパー | 過剰な指摘にならない（出ても `minor` 以下） |
| ⑤ | ほぼ正解と同じ | 正解と同じ3分割（命名だけ違う） | **指摘0件** |
| ⑥ | 正解＝URL | `--reference http://localhost:8929/root/answer-talker-answer.git` | clone され、実行後に一時ディレクトリが残らない |
| ⑦ | 正解＝ローカルgitリポジトリ | clone 済みディレクトリを指定 | cloneせず読む。**元ディレクトリが変更されない** |
| ⑧ | 正解＝素のディレクトリ | `.git` を除いたコピーを指定 | ⑦と同じ結果になる（cloneしない設計が効く） |
| ⑨ | ファイルの削除 | `main.sh` を消して作り直したMR | `status:removed` が出る |
| ⑩ | **リネーム** | `main.sh` → `cli.sh` | `status:renamed` と `oldPath` が正しい（**調査で未確認だった項目**） |
| ⑪ | 新規追加のみ | 初期状態に触れず新ファイルだけ | `status:added` のみ |
| ⑫ | 転記を含むfinding | 正解の識別子を含む findings を手で作って検査へ通す | **落とされる**。`drops` に反応した語が出る |
| ⑬ | 一般語のみの正当なfinding | 「重複」「責務」だけを含む findings | **落とされない** |
| ⑭ | 実投稿 | ①のMRへ投稿 | GitLabのMRにインラインコメントが付く |
| ⑮ | 指摘0件 | ⑤の結果をそのまま投稿手順へ | **投稿しない**。その旨が報告される |

①〜⑤・⑨〜⑪は**受講者MRを分けて用意する**（1つのMRに詰め込まない。どのMRがどのパターンかを
ブランチ名で対応付ける）。

### 再現可能にする

**構築を手作業で行わない。** 検証用のセットアップを1つのスクリプトにまとめ、
`.claude/scripts/test/` ではなく**一時ディレクトリ内で完結**させる（このリポジトリに題材を
残さないため）。スクリプト自体は `reports/` に手順として掲載し、flow-id 5-1 で消える。

- 冪等にする（既存プロジェクトがあれば消してから作り直す）。
- 後片付けとして、`glab api -X DELETE projects/<id>` で2プロジェクトを削除する手順も用意する。
  ローカルGitLabには過去の検証プロジェクトが4つ残っており（うち2つは削除予定のまま）、
  同じ状態を増やさない。

---

## 新たに生じた未決定事項

| # | 内容 | 扱い |
|---|---|---|
| N1 | `use_target_repo` を `Provider.sh` に置くか、answer-talker専用スクリプトに置くか | 汎用性はあるが、**現状 answer-talker しか使わない**。`Provider.sh` へ置く前提で実装するが、実装時に据わりが悪ければ再検討する |
| N2 | 除外語リストの初期内容（どこまで入れるか） | 実装時にパターン⑬で調整する。**足りなければ足す**方針で、最初から網羅しようとしない |
| N3 | 検証用セットアップスクリプトを `reports/` に載せるだけでよいか（`.claude/` に残す必要はないか） | flow-id 4-1 の反映対象の洗い出しで判断する |

## 実装（`【実装】【テスト】`）へ引き渡す項目

- 追加する6ファイルと、それぞれの責務（D1の表）
- `use_target_repo` / `get_mr_changed_files` のシグネチャと返却JSON（D2）
- `answer-talker-reference.sh` のサブコマンドと返却JSON（D3）
- サブエージェント定義の4つの差分（D4）
- 検査アルゴリズムと単体テスト12ケース（D5）
- SKILL.md の手順11段（D6）
- 検証環境の構成と15パターンの期待結果（D7）

**調査時点の未決定事項4件はすべて決定済み**（#2 返却形→stdout、#3 関数名→`get_mr_changed_files`、
#4 後始末→サブコマンド方式、#5 除外語→スクリプト内定数）。
