# loop — 自律開発ループ・テンプレート

「プロンプトを書くな、ループを書け」を実運用に落とすための汎用テンプレート。
ホスト側は**決定論的なシェルだけ**が動き、知能が要る作業（計画・実装・検証）は**使い捨て
コンテナ内の Claude** に委譲する。これにより——

1. **許可待ちで止まらない** — ホストに対話Claudeが常駐しない（プロンプトを出す相手がいない）。
   コンテナ内のClaudeは `--dangerously-skip-permissions`（箱が安全境界なので安全）。
2. **tmux + Docker で並列稼働** — 監督1（=このシェル）＋ワーカー複数を並走させ開発効率を最大化。
   git worktree は監督のレビュー用に温存（`review.sh`）。
3. **認証情報を Claude から完全秘匿** — どのClaudeもホストFSを一切マウントせず、渡るのは
   使い捨て・最小スコープのワーカー鍵だけ。ホストの本物の認証情報はClaude可読プロセスに入らない。

土台は `control/`（監督1＋ワーカーN の並列基盤）。その上に **ループ層**（`loop.sh` / `watch.sh`
/ `plan.sh` + `skills/` + `memory/`）を載せて DISCOVER→PLAN→EXECUTE→VERIFY→ITERATE を自走させる。

---

## ループの全体像

```
memory/backlog.md（ゴール投入口）
        │  loop.sh が次の "- [ ]" を取得
        ▼
   ┌─ DISCOVER/PLAN ── plan.sh：使い捨て計画役Claude（canonicalをro）が
   │                   縦割りスライス＋契約テスト(tests/)へ分解
   │        ▼
   │   ASSIGN ──────── assign.sh：空きワーカーへ owned-paths＋briefを配布
   │        ▼          （SessionStartフックで確実注入。send-keys非依存）
   │   EXECUTE ─────── ワーカーClaude（コンテナ・skip-permissions）が実装→commit
   │        ▼          →autopush→exchangeのpush-eventマーカー
   │   VERIFY ──────── watch/loop がマーカー検知→gate.sh（クリーン箱で試しマージ＋テスト
   │        │          ＋tests/改ざん検査）
   │        ├─ PASS → land.sh（baseへauto-merge）→ sync.sh（他ワーカーをrebase追従）
   │        └─ FAIL → feedback.md差し戻し → stop-gateフックがワーカーを再着手させる
   │        ▼
   └─ ITERATE（MAX_FEEDBACK_ROUNDS 超で人間へESCALATE）
        ▼
 backlog空 ∧ 全ワーカーidle → 完了通知
        │  全イベントは memory/PROGRESS.md に追記（ループの外部記憶）
```

---

## クイックスタート

```bash
# 0) 前提：WSL2上でDocker稼働、tmux/git/jq導入済み。Linuxネイティブパス推奨（/mnt/c は避ける）
./control/doctor.sh                 # 前提を自己診断

# 1) 設定
$EDITOR control/config.env          # PROJECT_NAME / BASE_BRANCH / CHECK_CMD / ループ調整値
cp control/secret.env.example control/secret.env && chmod 600 control/secret.env
$EDITOR control/secret.env          # ★認証情報（下記「認証・課金モード」参照）

# 2) プロジェクト知識（ループが毎回読む）
$EDITOR skills/VISION.md skills/ARCHITECTURE.md skills/RULES.md

# 3) 初期化（初回のみ・イメージビルドで時間がかかる）
bash ./control/setup.sh                       # 空リポジトリで開始
# bash ./control/setup.sh https://github.com/you/repo.git   # 既存リポから

# 4) ゴールを書いて起動
$EDITOR memory/backlog.md           # "- [ ] ユーザーが…できる" を1行
./control/up.sh                     # tmux起動。下ペインに loop.sh が事前入力済み→Enterで自走
```

別プロジェクトへ展開: `./control/scaffold.sh /path/to/new-project [repo-url]`

---

## 認証・課金モード（サブスク枠 or 従量API）

コンテナ内の Claude を動かす資格情報を `control/secret.env` に1つだけ設定する。注入は
`spawn.sh`/`plan.sh` が `cred_docker_args()`（`lib.sh`）経由で行い、**選んだ方だけ**を渡す。

| モード | 設定 | 課金 |
|--------|------|------|
| **サブスク（Pro/Max）推奨** | `claude setup-token` で1年OAuthトークン発行→ `CLAUDE_CODE_OAUTH_TOKEN=` に設定 | 従量課金なし。サブスク枠を消費 |
| **従量API** | `ANTHROPIC_API_KEY=`（使い捨て・最小スコープ推奨） | 使った分だけ課金 |

- **⚠️ 併記しない**: `ANTHROPIC_API_KEY` がセットされていると**認証の優先順位で必ず勝ち、従量APIに流れる**。
  サブスクを使うなら API キー欄は**空のまま**にする（テンプレは選んだ方だけをコンテナに渡すので安全側だが、混乱回避のため空推奨）。
