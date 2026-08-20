---
alwaysApply: true
title: ディレクトリ構成
type: rule
description: リポジトリのディレクトリ構成と配置方針を定めたルール
tags: [directory-structure, rule]
keywords: [ディレクトリ構成, claude, gemini, 配置方針, plans, worklog, mrworkflow, always-apply]
---

# ディレクトリ構成

各ディレクトリの役割説明は [index.md](../../index.md)（Repository Map）を正とする。本ファイルは
ツリー構造・配置ルールを扱う（ディレクトリの役割説明を重複記載しない）。

```
./
├── .claude/
│   ├── docs/                  # issue駆動MRワークフロー機構自体の設計ドキュメント
│   │   ├── README.md         # .claude/docs配下の目次
│   │   ├── spec/              # 機能ごとの正史仕様
│   │   └── ddr/                # 意思決定ログ（DDR）
│   ├── rules/                  # AI向け詳細ルール（コーディング規約・ドキュメント運用等）
│   ├── skills/                 # `/issue-mr-flow`（唯一の実装フロー定義）等のスキル定義
│   ├── agents/                 # サブエージェント定義（issue-mr-flow途中引き継ぎ等）
│   ├── scripts/                # AIエージェントが`.claude/skills/*`経由で能動的に実行するスクリプト一式
│   │   ├── src/
│   │   │   └── vcs/            # GitHub/GitLabの差異を吸収するVCS抽象化層（Provider.sh）
│   │   └── test/               # 副作用の無い純粋ロジックの単体テスト（`test_<対象>.sh`）。
│   │                            #   `passed=N failures=N`を出力し失敗時は終了コード1
│   │                            #   （詳細: `.claude/rules/shell-script-style.md`「テスト」）
│   ├── hooks/                  # SessionStart/PostToolUse等のClaude Code hookスクリプト
│   │   └── lib/                # 複数hookスクリプトで使い回す共通ロジック
│   ├── REVIEW-POINTS.md       # `.claude/`配下に適用するレビュー観点（`type: review-points`）
│   └── settings.json
├── .gemini/                    # Gemini CLI向け設定。settings.jsonのみGit管理。docs/hooks/rules/
│   │                            # scripts/skillsは.claude配下へのローカルリンクで.gitignore対象
│   └── settings.json
├── .github/
│   └── ISSUE_TEMPLATE/          # GitHub用issueテンプレート（目的・現状・期待する動作・受け入れ条件）
├── .gitlab/
│   └── issue_templates/         # GitLab用issueテンプレート（同上）
├── build/                      # ビルド成果物の出力先。`.gitignore`対象でコミットしない（通常は空）
├── plans/                      # 計画ファイル。全体作業計画（planツールが出力する`<自動命名>.md`、
│                                #   issueにつき1つ）と個別作業計画（`【種別】タスク内容.md`、
│                                #   planツールを使わずWrite/Editで作成）の2階層。タスクごとに
│                                #   新規生成しそのままコミットして履歴として残す
│   └── REVIEW-POINTS.md        # `plans/`配下に適用するレビュー観点。**flow-id 5-1で削除しない**
├── worklog/                    # 実装中の詳細な試行錯誤ログ（`日付_<全体計画名>_<個別計画名>_push<N>.md`）
│   └── TEMPLATE.md             # worklog作成時にコピーして使うテンプレート
├── .gitignore
├── .mrworkflow.json            # リポジトリ固有設定（ブランチ命名規則・plans/等の場所）
├── AGENTS.md                   # AIエージェント共通ルール・プロジェクト概要・開発実行方法
├── CLAUDE.md                   # Claude Code固有ルールへのポインタ（AGENTS.mdを@import）
├── DEVELOPERS.md                # 開発者向けドキュメントの入り口
├── GEMINI.md                    # Gemini CLI固有ルールへのポインタ（AGENTS.mdを@import）
├── HANDOFF.md                   # セッション間・作業者間の軽量な引継ぎメモ
├── index.md                     # Repository Map
├── README.md
└── REVIEW-POINTS.md            # リポジトリ全体に適用するレビュー観点
```

`reports/`・`usage/`・`.claude/state/`は、いずれもワークフロー実行中に動的に作成されるディレクトリの
ため、初期スケルトンには含まれない（作成・削除のタイミングは `.claude/rules/docs-workflow.md`・
`.claude/skills/issue-mr-flow/SKILL.md` を参照）。

`reports/` には**mdとhtmlの2種類**を置く。`reports/日付_<全体計画名>_<内容を簡潔に>.md` が調査結果・
作業結果・反映結果の**正文**で（個別計画へ結果を書かないための分離先。issue #87。詳細:
`.claude/skills/issue-mr-flow/SKILL.md`「計画と実施結果の分離」）、
`reports/日付_<全体計画名>_<内容を簡潔に>.html` はその内容を視覚的にまとめた自己完結HTMLである
（`.claude/skills/canvas-report/SKILL.md` 参照）。両者は併存させ、flow-id 5-1でまとめて削除する。

`usage/` は対応工数レポート機能のローカル作業状態で、`.gitignore`対象（`/usage/`）。内訳は
`usage/session-logs/<sessionId>/`（セッションログのミラー）・`usage/state/<branch>.json`（集計状態）・
`usage/state/session-cursors/<sessionId>.json`（処理済み行数カーソル。Claude Code経路のみ）・
`usage/state/gemini-totals/<sessionId>.json`（**Gemini CLI経路の前回累計。ブランチ非依存**。
issue #97。ブランチ別に持つと、同じセッションのままブランチを切り替えたときに蓄積済みの全件が
新ブランチの初回差分として再計上されるため。詳細:
`.claude/docs/ddr/0050-Gemini集計の差分はファイル全体の畳み込みと前回累計の差分で取る.md`）・
`usage/state/push-index.jsonl`（push断面の行範囲。Claude Code経路のみ）。issue #23以前は、これとは別に
`logs/push-<N>/` へpushのたびにセッションログ全文を保存する系統があったが、transcriptが追記専用で
あることを確認したうえで廃止し `usage/` へ一本化した（詳細:
`.claude/docs/ddr/0022-push断面の全文コピーをやめ行番号インデックスで表現する.md`）。

`.claude/state/`は`post-push-compact-prompt.sh`がレビュー依頼メッセージの参照リンク組み立てに使う、
前回push時点のHEAD SHAのローカル作業状態で、`.gitignore`対象（`/.claude/state/`）。責務分離のため
`usage/`とは別ディレクトリにしている（詳細: `.claude/docs/spec/issue-mr-workflow.md`
「/compact実施の呼びかけ」節、`.claude/docs/ddr/0023-レビュー依頼メッセージの参照リンクは前回pushSHAをローカル状態で保持して組み立てる.md`）。

## 配置の指針

- 開発フロー全体（issue起票〜マージ）は `.claude/skills/issue-mr-flow/SKILL.md`
  （唯一の実装フロー定義）に従う。詳細は `AGENTS.md` を参照。
- **AIエージェントが`.claude/skills/*`経由で能動的に実行するスクリプト**は `.claude/scripts/`
  配下に置く。`.claude/scripts/src/` にスクリプト本体、`.claude/scripts/test/` に
  その単体テスト、`.claude/scripts/docs/` ではなく
  `.claude/docs/` に関連ドキュメント（`spec/`・`ddr/`）を置く（このリポジトリは移植元と異なり
  アプリ本体を持たないため、`dev-tools/` 等の人間専用ツール置き場との分離は行っていない。将来
  アプリ本体を追加する場合は、そのアプリ専用の `docs/spec/` `docs/ddr/`（または人間専用ツール用の
  `dev-tools/docs/`）を新設し、`.mrworkflow.json` の `specDirs`/`ddrDirs` に追記することを検討する）。
  Claude Codeのplugin配布は`.claude/`配下一式をパッケージ化する想定のため、AIが実行時に必要とする
  スクリプト・設計書は`.claude/`の外に置かない。
- 各`.claude/skills/<name>/`は`SKILL.md`単体が基本だが、スキルの実行に必須のバンドルリソース
  （テンプレート・補助スクリプト等）がある場合は`.claude/skills/<name>/templates/`のような
  サブディレクトリを追加してよい（実例: `canvas-report/templates/canvas-report.html`）。他に
  `scripts/`・`references/`・`assets/`等、用途に応じた名前を使ってよい。
- `.gemini/` は `settings.json` のみGit管理下に置く。`docs/`・`hooks/`・`rules/`・`scripts/`・
  `skills/` は `.claude/` 配下の同名ディレクトリへのローカルリンク（可能ならシンボリックリンク、
  Windowsで作成できない環境ではNTFSジャンクション）とし、**Git管理下には置かない**
  （`.gitignore`で除外。Gemini CLIとClaude Code間でルール・スキル・スクリプトの内容を二重管理
  しないための仕組みだが、NTFSジャンクションはGitがリンクとして認識できず中身をそのまま複製して
  コミットしてしまうため、リンク自体はGitに載せず各開発者のマシン上でローカルに生成する方針とした。
  詳細: `.claude/docs/ddr/0017-gemini配下はGit管理下に置かずセットアップスクリプトで生成する.md`）。
  リンクの作成・再作成は `bash .claude/scripts/src/setup-gemini-links.sh` を実行する
  （clone直後に1回実行すればよい。既存のリンクがあれば何もしない）。実体は常に `.claude/` 側を編集する。
- `.claude/hooks/` 配下のスクリプトは現在すべてbash（`.sh`）。新規`.ps1`を作成する場合のみ
  **BOM付きUTF-8で保存する**こと（BOM無しだとWindows PowerShell 5.1でパースエラーになる。詳細:
  `.claude/rules/powershell-encoding.md`）。`.sh`はBOM無しUTF-8・LF改行で保存する
  （詳細: `.claude/rules/shell-script-style.md`）。複数hookスクリプトで使い回すロジックは
  `.claude/hooks/lib/` に切り出す。
- 開発補助スクリプト（`.claude/scripts/src/`, `.claude/hooks/`配下のシェルスクリプト等）は
  git bash経由で実行可能な範囲でbash（`.sh`）を使う。bash化できない場合のみPowerShell（`.ps1`）
  とする。bashスクリプトは`jq`（JSON操作）を前提とする。詳細な判断基準・規約は
  `.claude/docs/spec/shell-scripts.md`, `.claude/rules/shell-script-style.md` を参照。
- **レビュー観点表 `REVIEW-POINTS.md` は、観点を適用したいディレクトリの直下に置く**（issue #77）。
  1つの `REVIEW-POINTS.md` は**そのディレクトリ配下すべて（孫以下を含む）**に適用され、収集時は
  対象ファイルのディレクトリからリポジトリルートまで祖先を遡って集めてマージする（浅い→深い）。
  一般的な観点ほど上位へ置き、下位で重複して書かない。現在の配置はルート直下・`.claude/`・
  `plans/`・`reports/` の4つ。収集アルゴリズム・frontmatterの詳細は
  `.claude/docs/spec/adversarial-review.md`「レビュー観点（REVIEW-POINTS.md）」を参照する。
  **`plans/REVIEW-POINTS.md` と `reports/REVIEW-POINTS.md` は、それらのディレクトリを片付ける
  flow-id 5-1でも削除しない**（`.claude/rules/docs-workflow.md` のライフサイクル表が正）。
