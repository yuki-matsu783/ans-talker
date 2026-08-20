---
title: 開発補助スクリプトのシェル言語方針
type: spec
description: 開発補助スクリプトをbash/PowerShellのどちらで書くかの判断基準と移行方針の仕様
tags: [bash, powershell, spec]
keywords: [git-bash, jq, powershellからの移行, パス変換, bash化, フック起動]
---

# 開発補助スクリプトのシェル言語方針

## 背景・目的

PowerShellはWSL等の非Windows的なシェル環境から扱いにくいため、git bash経由で同等の
ことが行えるスクリプトはbash化し、行えないものだけPowerShellのまま残す方針とした。

実機で変換可否を検証した結果、リポジトリ内にあった全PowerShellスクリプト（issue-mr-flowの
中核であるVCS抽象化層、ビルドスクリプト、Claude Code hook、結合テストスクリプト）が git bash +
`jq` + 標準的なWindowsコマンド呼び出しの組み合わせで同等の動作を実現できることが分かり、
2026-08-16時点で `.ps1` ファイルはリポジトリ内に1つも残っていない。

## 仕様

### 対象スクリプト一覧（旧ファイル→新ファイル）

| 旧ファイル(`.ps1`) | 新ファイル(`.sh`) | 役割 |
|---|---|---|
| `dev-tools/src/vcs/Provider.ps1` | `.claude/scripts/src/vcs/Provider.sh` | issue-mr-flowの中核。GitHub/GitLab差異吸収 |
| `dev-tools/src/vcs/Github.ps1` | `.claude/scripts/src/vcs/Github.sh` | `gh` CLIラッパー |
| `dev-tools/src/vcs/Gitlab.ps1` | `.claude/scripts/src/vcs/Gitlab.sh` | `glab` CLIラッパー（未検証。GitLab実remoteが無いため） |
| `.claude/hooks/session-start.ps1` | `.claude/hooks/session-start.sh` | SessionStart hook |
| `.claude/hooks/post-push-usage-report.ps1` | `.claude/hooks/post-push-usage-report.sh` | PostToolUse hook（使用量レポート） |
| `.claude/hooks/lib/UsageTracking.ps1` | `.claude/hooks/lib/UsageTracking.sh` | 上記hookの共通集計ロジック |
| `tests/test_external_command_server.ps1` | `tests/test_external_command_server.sh` | 結合スモークテスト |

新規（PowerShell版に対応物が無い）:
- `.claude/scripts/test/test_vcs_provider.sh`（新規作成当時は `tests/test_vcs_provider.sh`。
  issue #63 で移動）: `Provider.sh` の純粋ロジック（`to_slug`, `test_issue_sections`,
  `get_issue_number_from_branch`）に対する単体テスト。受け入れ条件「スクリプトをテストするための
  スクリプトを作成する」に対応。

### 前提（新規追加）

- git bash（Git for Windows付属のMSYS bash。既存の`git`利用が前提のため追加インストール不要）
- `jq`（JSON操作。PowerShellの`ConvertFrom-Json`/`ConvertTo-Json`相当。**新規の外部依存として
  インストールが必要**）
- 既存: `gh`/`glab` CLI（テスト対象アプリ）

### 実行環境の検証状況（開発機で確認済み、2026-08-16）

- git bash: mingw64同梱bash 5.2、`/dev/tcp`（TCPソケット。`/dev/tcp/host/port`構文）対応、
  `ps -W`でWindowsプロセス一覧取得可
- `jq` 1.6
- `gh` CLI

### 設計方針

- **戻り値**: PowerShell版のPSCustomObjectに代えて、JSON文字列をstdoutへ出力する設計に統一した。
  呼び出し側は`jq`でフィールドを取り出す（例: `get_issue 6 | jq -r '.title'`）。JSONのキー名は
  PowerShell版のPascalCase（`Number`/`Title`/...）ではなく、bash/jqのエコシステムに合わせて
  camelCase（`number`/`title`/...）に統一した。
- **関数命名**: PowerShellの`Verb-Noun`規約からbashのsnake_case関数へ移植した
  （例: `Get-Issue`→`get_issue`、`New-IssueBranch`→`new_issue_branch`）。
- **エラー方針**: `set -euo pipefail`をPowerShell版の`$ErrorActionPreference = "Stop"`相当として
  採用する。
