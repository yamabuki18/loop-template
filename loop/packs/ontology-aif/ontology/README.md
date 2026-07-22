# memory/ontology — イベント駆動の論証グラフ（AIF 準拠）

## 正本
`graph.jsonl` — 1 行 1 ノード。**ループイベントからの自動追記のみ**（手編集・LLM 編集は禁止。
鮮度の腐った知識は劣化した検証器と同じ害を生むため、書き手を機械に限定している）。

行の形:
```json
{"ts":"<UTC>","node":"I|RA|CA|PA","scheme":"<forms語彙>","premise":"<根拠側>","target":"<対象側>","note":"<一文>"}
```

## 上位オントロジー（固定 — `loop ontology-check` が機械検証）
| node | AIF 対応 | このループでの意味 | 制約 |
|------|----------|--------------------|------|
| I  | Information node | 命題・事実（モジュールの責務は wiki/modules/ が実体） | note 必須。premise/target を持たない（I→I エッジ禁止） |
| RA | Rule Application | 推論（設計判断の根拠づけ） | premise・target 必須 |
| CA | Conflict Application | 対立（gate FAIL / codex 懸念 / テストゲーミング検出） | premise・target 必須 |
| PA | Preference Application | 選好（land / handoff 承認 / 設計取込） | premise・target 必須 |

## forms 層（プロジェクトで拡張可）
`scheme` の語彙。エンジンが発行する既定: `gate-fail` `codex-concerns` `test-gaming`
`landed` `handoff`。プロジェクト固有のスキームを増やすときは `forms.md` に
定義を書き足す（上位オントロジーの制約は変えられない）。

## 読み方
- 計画役: `digest.md`（land ごとに自動再生成）だけを読む。「未解決の CA」= その target への
  最後の PA より新しい対立 = 再計画で繰り返してはいけない失敗。
- 人間: `graph.jsonl` を jq で。例: `jq 'select(.node=="CA")' graph.jsonl`
