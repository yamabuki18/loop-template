# CHANGELOG — loop-template

変更履歴と「実運用で判明した不具合→対策」の記録。現行仕様は `README.md` が正であり、
ここは「なぜそうなったか」を遡るための資料。エンジン開発時の回帰防止規約は
リポジトリ直下の `CLAUDE.md` を読むこと。

## v3.7 平文シークレット化 + 監査対応

- **sops+age の暗号化層を撤去**し、秘密はスコープ別（worker/gate/codex）の**平文**
  `secret.<scope>.env` に単純化（`secrets.sh` / `SECRET_BACKEND` / `loop secrets` 削除）。
  スコープ分離（gate/codex の値は Claude プロセス非経由）・OAuth 優先の課金順位・
  L2 秘匿ガードは維持。gitignore（`secret.*.env`）が誤コミットへの唯一の防壁になった。
- `secret_present` を「ファイル存在」から「空でない値の代入がある」判定へ（init/setup が
  空テンプレートを seed するため。存在判定のままだとホストログイン・フォールバックと
  usage guard プローブが黙って死ぬ）。
- **handoff の冪等化**: 同一タイトルの open ゴール（`[ ]`/`[~]`）が backlog にあるとき
  再 handoff を拒否（二重実装の防止。`[x]`/`[!]` は再投入可）。
- **scaffold の再実行ガード**: 既存の control/skills/memory がある対象への再 scaffold を拒否
  （旧挙動は backlog を truncate し control/control を入れ子にする破壊的再実行だった）。
- **ワーカープール起動の一本化**: loop.sh / up.sh / supervise.sh の 3 コピーを lib.sh の
  `spawn_pool` へ集約。
- **ontology-check の自動結線**: digest 再生成（= land ごと）の直前に上位オントロジー検証を
  自動実行。違反は PROGRESS へ `ONTOLOGY_INVALID` 警告（advisory・rc 0 契約）。
- README 再構成: 推奨導入経路（中央インストール）を先頭へ、変更履歴をこのファイルへ分離、
  テスト件数等のハードコード数値を撤去。

## v3.6 pack spec v1（外部産パックの取込）+ エンジン監査対応

- パック形式を交換形式として公開（pack spec v1）: frontmatter 契約（enforces /
  when-to-remove 必須、origin / requires 推奨）+ L2 ガード 1 つにつき 1 ケース以上の
  selftest を**インストール前に**ステージ検証。`loop harness apply <dir>` で外部産パックを
  取込。仕様の正は `packs/README.md`。

## v3 で固定した回帰点（実運用で判明した不具合と対策）

v2 時代の 5 件（uid 不一致・オンボーディング停止・send-keys 競合・LOOP_MAX_CYCLES 誤解・計画役
ハング）は v3 で仕組みごと消えたか（uid/exchange）、対策を継承している（オンボーディング
pre-seed → `worker-claude.template.json`、nudge の本文/Enter 分離 → `agent_send`、`timeout` 保護
→ plan.sh / second-opinion.sh）。v3 で新たに固定した回帰点:

1. **`set -e` × 失敗しうるコマンド置換**（D1 の類型）: `ws="$(herdr_workspace)"` のような代入は
   中身が rc≠0 でもスクリプトを殺す。herdr 系 helper は**常に rc 0**（不明時は空出力）で統一。
2. **worktree の `.git` はファイル**: 存在検査は `[ -d .git ]` ではなく `[ -e .git ]` /
   `git rev-parse --git-dir`（stop-gate で踏んだ）。
3. **テストの隔離**: herdr CLI は `HERDR_SOCKET_PATH` が壊れていても実サーバに繋がることがある。
   テストは失敗する herdr シムを PATH 先頭に置いて遮断する（実 workspace を汚さない）。
4. **中央エンジンの旧版**（v3.1 で実際に踏んだ）: `loop` CLI は `~/.loop/loop-template` の
   **checkout 済みブランチ**を実行する。開発リポジトリで新ブランチ（v3 等）を切っても、中央
   エンジンに届いていなければ**旧世代のループが黙って動く**（症状: herdr を起動しても
   ワーカーペインが一切現れない＝旧 tmux/Docker 世代が走っていた）。対策: リリースは
   エンジンが追跡するブランチへ fast-forward してから `loop update`。`loop version` /
   `loop doctor` が表示するエンジンのバージョンとコミットを疑うこと。

## v3.3 ハーネス堅牢化（失敗系・生存性の穴を塞ぐ）

レビューで判明した「宣言している不変条件が実は L2 正規表現でしかない／失敗系が未防御」を修正。
方針は一貫して**壊れている保証をより深いラダー（L3・構造）へ移す**（L2 の追加ではない）。

5. **ワーカー生存性ウォッチドッグ**（P1）: ハング/空回り/無 commit のワーカーは ref が動かず
   `BUSY` が永久化しループが完了しなかった。無進捗検知→nudge→自動 respawn→ESCALATE で回収する
   （`WORKER_TIMEOUT_SECS` / `WORKER_HANG_GRACE`）。
6. **「worktree が壁」を Bash にも**（P2, D-write）: `guard-paths` は Edit 系のみ。`echo > /host`・
   `tee`・`cp`/`mv`・`dd`・`sed -i`（とりわけワーカー自身の `CLAUDE_CONFIG_DIR` への自壊書き込み）
   を `harness-guard-write` で遮断。速度制限であり、構造側（下記 D12・fail-closed）と併用。