- **bashでのtry/catch相当の書き方**: 本体処理を関数化し、コマンド置換`$(func)`または明示的な
  実サブシェル`( func )`の中で呼ぶ。
  - **理由**: bashは`if cmd; then...else...fi`や`cmd1 || cmd2`のような条件式の中では、`set -e`
    による「コマンド失敗時に即座にシェルを終了する」動作が一時停止される仕様がある。この一時停止は
    条件式として評価される間、そこで呼ばれる関数の内部にまで及ぶため、関数呼び出しをそのまま
    条件式に置くと、内部で複数のコマンドが順に実行される場合、途中で失敗があっても最後まで
    実行され続けてしまい、PowerShellのtry/catchのような「最初の失敗で即座に中断」という直感的な
    動作にならない。
  - **対策**: コマンド置換 `$(...)` や `( ... )` は実行時に必ず新しいプロセス（サブシェル）へ
    フォークされる。フォークされたサブシェルの内部では、そのサブシェル自身の視点で見て
    「条件式の中にいる」わけではないため、`set -e`（呼び出し元から継承される）が正しく機能し、
    内部で失敗したコマンドの時点で即座にサブシェルごと終了する。その終了コードは呼び出し元の
    `if`/`||`から正しく検知できる。
  - **採用箇所**: `session-start.sh`（`build_context`関数。成功時はstdout経由でコンテキスト文字列を
    受け取り、失敗時はフォールバックメッセージを出す）、`post-push-usage-report.sh`（`main`関数。
    失敗はすべて握りつぶしgit push自体はブロックしない）。
- **git bashのパス変換**: `/in`のようなDOS形式の単一スラッシュ引数を、Windowsネイティブの
  非MSYS実行ファイル（`tasklist.exe`, `taskkill.exe`等）に渡すと、git bash（MSYS）が
  「POSIXパスらしき文字列」と誤認しWindowsパスへ自動変換してしまう既知の問題がある。先頭を`//`にする（`//in`）と
  MSYSの自動変換対象から外れ、ネイティブ側には`/in`として渡る。`build.sh`の`//in` `//out` `//base`
  `//icon`、`test_external_command_server.sh`の`tasklist`/`taskkill`の`//FI` `//IM` `//F`が実例。
- **文字コード**: PowerShell版が必要としていたANSI/OEMコードページ対策
  （`[Console]::OutputEncoding`の明示切り替え等。`.claude/rules/powershell-encoding.md`参照）は
  bash版では不要（git bashの標準入出力・パイプ・`jq`/`gh`とのやり取りはコードページの影響を
  受けないため）。ただし`tasklist.exe`のような非MSYSネイティブコマンドの出力はシステムの
  コードページ（cp932）のまま返る（実機確認: 日本語メッセージが文字化けした）。この種のコマンドの
  出力を判定に使う場合は、日本語メッセージの文字列一致を避け、終了コードやASCII文字列
  （イメージ名等）での判定に留める（`test_external_command_server.sh`の`proc_running`参照）。
- **Claude Code hookの起動コマンド**: `.claude/settings.json`のhook `command`は `"bash"` とだけ
  指定する（実行体をフルパスで固定しない。他環境への移植性を優先する方針。issue #6のレビューで
  フルパス直書き案から変更）。ただしこのマシンでは、Windowsの`PATH`（システム環境変数）が
  `C:\Windows\System32`（`bash.exe`というWSL起動用スタブが存在する）を`C:\Program Files\Git\cmd`
  より先に列挙しており、しかもGit for Windowsのインストーラは既定で`Git\cmd`（`git.exe`用）のみを
  `PATH`に追加し、`bash.exe`のある`Git\bin`は追加しない。そのため素の`"bash"`はエラーにならず
  **WSL側のbash.exeスタブへ黙って解決されてしまう**ことを実機確認した（`where.exe bash`で確認。
  WSL内では`${CLAUDE_PROJECT_DIR}`がWindows形式パスのままのため解決できず、hookは例外を
  握りつぶす設計のためエラーも出ずに黙って動作しなくなる）。
  - **対処（PATHへのgit bash追加＋順序調整）**: `C:\Program Files\Git\bin`を、
    `C:\Windows\System32`より**前**に来るよう**システム環境変数**（`Machine`スコープ）の`Path`へ
    追加する。**ユーザー環境変数`Path`に追加するだけでは効果が無い**ことを実機確認済み
    （Windowsの有効PATHは「システム環境変数のPath」を先頭に、その後ろに「ユーザー環境変数のPath」を
    連結して構成されるため、`C:\Windows\System32`のようなシステム環境変数側のエントリは、
    ユーザー環境変数側に何を積んでも常に先に解決されてしまう）。
    設定方法はPowerShellのみを案内する（`setx`はシステムPATHが1024文字を超えると値を切り詰めて
    破壊する既知の危険があり、システムPATHは他ソフトの追加で既に長くなっていることが多いため
    避ける）。管理者権限のPowerShellで実行する:
    ```powershell
    $gitBin = "C:\Program Files\Git\bin"
    $current = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($current -notlike "*$gitBin*") {
      [Environment]::SetEnvironmentVariable("Path", "$gitBin;$current", "Machine")
    }
    ```
    （Git for Windowsの実際のインストール先が異なる場合は`$gitBin`をそちらの`bin`フォルダへ
    書き換える。上記は先頭に追加するため`C:\Windows\System32`より前に来る。）
    実行後、開いているターミナル・Claude Codeセッションを再起動し、`where bash`（PowerShell/cmd上）で
    `C:\Program Files\Git\bin\bash.exe`が最初に出ることを確認する。
  - この対処をしていない環境では、SessionStart/PostToolUseの自動コンテキスト注入・使用量レポート
    投稿がエラーも出さずに動かなくなる（`git`コマンド自体は通常通り動くため気づきにくい）。
