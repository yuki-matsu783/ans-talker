---
title: "0007. Claude Code hookの起動コマンドはPATH解決方式（`\"bash\"`）を採用し、フルパス直書きは採用しない"
type: ddr
description: Claude Code hookの起動コマンドをPATH解決方式（bash）へ変更した経緯を記録したDDR
tags: [hook, bash, ddr]
keywords: [path解決, wslスタブ, system32, システム環境変数, settings-json]
---

# 0007. Claude Code hookの起動コマンドはPATH解決方式（`"bash"`）を採用し、フルパス直書きは採用しない

## 背景

issue #6でリポジトリ内の開発補助スクリプトを全てPowerShellからbashへ移行するにあたり、
`.claude/settings.json`のhook `command`（従来は`powershell.exe`）もbashへ切り替える必要があった。

最初はgit bash本体のフルパス（`C:\Program Files\Git\bin\bash.exe`）を直書きする実装で進めたが、
PR #18のレビューで「bashでパスが通っている前提でここは記載して良い。もしパスが通ってない場合は
ユーザにbashのパスを通す手順を案内すること」という指摘を受けた。

## 検討した案

1. **git bash本体のフルパスを`command`に直書きする（最初の実装）**: 単一開発者運用のこのマシンでは
   確実に動作するが、他環境（Git for Windowsのインストール先が異なる、別の開発者のマシン等）への
   移植性が無い。レビューで明確に却下された。
2. **`"command": "bash"`とし、PATH解決に委ねる（レビューで最初に提案された案）**: 移植性は高いが、
   「エラーになったらパスを通す手順を案内する」という前提そのものが成り立たないことが実機検証で
   判明した（下記「わかったこと」参照）。
3. **`"command": "bash"`＋ユーザーへPATH設定手順を案内（採用案）**: 案2の実装に、
   「WSLのbash.exeスタブが優先されて黙って誤動作する」という実際の失敗モードに即したPATH設定手順
   （システム環境変数への追加）をあわせて案内する。

## わかったこと（案2だけでは不十分だった理由）

このマシンで`"command": "bash"`を実機検証したところ、Windowsの`PATH`（システム環境変数）が
`C:\Windows\System32`（`bash.exe`というWSL起動用スタブが存在する）を`C:\Program Files\Git\cmd`より
先に列挙しており、しかもGit for Windowsのインストーラは既定で`Git\cmd`（`git.exe`用）のみを`PATH`に
追加し、`bash.exe`のある`Git\bin`は追加しないことが判明した。そのため素の`"bash"`は**エラーになら
ずWSL側のbash.exeスタブへ黙って解決されてしまう**（`where.exe bash`で確認）。WSL内では
`${CLAUDE_PROJECT_DIR}`がWindows形式パスのままのため解決できず、しかもhookは例外を握りつぶす
設計のため、エラーメッセージも出さずにhookが黙って動作しなくなる。「エラーになったら案内する」
という当初の前提が成り立たないことをユーザーに報告し、対応方針を確認した。

さらに、PATH設定はユーザー環境変数の`Path`に追加するだけでは効果が無く、**システム環境変数**
（`Machine`スコープ）の`Path`でないと効かないこともユーザーの実機検証で判明した
（Windowsの有効PATHはシステム環境変数のPathが先に連結されるため、ユーザー環境変数側に何を積んでも
`C:\Windows\System32`より後になる）。

## 決定

**`.claude/settings.json`のhook `command`は`"bash"`のみとする（フルパス直書きはしない）。**
その代わり、開発機ごとに以下のセットアップを一度だけ行う必要があることをドキュメント化する。

- **システム環境変数**（`Machine`スコープ、ユーザー環境変数では不可）の`Path`に、git bashの
  `bin`フォルダ（例: `C:\Program Files\Git\bin`）を`C:\Windows\System32`より前に来る位置で追加する。
- 設定方法はPowerShell（`[Environment]::SetEnvironmentVariable`）のみを案内する。`setx`は
  システムPATHが1024文字を超えると値を切り詰めて破壊する既知の危険があり、システムPATHは他ソフトの
  追加で既に長くなっていることが多いため採用しなかった。

具体的な手順は [dev-tools/docs/spec/shell-scripts.md](../spec/shell-scripts.md)
「Claude Code hookの起動コマンド」節に記載する。

この対処はリポジトリ側のファイルには残らないマシンごとのセットアップであり、新しい開発機で
このリポジトリを使い始める際は毎回必要になる（`shell-scripts.md`の未決定事項に記載）。

このマシンでは対処を適用し、`where.exe bash`がgit bash優先で解決されること、SessionStart hookが
実セッションで正常にコンテキストを注入することを実機確認済み。
