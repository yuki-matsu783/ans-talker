---
name: issue-create
description: issueをAIエージェントが起票（作成）したいときに使う。issue-mr-flowのflow-id 1-1（人間による起票）をAIが代行する手段。ユーザーからの依頼内容をもとに目的・現状・期待する動作・受け入れ条件の4見出しを組み立て、ユーザーの確認を得たうえで.claude/scripts/src/create-issue.shを呼び出しGitHub/GitLab上にissueを作成する。issueをUIを使わずAIから起票したい場合に使う。
title: issue起票（AI代行）
type: skill
tags: [issue, automation, github, gitlab]
keywords: [issue作成, create-issue.sh, issue分割, 並列列挙, 目的, 現状, 期待する動作, 受け入れ条件, テンプレート, issue-mr-flow, 重複チェック, 類似issue, search_issues, AskUserQuestion, 最終確認, 着手確認, post-issue-create-notice]
---

# issue起票（AI代行）

`.claude/skills/issue-mr-flow/SKILL.md`（唯一の実装フロー定義）のflow-id 1-1「issueを起票する」は
本来人間の担当だが、本スキルはAIエージェントがそれを代行するための手順を定義する。issue取得後の
ブランチ・Draft MR作成（flow-id 1-2〜1-3）は対象外であり、そこから先は通常どおり
`/issue-mr-flow start <issue番号>` を使う。

## 実行フロー

各手順の見出しには番号と内容名を併記する。後から手順を追加・変更する際に、番号ではなく
名前で位置を指せるようにするため。

1. **5項目を組み立てる** — ユーザーの依頼内容から、issueに必要な5項目（タイトル・目的・現状・
   期待する動作・受け入れ条件）を埋められるか確認する。
   `.github/ISSUE_TEMPLATE/task.md` / `.gitlab/issue_templates/Default.md`
   と同じ4見出し構成に対応する。情報が不足している場合は、AskUserQuestionまたは通常のチャットで
   ユーザーに質問して補う。**依頼内容から読み取れない項目を勝手に創作しない。**

2. **issueが大きすぎないかを確認する**（issue #64） — 組み立てた「期待する動作」「受け入れ条件」
   が**同型の成果物の並列列挙**（画面・機能／APIエンドポイント／CLIサブコマンド等が「AとBとCを
   作る」と並ぶ形）になっていないかを見る。該当し、かつ分割しない条件（横断的変更／分割コストが
   本体を上回る／共通部分の先行実装が必要）にも当たらない場合は、`AskUserQuestion` で
   「1件のissueとして起票する」「成果物ごとに分けて起票する」を確認する。分けて起票する場合は、
   **親issue（子issueをチェックリストで束ねる）→ 子issue** の順に作成する。**判定基準の詳細は
   ここに再掲せず**、`.claude/skills/issue-mr-flow/SKILL.md` の
   「issueが大きすぎる場合の分割提案」を参照する（二重管理を避けるため）。
   分割の要否が決まってから手順3の重複チェックへ進む（分割後の各issueについて検索するため）。