- **PowerShell版からの簡略化点**: `ConvertTo-HashtableDeep`（Windows PowerShell 5.1の
  `ConvertFrom-Json`が`-AsHashtable`を持たないための回避策）はjqのネイティブなJSON操作機能により
  不要になったため、bash版（`UsageTracking.sh`）には存在しない。

## 影響範囲

新規:
- `dev-tools/src/vcs/{Provider,Github,Gitlab}.sh`
- `dev-tools/src/build.sh`
- `.claude/hooks/{session-start,post-push-usage-report}.sh`
- `.claude/hooks/lib/UsageTracking.sh`
- `tests/test_external_command_server.sh`
- `tests/test_vcs_provider.sh`
- 本ドキュメント

削除:
- 上記に対応する全`.ps1`ファイル

変更:
- `.claude/settings.json`（hook `command`を`powershell.exe`から`bash`へ。PATH解決に依存するため
  「PATHへのgit bash追加＋順序調整」の実施が別途必要）
- `.claude/skills/issue-mr-flow/SKILL.md`（コード例・関数名の更新、前提に`jq`を追加）
- `dev-tools/docs/spec/issue-mr-workflow.md`（コンポーネント構成・提供関数表・各hookの説明を更新）
- `dev-tools/docs/spec/distribution.md`（`build.ps1`→`build.sh`）
- `tests/README.md`
- `.claude/rules/directory-structure.md`（`.sh`配置ルール・jq前提の追記）
- `.claude/rules/shell-script-style.md`（新規。bashスクリプトの規約）
- `.claude/rules/powershell-encoding.md`（「PowerShellを直接書く場合のみ適用」である旨を明確化）

変更（issue #24 dev-toolsをAI専用/人間専用に分離）:
- `dev-tools/src/vcs/{Provider,Github,Gitlab}.sh`, `create-commit.sh`, `create-issue.sh`,
  `archive-reentrant-plan.sh`, `extract-frontmatter.sh` を `.claude/scripts/src/` へ、本ドキュメント含む
  AI専用spec/ddrを `.claude/scripts/docs/` へ移動（詳細: `.claude/scripts/docs/spec/issue-mr-workflow.md`
  「影響範囲」issue #24エントリ参照）。`dev-tools/src/build.sh`は人間専用のため`dev-tools/`に残した。

## 設定項目

新規のSettings値は不要。

## 未決定事項・懸念点

- **GitLab版の実機動作未検証**: `Gitlab.sh`はPowerShell版`Gitlab.ps1`と同様、このリポジトリの
  実remoteがGitHubのみのため未検証。GitLabリポジトリで実際に使う前に動作確認が必要。
- **hook起動コマンドのPATH依存はマシンごとの手動セットアップが必要**: `"bash"`のみ・PATH解決方式を
  採用した経緯・却下案は
  [dev-tools/docs/ddr/0007-hookのcommandはbashのPATH解決方式へ変更.md](../ddr/0007-hookのcommandはbashのPATH解決方式へ変更.md)
  参照。この対処（システム環境変数`Path`の変更、管理者権限が必要）はリポジトリ側のファイルには
  残らないため、新しい開発機でこのリポジトリを使い始める際は毎回手動セットアップが必要になる
  （自動化・簡略化の余地はあるが本issueのスコープ外）。
- **"PowerShellのまま残すべきスクリプト"の実例が無い**: 本issueの対応で最終的に全PowerShell
  スクリプトがbash化されたため、判断基準（git bashで実行不可能なもの）を実際に適用した例が
  今のところ無い。今後、PowerShell固有機能（COM操作・.NETクラスの直接利用等）に依存する新規
  スクリプトが必要になった場合の判断基準は、その時点で改めて検討する。
- **`jq`のインストール確認手順が無い**: `gh`/`glab`と異なりインストール状況を確認する仕組みが
  スクリプト側に無い。未インストール時は`jq: command not found`のような分かりにくいエラーになる
  （実害は小さいが改善余地がある）。
