# loop — 自律開発ループ・テンプレート (v3)

「プロンプトを書くな、ループを書け」を実運用に落とすための汎用テンプレート。
ホスト側は**決定論的なシェルだけ**が動き、知能が要る作業（計画・実装）は **git worktree 上の
使い捨て Claude プロセス**に委譲する。v3 で Docker と tmux を全廃し、多重化は
[herdr](https://herdr.dev)、秘匿は [sops](https://github.com/getsops/sops) + age、
検証には **Codex によるセカンドオピニオン**（独立並行評価）を加えた。

1. **許可待ちで止まらない** — ループ本体に対話 Claude は常駐しない（プロンプトを出す相手がいない）。
   ワーカー Claude は `--dangerously-skip-permissions`（フックのハーネスが柵）。
2. **herdr + git worktree で並列稼働** — 監督1（=このシェル）＋ワーカー複数を並走。herdr が各
   エージェントの状態（idle/working/blocked）をネイティブ検知し、ループの完了シグナルになる。
3. **認証情報の秘匿** — 秘密は sops+age で**ディスク上は常に暗号化**。復号された値は
   `secret_exec` が「その値を必要とする 1 プロセスの env」にだけ注入する。gate/codex 用の秘密が
   Claude プロセスに入ることは構造上ない。
4. **セカンドオピニオン** — 別アーキテクチャの AI（Codex）が計画とゲート通過差分を**成果物だけ
   見て**独立レビュー。作者モデルの盲点を別の目で拾う（既定は advisory、ブロックはしない）。

土台は `control/`（監督1＋ワーカーN の並列基盤）。その上に **ループ層**（`loop.sh` / `watch.sh`
/ `plan.sh` + `skills/` + `memory/`）を載せて DISCOVER→PLAN→EXECUTE→VERIFY→ITERATE を自走させる。

---

## ループの全体像

```
memory/backlog.md（ゴール投入口）
        │  loop.sh が次の "- [ ]" を取得
        ▼
   ┌─ DISCOVER/PLAN ── plan.sh：使い捨て worktree 上の headless Claude が
   │        │          縦割りスライス＋契約テスト(tests/)へ分解
   │        │          → validate_slices（決定論検証）
   │        │          → codex が計画を独立批評（advisory: 指摘を brief に折込み）
   │        ▼
   │   ASSIGN ──────── assign.sh：空きワーカーへ owned-paths＋brief を配布
   │        ▼          （SessionStart フックで確実注入。nudge 非依存）
   │   EXECUTE ─────── ワーカー Claude（worktree・skip-permissions）が実装→commit
   │        ▼          → worktree は canonical と refs 共有＝コミット即可視（push 不要）
   │   VERIFY ──────── loop が「ref 変化 × herdr agent=idle」を検知
   │        │          → gate.sh（使い捨て worktree で試しマージ＋チェック＋tests/改ざん検査）
   │        │          → PASS 後に codex が差分を独立レビュー
   │        ├─ PASS → land.sh（base へ auto-merge）→ sync.sh（他ワーカーを rebase 追従）
   │        ├─ FAIL → feedback.md 差し戻し → stop-gate フックがワーカーを再着手させる
   │        └─ codex high 指摘（advise）→ 1 回だけ feedback ラウンド消費（有界）
   │        ▼
   └─ ITERATE（MAX_FEEDBACK_ROUNDS 超で人間へ ESCALATE）
        ▼
 backlog 空 ∧ 全ワーカー idle → 完了通知
        │  全イベントは memory/PROGRESS.md に追記（ループの外部記憶）
```

---

## クイックスタート

```bash
# 0) 前提：git / jq / claude CLI / herdr / sops / age。Linux ネイティブパス推奨（/mnt/c は避ける）
#    herdr : curl -fsSL https://herdr.dev/install.sh | sh
#    sops  : https://github.com/getsops/sops/releases（単一バイナリ）
#    age   : apt install age
./control/doctor.sh                 # 前提を自己診断

# 1) 設定と秘密
$EDITOR control/config.env          # PROJECT_NAME / BASE_BRANCH / CHECK_CMD / ループ調整値
claude setup-token                  # サブスク用 OAuth トークン発行（推奨）
bash ./control/secrets.sh init      # age 鍵 + .sops.yaml（初回のみ）
bash ./control/secrets.sh edit worker   # ★エディタが開く→ CLAUDE_CODE_OAUTH_TOKEN= に貼る
                                        #   平文ファイルは一切ディスクに残らない

# 2) プロジェクト知識（ループが毎回読む）
$EDITOR skills/VISION.md skills/ARCHITECTURE.md skills/RULES.md

# 3) 初期化（v3 はイメージビルドが無いので数秒）
bash ./control/setup.sh                       # 空リポジトリで開始
# bash ./control/setup.sh https://github.com/you/repo.git   # 既存リポから

# 4) ゴールを書いて起動
$EDITOR memory/backlog.md           # "- [ ] ユーザーが…できる" を1行
./control/up.sh                     # herdr 起動。loop ペインに loop.sh が事前入力済み→Enter で自走
```

別プロジェクトへ展開: 下記「**他プロジェクトへの展開**」参照（推奨: `loop init`）。

---

## 日々の開発への適用 — zero-footprint 運用（`loop here`）

普段の開発リポジトリにループを使いたいが、**リポジトリに一切ファイルを増やしたくない**場合の
標準運用。ワークスペースはプロジェクトの**外**（`$LOOP_HOME/workspaces/<パスのスラッグ>/`、
既定 `~/.loop`）に置かれ、成果は**ブランチとして**還流する。作業ツリーには何も書かない。

```bash
cd ~/dev/myproject
loop here            # 一度だけ: 外置きワークスペースを作成し、このパスに紐付ける
loop secrets init && loop secrets edit worker   # 一度だけ: 秘密を暗号化保管
loop setup           # canonical をローカル repo からクローン（イメージビルド無し・数秒）
$EDITOR ~/.loop/workspaces/<slug>/memory/backlog.md    # ゴールを書く
loop up              # herdr fleet + ダッシュボード起動。以降 loop run / loop dashboard など

# ← ここからが日常サイクル →
loop publish         # ループが land した成果を loop/main ブランチとしてプロジェクトへ push
git log -p ..loop/main && git merge loop/main          # 君がレビューして取り込む
loop refresh         # 逆方向: 君が手で進めたコミットをループの base へ ff 取り込み
loop workspaces      # 紐付け済みプロジェクト一覧（backlog 残数・ワーカー数）
```

- 紐付け後は**プロジェクト内のどこから `loop <cmd>` を打っても**正しいワークスペースに解決される
  （`.loop-workspace` マーカー → git toplevel のスラッグ、の順で lib.sh が解決）。
- `loop refresh` は **ff-only**。履歴が分岐していたら「先に publish→merge しろ」と拒否する
  （監督の与り知らぬ所で 2 つの履歴を自動マージしない、という設計判断）。
- `loop publish` が作る `loop/<base>` はループ専有ブランチ（毎回 force 更新）。プロジェクト側は
  通常の PR ブランチと同じ流儀でレビュー・merge すればよい。
- プロジェクトの git に入るものは**ブランチ参照 1 本だけ**。tracked ファイルの増減はゼロ
  （回帰テストで恒久固定済み）。

## 他プロジェクトへの展開（エンジン中央インストール・推奨）

エンジン（このリポジトリ）をマシンに**一度だけ**置き、各プロジェクトは薄い「ワークスペース」
（config.env / 暗号化 secrets / skills / memory / 実行時 state）だけを持つ。バグ修正・改善は
`loop update`（= エンジンで `git pull`）一発で**全プロジェクトに即反映**される。

```bash
# 1) エンジンを一度だけインストール
git clone <this-repo> ~/.loop/loop-template
ln -s ~/.loop/loop-template/loop/bin/loop ~/.local/bin/loop   # PATH の通った場所へ

# 2) プロジェクトごとにワークスペースを作る
loop init ~/dev/myproject [repo-url]   # PROJECT_NAME はディレクトリ名から自動設定
cd ~/dev/myproject
$EDITOR config.env
loop secrets init && loop secrets edit worker
$EDITOR skills/VISION.md skills/ARCHITECTURE.md skills/RULES.md
loop setup                             # canonical 作成（数秒）
$EDITOR memory/backlog.md && loop up   # 以降は loop status / loop verify w1 / loop land w1 ...

# 3) エンジン更新（全ワークスペースに共通適用）
loop update                            # 固定したければエンジン側で git checkout <tag>
```

- ワークスペースは `.loop-workspace` マーカーで検出される（`LOOP_PROJECT` 環境変数でも明示可）。
  `spawn.sh` が herdr ペインに `LOOP_PROJECT` を注入するので、ペイン内のコマンドも正しく束縛される。
- `loop <cmd>` は `control/<cmd>.sh` への転送（`loop run` = loop.sh、`loop secrets` = secrets.sh）。
- `loop doctor` がエンジンのバージョンと動作モード（workspace / legacy）を表示する。
- 従来の**丸ごとコピー展開**（`./control/scaffold.sh <dir> [repo-url]`）も引き続き動くが、
  エンジン更新が伝播しない（レガシー）。

---

## 秘密情報の管理（sops + age — 無料・アカウント不要）

v3 の秘密は**スコープ別の暗号化 env ファイル**で管理する。平文ファイルはディスクに置かない。

| スコープ | ファイル | 中身 | 復号された値が入るプロセス |
|----------|----------|------|---------------------------|
| `worker` | `secret.worker.sops.env` | `CLAUDE_CODE_OAUTH_TOKEN` または `ANTHROPIC_API_KEY` | ワーカー/計画役の **claude プロセスのみ** |
| `gate`   | `secret.gate.sops.env`   | テスト用 DB URL・試験キー等 | **決定論チェックのみ**（Claude には決して入らない） |
| `codex`  | `secret.codex.sops.env`  | `OPENAI_API_KEY`（`codex login` 派は不要） | codex プロセスのみ |

```bash
loop secrets init            # age 鍵生成（~/.config/sops/age/keys.txt・要バックアップ）+ .sops.yaml
loop secrets edit worker     # sops edit（保存時に自動暗号化。平文が残らない）
loop secrets status          # スコープごとの有無・復号可否・auth モード
loop secrets migrate --yes   # v2.2 の平文 secret.env / secret.gate.env を暗号化して破棄
```

- 注入は `lib.sh` の `secret_exec <scope> -- cmd`（実体は `sops exec-env`）。**そのコマンドの
  子プロセス env にだけ**復号値が入り、ループ本体のシェルには決して載らない。
- **課金の優先順位（v2.2 から継続）**: `ANTHROPIC_API_KEY` が見えると従量 API が必ず勝つ。
  worker スコープでは OAuth トークンがある場合 API キーを**子環境内で自動 unset** する。
- スコープファイルが無い場合の**ホストログイン・フォールバック**: `~/.claude` にログイン済みなら
  spawn がその資格情報をワーカーの隔離 config にコピーして動かす（doctor が `auth = host` と表示）。
  手軽だが**個人アカウントの資格情報**なので、常用するなら `claude setup-token` + worker スコープへ。
- 暗号化済み `*.sops.env` と `.sops.yaml`（公開鍵のみ）は原理上コミット可能だが、既定では
  gitignore している。チームで age 公開鍵を共有する場合のみ、自分のワークスペースの
  `.gitignore` から該当行を外して opt-in すること。
- backend は差し替え可能: `SECRET_BACKEND=sops`（既定）`| op`（1Password CLI）`| plain`（レガシー平文。
  doctor が強く警告）。

### 脅威モデル（正直に）

v2 の Docker は「ワーカーからホスト FS が**物理的に**見えない」壁（L3）だった。v3 のワーカーは
ホストプロセスであり、その壁は無い。v3 の現実的な保証は:

- **暗号化 at rest**: ディスク上に平文の秘密は存在しない（`loop secrets edit` 経由なら一度も）。
- **スコープ別最小権限**: gate/codex の秘密は**どの Claude プロセスにも入らない**。ワーカー資格
  情報は v2.2 と同様「ワーカー自身のプロセス env」には見える（`-e` 注入と同等）。
- **L2 ガード（`harness-guard-secrets`、v3 で必須化）**: age 鍵・`~/.ssh`・`~/.claude`・
  `~/.codex`・secret ファイル・env ダンプ（`env`/`printenv`/`set`/`/proc/*/environ`）・
  sops/age/op の起動をフックで遮断。**ただしフックは決意した攻撃者への完全な壁ではない**
  （コンパイル済みバイナリや `os.environ` など側路はある）。
- **L3 相当で残るもの**: gate の tests/ 改ざん検査（exit 4）、base ブランチの checkout 不能
  （canonical が checkout 中という git の構造的制約）、**実プロジェクトリポジトリへの push は
  構造的に到達不能**（setup.sh が canonical の origin push url を無効化＝D12。正規の publish は
  fetch url へ明示 push するので生きる。`--no-verify` でも回避できない URL レベルの遮断）。
- **L2 で新たに塞いだ穴（v3.3）**:
  - **Bash 書き込みの worktree 逸脱**（`harness-guard-write`）: `echo > /host/path`・`tee`・
    `cp`/`mv`・`dd`・`sed -i` の書き込み先を canonicalize し、worktree 外（特にワーカー自身の
    `CLAUDE_CONFIG_DIR`＝フック設定の自壊）を遮断。速度制限であり壁ではない（下記の構造側と併用）。
  - **`git -C` / `GIT_DIR=` などによる git ガード回避**（`harness-guard-git` 強化）。
  - **ガードの fail-closed 化**: jq / realpath(・python3) 不在時はツールを**拒否**する
    （従来は空パース→黙って許可＝ハーネス全体の武装解除だった）。spawn.sh が依存をプリフライト。

「箱の外に出られない」保証が要件なら v2.2（git 履歴に残っている）を使うか、コンテナ内で
このテンプレートごと動かすこと。v3 は**起動の速さと運用の単純さ**をこの トレードオフで買っている。

---

## セカンドオピニオン（Codex — 独立並行評価）

異なるアーキテクチャのモデルは異なる盲点を持つ。v3 は [codex CLI](https://developers.openai.com/codex/cli/)
を**独立レビュアー**として 2 箇所に置く（`control/second-opinion.sh`）:

- **計画時**（plan.sh・validate_slices 通過後）: スライスのパス重複・受け入れ基準の穴・
  並列実行に潜む依存・保護パス侵犯を批評。advise では指摘が各スライスの brief に
  「Second opinion notes」として折り込まれ、**ワーカーが実装前に読む**。
- **ゲート時**（gate.sh の PASS 後）: merge-base 差分＋task brief だけを見て、テストが
  拾えない種類の欠陥（ロジックバグ・仕様との乖離・危険な変更）をレビュー。

**独立性の規則（コードで強制）**: codex が見るのは成果物のみ（slices.json / diff / brief /
受け入れテスト）。Claude の思考過程・feedback 履歴・PROGRESS は**決して渡さない**。
一次意見を読んだ第二意見はただのエコーだからだ。

| ノブ（config.env） | 既定 | 意味 |
|---|---|---|
| `SECOND_OPINION` | `advise` | `off` / `advise`（非ブロック） / `block`（懸念で plan 却下・land 停止） |
| `SECOND_OPINION_PLAN` / `_GATE` | 空 | フェーズ別上書き（空=継承） |
| `CODEX_MODEL` | 空 | `codex exec -m` に渡すモデル（空= codex 既定） |
| `CODEX_TIMEOUT` | 300 | 1 レビューの上限秒。ハングしてもループは止まらない |
| `CODEX_GATE_MAX_ROUNDS` | 1 | advise 時、high 指摘がスライスあたり消費できる feedback ラウンド数 |
| `CODEX_DIFF_MAX_LINES` | 4000 | プロンプトに埋める diff の上限（head+tail 蒸留） |

- **有界性**: advise の high 指摘は `CODEX_GATE_MAX_ROUNDS` 回だけ feedback ラウンドを消費し、
  それも `MAX_FEEDBACK_ROUNDS` に計上される。codex が何を言おうと**ループは必ず前進 or ESCALATE**。
  low/medium は PROGRESS への記録のみ（CODEX_ADVISE）。
- **自動縮退**: codex 未インストール・タイムアウト・出力パース不能は全て skip（PROGRESS に
  CODEX_SKIP）。ループは一切ブロックされない。
- セットアップ: codex CLI を入れて `codex login`（ChatGPT アカウント）、または
  `loop secrets edit codex` で `OPENAI_API_KEY` を設定。
- コスト注意: ゲート 1 回ごとに codex 1 呼び出し。太い差分を大量に land するプロジェクトでは
  `SECOND_OPINION_GATE=off` や `CODEX_MODEL` を軽いモデルにする調整が効く。

---

## 自律レベルの選び方

| モード | コマンド | 挙動 |
|--------|----------|------|
| **完全自律** | `./control/loop.sh` | backlog→計画→割当→gate→**auto-land**→追従までノンストップ。人間はゴールと PROGRESS 監視だけ |
| **対話監督** | `loop supervise` | ★君＋強モデルの監督 Claude（`SUPERVISOR_MODEL`）が対話で分解・割当・land を判断。gate は watch ペインが自動駆動、実装は安価な並列ワーカー（`WORKER_MODEL`） |
| **半自律** | `./control/watch.sh` | コミット検知で gate 自動実行・FAIL は自動差し戻し。**land は人間**が判断（`land.sh`） |
| **手動** | `assign.sh`→`verify.sh`→`land.sh` | 1 ステップずつ。デバッグ・初期の信頼構築向け |

`loop.sh` と `watch.sh`（`loop supervise` 含む）は**同時に動かさない**（両方が gate を駆動して
競合する）。v3.1 からは `state/loop.pid` / `state/watch.pid` の生存チェックで**起動時に構造的に
拒否**される（stale な pid は無視される）。

### 対話監督モード（`loop supervise`）の中身

「安いモデルの並列ワーカーを、強いモデル＋人間が監督する」ための一等市民モード。

1. ワーカープール（`WORKER_MODEL`、既定 sonnet）を冪等に起動
2. `watch` herdr ペインで watch.sh（コミット駆動 gate＋FAIL 自動差し戻し）を起動
3. **今いるターミナルが監督席になる**: `CLAUDE.supervisor.md`（分解・割当・テスト戦略の
   プレイブック）＋自動生成の環境情報（絶対パス・ワーカー一覧）を CLAUDE.md に持つ
   対話 Claude が `SUPERVISOR_MODEL`（既定 opus）で canonical 上に立ち上がる
4. 監督 Claude は許可プロンプト**あり**で動く（君が同席しているのだから、承認そのものが
   このモードの価値）。秘密ガード（host-harness L2）は自動で装着される
5. 追加引数は claude へ素通し: `loop supervise -- --continue`

### plan mode からのハンドオフ（対話で計画 → 艦隊が実装）

対話セッション（監督ペインや君の日常 claude）で **plan mode** を使って計画を練った場合、
承認後にそのセッション自身が auto-edit モードで実装へ突入するのではなく、**ループに実装を
降ろす**のが v3.2 の標準動線だ。

1. plan mode で計画を承認すると、フック（`harness-plan-capture`、PostToolUse: ExitPlanMode）が
   計画本文を `memory/plans/latest.md` に**決定論的に保存**し、セッションへ「ここで実装するな、
   handoff せよ」と文脈注入する
2. `loop handoff "<ゴール名>" --latest` — 計画を `memory/plans/<日時>-<slug>.md` へアーカイブし、
   backlog に `- [ ] <ゴール名> (plan: memory/plans/…)` を積む
3. 計画役（plan.sh）は参照付きゴールを見ると**その計画を忠実にスライス分解する**
   （再計画・方針変更・スコープ拡大はプロンプトで禁止）。実装は通常どおりワーカー＋gate

監督ペイン（`loop supervise`）にはこのフックが自動装着される。君自身の日常セッションで使う
場合は host-harness の settings（`harness-plan-capture` 込み）をプロジェクトの
`.claude/settings.json` にマージする（`scaffold.sh --install-host-guard`、host-harness/README 参照）。

### モデルルーティング（config.env）

| ノブ | 既定 | 入るプロセス |
|---|---|---|
| `WORKER_MODEL` | `sonnet` | 各ワーカー Claude（並列・高消費の実装役） |
| `PLANNER_MODEL` | 空（CLI 既定） | 計画役 headless Claude（分解と契約テストの品質が全ワーカーに波及） |
| `SUPERVISOR_MODEL` | `opus` | `loop supervise` の対話監督 Claude |

空にすればその役は claude CLI の既定モデル。値は `claude --model` にそのまま渡る
（`sonnet`/`opus` などのエイリアスもフルネームも可）。

## herdr レイアウト（全軍を1画面で見渡す）

`up.sh` が 1 プロジェクト = 1 herdr workspace を作る。ワーカーはそれぞれ**タスク名を名乗る
エージェントペイン**になり、herdr が状態（🟢 idle / 🟡 working / 🔴 blocked）を常時表示する。

```
herdr workspace <project>
┌── supervisor ─────────────┐  ┌── w1 ──────┐ ┌── w2 ──────┐ ┌── w3 ──────┐
│ loop ペイン(事前入力済み)   │  │ ワーカー    │ │ ワーカー    │ │ ワーカー    │
│ dashboard ペイン(戦況板)   │  │ Claude 画面 │ │ Claude 画面 │ │ Claude 画面 │
└───────────────────────────┘  └────────────┘ └────────────┘ └────────────┘
```

- **ダッシュボード**（読み取り専用）: backlog 残数と分解中ゴール、各ワーカーの herdr 状態・
  ブランチ・最終コミット時刻・STATUS・**ライブ画面の末尾 3 行**、PROGRESS 直近イベント
  （LANDED=緑 / FAIL=黄 / ESCALATED=赤 / CODEX_*=シアン）を数秒間隔で自動更新。
- **介入**: マウスで対象ペインをクリックして直接入力（herdr はマウスネイティブ）。
  デタッチしても herdr サーバがペインを保持し、`herdr` 一発で再アタッチできる（SSH 越しも可）。
- herdr サーバはプロジェクト横断で共有される。`down.sh` はペインを閉じるだけでサーバは
  止めない（止めるなら `herdr server stop`）。
- herdr が無い/落ちている場合もループは動く（ref 監視＋`AGENT_UNKNOWN_GRACE` で縮退。
  nudge は失われるが SessionStart/Stop フックが配達を保証する）。

---

## コマンド一覧

```
セットアップ/起動
  bin/loop <cmd>        中央インストール用 CLI（here / init / secrets / update / version / 転送）
  here.sh               ★カレントのプロジェクトに zero-footprint で紐付け（= loop here）
  secrets.sh <sub>      ★sops+age の秘密管理（init / edit <scope> / status / migrate --yes）
  publish.sh            land 済み成果をプロジェクトへ loop/<base> ブランチとして push
  refresh.sh            プロジェクトの新コミットをループの base へ ff 取り込み
  workspaces.sh         紐付け済み全プロジェクトの一覧（backlog・ワーカー数）
  init.sh <dir> [repo]  ワークスペース作成（= loop init。エンジンは中央に留まる）
  harness.sh [sub]      ★方針パックをハーネス/ゲートへ取込（= loop harness。wizard / list /
                        apply <pack>... / status）
  doctor.sh [--quick]   前提検査・自己診断（herdr/sops/age/codex・孤児検出・エンジン ver）
  setup.sh [repo]       初回初期化（canonical 作成・BASE_BRANCH 検証・secrets init）
  up.sh                 冪等な日次起動（herdr workspace＋ワーカー＋loop/dashboard ペイン）
  down.sh [--purge]     停止（--purge で worktree/ブランチ/state も破棄。サーバは残す）
  scaffold.sh <dir>     別プロジェクトへテンプレ展開／ --install-host-guard

ループ
  loop.sh               ★完全自律オーケストレータ（心拍）
  supervise.sh          ★対話監督モード（= loop supervise。watch ペイン＋監督 Claude を起動）
  handoff.sh <title>    ★plan mode で承認した計画を backlog ゴール化（--latest / --plan <f>|-）
  watch.sh              半自律：コミット駆動の自動 gate＋差し戻し
  plan.sh "<goal>"      計画役を単独実行（loop.sh が内部で使用）
  second-opinion.sh     codex 独立レビュー（plan.sh / gate.sh が内部で使用）

ワーカー操作
  dashboard.sh [sec]    ★戦況板：全ワーカーの状態/直近出力/イベントを1画面でライブ表示
  spawn.sh <w> [br]     ワーカー1体を起動（冪等・worktree＋herdr ペイン）
  worker-run.sh <w>     ペインの中身（資格情報を注入して claude を起動。手動起動にも使える）
  reap.sh <w>           ワーカー完全撤去（※未 land のブランチも消える）
  respawn.sh <w>        詰まったワーカーを assignment 退避付きで即リセット
  assign.sh <w> [--brief ".."] <paths..>   担当領域＋タスク配布
  status.sh             各ワーカーの状態
  overlap.sh            衝突予備軍（複数ワーカーが触るファイル）検出
  review.sh <w>         凍結スナップショットを review/<w> に worktree 展開

検証/統合
  gate.sh <w>           使い捨て worktree で試しマージ＋チェック（exit3=衝突 / exit4=tests/・
                        harness/改ざん / exit6=テストゲーミング block 時）＋ gate.d/ チェック
                        PASS 後に codex レビューを併走（verdict は state/gate/<w>.codex.json）
  ontology-check.sh     memory/ontology/graph.jsonl の決定論検証（AIF 上位オントロジー制約）
  verify.sh <w>         gate 実行→PASS 案内／FAIL は feedback.md へ差し戻し＋催促
                        codex の high 指摘（advise）は exit 7 で有界の feedback ラウンドに変換
  land.sh <w> [--no-verify]   gate 通過後に base へ merge（worktree 共有で伝播は構造的に不要）
  sync.sh --others <w>  land 後に他ワーカーを新 base へ rebase 追従（working 中は退避、衝突は差し戻し）
```

---

## 4つの目標がどう構造で担保されるか

- **#1 止まらない**：ループ＝決定論シェル（許可プロンプト無し）。ワーカー Claude＝skip-permissions
  （ハーネスが柵）。配布は herdr nudge ではなく **SessionStart/Stop フック**で保証（取りこぼし無し）。
  codex・herdr が死んでいてもループは縮退して前進する（CODEX_SKIP / AGENT_UNKNOWN_GRACE）。
  **ハング/無進捗ワーカーは生存性ウォッチドッグが nudge→自動 respawn→ESCALATE で回収**し、
  1 ワーカーの沈黙がゴール全体を止めない（WORKER_TIMEOUT_SECS / WORKER_HANG_GRACE）。クラッシュ後の
  再起動時は `- [~]`（進行中）ゴールを `- [ ]` へ戻して取り零しを防ぐ。
- **#2 並列**：ワーカーは canonical の **git worktree**（refs/objects 共有）。コミット即可視なので
  exchange も push も不要。縦割り（各ワーカーが自分のディレクトリだけ）＋ owned-paths を
  `harness-guard-paths` で**強制**。base は canonical が checkout 済み＝ワーカーは**構造的に**触れない。
- **#3 秘匿**：ディスク上の秘密は常に暗号化（sops+age）。`secret_exec` がスコープ別に 1 プロセス
  へだけ注入。gate/codex の秘密は Claude 非経由。ワーカーには `harness-guard-secrets`（L2）。
  マージ/push は監督独占（実リポジトリへの push は origin push url 無効化で**構造的に**到達不能、
  `harness-guard-git` は `git -C` 等の回避も含む L2 の速度制限）。Bash 経由の worktree 逸脱書き込みは
  `harness-guard-write` が遮断。
- **#4 別の目**：codex が計画と差分を独立レビュー（成果物のみ・思考過程は非共有）。指摘は
  有界の feedback として還流し、暴走はしない（advise 既定・block は opt-in）。

---

## トークンバーンのガードレール（「Go 押すだけ」にならないために）

クローズドループは強力だがトークンを食う。暴走を**構造で**抑える調整値（`config.env`）:

- `MAX_FEEDBACK_ROUNDS`（既定4）… 1 スライスの FAIL→修正の上限。超えたら人間へ ESCALATE。
- `LOOP_MAX_CYCLES`（既定0=無制限）… ループ総サイクルの安全上限。信頼が浅いうちは数値を入れる。
- `GATE_CONCURRENCY`（既定2）… 同時 gate 数の上限（watch.sh。ホスト資源保護）。
- `PLANNER_MAX_SLICES`（既定3）… 1 ゴールを最大何スライスに割るか＝1 ゴールの並列度上限。
- `CODEX_GATE_MAX_ROUNDS`（既定1）… codex 指摘が消費できるラウンドの上限（前掲）。
- **`WORKER_TIMEOUT_SECS`（既定1800）/ `WORKER_HANG_GRACE`（既定300）… ワーカー生存性
  ウォッチドッグ**。ハング・空回り・「一度も commit しない」ワーカーは ref が動かず `BUSY` が
  永久に残ってループが完了しない。無進捗が続いたらまず nudge、なお駄目なら自動 respawn
  （assignment 保持・未 commit の作業のみ破棄）してラウンドを消費、最終的に ESCALATE。0=無効
  （lib.sh 既定は 0＝旧挙動維持、config テンプレが有効化）。

コンテキスト衛生（LLM に渡す文脈の劣化・肥大を構造で防ぐ）:

- **slices.json は決定論的に検証**される（スキーマ／スライス間パスの重複／PROTECTED_PATHS 侵犯）。
  不正な計画はワーカーがトークンを使う前に PLAN_FAIL で弾かれる。
- **`memory/REPO_MAP.md`** … land のたびに canonical から自動再生成される構造マップ（bash 製・
  トークン不要）。計画役は手書きで腐りがちな地図ではなく常に現在のコードの地図を読む。
- `PROGRESS_MAX_LINES` / `PROGRESS_KEEP_LINES`（既定400/200）… PROGRESS.md の自動圧縮。古い
  イベントは件数サマリに畳まれ、ESCALATED / LAND_FAIL（未解決の宿題）は原文のまま残る。
- `FEEDBACK_MAX_LINES`（既定200）… ワーカーへ渡すゲートログの上限（head+tail 蒸留）。
- `CODEX_DIFF_MAX_LINES`（既定4000）… codex に渡す diff の上限（同じ蒸留）。
- 各スライスの `tests` フィールド … 計画役が書いた契約テストのパスが brief に明記され、ワーカーは
  自分の合格基準を探さずに読める。
- **モジュール wiki**（`WIKI_ENABLED=1`）… 各スライスが `wiki/modules/<slice>.md` を所有し、
  **ワーカーが DONE の一部として更新**する。計画役は index＋関連ページを**コード探索より先に**読む。
  `wiki/index.md` は land のたびに frontmatter から bash が自動生成（0 トークン・衝突ゼロ）。
- **PLAN_USAGE 計測** … 計画役 1 回ごとのトークン消費を `PROGRESS.md` に記録。

---

## 受け入れゲートを「効かせる」

gate は既定で **advisory（チェック未設定なら警告のみで通す）**。本気で守らせるには:

1. リポジトリに `harness/check.sh` をコミット（雛形 `control/harness-check.sample.sh`）、または
2. `config.env` の `CHECK_CMD` を設定（例 `CHECK_CMD="npm ci && npm run typecheck && npm test"`）。

`tests/`（`PROTECTED_PATHS`）はワーカー編集不可。改ざんブランチは gate が **exit 4** で land 拒否
（強制点はワーカーの手が届かない監督側に置く）。契約テストの質＝auto-land の安全性。
テストに秘密が要るなら `loop secrets edit gate`（gate プロセスにだけ注入される）。

v3.4 でゲートは 3 点強化された:

- **harness/ 保護**（`GATE_PROTECT_HARNESS=1` 既定）: gate のチェックスクリプトはマージ済み
  ツリーから実行されるため、ワーカーが `harness/check.sh` を書き換えると自分のゲートを無力化
  できてしまう。この経路は exit 4 で構造的に遮断（セキュリティ系 — 剥がさないこと）。
- **テストゲーミング検知**（`GATE_TESTGAMING=warn|block|off`、既定 warn）: 差分に「テストの
  skip 化・無効化」「チェックスクリプトへの `|| true`」等の**検証器を弱める変更**があれば検出。
  warn で運用を始め、誤検知が無ければ block（exit 6）へ昇格させる。検知は PROGRESS
  （TESTGAMING）とオントロジー（CA）にも記録される。
- **gate.d チェック**（`<workspace>/gate.d/*.sh`）: ワークスペース側のゲート拡張シーム
  （手書きでも `loop harness` 由来でも同じ場所・同じ契約）。プロジェクトのチェックに**追加で**
  マージ済みツリー上で実行される。ワークスペース側にあるためワーカーは自分の受け入れ基準に
  触れない（cwd=マージ済みツリー、`GATE_TASK` / `GATE_BRANCH` / `GATE_BASE_BRANCH` /
  `GATE_MERGE_BASE` が渡る）。

**検証器も改訂対象**: 検証器は人間意図の proxy に過ぎず、固定すると劣化する（生成側と共進化
させる）。スライスが ESCALATED すると `state/escalations/` に「実装が悪い/ゲートが悪い」の
両仮説を並べたレビューパケットが書かれる — 契約テストや check.sh の過剰厳格・flaky・仕様外
要求を疑うことも「前進」に数えること。

---

## ハーネスパック（`loop harness`）— 方針を既存シームへ取り込む

プロジェクト導入時に開発方針（アーキテクチャ規律・テスト戦略・知識管理）を**対話で決定**し、
既存のハーネス/ゲートのシームへ「取り込む」。パックは新しい概念ではない — escalation ladder に
元からある L1（skills/・CLAUDE.worker.local.md）/ L2（worker-harness.d/）/ L3（gate.d/）の
部品の束で、手書きの拡張と同じ場所に同じ契約で落ちる。エンジンは編集されない。

```bash
loop harness                # 対話ウィザード（パックを選んで取込）
loop harness list           # 同梱パック一覧
loop harness apply backend-clean-arch frontend-humble-object ontology-aif
loop harness status         # このワークスペースのハーネス/ゲートに何が入っているか
```

パックの設定は `gate.d/*.env`（**これを編集すると強制が発火する**。未設定の間は助言のみ）。
L2 ガードと L3 チェックが同じ設定ファイルを読むため、編集時ブロックとマージ時検査で規則が
食い違うことはない。詳細は `packs/README.md`。

**簡素化原則（when-to-remove）**: ハーネス部品は「モデルが単独でできないこと」への仮定の
符号化であり、新モデル世代ごとに再検証して支えになっていない部品は剥がす。各パックは
frontmatter でいつ再評価すべきかを宣言している。**例外はセキュリティ系ガード**（秘匿・push
遮断・harness/ 保護など敵対的仮定のもの）— これらは能力が上がっても撤去しない。

### 設計 SSOT の直読（Spec Atlas 等の型付き設計データ）

設計を型付きデータ（例: Spec Atlas の `atlas/` — Lean 正本。`Domain/`=語彙と型、`Spec/`=設計
データ本体）で管理している場合、**計画役はそれを直接読む**。エクスポート成果物の取込コピーは
作らない（鮮度の腐った複製は劣化した検証器と同種の害になるため。正本は常に 1 箇所）。

- リポジトリ直下に `atlas/` があれば自動検出。外部の設計リポジトリに置くなら `config.env` の
  `DESIGN_SSOT_DIR=/path/to/design-repo/atlas` でパスを渡す。
- 計画役は毎サイクル最初に語彙/型（Domain/）→ ゴールに関係する Spec/ の順で読み、エンティティ・
  ポート・IO 契約を**実装より上位の正**として扱う（設計と食い違う実装は実装側の誤り。設計変更は
  設計リポジトリ側のフローで行う）。
- `atlas/` を in-repo で持つ場合は `PROTECTED_PATHS` に `atlas/` を足すこと — 設計の変更は
  設計フローの仕事であり、実装ワーカーの仕事ではない。

### イベントオントロジー（AIF 準拠・人手維持ゼロ）

`ONTOLOGY_ENABLED=1`（既定）で、ループのイベントが `memory/ontology/graph.jsonl` に AIF の
論証グラフ（I/RA/CA/PA）として自動蓄積される: gate FAIL・codex 懸念・ゲーミング検知 → CA
（対立）、land・handoff・設計取込 → PA（選好）。**書き手は機械のみ**（手維持の知識構造は腐り、
腐った知識は劣化した検証器と同種の害を生むため）。land ごとに `digest.md` が再生成され、
計画役は「未解決の CA（最後の PA より新しい対立）」を再計画の地雷リストとして読む。
検証は `loop ontology-check`。語彙の拡張は `memory/ontology/forms.md`（forms 層）へ。

---

## ツールキット自体のテスト

```bash
./tests-toolkit/run.sh          # bash -n / shellcheck(任意) / フック契約 / lib 単体（herdr 不要・283 ケース）
./tests-toolkit/e2e-nocreds.sh  # gate/verify/land/sync の全経路 e2e（資格情報・herdr・Docker 全て不要）
```

フックは「stdin JSON → exit code」の純粋な契約なので隔離して回帰検証できる。テストは失敗する
`herdr` シムを PATH に置き、`$HOME` も付け替える——**実サーバや実際の鍵には決して触れない**。
v3 で e2e が CI（GitHub Actions）でも回るようになった（Docker 依存が消えたため）。

---

## カスタマイズの勘所

- ワーカー既定数 → `config.env` の `WORKER_COUNT`。臨時追加は `spawn.sh <name>`。
- モデル → `WORKER_MODEL` / `PLANNER_MODEL` / `SUPERVISOR_MODEL`（前掲の表）。
- ワーカー行動規約 → `control/CLAUDE.worker.md`（助言L1・全プロジェクト共通）。破られ続けた
  ものだけフック/構造テストへ昇格。
- ガードの強制点 → `control/worker-harness/`（L2 フック）と gate（L3）。「絶対に守らせたい」は
  プロンプトではなくここに足す。
- **プロジェクト固有の制約はワークスペース側に置く**（v3.1。エンジンは汎用のまま、制約は外部）:
  - `<workspace>/CLAUDE.worker.local.md` … 助言 L1。spawn 時にワーカーの CLAUDE.md へ追記される。
  - `<workspace>/worker-harness.d/` … 実行可能ファイルを置くと L2 の PreToolUse ガードとして
    全ツール呼び出しに合成される。契約はエンジンのフックと同一（stdin に JSON →
    exit 0=許可 / 2=ブロック、stderr がワーカーへ表示）。`.tool_name` の絞り込みはガード自身が行う。
  - escalation ladder はプロジェクト単位で完結する: local.md で始め、破られ続けたら
    worker-harness.d/ のガードに昇格。**エンジンを編集する必要はない**。
- codex のモデル/閾値 → `CODEX_MODEL` / `SECOND_OPINION_*`（前掲の表）。

## Claude Code 組み込み worktree 機能との関係（v3.1）

Claude Code 自身にも並列用の worktree 機構がある（`claude -w <name>` → `.claude/worktrees/`、
サブエージェントの `isolation: worktree`、`EnterWorktree` ツール）。本テンプレートとの関係:

- **ワーカーの隔離はエンジン管理の git worktree のまま**。これは Claude Code 公式ドキュメントが
  サポートする「外部で作った worktree に cd して claude を起動する」パターンそのものであり、
  その上にだけ載る保証がある（owned-paths ガード・ref 監視による完了検知・base ブランチの
  checkout 不能・land/sync の分業）。組み込み機構に置き換えるとブランチ命名（`worktree-<name>`）
  とセッション終了時の自動削除がループの契約と衝突する。
- **ワーカーからは組み込み worktree ツールを遮断**（`harness-guard-worktree`）。`EnterWorktree`
  で自分の箱の外へ出る・サブエージェントが共有リポジトリに `worktree-*` ブランチを撒く、を
  フックで決定論的に拒否する（Bash ガードの `git worktree` 遮断のネイティブツール版）。
- **監督と君自身は自由に使ってよい**。`loop supervise` の監督 Claude や、プロジェクト側で君が
  開く `claude -w` セッションはループと衝突しない（`loop here` 運用ではワーカーはプロジェクトとは
  別クローン＝canonical の worktree で動くため、名前空間が構造的に分離されている）。

## v2.2 からの移行

```bash
# 1) エンジン更新後、各ワークスペースで:
loop secrets init
loop secrets migrate --yes      # secret.env → secret.worker.sops.env / secret.gate.env → gate（平文は破棄）
loop down --purge               # 旧コンテナ資産の掃除は手動: docker rm -f $(docker ps -aq --filter name=cw-) など
loop setup && loop up           # worktree 方式で再スポーン
```

- **broker は廃止**。ネットワーク隔離（--internal bridge）が無いホスト実行では「プロキシで鍵を
  隠す」保証が成立しないため（プロセスは外に出放題）。テスト時秘密は gate スコープで代替し、
  ワーカーには「秘密は渡らない」規約のまま。将来 `SECRET_BACKEND=op` 側の拡張として再検討する。
- 旧 exchange bare repo / push-event / pre-receive/post-receive も廃止（worktree の refs 共有が
  同じ役割を構造的に果たす）。v2.2 が必要なら git タグ/履歴から取り出せる。

## 実運用で判明した不具合と対策

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

### v3.3 ハーネス堅牢化（失敗系・生存性の穴を塞ぐ）

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

### v3.4 ハーネスパック + 検証器強化（直近研究の反映）

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

