---
title: "0017. .gemini/配下のリンク（docs/hooks/rules/scripts/skills）はGit管理下に置かず、セットアップスクリプトでローカル生成する"
type: ddr
description: .gemini/配下を.claude/へのシンボリックリンクとして設計した際、Windows環境でNTFSジャンクションへフォールバックした結果Gitがリンクとして認識できず中身を複製してしまうことが判明し、Git管理下から外してセットアップスクリプトで生成する方式へ変更した経緯を記録したDDR
tags: [gemini, symlink, junction, git, ddr]
keywords: [ntfsジャンクション, シンボリックリンク, 開発者モード, git-status, 複製, セットアップスクリプト]
---

# 0017. .gemini/配下のリンク（docs/hooks/rules/scripts/skills）はGit管理下に置かず、セットアップスクリプトでローカル生成する

## 背景

`.claude/rules/directory-structure.md`が定める通り、`.gemini/`は`settings.json`以外
（`docs/`・`hooks/`・`rules/`・`scripts/`・`skills/`）を`.claude/`配下の同名ディレクトリへの
シンボリックリンクとする設計だった（Gemini CLIとClaude Code間でルール・スキル・スクリプトの
内容を二重管理しないため）。

このマシンで`New-Item -ItemType SymbolicLink`を試みたところ失敗した。Windowsで本物のシンボリック
リンクを作成するには管理者権限または開発者モード（設定 → プライバシーとセキュリティ →
開発者向け → 開発者モード）が必要で、このセッションにはどちらも無かった。そのため代替として
`New-Item -ItemType Junction`（NTFSジャンクション）で作成した。ディレクトリに対しては透過的な
リダイレクトとして動作上ほぼ同等に見えたが、Git管理下に置いた場合の挙動は未検証のまま運用していた。

## わかったこと（実機検証）

`.gemini/docs`（`.claude/docs`へのNTFSジャンクション）に対して`fsutil reparsepoint query`を
実行したところ、reparse pointタグは`Mount Point`（`0xa0000003`）であり、Gitが特別扱いする
シンボリックリンクのタグ（`IO_REPARSE_TAG_SYMLINK`）とは異なることを確認した。

この状態で`git status --short .gemini`を実行すると、`.gemini/docs`という1エントリのリンクとしては
扱われず、**ジャンクションの先にある実ファイルすべてが`.gemini/docs/...`という個別の新規ファイルと
してそのまま列挙される**ことを確認した（`.claude/docs`配下の全ファイルに対応する56件の`A`エントリ。
`.gemini/hooks`・`.gemini/rules`・`.gemini/scripts`・`.gemini/skills`でも同様）。Gitはジャンクションを
リンクとして認識できず、Windows側が未知のreparse pointを透過的に辿ってしまうため、Gitのディレクトリ
走査がジャンクションの中へそのまま入り込んでしまうことが原因と判断した。

この状態のまま`git add`・コミットすると、`.claude/{docs,hooks,rules,scripts,skills}`の内容が
`.gemini/{docs,hooks,rules,scripts,skills}`として丸ごと二重にコミットされ、「`.gemini`は`.claude`
への参照のみで実体を持たない」という設計そのものが崩れる。以後は`.claude`側だけを編集すると
`.gemini`側の内容が古いまま残り続け、乖離していく。

## 検討した案

1. **開発者モードを有効化し、本物のシンボリックリンクとして作り直す**: Gitは`120000`モード
   （リンク先パス文字列のみを保持する1件のblob）として扱うため複製は起きない。ただし、他の
   Windows環境でこのリポジトリをcloneする開発者にも同様に開発者モード・管理者権限が必要で、
   無い場合Gitは実リンクの代わりに「リンク先パス文字列が書かれたただのテキストファイル」を
   生成してしまう（中身の複製は起きないが、そのままではリンクとして機能しない）。開発者ごとの
   環境要件が増える。
2. **`.gemini/{docs,hooks,rules,scripts,skills}`を`.gitignore`に加えGit管理外とし、代わりに
   セットアップスクリプトでclone後にローカル生成する（採用案）**: シンボリックリンクが作れる
   環境ではシンボリックリンクを、作れない環境（開発者モード・管理者権限が無いWindows）では
   NTFSジャンクションを、というフォールバックをスクリプト側で自動判定する。Git上には一切
   リンクの実体が残らないため、環境差によらず複製リスクが発生しない。
3. **リンクをやめて実体コピーとして割り切り、同期スクリプトで手動同期する**: シンボリックリンク・
   ジャンクションいずれの制約も受けないが、同期を忘れると`.claude`と`.gemini`の内容が容易に
   乖離する。手動同期の運用負荷・ヒューマンエラーのリスクが増える。

## 決定

**案2を採用する。** `.gemini/docs`・`.gemini/hooks`・`.gemini/rules`・`.gemini/scripts`・
`.gemini/skills`を`.gitignore`に追加してGit管理下から外し、`.gemini/settings.json`のみを
Git管理する。リンクの作成・再作成は新設した`.claude/scripts/src/setup-gemini-links.sh`が担う。

- まず`ln -s`でシンボリックリンク作成を試みる（Linux/macOSでは常に成功する。Windowsで開発者
  モード・管理者権限がある場合も成功する）。
- 失敗した場合、`cmd.exe //c mklink //J`（NTFSジャンクション。ディレクトリのみ対象、管理者権限
  不要）へフォールバックする。
- 既にリンク（またはディレクトリ・ファイル）が存在する場合は何もしない（再実行しても安全）。

この方式では、Windowsで開発者モード・管理者権限の有無によらず、clone直後に1回
`bash .claude/scripts/src/setup-gemini-links.sh`を実行するだけでどちらの環境でも安全に動作し、
かつGitに複製コミットが混入するリスクが構造的に発生しない。

`rm -rf .gemini/docs`のようにジャンクション自体を削除してもリンク先（`.claude/docs`）の実ファイルは
巻き込まれず安全に残ることも、使い捨てディレクトリを使った実機検証で確認済み。
