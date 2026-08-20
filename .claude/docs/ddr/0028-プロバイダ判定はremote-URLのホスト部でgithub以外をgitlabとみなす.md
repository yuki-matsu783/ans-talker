---
title: 0028. プロバイダ判定はremote URLのホスト部でgithub以外をgitlabとみなす
type: ddr
description: self-hosted GitLabを判定できるようにするため、glab由来の情報を使う3案と設定ファイル案を却下し、remote URLのホスト部だけで判定する方式を採用した判断を記録したDDR
tags: [vcs-provider, gitlab, github, ddr]
keywords: [get_provider, provider_from_remote_url, self-hosted, ホスト判定, glab, 認証状態, メモ化, トレードオフ]
---

# 0028. プロバイダ判定はremote URLのホスト部でgithub以外をgitlabとみなす

## 背景

`get_provider`（`.claude/scripts/src/vcs/Provider.sh`）は、`git remote get-url origin` の
**URL文字列全体**への部分一致でプロバイダを判定していた。

```bash
case "$url" in
  *github.com*) printf 'github\n' ;;
  *gitlab*) printf 'gitlab\n' ;;
  *) echo "サポート対象外のリモートです（GitHub/GitLabのみ対応）: $url" >&2; return 1 ;;
esac
```

このためホスト名に `gitlab` を含まないGitLabインスタンス（`git@git.example.co.jp:...`、
`http://localhost:8929/...`）は「サポート対象外のリモートです」として弾かれ、self-hosted GitLabで
本ワークフローを使えなかった（issue #45）。

[0026-空コミットフォールバックはGitHub固有の制約として残す.md](0026-空コミットフォールバックはGitHub固有の制約として残す.md)
の元になったissue #48で、ローカルGitLab CE 18.5.4に対し `Gitlab.sh` の全13関数が動作することは
実機確認済みだった。ただしその検証は `get_provider` に弾かれるため `gitlab_*` を直接呼ぶ形で
迂回しており、**残る障害は判定ロジックだけ**であることが分かっていた。

## 決定

remote URLから**ホスト部を抽出**し、次の順で判定する。

```
*aslead*  → gitlab   （社内GitLabの明示ケース。GitHub判定より先に評価する）
*github*  → github
それ以外  → gitlab
```

ホスト抽出と判定は純粋関数 `provider_from_remote_url` へ切り出し、`get_provider` は
`git remote get-url origin` の結果をこの関数へ渡すだけの薄いラッパーにする
（`tests/test_vcs_provider.sh` から単体テストできるようにするため。issue #48 の
`gitlab_format_discussion_notes` と同じ切り出し方）。

「GitHubでなければGitLab」で十分な理由は、**本ワークフローの対応プロバイダがGitHubとGitLabの
2つに限られる**こと、そして**GitHubはSaaS（`github.com`）・GHEとも慣習的にホスト名へ `github` を
含む**ことである。判別しやすい側を先に確定させ、残りを他方に倒すのが最も単純で、issue #45の
受け入れ条件をすべて満たす。

`aslead` は実際に使う社内GitLabの明示ケースである。既定規則でも同じ結果になるため機能上は冗長だが、
**GitHub判定より前に置く**ことでホスト名に `github` と `aslead` が同時に含まれる場合もGitLabが
優先され、順序自体に意味を持たせている。

### ホスト抽出の順序

パラメータ展開のみで行い、外部コマンド・コマンド置換を使わない。

```
https://user@gitlab.com:8080/foo/b@r.git
  ── "://" 以降 ──▶  user@gitlab.com:8080/foo/b@r.git
  ── "/" 以降を落とす ──▶  user@gitlab.com:8080
  ── "@" まで落とす ──▶  gitlab.com:8080
  ── ":" 以降を落とす ──▶  gitlab.com
```

**パスを先に落としてから認証情報を落とす**のが要点。逆順にすると `${host#*@}` が最短一致で
パス中の `@` にかかり、`b@r.git` の `r.git` をホストとみなしてしまう。scp形式
（`git@github.com:foo/bar.git`）も同じ手順で `github.com` になる。

### 副次的に解消したバグ

判定対象をURL全体からホスト部へ変えたことで、**パスに `github` を含むGitLab URL**の誤判定も
同時に解消した。

```
https://gitlab.com/github-mirror/x.git   旧: github（誤） → 新: gitlab
```

旧実装は `*github.com*` を先に評価していたため、パス部分の一致でGitHubと判定していた。

## 却下した案

判定方式の候補を実測で比較した（git bash / Windows）。