3. **類似・重複issueをチェックする**（issue #68） — 最終確認へ進む前に、組み立てた内容と近い
   既存issueが無いかを検索して提示する。人間がUIから起票する場合は入力中に類似issueが
   サジェストされるが、`create-issue.sh` 経由のAI代行ではそれが働かないため、この手順で補う。

   1. **検索キーワードを3〜5個選ぶ。** 手順1で組み立てたタイトルと目的から、AIエージェント自身が
      選ぶ（`Provider.sh` 側にキーワード抽出は実装されていない。理由:
      `.claude/docs/ddr/0033-issue起票前の重複チェックは検索をProvider層へ置きキーワード抽出はAIに委ねる.md`）。
      粒度の指針:
      - **選ぶ**: そのissue固有の語（機能名・関数名・スクリプト名・ファイル名・固有名詞）。
        例: `search_issues` `create-issue.sh` `frontmatter` `Draft PR`
      - **選ばない**: 「追加」「修正」「対応」「改善」のような汎用語、`issue` `ワークフロー`
        `SKILL.md` のようにこのリポジトリのほぼ全issueに現れる語。ヒットが多すぎて
        重複の判定に使えないため。
      - 語は短く区切る。長い複合句（「issue起票時の類似issueチェック」）は一致しにくいので、
        「類似issue」「重複」のように分ける。
   2. **検索する。**

      ```bash
      source .claude/scripts/src/vcs/Provider.sh
      search_issues "<キーワード1>" "<キーワード2>" "<キーワード3>"
      ```

      `[{number, title, state, url}]` のJSON配列が返る。**closedのissueも含まれる**
      （過去に見送られた提案の再提出を検知するため）。キーワードごとに1回ずつ検索した結果が
      統合されており、上限は5キーワードである。

      **`gh`/`glab` CLIが無い実行環境では**（`get_vcs_access_mode` が `mcp` を返す場合）、
      `mcp__github__search_issues`（`query`, `owner`, `repo`）に読み替える。このMCPツールは
      自然言語のセマンティック検索で既に `is:issue` にスコープされているため、CLI版のように
      キーワードごとに呼び分けず、1回の `query` に複数キーワードを平文で並べてよい。
      `owner`/`repo` は `get_repo_slug | jq -r '.owner, .repo'` で得る。
      WebFetchツール・curlへはフォールバックしない（DDR 0020, DDR 0027）。
   3. **結果を提示する。** 候補が1件以上あれば「番号・状態・タイトル」の一覧（URL付き）で示し、
      それぞれが今回の依頼とどう近いのか・どこが違うのかを一言添える。
      候補が0件のときは「**類似issueは見つかりませんでした**」と明示したうえで手順4へ進む
      （検索したこと自体を黙らせない）。
   4. **判断はユーザーに委ねる。** 候補があった場合は `AskUserQuestion` で次を選んでもらう。
      - `新規にissueを起票する (Recommended)` — 候補はあるが別の関心事だと判断した場合
      - `既存issue #<番号> へコメントを追記する` — 候補ごとに選択肢を作ってよい。選ばれた場合、
        本スキルは起票を行わず、追記内容をまとめてユーザーに渡す（コメント投稿自体は本スキルの
        対象外）
      - `起票をやめる`

      **AIは候補を提示するに留め、重複と断定して勝手に起票を中止しない**（似ているだけで、
      粒度・観点が異なる別issueであることは珍しくないため）。

4. **ユーザーへ最終確認する** — 組み立てたタイトルと4項目の内容を、**通常のメッセージとして
   全文提示する**。そのうえで `AskUserQuestion` で作成可否を確認する（GitHub/GitLab上に公開される
   操作のため、他のissue-mr-flowサブコマンド同様、明示的な合図を待ってから実行する）。選択肢は
   次の方針で組み立てる。
   - `この内容で作成する (Recommended)`
   - `内容を修正する`（選択された場合、`AskUserQuestion` は選択式が主眼のため、続けて通常の
     プロンプトで修正したい点をユーザーに尋ね、手順1へ戻る）
   - `作成しない`（起票を中止し、本スキルを終了する）

   **issue本文は長く `AskUserQuestion` の選択肢・説明文には収まらないため、内容の提示は
   通常のメッセージで行い、`AskUserQuestion` は可否の選択だけに使う。**

