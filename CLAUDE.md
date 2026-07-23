# loop-template — 開発ガイド（このリポジトリ自体を改修するときに読む）

自律開発ループのテンプレート（エンジン）。**ホスト側は決定論的な bash のみ**が動き、知能
（計画・実装）は **git worktree 上の使い捨て Claude プロセス**に委譲する設計（v3。多重化は
herdr、秘匿は sops+age、セカンドオピニオンは codex）。運用者向けドキュメントは
`loop/README.md`（日本語）。ここは「エンジンを開発する側」のための地図。

## レイアウト

```
loop/
  bin/loop            薄い CLI ディスパッチャ（init/secrets/update/version + control/*.sh へ転送）
  control/            エンジン本体（全 bash スクリプト + フック）
    lib.sh            共有ライブラリ。全スクリプトが source する。パス解決・secret_exec・
                      herdr helper・codex policy の唯一の起点
    loop.sh           完全自律オーケストレータ（心拍）。watch.sh は半自律版
    supervise.sh      対話監督モード（= loop supervise）: watch ペイン + SUPERVISOR_MODEL の
                      対話 Claude（CLAUDE.supervisor.md + 生成環境情報を CLAUDE.md に注入。
                      supervisor-skills/ を CLAUDE_CONFIG_DIR/skills へ同期）
    supervisor-skills/ 監督セッション専用スキル（test-architecture-design）。planner/worker
                      には非配布 — テスト設計は対話で行い、計画捕捉→handoff でループへ流す
    plan.sh           ヘッドレス計画役 Claude（使い捨て worktree）を回し slices.json を得る
    handoff.sh        plan mode 承認済み計画 → backlog ゴール化（host-harness/harness-plan-capture
                      が ExitPlanMode で計画を memory/plans/latest.md へ捕捉する）
    gate.sh           受け入れゲート（使い捨て detached worktree で試しマージ+チェック）
    second-opinion.sh codex 独立レビュアー（純評価器。policy は呼び出し側と lib.sh）
    secrets.sh        sops+age の秘密管理（init/edit/status/migrate）
    spawn.sh / worker-run.sh   ワーカー worktree + herdr ペイン + 資格情報注入の seam
    harness.sh        `loop harness`: 導入時に方針パックを対話/非対話で既存シームへ取込
                      （L1 snippets / L2 worker-harness.d / L3 gate.d — 新概念は作らない）。
                      外部産パックは apply <dir>（pack spec v1: frontmatter 契約 +
                      L2 ガードの selftest をインストール前に検証。packs/README.md が仕様の正）
    ontology-check.sh AIF イベントオントロジー（memory/ontology/graph.jsonl）の決定論検証
    worker-harness/   ワーカーの Claude Code フック（決定論ガード。settings.template.json）
    host-harness/     任意の対話監督 Claude 用の保険フック
  packs/              ハーネス/ゲート拡張パック（backend-clean-arch / frontend-humble-object /
                      ontology-aif）。各パックは when-to-remove を必ず宣言
  skills/ memory/     プロジェクト知識のテンプレ（VISION/ARCHITECTURE/RULES, backlog/PROGRESS）
  tests-toolkit/      herdr/Docker 不要の回帰テスト（フック契約 + lib 単体 + e2e + shellcheck）
```

## テスト（改修したら必ず回す）

```bash
bash loop/tests-toolkit/run.sh          # 数秒・143 ケース（フック契約 + lib 単体）
bash loop/tests-toolkit/e2e-nocreds.sh  # gate/verify/land/sync の全経路（資格情報不要）
```

フックは「stdin に JSON → exit code（0=許可, 2=ブロック）」の純粋な契約。テストはこの契約を
直接叩く。`control/` を触ったら両方を通してから完了とすること。

## 罠と規約（守らないと過去のバグが再発する）

- **`lib.sh` は `set -euo pipefail` を有効化する。** source した側の script 内で
  「失敗しうるコマンド」は必ず `if` / `||` で包む。裸のパイプライン失敗や
  `var="$(失敗しうる関数)"` の代入が -e でスクリプトごと殺した前例が**二度**ある
  （verify.sh の D1 コメント、lib.sh の herdr_workspace コメント参照）。herdr 系 helper は
  「常に rc 0・不明時は空出力/none」を契約とする。
- **D1〜D12 のコメントは過去バグの回帰防止点。** 該当行を変更するときはコメントの理由を
  読み、テストが固定していることを確認してから。v3 で仕組みごと消えたもの: D2（gate clone 先）
  D3（exchange への base 伝播 → worktree の refs 共有で構造的保証に昇格）。D12（setup.sh: 実リポ
  への push を origin push url 無効化で構造遮断。publish は fetch url へ明示 push）は v3.3 追加。
- **worktree の `.git` はファイル。** 存在検査は `[ -e .git ]` か `git rev-parse --git-dir`。
  `[ -d .git ]` は worktree で必ず偽になる（stop-gate で踏んだ）。
- **パス解決は 2 モードある**（lib.sh 冒頭）:
  - legacy: `control/` の親 = プロジェクトルート、config/secret は `control/` 直下
  - workspace: `.loop-workspace` マーカーを持つディレクトリ = payload、エンジンは中央設置
  スクリプトは `$ROOT` `$CONFIG_DIR` `$CONTROL_DIR` を必ず経由し、相対パスを直書きしない。
- **強制点はワーカーの手が届かない側に置く**（escalation ladder）: 助言は
  `CLAUDE.worker.md`(L1)、クライアントフック(L2)、ホスト側 gate(L3) + git の構造制約
  （base は canonical が checkout 済み＝ワーカー worktree からは checkout 不能）。
  「絶対に守らせたいルール」をプロンプトに足すのは誤り。ハーネス/gate に足す。