| 候補 | 実測 | 却下理由 |
|---|---|---|
| `glab auth status` で既知ホストを照会 | **14.5秒** | ホストごとにネットワーク接続するため、判定に使える速度ではない。停止中のホストがあると接続タイムアウトぶんさらに延びる |
| `glab config get token --host <host>` | 0.55〜0.9秒 | オフラインで既知/未知を判別できるが、ホスト判定だけで足りるため不要なコスト |
| glabの `config.yml` を直接パース | 読み取り0.1秒 | 配置がOS依存。この環境では `%LOCALAPPDATA%/glab-cli/config.yml` にあり、一般的なドキュメントが示す `~/.config/glab-cli/` は存在しなかった。自前YAMLパースも脆い |
| `.mrworkflow.json` に `provider` キーを追加 | 約190ms／回 | `get_workflow_config` が `git rev-parse` と `jq` を呼ぶ。12箇所のディスパッチすべてで増える |

**上位3案に共通する決定的な欠点は、いずれも「glabに登録済みのホストか」を見るため、
未ログイン状態ではself-hosted GitLabを判定できない**ことである。実測した未認証時の挙動は次のとおり。

| 状況 | メッセージ |
|---|---|
| `glab`: ホスト未登録 | `None of the git remotes configured for this repository point to a known GitLab host` |
| `glab`: ホスト登録済み・トークン無効 | `401 Unauthorized (HTTP 401)` |

「動かすには先にログインが要る」ことと「判定そのものがログインに依存する」ことは別問題である。
採用した方式は `git remote get-url origin` を読むだけで `gh`/`glab` を呼ばないため、
**認証状態に一切依存しない**。

`Provider.sh` 側に `gh`/`glab` の認証状態の事前チェックを足すことも検討したが、採用しなかった。
未認証時は上記のとおりCLI由来のメッセージがそのまま出て次に取るべき操作が分かるうえ、
判定コストをゼロに保つ方針と噛み合わないため。

## 判定コストをゼロに保つ必要があった理由（メモ化できない）

12個のディスパッチャがいずれも次の形で `get_provider` を呼ぶ。

```bash
case "$(get_provider)" in
```

**コマンド置換はサブシェルを作るため、関数内でグローバル変数へ代入してもキャッシュが親に残らない。**
「1回だけ判定して使い回す」には12箇所すべてを `REPLY` 方式（`.claude/rules/shell-script-style.md`
「ホットパスの小さなヘルパー関数は…`REPLY` へ返す」）へ書き換える必要があり、issue #45 の範囲を
超える。したがって「判定に外部コマンドを足すと12箇所すべてで増える」という制約が効き、
**追加forkゼロで済むホスト判定**を選ぶ根拠になった。

## 受け入れたトレードオフ

「`github` を含まなければGitLab」とみなす結果、**GitHub/GitLabのどちらでもないリモート**
（Bitbucket等、あるいはURLのtypo）に対しても `gitlab` を返す。旧実装の
`サポート対象外のリモートです（GitHub/GitLabのみ対応）` という明快なメッセージは出なくなり、
後続の `glab` 側のエラー（`None of the git remotes ... known GitLab host`）に変わる。

対応プロバイダが2つしかない以上、**self-hostedを弾かずに非対応だけを弾く判定は原理的に書けない**
（ホスト名だけでは区別できない）。self-hostedが使えないことの方が実害が大きいため受け入れる。
これはレビューで明示的に合意された（issue #45 / PR #52）。

旧実装のエラー経路そのものは、ホスト名の抽出結果が空になった場合
（`remote URLからホスト名を取得できませんでした`）としてのみ残っている。

## 実機検証

ローカルGitLab CE 18.5.4（Docker、`http://localhost:8929`）の検証用リポジトリで、
**`Provider.sh` の共通インターフェース関数をディスパッチ経由で**呼び、以下が通ることを確認した。
issue #48 では `get_provider` に弾かれるため迂回していた経路である。

`get_provider`（→ `gitlab`）/ `get_repo_url` / `get_issue` / `get_mr_for_branch` /
`get_mr_unresolved_comments` / `add_mr_comment` / `set_mr_description` / `add_mr_thread_reply` /
`get_mr_diff_url` / `get_mr_diff_since_url` / `get_workflow_config` / `get_issue_number_from_branch`

あわせて、このリポジトリ（GitHub）で `get_provider` が従来どおり `github` を返し、
ディスパッチが退行していないことも確認した。単体テストは `passed=26 failures=0`。