7. **push を構造遮断**（P3, D12）: canonical の origin push url を無効化。ワーカーの
   `git push origin`（`git -C .` 含む）は URL 解決で失敗（`--no-verify` でも回避不能）。publish は
   fetch url へ明示 push するので不変。`guard-git` は `git -C`/`GIT_DIR=` 回避も拾うよう強化。
8. **未追跡ファイルの無言喪失**（P4）: Stop gate を `git status --porcelain` 基準に。add し忘れた
   新規ファイルも commit を促す（`.gitignore` 済みは除外）。
9. **ガードの fail-closed 化**（P5）: jq / realpath(・python3) 不在時はツールを**拒否**（従来は
   空パース→黙って許可＝武装解除）。spawn.sh が依存をプリフライト。
10. **クラッシュ後の孤児ゴール**（P6）: 起動時に `- [~]` を `- [ ]` へ戻す。`mark_goal` は
    バイト完全一致の no-op を検出して警告。
11. **sync の herdr 非依存化**（P8）: herdr が状態不明（サーバ停止等）のとき、生きたワーカーの
    worktree を rebase して壊さないよう、直近 commit からの経過時間（`SYNC_IDLE_SECS`）で退避判断。
12. **ワーカー観測性**（P7）: land/escalate 時に commit 数・diff 規模・経過時間を `WORKER_STATS` として
    PROGRESS へ。`status.sh` に集約サマリ。`LOOP_WORKER_TRANSCRIPT=1` で reap/respawn 前に
    セッション transcript を `state/logs/<w>.session/` へ退避。

## v3.4 ハーネスパック + 検証器強化（直近研究の反映）

2026 年前半のハーネス研究（Anthropic 実務報告 / Verification Horizon / Bias in the Loop /
LongCLI-Bench 等）のサーベイ結果をエンジンへ反映した。

13. **`loop harness`**: 方針（アーキテクチャ規律・テスト戦略・知識管理）を導入時に対話で決定し、
    既存シーム（L1: skills/・CLAUDE.worker.local.md / L2: worker-harness.d/ / L3: gate.d/）へ
    パックとして取込。新概念は作らない — 手書き拡張と同じ場所・同じ契約。同梱:
    `backend-clean-arch` / `frontend-humble-object` / `ontology-aif`。各パックは
    `when-to-remove`（簡素化原則: 部品=能力仮定の符号化、モデル世代ごとに再検証）を必ず宣言。
14. **設計 SSOT 直読**: 型付き設計データ（Spec Atlas の `atlas/` 等）を計画役が**直接読む**
    （`DESIGN_SSOT_DIR` またはリポジトリ直下 `atlas/` の自動検出）。エクスポート成果物の取込
    コピーは作らない — 正本は常に 1 箇所。in-repo の場合は `PROTECTED_PATHS` に足して
    実装ワーカーから遮断する。
15. **gate 強化**: `harness/` 保護（自ゲート無力化の遮断、exit 4・セキュリティ系）、テスト
    ゲーミング検知（`GATE_TESTGAMING=warn|block`、skip 化・`|| true` 等の検証器弱体化を検出、
    exit 6）、ワークスペース側ゲート拡張（`gate.d/*.sh`、GATE_* env 契約）。
16. **検証器の共進化シーム**: ESCALATED 時に `state/escalations/` へ「実装が悪い/ゲートが悪い」
    両仮説のレビューパケットを生成（検証器は意図の proxy であり改訂対象）。verify の feedback
    に F2P（新規契約）/P2P（回帰）の区別を明記し、planner の契約テストにも F2P 規約を指示。
17. **codex 提示バイアス緩和**: judge プロンプトから provenance cue（作者情報）を除去し、
    diff 内の自己評価コメント（reviewed/approved 等）を証拠と見なさない指示を追加
    （判定はコード同一でも提示形式で反転しうる、という監査研究への対応）。
18. **イベントオントロジー（AIF 準拠）**: `memory/ontology/graph.jsonl` に CA（gate FAIL /
    codex 懸念 / ゲーミング検知）と PA（land / handoff / 設計取込）をホストが機械追記。
    人手・LLM 維持ゼロ。land ごとに digest を再生成し、計画役が「未解決の対立」を既読。
    上位オントロジー制約は `ontology-check.sh` が決定論検証（`ONTOLOGY_ENABLED` で無効化可）。

## v3.5 使用量ガード（サブスクリプションの窓に合わせた自動ペース配分）

19. **`USAGE_GUARD`**: プラン共有の 5h/7d 窓を OAuth 使用量エンドポイント（/usage HUD と同源、
    非公式のため fail-open）で監視し、80% で DRAIN（進行中は完走・新規停止）→ 全員完了か
    100% 到達で PAUSE → 窓リセット後に自動再開トリガー（USAGE_RESUME + 通知 + 進行中ワーカー
    へ nudge）。watchdog はリミット起因の停滞を respawn せず pause に切替（ラウンド浪費を防止）。
    プローブはキャッシュ + 必須 User-Agent でエンドポイント側のレート制限を尊重。詳細は
    README「トークンバーンのガードレール > 使用量ガード」。
