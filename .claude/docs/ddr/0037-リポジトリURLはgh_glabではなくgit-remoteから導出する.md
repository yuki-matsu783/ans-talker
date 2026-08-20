---
title: 0037. リポジトリURLはgh/glabではなくgit remoteから導出する
type: ddr
description: get_repo_urlのプロバイダ依存を解消するにあたり、gh/glabの呼び出しを残す案・両者を突き合わせる案・設定ファイルへ持つ案を却下し、git remote get-url originの正規化だけで導出する方式を採用した判断を記録したDDR
tags: [vcs-provider, url, hook, ddr]
keywords: [get_repo_url, repo_url_from_remote_url, git remote, プロバイダ非依存, insteadOf, カスタムポート, scp形式, プロセス起動, DDR 0023]
---

# 0037. リポジトリURLはgh/glabではなくgit remoteから導出する

## 背景

`get_repo_url`（`.claude/scripts/src/vcs/Provider.sh`）は、`github_get_repo_url`
（`gh repo view --json url`）／`gitlab_get_repo_url`（`glab repo view --output json` の `.web_url`）
へディスパッチするプロバイダ依存関数だった（issue #13フォローアップ）。

実機で両者の戻り値を確認したところ、`git remote get-url origin` の値と `.git` サフィックスの
有無しか違わなかった。

```
git remote get-url origin  → https://github.com/yuki-matsu783/MR-driven-workflow.git
gh repo view --json url    → https://github.com/yuki-matsu783/MR-driven-workflow
```

この関数の主な呼び出し元 `.claude/hooks/post-push-compact-prompt.sh` は**pushのたびに走る**ため、
毎回CLIのプロセス起動（git bashで約95ms/回。`.claude/rules/shell-script-style.md`「外部プロセス
起動のコスト」）とAPI往復のコストを払っていた。加えて `gh`/`glab` が存在しない実行環境
（Claude Code on the web）ではこの経路が動かないため、issue #34では「MCP経路のときだけ
`get_repo_slug` から組み立てる」という**経路ごとの分岐**を入れていた（DDR 0027）。同じ値を返す
2つの実装が経路で切り替わっている状態である。

なお、gitだけで解決できるプロバイダ差分は他に無いことも調査済みである（issue/MR/レビュー
スレッドはgitのデータモデルに存在せずAPI必須、compare URLの `/compare/` vs `/-/compare/` は
Web UIの体系差でgitの管轄外、`get_mr_for_branch` は `refs/pull/*` / `refs/merge-requests/*` から
番号だけは取れるがref名前空間自体が差分として残り `isDraft`/`title`/`url` も取れない）。

## 決定

`get_repo_url` を **`Provider.sh` 側のプロバイダ非依存関数**とし、`git remote get-url origin` の値を
純粋関数 `repo_url_from_remote_url` で正規化して返す。`github_get_repo_url` /
`gitlab_get_repo_url` とそのディスパッチャ、およびissue #34で入れた経路ごとの分岐は削除する。

正規化の規則と `parse_repo_slug` との整合は
[../spec/issue-mr-workflow.md](../spec/issue-mr-workflow.md)「リポジトリURLの導出（issue #44）」節が正。

### DDR 0023 との関係

[0023-レビュー依頼メッセージの参照リンクは前回pushSHAをローカル状態で保持して組み立てる.md](0023-レビュー依頼メッセージの参照リンクは前回pushSHAをローカル状態で保持して組み立てる.md)
が却下したのは「MR/PRの**URL文字列**へ `/files` 等のsuffixを推測で付け足す」案である。これは
「PRのURLに `/files` を足せばFiles changedタブになるはず」という**UIの構造に対する推測**であり、
プロバイダのUI変更で壊れる。

一方、remote URLからの導出は推測ではない。remote URLは「このリポジトリがどこにあるか」を表す
一次情報であり、そこからWeb URLを得る変換は `.git` の除去とscp形式→https変換という**機械的で
可逆な文字列操作**に閉じている。DDR 0023の判断軸（推測を避け正確性を担保する）はそのまま維持
される。当時この案が検討されていなかったのは、`gh`/`glab` が常に存在する前提だったためである。

## 却下した案

### 1. `gh`/`glab` の呼び出しを残し、CLI不在時だけremote由来へフォールバックする（現状維持）

issue #34時点の実装そのもの。**却下理由**: 同じ値を返す実装が2つ並存し続け、プロバイダ依存関数も
減らない。pushのたびのプロセス起動＋API往復も残る。実機で戻り値が一致すると確認できた以上、
分岐を維持する根拠が「CLIの返す値の方が権威がある」という一般論しか残らない。

### 2. remote由来の値を `gh`/`glab` の戻り値と突き合わせ、食い違ったら警告する

**却下理由**: 突き合わせのためにCLI呼び出しが必要になり、削減したかったコストがそのまま残る
（むしろ増える）。食い違いが起きるのは下記のリスクケースだけで、いずれも警告を出せたところで
参照リンクが1本ずれる以上の実害が無く、pushのたびの警告はノイズになる。

### 3. リポジトリURLを `.mrworkflow.json` に設定値として持つ

**却下理由**: DDR 0028で `provider` キーの追加を却下したのと同じ理由。remoteから機械的に導出できる
値を人手の設定に落とすと、fork・リポジトリ移設のたびに更新が必要な二重管理になり、更新漏れが
「間違ったリポジトリへのリンク」という気づきにくい形で表面化する。

### 4. 導出の失敗・ずれを検知して `gh`/`glab` へフォールバックする

**却下理由**: 「ずれている」ことを検知するには結局CLIを呼ぶ必要があり、案2と同じ問題になる。
導出そのものの失敗（ホスト・パスが取れない）は終了コード1で表現し、hook側は従来どおり
失敗を握りつぶす（`( main ) || true`）ため、リモートへの反映がブロックされることはない。

## 受け入れたトレードオフ

正規URLと一致しないケースが原理的に残る。いずれも「参照リンクが1本ずれる／出ない」だけで、
フロー自体は止まらないため、検知機構は設けない（案2・案4のとおり）。

| ケース | 挙動 |
|---|---|
| `insteadOf` によるURL書き換え | `git remote get-url origin` は書き換え**前**の設定値を返すため、`https://…` を `ssh://…` へ書き換える一般的な用法では影響しない。remoteに `gh:owner/repo` のような短縮エイリアスを設定している場合のみ、ホスト名が `gh` になり導出URLが壊れる（非対応） |
| カスタムポート | http/httpsのポートは引き継ぎ、SSHのポートは捨てる。SSHポートとWeb UIポートが別のself-hosted構成では、ポート無しのURLになる（非対応） |
| リポジトリ名変更後の旧remote URL | GitHub/GitLabとも旧URLからリダイレクトするため到達できる。`gh repo view` が新名称を返すのに対し導出は旧名称のURLになる、という違いだけが残る |
| リモート名が `origin` でない | `git remote get-url origin` が失敗し `get_repo_url` も失敗する。本ワークフローは他所（`get_provider` / `get_repo_slug`）でも `origin` 前提のため、新たな制約にはならない |

SSHのポートを捨てるのは、`ssh://host:2222/o/r.git` の `2222` がSSHの待ち受けポートであって
Web UIのポートではないためである。ここを引き継ぐと、ポートを持たないGHE/GitLabのSSH構成で
**必ず**壊れたリンクになる。逆にhttp/httpsのポートはWeb UIのポートそのものなので引き継ぐ。
どちらを既定にしても救えないケースは残るが、前者の方が発生頻度が高い。
