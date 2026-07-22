---
enforces: AIF 準拠のイベントオントロジー（memory/ontology/）— 人手維持ゼロ、ループイベントからの自動追記のみ
when-to-remove: 効果測定型。数サイクル回して計画役が digest を実際に参照している形跡（PLAN_USAGE との比較、再発 CA の減少）が無ければ ONTOLOGY_ENABLED=0 で撤去する
---
# ontology-aif — プロジェクト知識の論証グラフ（AIF 準拠・イベント駆動）

AIF（Argument Interchange Format）の上位オントロジー — I-node（情報）と S-node
（RA=推論 / CA=対立 / PA=選好）— を骨格に、ループの知識をグラフとして蓄積する。

**設計原則: 人手（LLM の手も）で維持させない。** 手維持の知識構造は腐り、腐った知識は
劣化した検証器と同種の害を生む（Anthropic が vector RAG を撤去し grep 探索に置換した事例が
傍証）。よって:

- **CA / PA ノードはホストが機械追記する**（gate FAIL・codex 懸念 → CA、land・handoff → PA。
  lib.sh の `ontology_event`、常に rc 0 の best-effort 契約）。
- **I-node は既存の wiki 契約に相乗り**: ワーカーが DONE 時に更新する `wiki/modules/<slice>.md`
  が各モジュールの I-node に相当する。新しい書き作業は増やさない。
- 計画役は `memory/ontology/digest.md`（land ごとに自動再生成）だけを読む。未解決の CA
  （その target への最後の PA より新しい対立）が「再計画してはいけない地雷」のリスト。
- 上位オントロジー（ノード型とエッジ制約）は固定で、`control/ontology-check.sh` が機械検証
  する。プロジェクト固有のスキーム語彙（forms 層）は `memory/ontology/forms.md` に追記する。
