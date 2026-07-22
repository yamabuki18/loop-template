# loop/packs — ハーネス/ゲート拡張パック（`loop harness` が読む）

プロジェクト導入時に**対話（`loop harness`）または非対話（`loop harness apply <pack>`）で
開発方針を決め**、その決定を既存のシームへ「取り込む」ためのパック置き場。パックは新しい
概念ではない — escalation ladder に元からある**ハーネス（L1: skills/・CLAUDE.worker.local.md、
L2: worker-harness.d/）とゲート（L3: gate.d/）の部品の束**であり、手書きで置く拡張と同じ場所に
同じ契約で落ちる。エンジンは編集されない。

## パックの構造
```
<pack>/
  pack.md                          説明。frontmatter に enforces / when-to-remove（必須）
  RULES.snippet.md                 skills/RULES.md へ追記される L1 断片（任意）
  ARCHITECTURE.snippet.md          skills/ARCHITECTURE.md へ追記（任意）
  CLAUDE.worker.local.snippet.md   ワーカー CLAUDE.md オーバーレイへ追記（任意）
  guards/*                         L2 PreToolUse ガード → worker-harness.d/（stdin JSON → exit 0/2）
  check.d/*.sh                     L3 gate チェック → gate.d/（マージ済みツリーで実行）
  config/*                         gate.d/ に置かれる設定テンプレ（no-clobber。ガードとチェックが
                                   同じファイルを読む＝規則の正は 1 箇所）
  ontology/*                       memory/ontology/ の雛形（no-clobber）（任意）
```

## when-to-remove（必須メタデータ）
ハーネスの各部品は「モデルが単独でできないこと」への仮定を符号化している。新モデル世代ごとに
その仮定を再検証し、支えになっていない部品は剥がす — ただし**セキュリティ系（敵対的仮定）の
ガードは撤去対象外**。各パックはどちらに属し、いつ再評価すべきかを frontmatter で宣言すること。

## 同梱パック
- `backend-clean-arch` — コア/ポート境界（ヘキサゴナル最小形）の機械検査
- `frontend-humble-object` — E2E スイート新設ブロック + Humble Object 単体テスト方針
- `ontology-aif` — AIF 準拠イベントオントロジー（人手維持ゼロ）