- **herdr は常に best-effort。** ループの保証（配達= SessionStart/Stop フック、完了検知=
  ref 監視 + AGENT_UNKNOWN_GRACE）は herdr 不在でも成立しなければならない。herdr 呼び出しを
  必須経路に置かない。
- **モデルルーティングは `--model` 引数で**（WORKER_MODEL/PLANNER_MODEL/SUPERVISOR_MODEL）。
  空=CLI 既定、はテストで固定。lib.sh 側の既定は空のまま（旧 config の挙動を変えない）。
- **心拍は排他**: loop.sh と watch.sh（supervise 経由含む）は state/{loop,watch}.pid の生存
  チェックで相互拒否。stale pid は無視。テストで固定済み。
- **プロジェクト固有制約はワークスペース側のシームへ**: `worker-harness.d/`（L2 ガード合成）と
  `CLAUDE.worker.local.md`（L1 追記）。エンジンの worker-harness/ に固有ルールを足すのは誤り。
- **ワーカーには Claude 組み込み worktree ツールを遮断**（harness-guard-worktree:
  EnterWorktree/ExitWorktree/WorktreeCreate）。エンジン管理 worktree が唯一の箱。
- **リリースは中央エンジンへ届けて完結**: エンジン（~/.loop/loop-template）が追跡するブランチに
  fast-forward してから `loop update`。届いていない v3 が「ワーカーが立ち上がらない」事故の
  正体だった（README 不具合 4）。
- **テストは実 herdr サーバに触れてはならない。** `HERDR_SOCKET_PATH` の偽装では遮断できない
  （実サーバに繋がる）。失敗する herdr シムを PATH 先頭に置くこと（run.sh / e2e の冒頭参照）。
- **ハーネス部品 = 能力仮定の符号化（簡素化原則）**: 能力補助系の部品（分解・feedback・
  ガイダンス類）は「モデルが単独でできないこと」への仮定であり、新モデル世代ごとに再検証して
  支えになっていないものは剥がす。パック（packs/）は `when-to-remove` を frontmatter に必ず持つ。
  **セキュリティ系（秘匿・push 遮断・harness/ 保護・PROTECTED_PATHS）は敵対的仮定の符号化で
  あり、この原則の撤去対象にしてはならない。**
- **検証器も改訂対象**: gate/契約テストは固定物ではない（検証器は意図の proxy で、生成側と
  共進化が必要）。ESCALATED 時に escalation_report が「ワーカーが悪い/ゲートが悪い」の両仮説
  を提示するレビューパケットを state/escalations/ に書く。この framing を消さないこと。
- **オントロジーは機械追記のみ**: memory/ontology/graph.jsonl へ書いてよいのは lib.sh の
  `ontology_event`（ループイベント由来）だけ。手書き・LLM 書きの導線を作るのは誤り（腐った
  知識は劣化した検証器と同種の害）。ontology_event は「常に rc 0」契約 — 呼び出し側を殺さない。
- **gate.d チェック（$CONFIG_DIR/gate.d/*.sh）はワークスペース側**: ワーカーの手が届かない
  ことが前提の L3。エンジンの gate.sh に project 固有チェックを直書きするのは誤り。パックの
  設定（*.env）も gate.d/ に置き、L2 ガードと L3 チェックが同じファイルを読む（規則の正は 1 箇所）。
- **設計 SSOT は直読**: 型付き設計データ（Spec Atlas の atlas/ 等）は DESIGN_SSOT_DIR または
  リポジトリ直下 atlas/ を planner が**直接読む**。エクスポート成果物の取込コピー
  （キャッシュ）を作る導線は誤り（鮮度の腐った複製は劣化した検証器と同種の害）。
- スクリプト内コメントは英語、運用ドキュメント（README 等）は日本語。

## 秘匿モデル（変更時に壊しやすい不変条件）

- 秘密は**スコープ別**（worker/gate/codex）の sops+age 暗号化ファイル。復号値は
  `secret_exec <scope> -- cmd` が**その 1 プロセスの env にだけ**注入する。ループ本体の
  シェルに秘密を source しない（lib.sh は config.env しか source しない）。
- `secret.gate.sops.env` は gate の決定論チェック専用、`secret.codex.sops.env` は codex 専用。
  **どちらも Claude プロセスには決して渡さない。** 新しい注入点を足すときはこの表を壊して
  いないか必ず確認する。
- worker スコープの課金優先順位: OAuth トークンがあれば `ANTHROPIC_API_KEY` を子環境で
  unset（`cred_precedence_prelude`）。この規則はテストで固定されている。
- ホスト実行の秘匿は L2（`harness-guard-secrets`）**まで**。「物理的な壁」が要る変更は
  v3 では成立しない前提で設計する（README の脅威モデル参照）。

## セカンドオピニオン（codex）の不変条件

- `second-opinion.sh` は**純評価器**: exit 0=verdict 出力、exit 3=skip。policy（advise/block、
  ラウンド消費）は plan.sh / verify.sh / `codex_gate_policy`（lib.sh）側。混ぜない。
- **独立性**: codex に渡してよいのは成果物のみ（slices.json / diff / brief / 受け入れテスト）。
  Claude の transcript・feedback 履歴・PROGRESS を渡すコードを書いてはならない（テストで
  マーカー混入を検査している）。
- codex 由来の feedback ラウンドは `CODEX_GATE_MAX_ROUNDS` と `MAX_FEEDBACK_ROUNDS` の
  二重に有界。この有界性を壊す変更（無条件 exit 7 など）は不可。
