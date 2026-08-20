---
title: PowerShellスクリプト・コマンドの文字コード注意事項
type: rule
description: PowerShellスクリプト・コマンドでの文字コード（ANSI/OEMコードページ）に関する注意事項を定めたルール
tags: [powershell, encoding, rule]
keywords: [文字コード, cp932, utf-8, bom, provider-ps1, コンソール出力, 既定パラメータ, 文字化け]
---

# PowerShellスクリプト・コマンドの文字コード注意事項

**適用範囲**: 本ファイルはPowerShell（`.ps1`・`powershell.exe`経由のコマンド）を直接書く場合にのみ
適用する。issue #6でリポジトリ内の開発補助スクリプトは全てbash（`.sh`）へ移行しており、
2026-08-16時点でリポジトリ内に`.ps1`ファイルは1つも存在しない（bashには本ファイルが扱う
ANSI/OEMコードページの問題自体が発生しない。詳細:
[.claude/docs/spec/shell-scripts.md](../docs/spec/shell-scripts.md)「文字コード」節）。
bashスクリプトの規約は [shell-script-style.md](shell-script-style.md) を参照。
本ファイルは、将来新規に`.ps1`スクリプトを書く必要が生じた場合に備えた注意事項を残すためのもの。

Windows PowerShell 5.1（`powershell.exe`。本プロジェクトの実行環境）は既定で、コンソール入出力・
`Get-Content`/`Set-Content`/`Out-File`等のファイルI/Oを**システムのANSI/OEMコードページ**
（日本語Windowsでは通常cp932）で扱う。UTF-8を前提とする`gh`/`glab` CLIとのやり取りや、日本語を含む
テキストファイルの読み書きでこれを踏まえないと、実機でのみ再現する文字化け・構文エラーが発生する
（issue #5対応時に2種類の実例で確認済み。詳細は
[.claude/docs/spec/issue-mr-workflow.md](../docs/spec/issue-mr-workflow.md)
「セッション開始時の自動コンテキスト注入」節参照）。

## 新規`.ps1`スクリプトを書く場合の注意

- コンソール入出力（`gh`/`glab`等の外部コマンドとのI/O）を保護するには、スクリプト冒頭で
  `[Console]::OutputEncoding` / `[Console]::InputEncoding` をUTF-8へ切り替える。
- ファイル読み書き（`Get-Content`/`Set-Content`/`Add-Content`/`Out-File`）を保護するには、
  `$PSDefaultParameterValues` で既定エンコーディングをUTF-8へ切り替える（ワイルドカード
  `'*:Encoding'`は他コマンドレットの`-Encoding`パラメータ定義と衝突して警告が出るため、
  対象コマンドレットを個別に指定する）。
- `.ps1`ファイル自体は**BOM付きUTF-8で保存する**。BOM無しUTF-8で保存すると、Windows PowerShell 5.1が
  日本語コメント等を正しく解釈できず、離れた箇所で構文エラーになることがある（実例: issue #5対応時、
  hookスクリプトを新規作成した際、BOM無しUTF-8で保存され`[Draft]`のような無関係な箇所でパース
  エラーになった。当時のhookスクリプトは現在はbash化され存在しない）。これはランタイムの設定では
  防げない、ファイル保存時の性質のため、新規`.ps1`作成時は必ずBOM付きUTF-8で保存する。
  **AIエージェント向け注記**: Writeツールで新規`.ps1`を作成した場合は既定でBOM無しになるため、
  作成直後に必ず以下で変換し、構文検証まで行う（issue #15対応でこの手順を怠り、同じ事故を1セッション内で
  3回再発させた実例あり。ルールの存在を知っているだけでは防げず、新規`.ps1`作成のたびに機械的に
  実行することが必要）。

  ```powershell
  $path = "対象ファイルパス"
  $content = [System.IO.File]::ReadAllText($path)
  [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($true)))
  # 構文検証もあわせて行う
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors) | Out-Null
  if ($errors.Count -gt 0) { $errors | Format-List } else { "構文OK" }
  ```
