---
title: "0018. .gemini/settings.jsonへのhooks追加は、レビューで提示されたスニペットのhooksセクションのみ採用する"
type: ddr
description: post-push-save-logs.shのGemini CLI対応（issue #3）でのPRレビューコメントに含まれていた.gemini/settings.jsonのフルスニペットのうち、既存のgeneral.plan.directoryと衝突しうるpermissions/plansDirectory部分を採用せず、hooksセクションのみをマージした経緯を記録したDDR
tags: [gemini, settings, hooks, ddr]
keywords: [general.plan.directory, permissions, plansDirectory, レビュー提示スニペット, issue-3]
---

# 0018. .gemini/settings.jsonへのhooks追加は、レビューで提示されたスニペットのhooksセクションのみ採用する

## 背景

issue #3（post-push-save-logs.shのGemini CLI/Claude Code自動判定化）のPR #5レビューで、
リポジトリオーナーから`.gemini/settings.json`の完成形として、以下のようなスニペットが
コメントで提示された。

```json
{
  "permissions": {
    "defaultMode": "plan"
  },
  "plansDirectory": "./plans",
  "hooks": {
    "SessionStart": [ ... ],
    "BeforeTool": [ ... ],
    "AfterTool": [ ... ]
  }
}
```

このスニペットの`hooks`セクション自体は、Gemini CLI公式ドキュメント
（[Hooks reference](https://geminicli.com/docs/hooks/reference/)）で確認できるスキーマと整合して
おり、そのまま採用できる内容だった。一方、冒頭の`"permissions": {"defaultMode": "plan"},
"plansDirectory": "./plans"`という部分は、既存の`.gemini/settings.json`（`"general": {"plan":
{"directory": "./plans"}}`）とはキー構造が異なり、これは実は**Claude Code側の`.claude/settings.json`
が使うキー形式**である（`.claude/settings.json`は`permissions.defaultMode`・`plansDirectory`を
トップレベルに持つ）。

## 検討した案

1. **スニペットを丸ごと採用する**: レビューコメントの内容を疑わず、提示された通りに
   `.gemini/settings.json`を丸ごと置き換える。シンプルだが、`permissions.defaultMode`/
   `plansDirectory`というキーがGemini CLI側で実際に有効かどうかは未検証であり、もし
   Gemini CLIがこれらのキーを認識しない（無視する、あるいはエラーになる）場合、既存の
   動いている`general.plan.directory`設定を壊し、Gemini CLIのPlanモード関連設定が
   意図せず失われるリスクがある。
2. **`hooks`セクションのみ採用し、既存の`general.plan.directory`は維持する（採用案）**:
   レビューコメントの主目的（hookの登録方法を示すこと）に沿って`hooks`セクションのみを
   マージし、それ以外の既存キーには触れない。
3. **スニペット全体をそのまま採用しつつ、`general.plan.directory`も残し両方書く**:
   キーが重複しても実害はないだろうという判断で両方残す。ただし、片方が実際には無効な
   デッドコードとして残り続け、将来の読み手を混乱させる（どちらが有効な設定か一見して
   分からない）。

## 決定

**案2を採用する。** `.gemini/settings.json`は既存の`general.plan.directory`をそのまま維持し、
`hooks`キー（`SessionStart`/`BeforeTool`/`AfterTool`）のみをレビューコメントの内容通りに
新規追加した。`permissions`/`plansDirectory`というキー形式がGemini CLI側で有効かどうかは
本タスクのスコープ外として検証していない（`.claude/docs/spec/session-log-hooks.md`の
「未決定事項・懸念点」に記録）。今後Gemini CLI側のPlanモード関連設定を見直す場合は、
別途この点を検証したうえで判断する。