- **⚠️ サブスク枠の実態（2026-06-15〜）**: `claude -p`＝**計画役**の消費は「月額 Agent SDK クレジット」
  （Pro $20 / Max5x $100 / Max20x $200 相当・月次）から、tmux内の**対話ワーカー**は従来の対話枠
  （5時間枠/週上限）から引かれる。枠を超えると停止 or 従量へ溢れる。「使い放題」ではない。
- **並列度に注意**: 並列フリート＋計画役は枠を速く食う。`WORKER_COUNT` を小さく、`LOOP_MAX_CYCLES`/
  `MAX_FEEDBACK_ROUNDS` を絞って運用する（下記ガードレール）。レート制限(429)時はループが待ち＆再試行する。
- **秘匿(#3)への影響**: サブスクトークンは**あなたの個人アカウントの1年トークン**。コンテナ隔離
  （ホストFS無マウント＝外から読めない）は維持されるが、漏洩時の被害範囲は「捨てれば済む専用キー」より広い
  （revoke は可能）。公式CLI内で使う分はToS適合（トークンを別ツールへ抜き出すのは規約違反）。
- 現在のモード確認: `./control/doctor.sh`（`auth = subscription / api / none` を表示）。

## 自律レベルの選び方

| モード | コマンド | 挙動 |
|--------|----------|------|
| **完全自律** | `./control/loop.sh` | backlog→計画→割当→gate→**auto-land**→追従までノンストップ。人間はゴールとPROGRESS監視だけ |
| **半自律** | `./control/watch.sh` | push検知でgate自動実行・FAILは自動差し戻し。**landは人間**が判断（`land.sh`） |
| **手動** | `assign.sh`→`verify.sh`→`land.sh` | 1ステップずつ。デバッグ・初期の信頼構築向け |

`loop.sh` と `watch.sh` は**同時に動かさない**（両方がgateを駆動して競合する）。

---

## コマンド一覧

```
セットアップ/起動
  doctor.sh [--quick]   前提検査・自己診断（孤児state検出含む）
  setup.sh [repo]       初回初期化（イメージビルド・canonical作成・BASE_BRANCH検証）
  up.sh                 冪等な日次起動（tmux＋ワーカー＋loopペイン）
  down.sh [--purge]     停止（--purgeでvol/レビューworktreeも破棄）
  scaffold.sh <dir>     別プロジェクトへテンプレ展開／ --install-host-guard

ループ
  loop.sh               ★完全自律オーケストレータ（心拍）
  watch.sh              半自律：push駆動の自動gate＋差し戻し
  plan.sh "<goal>"      計画役を単独実行（loop.shが内部で使用）

ワーカー操作
  spawn.sh <w> [br]     ワーカー1体を起動（冪等）
  reap.sh <w>           ワーカー完全撤去
  respawn.sh <w>        詰まったワーカーを退避付きで即リセット
  assign.sh <w> [--brief ".."] <paths..>   担当領域＋タスク配布
  status.sh             各ワーカーの状態
  overlap.sh            衝突予備軍（複数ワーカーが触るファイル）検出
  review.sh <w>         監督レビュー用に worktree 展開（git worktreeの用途）

検証/統合
  gate.sh <w>           クリーン箱で試しマージ＋チェック（exit3=衝突 / exit4=tests/改ざん）
  verify.sh <w>         gate実行→PASS案内／FAILは feedback.md へ差し戻し＋催促
  land.sh <w> [--no-verify]   gate通過後にbaseへmerge＋全exchangeへbase伝播
  sync.sh --others <w>  land後に他ワーカーを新baseへrebase追従（衝突は差し戻し）
```

---

## 3つの目標がどう構造で担保されるか

- **#1 止まらない**：ホスト＝決定論シェル（許可プロンプト無し）。コンテナ内Claude＝skip-permissions
  （箱が安全境界）。配布は tmux send-keys ではなく **SessionStart/Stopフック**で保証（取りこぼし無し）。
- **#2 並列**：ワーカーは独立clone＋専用 exchange bare repo（fileプロトコル）。tmuxで全員を常時覗ける。
  縦割り（各ワーカーが自分のディレクトリだけ）＋ owned-paths を `harness-guard-paths` で**強制**。
- **#3 秘匿**：ワーカー/計画役コンテナは `$HOME`・SSH鍵・`/mnt/c` を**一切マウントしない**。渡すのは
  自分の exchange と使い捨て鍵のみ。マージ/保護ブランチpushは監督独占（クライアントフック＋
  サーバ pre-receive の二重）。任意の対話監督Claudeを置く場合は `control/host-harness/` が保険の二層目。

---

## トークンバーンのガードレール（「Go押すだけ」にならないために）

クローズドループは強力だがトークンを食う。暴走を**構造で**抑える調整値（`config.env`）:

- `MAX_FEEDBACK_ROUNDS`（既定4）… 1スライスのFAIL→修正の上限。超えたら人間へESCALATE（再催促を止める）。
- `LOOP_MAX_CYCLES`（既定0=無制限）… ループ総サイクルの安全上限。信頼が浅いうちは数値を入れる。
- `GATE_CONCURRENCY`（既定2）… 同時gate数の上限（ホスト資源保護）。
- `PLANNER_MAX_SLICES`（既定3）… 1ゴールを最大何スライスに割るか＝1ゴールの並列度上限。

ループの全イベントは `memory/PROGRESS.md` に残るので、何が通り・詰まり・残っているかを後から追える。

---

## 受け入れゲートを「効かせる」

gate は既定で**advisory（チェック未設定なら警告のみで通す）**。本気で守らせるには:

1. リポジトリに `harness/check.sh` をコミット（雛形 `control/harness-check.sample.sh`）、または
2. `config.env` の `CHECK_CMD` を設定（例 `CHECK_CMD="npm ci && npm run typecheck && npm test"`）。

`tests/`（`PROTECTED_PATHS`）はワーカー編集不可。改ざんブランチは gate が **exit 4** で land 拒否
（強制点はワーカーの手が届かない監督側に置く）。契約テストの質＝auto-landの安全性。

---

## ツールキット自体のテスト

```bash
./tests-toolkit/run.sh    # bash -n / shellcheck(任意) / フック単体テスト（Docker不要・52ケース）
```

フックは「stdin JSON → exit code」の純粋な契約なので Docker 無しで回帰検証できる。
ループ依存の既存バグ修正（FAIL差し戻し復活・gate clone先・base伝播・tests/強制・pull遮断）も
ここで固定している。

---

## カスタマイズの勘所

- 言語ランタイム → `control/Dockerfile` に追加（再 `setup.sh`）。
- ワーカー既定数 → `config.env` の `WORKER_COUNT`。臨時追加は `spawn.sh <name>`。
- 保護ブランチ集合 → `control/hooks/pre-receive` の正規表現。
- ワーカー行動規約 → `control/CLAUDE.worker.md`（助言L1）。破られ続けたものだけフック/構造テストへ昇格。
- Claude Code バージョン固定 → `config.env` の `CLAUDE_CODE_VERSION`（再現性。イメージ内は自動更新OFF）。

## 実運用で判明した不具合と対策（2026-06 反映済み）

実プロジェクト（フル自律ループ）を回して詰まった点と、テンプレートに取り込んだ修正。同症状が出たらここを参照。

1. **計画役が `slices.json` を出せない / ワーカーが push できない（uid 不一致）**
   - 症状: `plan.sh` が「planner produced no slices.json」で必ず失敗。原因はホスト所有(uid 1000)の bind-mount（planner の `/out`、worker push 先 `exchange/*.git`）へコンテナの `dev` が書けない。
   - 真因: `node:22-bookworm` が uid 1000 を `node` ユーザーに使うため、素の `useradd dev` が **uid 1001** になりホストと不一致。
   - 対策: `Dockerfile` で `userdel -r node` → `useradd -u 1000 dev`（ホスト uid に一致）。**ホスト uid が 1000 でない環境では合わせること。**

2. **ワーカーがタスクに着手しない（初回オンボーディング）**
   - 症状: `assign.sh` の nudge を送っても、対話 `claude` が初回 TUI（テーマ選択→ログイン→フォルダ信頼→bypass 警告）で停止し入力が吸われる。
   - 対策: `control/worker-claude.json` を `/home/dev/.claude.json`（HOME 直下のファイル）に COPY し `hasCompletedOnboarding` / `projects["/work"].hasTrustDialogAccepted` / `bypassPermissionsModeAccepted` を事前承認。`-p` の planner は対話 UI を出さないので影響なし。

3. **nudge が「入力欄に残って未送信」（tmux send-keys の Enter 競合）**
   - 症状: タスク/フィードバックの指示文が `❯` に表示されたまま実行されず、ワーカーが固まる。
   - 対策: `assign.sh` / `verify.sh` で本文と Enter を**別々の send-keys に分離**（間に `sleep 1`）。

4. **ループが即停止（`LOOP_MAX_CYCLES` の単位誤解）**
   - 症状: ワーカー実装中なのにループが数十秒で終了し、ゲートが走らない。
   - 真因: 1 cycle = loop.sh の**ポーリング1回**であってゴール数ではない。小さい値はワーカー完了前に上限到達。
   - 対策: 既定 `0`（無制限）を推奨し、コメントを明記。**トークン上限は `MAX_FEEDBACK_ROUNDS`** で掛ける（ポーリングは無料）。

5. **計画役コンテナが長時間ハング（無限ブロック）**
   - 症状: `plan.sh` の `claude -p` が応答せず、loop.sh ごと停止（実例で約15時間）。
   - 対策: `plan.sh` の planner 実行を `timeout`（既定 900s、`PLAN_TIMEOUT` で調整）で保護。タイムアウト時は PLAN_FAIL 扱いでループは前進。

> 補足（プロジェクト固有なのでテンプレートには入れない設計判断）: 「最終ゴールの受け入れ基準」を毎ゲートで強制すると、
> パイプライン完成時点で以降のスライスが全て land 不能になりデッドロックする。中間ゴールは基準を非ブロック化（メトリクス出力＋xfail）し、
> 最終ゴールだけセンチネルで厳密強制する、という二段構えが有効だった（`harness/check.sh` + 受け入れテスト側で実装）。