5. **issueを作成する** — 承認を得たら、以下の形で `.claude/scripts/src/create-issue.sh` を実行する。

   ```bash
   .claude/scripts/src/create-issue.sh \
     --title "<タイトル>" \
     --purpose "<目的>" \
     --current "<現状>" \
     --expected "<期待する動作>" \
     --acceptance "<受け入れ条件>"
   ```

   標準出力に作成されたissueのJSON（`number`/`title`/`body`/`url`/`slug`）が返る。

   **`gh`/`glab` CLIが無い実行環境（Claude Code on the webのリモート実行環境等）では、
   `create-issue.sh` は内部の `new_issue` が失敗するため使えない**（issue #34）。
   `source .claude/scripts/src/vcs/Provider.sh && get_vcs_access_mode` が `mcp` を返す場合は、
   次のように読み替える（GitHubのみ。GitLabは対象外。詳細:
   `.claude/skills/issue-mr-flow/SKILL.md`「`gh`/`glab` CLI不在時のMCPフォールバック」節）。

   1. `get_repo_slug | jq -r '.owner, .repo'` で `owner` / `repo` を得る。
   2. 本文は `build_issue_body "<目的>" "<現状>" "<期待する動作>" "<受け入れ条件>"` で組み立てる
      （4見出しの構成をスクリプトと揃えるため。この関数はCLIに依存しない）。
   3. `mcp__github__issue_write`（`method="create"`, `owner`, `repo`, `title`, `body`）で作成する。
   4. WebFetchツール・curlへはフォールバックしない（DDR 0020, DDR 0027）。

6. **結果を提示する** — 結果（issue番号・URL）をユーザーに提示する。**そのうえで、着手する際は
   新しいセッションで `/issue-mr-flow start <issue番号>` を実行することを勧めるに留める。**
   起票したセッションでそのまま作業を続けると、進行中の別issueのブランチ・MRと作業コンテキストが
   混ざり、1つのセッション・1つのMRに複数issueの変更が入りかねないため。**AIから着手を持ちかけず、
   着手するのはユーザーからの明示的な指示があったときのみとする。**

   **`HANDOFF.md` の更新は行わない。** `HANDOFF.md` はブランチ単位の引継ぎメモであり、本スキルの
   時点ではまだissueに対応するブランチが存在しない。更新は `/issue-mr-flow start` 以降
   （flow-id 1-6）の担当である。

   この手順は `.claude/hooks/post-issue-create-notice.sh`（PostToolUse hook）でも補強されている
   （issue #39）。issueの起票（`create-issue.sh` の実行、またはMCP経路の
   `mcp__github__issue_write` の `method="create"`）を検知すると、上記と同じ内容の注意が
   コンテキストへ注入される。**hookは多重防御であり、注入が無かったことは着手してよい根拠に
   ならない**（判断の根拠は常に本スキルと `issue-mr-flow` 側の記載である）。

## してはいけないこと

- ユーザーの明示的な確認なしに、いきなり `create-issue.sh` を実行しない。
- 4見出しの内容を、ユーザーの依頼から読み取れる範囲を超えて創作しない。
- ユーザーの決定を待たずに、issueを分割して子issueを起票しない（分割は提案までがAIの役割）。
- **類似issueが見つかったことだけを根拠に、ユーザーの判断を待たず起票を中止しない**（issue #68）。
  重複かどうかを決めるのは人間であり、AIは候補の提示までを担当する。
- **手順3（類似・重複issueのチェック）を省略して最終確認へ進まない。** 検索が0件だった場合も、
  その事実を明示する。
- **ユーザーの明示的な指示なしに、同一セッションで `/issue-mr-flow start` へ進まない**（issue #59。
  起票と実装が同じセッションに同居すると、1つのMRに複数issueの作業が混ざるため）。
- **起票したissueに着手するかどうかの確認そのものを省略しない**（issue #39）。「起票の流れで
  そのまま着手する」「ユーザーが起票を依頼した時点で着手も依頼したものとみなす」といった解釈は
  してはいけない。**どのissueにいつ着手するかを決めるのは人間である。** 起票直後のAIからの
  持ちかけ（「続けて着手しますか？」）も行わず、手順6の案内に留める。
  実際にissue #38の起票直後、AIエージェントが確認を挟まないまま `start 38` へ進み、issue取得・
  既存ブランチ確認まで実行した事故がある（ユーザーの中断により、ブランチ・Draft MR作成の
  手前で止まった）。
- 本スキルの実行結果として `HANDOFF.md` を更新しない（更新はflow-id 1-6の担当）。
