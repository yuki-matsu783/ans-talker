---
title: frontmatter抽出スクリプト（extract-frontmatter.sh）
type: spec
description: markdownのYAML frontmatterを抽出しindex.jsonlとして出力するdev-toolスクリプトの仕様
tags: [extract-frontmatter, jsonl, spec]
keywords: [frontmatter, jsonl, concept-id, リポジトリルート, yq, 抽出スクリプト, mtimeキャッシュ, 原子的更新, 中断耐性, プロセス起動]
---

# frontmatter抽出スクリプト（extract-frontmatter.sh）

## 背景・目的

issue #7（各markdownドキュメントへのOKF風frontmatter付与）のPR #23レビューで、リポジトリ内の
frontmatterを機械可読な形で一覧化したいという要望を受けて追加した。指定ディレクトリ配下の
markdownファイルからYAML frontmatterのみを抽出し、1行1JSON（[JSON Lines](https://jsonlines.org/)）
の`index.jsonl`として出力する。`.claude/rules/markdown-frontmatter.md`が定めるOKF風frontmatterの
機械可読なインデックスとして、将来的な検索・ツール連携の基盤にする位置づけ。

## 仕様

### 実行方法

```bash
bash .claude/scripts/src/extract-frontmatter.sh [--force] <directory>
```

指定ディレクトリ配下を再帰的に走査する。リポジトリルートで`.`を指定すると、markdownを含む全
ディレクトリの`index.jsonl`を一括生成できる（**通常はこの使い方をすればよい**。差分が無ければ
2秒未満で終わる）。

| オプション | 意味 |
|---|---|
| `--force` / `-f` | mtimeが変わっていないファイルもすべて再生成する（後述の差分スキップを使わない） |
| `-h` / `--help` | 使い方を表示して終了する |

標準エラー出力へ、`index.jsonl`ごとの結果（`wrote:` / `unchanged:`）と、実行全体のサマリ
`files=<走査したmarkdown数> built=<再解析した数> reused=<キャッシュを再利用した数> failed=<行の生成に失敗した数> skipped=<削除済みとしてスキップした数>`を出力する。
標準出力は使わない（生成物はファイルへ直接書き出す）。

行の生成に失敗したファイルは、`error: failed to build index line: <パス>`を標準エラーへ出したうえで
**その行を書かずにスキップ**し、他のファイルの`index.jsonl`は通常どおり書き出す。1件でも失敗が
あれば**終了コードは非ゼロ**になる（issue #69。以前は`jq`の失敗を握りつぶしており、`index.jsonl`へ
空行が1行入るだけで終了コード0のまま完了していたため、インデックスからの欠落に気づけなかった）。

### 出力単位

**markdownファイルが直下に存在するディレクトリ毎**に、そのディレクトリ自身へ`index.jsonl`を
出力する。1回の実行で複数ファイルが生成されうる。指定ディレクトリ配下に
サブディレクトリがあり、それぞれにmarkdownが存在する場合、サブディレクトリごとに個別の
`index.jsonl`が作られる（親ディレクトリの`index.jsonl`へ子ディレクトリ分を集約することはしない）。

**markdownが1つも無くなったディレクトリの`index.jsonl`は、出力対象から外れるだけで削除はされない**
（走査対象が「markdownが直下に存在するディレクトリ」であるため）。スクリプトがスコープ外のファイルを
消してしまう事故を避けるため、この削除は自動化せず**運用手順側で担保する**（例:
`.claude/skills/issue-mr-flow/SKILL.md`のflow-id 5-1で、`plans/*.md`の削除とあわせて
`plans/index.jsonl`も削除する）。

### 出力フォーマット

1行1JSON、各行は以下の形式。

```json
{"concept_id": "docs/spec/activity-status", "directory": "docs/spec", "frontmatter": {...}, "mtime": "2026-08-16T10:14:49"}
```

- `concept_id`: **gitリポジトリのルートからの相対パス**から`.md`拡張子を除いたもの。
  実行時に指定したディレクトリではなく、常にリポジトリルートを基準にする（例:
  `docs/`を指定して実行しても、`docs/spec/activity-status.md`の`concept_id`は
  `docs/spec/activity-status`のままになる。`spec/activity-status`にはならない）。
- `directory`: `concept_id`と同じくリポジトリルート基準の、そのファイルが属するディレクトリの
  相対パス。
- `frontmatter`: frontmatterをJSONオブジェクト化したもの。frontmatterが無いファイルは`null`。
- `mtime`: ファイルの最終更新日時（ISO 8601、タイムゾーン省略。ローカルタイムゾーンで算出）。

### frontmatterのYAML→JSON変換

- `yq`（[mikefarah/yq](https://github.com/mikefarah/yq)）がPATH上にあれば優先的に使い、フル
  YAML文法に対応した変換を行う。
- `yq`が無い、または変換に失敗した場合は、本リポジトリのfrontmatterスキーマ
  （単純なスカラー値・フロー配列`[a, b, c]`・ブロック配列`- item`のみ）に絞った自前の軽量パーサーへ
  フォールバックする。`yq`を新規の必須外部依存にはしない（経緯:
  [0021-frontmatter抽出は1ファイル1回のjq呼び出しとmtimeキャッシュで高速化する.md](../ddr/0021-frontmatter抽出は1ファイル1回のjq呼び出しとmtimeキャッシュで高速化する.md)
  の却下案1）。

自前パーサーは、解析結果をいったん**中間表現**（`種別 キー 値`の3要素を1組とするシェル配列
`FM_ITEMS`）へ溜め、`jq --args`へ**1ファイルにつき1回だけ**渡してJSONオブジェクトを組み立てる
（jq側は`reduce range(0; length; 3)`で畳み込む）。`concept_id`/`directory`/`mtime`を含む最終的な
1行の組み立ても同じjq呼び出しへ統合している。種別は次の4つ。

| 種別 | 意味 |
|---|---|
| `s` | スカラー文字列 |
| `b` | 真偽値（`true` / `false`） |
| `A` | 配列キーの初期化（要素0個なら`[]`になる） |
| `a` | 配列要素の追加 |

中間表現が大きく、コマンドライン引数として渡すと長さ上限（実測でおよそ32KB。詳細:
`.claude/rules/shell-script-style.md`「JSON操作」）に達しうる場合は、一時ファイルへNUL区切りで
書き出し`--rawfile`＋`split("\u0000")`で読ませる経路へ自動的にフォールバックする。

位置引数として渡す際は、**jqフィルタの直後に`--`を置き、それ以降をすべて位置引数として扱わせる**。
これが無いと、`-A`のようにハイフンで始まる要素をjqがオプションとして解釈し
`jq: Unknown option -A`で失敗する（issue #69。`keywords: [git add, -A, pathspec]`で発生した）。
`--rawfile`側の経路は位置引数を使わないため、この問題の影響を受けない。

**この構造を、キーや配列要素ごとに`jq`を呼び出す実装へ戻してはいけない**（後述「性能」参照）。

### 差分スキップ（mtimeキャッシュ）

既存の`index.jsonl`を読み、`concept_id`→（既存行, `mtime`）の対応をbashの正規表現だけで取り出す
（外部プロセス起動0回）。対象ファイルの現在のmtimeが既存行の`mtime`と一致すれば、**既存行をそのまま
再利用**してfrontmatterの再解析・jq呼び出しをスキップする。

キャッシュは次のいずれかで無効化される。

- `--force` / `-f` が指定された場合。
- **`extract-frontmatter.sh`自身のmtimeが`index.jsonl`より新しい場合**（そのディレクトリを全再生成する）。
  解析ロジックを変更したのに古い行が残り続ける事故を防ぐための自動無効化。

この自動無効化があるため、**スクリプトを変更した直後に`--force`を付ける必要は無い**。

なお、**内容が既存と同一で書き換えなかった（`unchanged:`）`index.jsonl`にも`touch`でmtimeを
付け直している**。付け直さないと「スクリプトの方が新しい」という条件が永久に成立し続け、差分が
無くても毎回全ファイルが再生成されてしまう（実装時に実際に発生した）。gitはmtimeを追跡しないため、
この`touch`によってリポジトリに差分は生じない。

### 原子的更新と中断耐性

生成した行はいったんメモリ上に溜め、**全走査が完了してから**出力する。出力は同一ディレクトリへ
`index.jsonl.tmp.<PID>`として書き、`mv -f`で差し替える（同一ボリューム内のrename）。
`trap ... EXIT INT TERM`により、中断時も一時ファイルを確実に削除する。
**内容が既存と同一なら書き換えない**（`unchanged:`を出力する）。

これは、走査の途中で`index.jsonl`をtruncateして1行ずつ追記していた旧実装が、**中断すると既存の
`index.jsonl`を不完全な状態で壊していた**ため（issue #9対応時に`.claude/docs/ddr/index.jsonl`が
18行→14行に破損した実例がある）。issue #11の改修で、`SIGINT`による強制中断でも既存の
`index.jsonl`がすべて保持されること・一時ファイルが残らないことを実機で確認している。

### 性能

**git bash（MSYS）は外部プロセス起動が約95ms/回と重く**（実測: `jq -nc '1'`を50回実行して4.73秒）、
本スクリプトの所要時間はアルゴリズムではなく**プロセス起動回数**で決まる。旧実装はfrontmatterの
キー・配列要素ごとに`jq`を呼んでおり、1ファイルあたり約30回のプロセス起動が発生していた。

| 実行 | 改修前（issue #11以前） | 改修後 |
|---|---|---|
| `.claude/docs/ddr`（16ファイル） | 46.4秒 | **3.0秒** |
| リポジトリルート`.`（46ファイル、全再生成） | 136秒 | **9.6〜11.8秒** |
| リポジトリルート`.`（差分なし・キャッシュ有効） | ― | **1.5〜2.4秒** |

改修後の出力は、改修前の出力とバイト単位で完全一致することをゴールデンファイル比較で確認している
（出力フォーマットは変更していない）。

高速化の内訳と、ホットパスでコマンド置換`$(...)`を使わない理由は
`.claude/rules/shell-script-style.md`「外部プロセス起動のコスト」を参照。

### リポジトリルートの解決

`concept_id`/`directory`の基準となるリポジトリルートは`resolve_repo_root`関数で解決する。
`git rev-parse --show-toplevel`と`realpath`が返すパス表記の差異を吸収するため、
指定ディレクトリへ`cd`したうえで`git rev-parse --show-toplevel`の結果へ再度`cd`し、`pwd`で
一貫した表記のパスを取得する。

解決したリポジトリルートには`main()`の冒頭で`cd`し、以降のパスをすべてリポジトリルート相対に
揃えている。これにより`realpath --relative-to`によるパス変換が不要になっている
（プロセス起動削減の一環。上記「性能」参照）。

### 走査方式

対象ディレクトリ配下のmarkdownファイル列挙は`git ls-files --cached --others --exclude-standard`
（トラッキング済み + 未トラッキングだが`.gitignore`非対象、NUL区切り）で行う。`.gitignore`に
マッチするファイル・ディレクトリは列挙自体の対象にならない（走査自体が発生しない）ため、
`.gitignore`対象ディレクトリに大量のファイルが存在していても性能に影響しない。本スクリプトは
gitリポジトリ内での実行を前提とする（`resolve_repo_root`が`git rev-parse --show-toplevel`に
依存するのと同様の制約）。

`.gitignore`非対象であればフェーズ途中の一時的なディレクトリも走査対象に含む。`plans/`・`worklog/`
（`.claude/rules/docs-workflow.md`の「ドキュメント運用」表でpush単位・タスク単位の寿命とされる
ファイル群）についても`index.jsonl`を生成し、Git管理下に置く。一方、`.gitignore`で除外されている
`logs/`・`build/`等はmarkdownを含んでいても列挙自体が発生せず、`index.jsonl`も作られない
（issue #11対応時に実機確認済み）。

### 削除済みの追跡ファイルの扱い

`git ls-files --cached` は、**削除したがまだステージしていない追跡ファイル**も列挙する。列挙結果を
そのまま`stat`へ渡すと`stat: cannot stat '<パス>': No such file or directory`で失敗するため、
**ワーキングツリーに実体が無いパスは走査対象から外す**（issue #117）。スキップした件数は
`skipped 3 deleted file(s) not present in the working tree`という警告とサマリ行の`skipped=`で分かる。

削除済みのファイルはインデックスに載せるべきものではないので、スキップは「取りこぼし」ではなく
**正しい結果**である。該当ファイルの行は`index.jsonl`から消え、残ったファイルの行は変わらない。

判定は`[[ -f "$f" ]]`（bash組み込み）で行うためforkを伴わず、上記「性能」の前提を崩さない。

この状態は異常系ではなく**正常系として必ず発生する**。`cleanup-task.sh`（flow-id 5-1）は
`plans/` `worklog/` `reports/` を削除したあと**コミットせずに**本スクリプトを呼ぶ設計であり
（コミットは`commit`スキル経由に限るため。
[.claude/docs/ddr/0048-flow-id5-1の後片付けはスクリプト化しコミットは含めない.md](../ddr/0048-flow-id5-1の後片付けはスクリプト化しコミットは含めない.md)）、対策前は**追跡ファイルを
1件でも削除した時点で必ず失敗していた**。

対策前の失敗の影響は、警告1つでは済まなかった。`stat`の一括取得（`xargs -0 stat`）が失敗すると
取得できたmtimeの数がファイル数と合わなくなり、フォールバックの1件ずつ取り直すループが`set -e`
配下で最初の欠損ファイルに当たって**走査全体を中断**する。その結果、削除とは無関係な
ディレクトリの`index.jsonl`まで再生成されないまま終わっていた。

### 文字コード

jqの出力を直接ファイルへ書き出す箇所は`tr -d '\r'`でLF改行に統一している（Windows版native jq
バイナリが行末にCRを付与することがあるため。詳細: `.claude/rules/shell-script-style.md`「文字コード」節）。

## 影響範囲

- 新規: `dev-tools/src/extract-frontmatter.sh`
- 新規: `tests/test_extract_frontmatter.sh`（`frontmatter_to_json`のYAML→JSON変換、
  `resolve_repo_root`によるリポジトリルート解決、concept_id/directoryの導出ロジックの単体テスト）
- 新規: 本ドキュメント
- 新規（git管理下）: markdownを含む各ディレクトリの`index.jsonl`（`index.jsonl`, `docs/index.jsonl`,
  `docs/spec/index.jsonl`, `docs/ddr/index.jsonl`, `dev-tools/docs/index.jsonl`,
  `dev-tools/docs/spec/index.jsonl`, `dev-tools/docs/ddr/index.jsonl`, `.claude/agents/index.jsonl`,
  `.claude/rules/index.jsonl`,
  `.claude/skills/issue-mr-flow/index.jsonl`, `plans/index.jsonl`, `tests/index.jsonl`,
  `worklog/index.jsonl`, `.github/ISSUE_TEMPLATE/index.jsonl`, `.gitlab/issue_templates/index.jsonl`）

変更（issue #24 dev-toolsをAI専用/人間専用に分離）:
- `dev-tools/src/extract-frontmatter.sh`・`tests/test_extract_frontmatter.sh`が参照するsource先・
  本ドキュメントを `.claude/scripts/src/extract-frontmatter.sh`・
  `.claude/scripts/docs/spec/extract-frontmatter.md` へ移動した。
  `dev-tools/docs/spec/index.jsonl`・`dev-tools/docs/ddr/index.jsonl`は縮小、
  `.claude/scripts/docs/`配下に新規`index.jsonl`が追加された。

変更（issue #54 走査方式の`.gitignore`対応）:
- `.claude/scripts/src/extract-frontmatter.sh`の`main()`内のファイル列挙を、`find`ベースから
  `git ls-files --cached --others --exclude-standard`ベースへ置き換えた。issue #43で判明していた
  「`参考ディレクトリ/`（`.gitignore`対象）配下の大量ファイルによるタイムアウト・`index.jsonl`
  破損」を根本解消した（詳細: 上記「走査方式」節）。
- 新規: `.claude/scripts/docs/ddr/0016-frontmatterスクリプトの走査方式にgit-ls-filesを採用する.md`

変更（issue #11 リポジトリルート一括実行の高速化と中断耐性）:
- `.claude/scripts/src/extract-frontmatter.sh`を改修した。jq呼び出しを1ファイル1回へ集約し、
  `realpath`/`dirname`/`date`/`stat`/`tr`の起動とホットパスのコマンド置換を排除、mtimeキャッシュに
  よる差分スキップ（`--force`で無効化）と一時ファイル＋`mv -f`による原子的更新を導入した
  （詳細: 上記「差分スキップ（mtimeキャッシュ）」「原子的更新と中断耐性」「性能」）。
  frontmatterの解析ロジック（行の正規表現・値の分類・`yq`優先パス）と出力フォーマットは変更していない。
- 新規: `tests/test_extract_frontmatter.sh`（`tests/`ディレクトリ自体がこのリポジトリに
  存在しなかったため新規作成し、上記「影響範囲」の記述と実体を一致させた）。`passed=17 failures=0`。
- 新規: `.claude/docs/ddr/0021-frontmatter抽出は1ファイル1回のjq呼び出しとmtimeキャッシュで高速化する.md`
- 追記: `.claude/rules/shell-script-style.md`「外部プロセス起動のコスト」節、
  `.claude/rules/markdown-frontmatter.md`の再生成手順、
  `.claude/skills/issue-mr-flow/SKILL.md`のflow-id 5-1、`.claude/rules/docs-workflow.md`の`plans/`行。
- 新規（git管理下）: `plans/index.jsonl`・`tests/index.jsonl`（従来は生成が完走しなかったため未生成
  だった`.claude/skills/apply-mr-workflow-to-project/index.jsonl`等も含め、全ディレクトリ分が
  最新化された）。

変更（issue #36 index.jsonlをGit管理から外し生成物として扱う）:
- `.gitignore`に`**/index.jsonl`パターンを追加し、既存15箇所の`index.jsonl`を`git rm --cached`で
  Git管理から除外した（ワーキングツリー上のファイル自体は削除していない）。
- `.claude/hooks/session-start.sh`に`regenerate_frontmatter_index`関数を追加し、セッション開始の
  たびに本スクリプトを非侵襲的（fail-open）に実行する自動再生成の仕組みを導入した。
- `.claude/skills/issue-mr-flow/SKILL.md`のflow-id 5-1にあった「`plans/index.jsonl`を個別削除し
  `index.jsonl`群を再生成する」特殊対応、および`.claude/rules/docs-workflow.md`の該当記述を除去した。
- 新規: `.claude/docs/ddr/0025-frontmatterのindex.jsonlをGit管理から外しSessionStart-hookで生成する.md`

変更（issue #69 ハイフン始まりのfrontmatter要素でjqに失敗しindex.jsonlから欠落する）:
- `.claude/scripts/src/extract-frontmatter.sh`の`run_fm_jq`で、jqフィルタの直後に`--`を置き、
  中間表現をすべて位置引数として扱わせるようにした（詳細: 上記「frontmatterのYAML→JSON変換」）。
- 同`run_fm_jq`が`return 0`でjqの終了コードを握りつぶしていたのをやめ、jqの終了コードをそのまま
  返すようにした。あわせて`main()`が行の生成に失敗したファイルを、空行を書かずにスキップして
  標準エラーへ`error: failed to build index line: <パス>`を出し、サマリへ`failed=<数>`を加え、
  1件でも失敗があれば非ゼロで終了するようにした（詳細: 上記「実行方法」）。
- `.claude/scripts/test/test_extract_frontmatter.sh`にハイフン始まり要素の回帰テストを追加した
  （フロー配列・ブロック配列・スカラー値、`--rawfile`経路、`run_fm_jq`の終了コード伝播、
  `yq`不在をPATHで再現した`build_index_line`）。`passed=23 failures=0`。
- 本ドキュメント内に紛れ込んでいた生のNULバイト1個（`split("...")`の説明箇所）を、意図どおりの
  `\u0000`というエスケープ表記へ直した（`grep`がこのファイルをバイナリ扱いしていたため）。

変更（issue #117 削除済みの追跡ファイルで走査全体が失敗する）:
- `.claude/scripts/src/extract-frontmatter.sh`の`main()`のファイル列挙で、`git ls-files --cached`が
  返したパスのうち**ワーキングツリーに実体が無いもの（削除済みだが未ステージ）をスキップ**する
  ようにした（詳細: 上記「削除済みの追跡ファイルの扱い」）。判定はbash組み込みの`[[ -f ]]`で行い、
  forkは増やしていない。
- サマリ行へ`skipped=<スキップした数>`を加え、1件以上あれば
  `skipped <N> deleted file(s) not present in the working tree`を標準エラーへ出すようにした。
  サマリ行は人間向けのstderr出力で、機械的に解釈している呼び出し元は無い（`session-start.sh`・
  `search-frontmatter.sh`・`cleanup-task.sh`はいずれもstderrを捨てるか素通ししている）。
- `.claude/scripts/test/test_extract_frontmatter.sh`へ、使い捨てのgitリポジトリで実プロセスとして
  起動する結合テストを追加した（削除前後のサマリ、残った行が変わらないこと、無関係な
  ディレクトリの`index.jsonl`も再生成されること、対象ディレクトリのmarkdownが全滅した場合）。
  `passed=32 failures=0`。
- `.claude/scripts/test/test_cleanup_task.sh`へ、`cleanup-task.sh`の`main`を同じく使い捨ての
  gitリポジトリで実行する結合テストを追加した（`frontmatterIndex.exitCode`が0になること、
  `--dry-run` / `--skip-index`の挙動が変わらないこと）。`passed=53 failures=0`。
- 新規: `.claude/docs/ddr/0057-削除済み追跡ファイルの除外はextract-frontmatter側で行う.md`

## 設定項目

新規の`Settings`値は不要（本スクリプトはアプリ本体ではなくdev-tool）。

## 未決定事項・懸念点

- **（解消）生成物の自動再生成は未導入**: issue #36で解消済み。`index.jsonl`は`.gitignore`対象化
  しGit管理から外し、`.claude/hooks/session-start.sh`（SessionStart hook）がセッション開始の
  たびに`extract-frontmatter.sh`を非侵襲的（fail-open）に再生成する（詳細:
  [0025-frontmatterのindex.jsonlをGit管理から外しSessionStart-hookで生成する.md](../ddr/0025-frontmatterのindex.jsonlをGit管理から外しSessionStart-hookで生成する.md)）。
  Git管理下でなくなったため「手動再生成の流し忘れによる追加コミット」という問題自体が構造的に
  発生しなくなっている。
- **`yq`の動作検証は未実施**: 開発機に`yq`がインストールされていないため、`yq`優先パスの実機動作
  確認は行えていない（フォールバック経路のみ動作確認済み）。`yq`をインストールした環境での
  動作確認は今後の課題。
- **git bash（MSYS）以外での動作は未検証**: `resolve_repo_root`の`cd`によるパス表記統一は
  git bash（Windows）特有の問題への対処であり、WSL/Linux実機での動作確認は行っていない
  （[shell-scripts.md](shell-scripts.md)の未決定事項と同様の制約）。なお、issue #11で導入した
  高速化はbash 5.x の組み込み機能（`printf '%(...)T'`・パラメータ展開・連想配列）に依存する。
- **（解消）対象を絞った個別実行が、スコープ外のディレクトリの`index.jsonl`に影響する**:
  issue #43対応時に「`extract-frontmatter.sh .claude/rules`のようにディレクトリを絞って実行した
  直後、スコープ外の`index.jsonl`まで変更され、ルート`index.jsonl`に重複行が生じる」と報告されて
  いたが、issue #11で改めて検証したところ**改修前・改修後のいずれでも再現しなかった**。
  - 改修前に`.claude/rules`を指定して実行した際に生じた差分の内訳は、**「`mtime`の更新2件」と
    「削除済みファイルの陳腐化エントリの除去1件」**であり、スコープ外への影響ではなかった。
    `mtime`はgitのcheckout/mergeでも更新されるため、ブランチ操作だけで差分が出る。
  - 全`index.jsonl`を調べても`concept_id`の重複行は0件だった。
  - 報告された現象は、この2種類の差分をスコープ外への影響と誤認したものと考えられる。改修後は
    「内容が同じなら書き換えない」（`unchanged:`）ため、この種の誤認自体が起きにくくなっている。
