---
title: 0057. 削除済み追跡ファイルの除外はextract-frontmatter側で行う
type: ddr
description: cleanup-task.shのインデックス再生成が必ず失敗していた問題に対し、再生成の順序を動かすのではなく、git ls-filesが返す削除済みパスをextract-frontmatter.sh側でスキップする形で解いた経緯を記録したDDR
tags: [extract-frontmatter, cleanup-task, ddr, workflow]
keywords: [git ls-files, 削除済み, ステージ, stat, index.jsonl, cleanup-task, flow-id5-1, スキップ, 再生成, DDR0048]
---

# 0057. 削除済み追跡ファイルの除外はextract-frontmatter側で行う

## 背景

issue #117。`cleanup-task.sh`（flow-id 5-1 の後片付け）は、`plans/` `worklog/` `reports/` を
削除したあとに `extract-frontmatter.sh .` で `index.jsonl` 群を再生成する。しかしこのスクリプトは
**コミットしない**（DDR 0048）ため、再生成の時点で削除はワーキングツリーにしか反映されていない。

`extract-frontmatter.sh` は対象の列挙に `git ls-files --cached --others --exclude-standard` を
使っており（DDR 0016）、`--cached` は**削除済みだがまだステージされていない追跡ファイル**も返す。
実体の無いパスをそのまま `stat` へ渡すため、**追跡ファイルを1件でも削除した時点で必ず失敗する**。
issue #97 の flow-id 5-1 で実際に発生した（削除14件すべてについて `stat: cannot stat`、
`frontmatterIndex.exitCode: 1`）。

問題は「たまに失敗する」ことではなく、**正常系で一度も成功しないステップが仕様として存在し、
その失敗が警告として正常扱いされている**ことだった。本当の異常が同じ警告に埋もれる。

失敗の影響は警告1つでは済んでいなかった。`stat` の一括取得（`xargs -0 stat`）が失敗すると
取得できたmtimeの数がファイル数と合わなくなり、フォールバックの1件ずつ取り直すループが
`set -e` 配下で最初の欠損ファイルに当たって**走査全体を中断**する。結果として、削除とは無関係な
ディレクトリの `index.jsonl` まで再生成されないまま終わっていた（issue #117 対応時に再現して確認）。

## 決定

- **`extract-frontmatter.sh` の列挙段階で、ワーキングツリーに実体が無いパスをスキップする。**
  `git ls-files` の結果を受けるループの中で `[[ -f "$f" ]]` を判定し、偽なら対象から外す。
- **スキップは「取りこぼし」ではなく正しい結果として扱う。** 削除されたファイルはインデックスに
  載せるべきものではないため、該当行は `index.jsonl` から消え、残ったファイルの行は変わらない。
- **ただし件数は必ず可視化する。** 1件以上あれば
  `skipped <N> deleted file(s) not present in the working tree` を標準エラーへ出し、サマリ行へ
  `skipped=<数>` を加える。無言でスキップすると、今度は「消えるはずのないファイルが消えた」異常を
  隠すことになる（issue #66 と同種の症状）。
- **`cleanup-task.sh` の手順・順序は変えない。** 削除 → 再生成 → `HANDOFF.md` リセット の順、および
  コミットしない方針（DDR 0048）はそのまま維持する。
- **判定はbash組み込みで行い、forkを増やさない。** `[[ -f ]]` はサブシェルを起こさないため、
  ファイル数に比例した外部プロセス起動を避ける設計（DDR 0021）を崩さない。

仕様の詳細は
[.claude/docs/spec/extract-frontmatter.md](../spec/extract-frontmatter.md)「削除済みの追跡ファイルの扱い」節を正とする。

## 却下した案

- **再生成を `cleanup-task.sh` から外し、削除をコミットしたあとの手順（flow-id 5-4）へ移す。**
  issue #117 が挙げたもう一方の候補で、`extract-frontmatter.sh` に手を入れずに済む。しかし
  `git ls-files --cached` が削除済みファイルを列挙するのは**このスクリプトに固有の事情ではなく
  gitの一般的な挙動**であり、順序を動かして回避しても、コミット前に `extract-frontmatter.sh` を
  呼ぶ他の経路（SessionStart hook、`search-frontmatter.sh` の自動更新、`resolve-conflict` スキルが
  案内する手動実行）では同じ失敗が残る。むしろSessionStart hookは「ファイルを消した直後の
  セッション開始」という形で日常的にこの状態を踏みうる。**原因のある側で直すほうが、呼び出し元の
  数だけ同じ回避策を書かずに済む。**
  加えてこの案は、後片付けの直後に `index.jsonl` が古いまま残る期間を作る。flow-id 5-1 と 5-4 の
  間で `doc-search` を使うと、削除済みの計画ファイルが検索結果に出る。

- **`git ls-files --cached` をやめ、`--others` のみ、あるいは `find` へ戻す。** 削除済みパスは
  そもそも列挙されなくなる。しかし `--others` だけでは追跡済みファイル（リポジトリ内の
  ほとんどのmarkdown）が丸ごと対象外になり成立しない。`find` へ戻す案は、DDR 0016 が
  `git ls-files` を採用した理由（`.gitignore` 対象ディレクトリの大量ファイルによるタイムアウトと
  `index.jsonl` 破損。issue #43）を再発させる。

- **`stat` の失敗を握りつぶす（`xargs stat` の終了コードを無視し、取得できなかった分を0で埋める）。**
  変更は小さいが、mtimeが0になったファイルはキャッシュ判定が常に外れて毎回再生成される。
  何より、`stat` が失敗する原因は削除済みファイルだけとは限らず（権限・I/Oエラー）、
  区別せずに埋めると本当の異常を隠す。issue #117 が問題視した「失敗が正常扱いされている」状態を
  別の形で作り直すことになる。
