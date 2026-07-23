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
  selftest/*.exit<0|2>.json        L2 ガードの契約検証 fixture（外部産パックでは必須。後述）
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

## pack spec v1 — 外部産パックの取り込み（`loop harness apply <dir>`）

パック形式はエンジン同梱専用ではなく**交換形式**でもある。他所（他リポジトリ、
`loop-pack-author` スキルによる書き起こし等）で作ったパックは、**ディレクトリパス**で
そのまま取り込める（引数に `/` を含めばパスと解釈、パック id はディレクトリ名）:

```bash
loop harness apply /path/to/my-pack
```

構造・シームは同梱パックと完全に同一。外部産にだけ追加で要求されるのは:

1. **frontmatter 契約（必須）**: `enforces:` と `when-to-remove:` が無ければ取り込み拒否。
   推奨: `origin:`（生成元。パックはコピーなので「更新は元で行い、再 apply で伝播」を成立
   させる鮮度トレーサビリティ）と `requires:`（外部ランタイム依存の宣言。稼働コンテナ、
   ツールパス等）。
2. **selftest（L2 ガードを含むパックは必須）**: `selftest/<guard名>.<説明>.exit<0|2>.json`
   — PreToolUse stdin にそのまま流す生 JSON fixture。fixture 内のパスは `/wt` 配下を使い、
   実行時は `HARNESS_WORKTREE=/wt` が与えられる。apply は**何かをインストールする前に**
   ガード+同梱 config 既定値をステージング（installed と同じ `worker-harness.d/` +
   `../gate.d/` レイアウト）して全ケースを実行し、1 つでも期待 exit と違えば取り込み中止。
   エンジン同梱パックのガードは tests-toolkit が固定しているが、外部産にはそれが無い —
   selftest はその代替であり、契約（stdin JSON → exit 0/2）を満たさない実行コードを
   フック/ゲートに入れないための検問。

### gate.d チェックの exit code 契約

チェックの失敗は **exit 1（または 10 以上）** を使うこと。**3 / 4 / 6 は gate.sh の予約値**
（3=マージ衝突、4=protected path 違反、6=test-gaming）で、チェックがこれらを返すと運用者と
エスカレーションパケットが失敗理由を誤読する。

### 外部ツールを包むときの規約

- **ツール本体はパックに入れない**。lint ツール等の実体は元リポジトリに置いたまま、パックは
  薄いラッパー（gate.d チェック + 場所を指す `config/*.env`）だけを運ぶ。鮮度の腐るコピーを
  作らない（設計 SSOT 直読と同じ原則）。
- **SKIP を緑にしない**。外部ツールの「検査不能」（前提コンテナ停止、ツール未導入等）は
  ラッパーが **fail with message** に写像する。advisory に落とすのは env での明示のみ
  （`20-no-e2e.sh` の「未設定なら advisory pass + 明示メッセージ」が既存の様式）。
- baseline・ルール自体のユニットテストはツール側の責務（パックは関知しない）。
