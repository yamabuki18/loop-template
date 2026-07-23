# loop — 自律開発ループ・テンプレート (v3)

「プロンプトを書くな、ループを書け」を実運用に落とすための汎用テンプレート。
ホスト側は**決定論的なシェルだけ**が動き、知能が要る作業（計画・実装）は **git worktree 上の
使い捨て Claude プロセス**に委譲する。v3 で Docker と tmux を全廃し、多重化は
[herdr](https://herdr.dev)、検証には **Codex によるセカンドオピニオン**（独立並行評価）を
加えた。秘密はスコープ別の平文 env ファイル（gitignore 済み・プロセス単位で注入）。

1. **許可待ちで止まらない** — ループ本体に対話 Claude は常駐しない（プロンプトを出す相手がいない）。
   ワーカー Claude は `--dangerously-skip-permissions`（フックのハーネスが柵）。
2. **herdr + git worktree で並列稼働** — 監督1（=このシェル）＋ワーカー複数を並走。herdr が各
   エージェントの状態（idle/working/blocked）をネイティブ検知し、ループの完了シグナルになる。
3. **認証情報のスコープ分離** — 秘密はスコープ別（worker/gate/codex）の平文 env ファイル
   （gitignore 済み）。値は `secret_exec` が「その値を必要とする 1 プロセスの env」にだけ
   注入する。gate/codex 用の秘密が Claude プロセスに入ることは構造上ない。
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

## クイックスタート（エンジン中央インストール — これが標準）

エンジン（このリポジトリ）をマシンに**一度だけ**置き、各プロジェクトは薄い「ワークスペース」
（config.env / secrets / skills / memory / 実行時 state）だけを持つ。バグ修正・改善は
`loop update`（= エンジンで `git pull`）一発で**全プロジェクトに即反映**される。

```bash
# 0) 前提：git / jq / claude CLI / herdr。Linux ネイティブパス推奨（/mnt/c は避ける）
#    herdr : curl -fsSL https://herdr.dev/install.sh | sh

# 1) エンジンを一度だけインストール
git clone <this-repo> ~/.loop/loop-template
ln -s ~/.loop/loop-template/loop/bin/loop ~/.local/bin/loop   # PATH の通った場所へ
loop doctor                            # 前提を自己診断

# 2) プロジェクトごとにワークスペースを作る
loop init ~/dev/myproject [repo-url]   # PROJECT_NAME はディレクトリ名から自動設定
cd ~/dev/myproject
$EDITOR config.env
$EDITOR secret.worker.env              # claude setup-token のトークンを貼る（平文・gitignore 済み）
$EDITOR skills/VISION.md skills/ARCHITECTURE.md skills/RULES.md
loop setup                             # canonical 作成（イメージビルド無し・数秒）
$EDITOR memory/backlog.md && loop up   # ゴールを書いて起動。以降 loop status / verify / land ...

# 3) エンジン更新（全ワークスペースに共通適用）
loop update                            # 固定したければエンジン側で git checkout <tag>
```

- ワークスペースは `.loop-workspace` マーカーで検出される（`LOOP_PROJECT` 環境変数でも明示可）。
  `spawn.sh` が herdr ペインに `LOOP_PROJECT` を注入するので、ペイン内のコマンドも正しく束縛される。
- `loop <cmd>` は `control/<cmd>.sh` への転送（`loop run` = loop.sh、`loop doctor` = doctor.sh）。
- `loop doctor` がエンジンのバージョンと動作モード（workspace / legacy）を表示する。

### 既存リポジトリに 0 ファイルで使う（`loop here` — 日々の開発への適用）

普段の開発リポジトリにループを使いたいが、**リポジトリに一切ファイルを増やしたくない**場合の
運用。ワークスペースはプロジェクトの**外**（`$LOOP_HOME/workspaces/<パスのスラッグ>/`、
既定 `~/.loop`）に置かれ、成果は**ブランチとして**還流する。作業ツリーには何も書かない。

```bash
cd ~/dev/myproject
loop here            # 一度だけ: 外置きワークスペースを作成し、このパスに紐付ける
$EDITOR ~/.loop/workspaces/<slug>/secret.worker.env   # 一度だけ: トークンを貼る（平文）
loop setup           # canonical をローカル repo からクローン（数秒）
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

### レガシー経路（クローン内で直接動かす / 丸ごとコピー）

エンジンを中央に置かず、このリポジトリのクローン内でそのまま回すこともできる（`bash
./control/setup.sh [repo-url]` → `./control/up.sh`。コマンドは全て `./control/<cmd>.sh` 直叩き）。
別ディレクトリへの丸ごとコピー展開は `./control/scaffold.sh <dir> [repo-url]`。**どちらも
エンジン更新（`loop update`）が伝播しないレガシー**であり、scaffold は再実行不可（既存の
control/ 等があれば拒否する）。新規導入は上の中央インストールを使うこと。

---

## 秘密情報の管理（スコープ別の平文 env ファイル）

秘密は**スコープ別の平文 env ファイル**で管理する（v3.7 で sops+age の暗号化層を撤去し、
運用を単純化した）。ファイルは gitignore 済みで、`init`/`setup` が空テンプレートを seed する。
**残る不変条件はスコープ分離**: 各ファイルの値は、それを必要とする 1 プロセスの env にだけ
注入され、ループ本体のシェルには決して載らない。

| スコープ | ファイル | 中身 | 値が入るプロセス |
|----------|----------|------|------------------|
| `worker` | `secret.worker.env` | `CLAUDE_CODE_OAUTH_TOKEN` または `ANTHROPIC_API_KEY` | ワーカー/計画役の **claude プロセスのみ** |
| `gate`   | `secret.gate.env`   | テスト用 DB URL・試験キー等 | **決定論チェックのみ**（Claude には決して入らない） |
| `codex`  | `secret.codex.env`  | `OPENAI_API_KEY`（`codex login` 派は不要） | codex プロセスのみ |

```bash
$EDITOR <workspace>/secret.worker.env   # トークンを貼るだけ。chmod 600 推奨
loop doctor                             # スコープごとの有無・パーミッション・auth モードを表示
```

- 注入は `lib.sh` の `secret_exec <scope> -- cmd`。スコープファイルをサブシェルで allexport
  読みして `sh -c` へ再 exec する — **そのコマンドの子プロセス env にだけ**値が入る。
  ファイルが無い/空のスコープは素のまま実行される（エラーにはならない）。
- **課金の優先順位（v2.2 から継続）**: `ANTHROPIC_API_KEY` が見えると従量 API が必ず勝つ。
  worker スコープでは OAuth トークンがある場合 API キーを**子環境内で自動 unset** する。
- worker スコープが未設定の場合の**ホストログイン・フォールバック**: `~/.claude` にログイン済み
  なら spawn がその資格情報をワーカーの隔離 config にコピーして動かす（doctor が `auth = host`
  と表示）。手軽だが**個人アカウントの資格情報**なので、常用するなら `claude setup-token` +
  worker スコープへ。
- **絶対にコミットしないこと**。ワークスペースの `.gitignore`（`secret.*.env`）が唯一の防壁。
  この行を外してはならない。

### 脅威モデル（正直に）

v2 の Docker は「ワーカーからホスト FS が**物理的に**見えない」壁（L3）だった。v3 のワーカーは
ホストプロセスであり、その壁は無い。さらに v3.7 で暗号化 at rest も撤去した（単純さとの
トレードオフ）: **ディスク上の秘密は平文**であり、ホストの読める者・プロセスからは読める。
残る現実的な保証は:

- **スコープ別最小権限**: gate/codex の秘密は**どの Claude プロセスにも入らない**。ワーカー資格
  情報は v2.2 と同様「ワーカー自身のプロセス env」には見える（`-e` 注入と同等）。
- **L2 ガード（`harness-guard-secrets`、v3 で必須化）**: secret ファイル（平文化した今こそ
  最重要の遮断対象）・`~/.ssh`・`~/.claude`・`~/.codex`・env ダンプ（`env`/`printenv`/`set`/
  `/proc/*/environ`）・鍵ツール類の起動をフックで遮断。**ただしフックは決意した攻撃者への
  完全な壁ではない**（コンパイル済みバイナリや `os.environ` など側路はある）。
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
  ワークスペースの `secret.codex.env` に `OPENAI_API_KEY` を設定。
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
5. **監督専用スキル**（`control/supervisor-skills/`）が監督セッションの
   `CLAUDE_CONFIG_DIR/skills/` へ毎回同期される。同梱: `test-architecture-design`
   （論理的機能構造×重篤度×テストサイズでテストケースを導出する手法。plan mode で
   テスト設計表を計画本文に含めて承認 → handoff すれば、計画役がその設計に沿って契約
   テストを切る）。planner / worker には**配布されない** — 設計は対話で行い、成果物
   （計画）だけがループへ流れる
6. 追加引数は claude へ素通し: `loop supervise -- --continue`

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
  bin/loop <cmd>        中央インストール用 CLI（here / init / update / version / 転送）
  here.sh               ★カレントのプロジェクトに zero-footprint で紐付け（= loop here）
  secret.<scope>.env    秘密はワークスペース直下の平文 env（worker / gate / codex。gitignore 済み。
                        init/setup が空テンプレートを seed — エディタで直接編集する）
  publish.sh            land 済み成果をプロジェクトへ loop/<base> ブランチとして push
  refresh.sh            プロジェクトの新コミットをループの base へ ff 取り込み
  workspaces.sh         紐付け済み全プロジェクトの一覧（backlog・ワーカー数）
  init.sh <dir> [repo]  ワークスペース作成（= loop init。エンジンは中央に留まる）
  harness.sh [sub]      ★方針パックをハーネス/ゲートへ取込（= loop harness。wizard / list /
                        apply <pack>... / status）
  doctor.sh [--quick]   前提検査・自己診断（herdr/codex・secrets/auth・孤児検出・エンジン ver）
  setup.sh [repo]       初回初期化（canonical 作成・BASE_BRANCH 検証・secret テンプレ seed）
  up.sh                 冪等な日次起動（herdr workspace＋ワーカー＋loop/dashboard ペイン）
  down.sh [--purge]     停止（--purge で worktree/ブランチ/state も破棄。サーバは残す）
  scaffold.sh <dir>     別プロジェクトへテンプレ展開／ --install-host-guard

ループ
  loop.sh               ★完全自律オーケストレータ（心拍）
  supervise.sh          ★対話監督モード（= loop supervise。watch ペイン＋監督 Claude を起動）
  supervisor-skills/    監督セッション専用スキル（test-architecture-design 等。planner/worker
                        には非配布 — 設計は対話、成果物の計画だけがループへ）
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
  ontology-check.sh     memory/ontology/graph.jsonl の決定論検証（AIF 上位オントロジー制約。
                        land ごとの digest 再生成時に自動実行 — 違反は ONTOLOGY_INVALID 警告）
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
  再起動は**割当台帳**（state/loop-active.json、遷移ごとに永続化）から進行中ゴール・キュー・
  実装中スライスを**復元**する（再計画・再割当で実装中ワーカーを潰さない）。台帳の無い孤児
  `- [~]` ゴールだけ `- [ ]` へ戻して取り零しを防ぐ。backlog のマークは
  `[ ]`=未着手 / `[~]`=進行中 / `[x]`=完了 / **`[!]`=全スライスがエスカレートし人間レビュー待ち**
  （state/escalations/ を見る。`[x]` に偽装しない）。
- **#2 並列**：ワーカーは canonical の **git worktree**（refs/objects 共有）。コミット即可視なので
  exchange も push も不要。縦割り（各ワーカーが自分のディレクトリだけ）＋ owned-paths を
  `harness-guard-paths` で**強制**。base は canonical が checkout 済み＝ワーカーは**構造的に**触れない。
- **#3 秘匿**：秘密はスコープ別の平文 env ファイル（gitignore 済み）。`secret_exec` がスコープ別に
  1 プロセスへだけ注入。gate/codex の秘密は Claude 非経由。ワーカーには `harness-guard-secrets`（L2）。
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

### 使用量ガード（`USAGE_GUARD` — プランの窓を見ながら艦隊を運転する）

Claude サブスクリプションの制限は**5 時間のローリング窓 + 7 日窓**の 2 本で、同一アカウントの
全サーフェス（全ワーカー・claude.ai・手元の Claude Code）が**同じ窓を共有**する。だからペース
配分はワーカーではなく**ループの仕事**。`USAGE_GUARD=1`（テンプレ既定）で loop.sh が毎サイクル:

```
利用率 < 80%           → 通常運転
5h窓 ≥ USAGE_PAUSE_PCT → DRAIN: 進行中スライスは完走して land（トークンは既に沈没費用）、
  (既定80%)               新規の計画・アサインは停止
全員完了 or 100%到達    → PAUSE: resets_at + マージンまで停止（PROGRESS: USAGE_PAUSE + 通知）
窓リセット後           → 自動再開トリガー: 生プローブで確認 → USAGE_RESUME + 通知 +
                         進行中ワーカー全員へ nudge（「窓が回復した。続きを実装して commit」）
```

- **情報源**: Claude Code の `/usage` HUD と同じ OAuth 使用量エンドポイント
  （`GET api.anthropic.com/api/oauth/usage`、worker スコープのトークンを `secret_exec` 経由で
  注入 — ループのシェルは秘密を見ない）。**非公式 API** なのでガードは全経路 fail-open —
  プローブが壊れたら「ガード無し」に縮退するだけで、ループは絶対に止まらない。
- エンドポイント自体がレート制限されるため、プローブは `USAGE_POLL_SECS`（既定300s）で
  キャッシュされ、`User-Agent: claude-code/<ver>` を必ず付ける（無いと恒常 429）。
- **7 日窓**も監視する（`USAGE_WEEKLY_PAUSE_PCT`、既定95%）。こちらで止まると再開は数日後に
  なりうる — 通知が飛ぶので気づける。100 にすれば「完全枯渇時のみ反応」。
- **watchdog との干渉を解消済み**: リミット中のワーカーは「無進捗」に見えるが、respawn しても
  何も変わらずラウンドを浪費するだけ。watchdog の respawn 直前に生プローブし、窓の枯渇が原因
  なら respawn ではなく pause に切り替える（再開 nudge で同じセッションが文脈ごと続きから動く）。
- 対象は loop.sh（完全自律）のみ。`loop supervise` / watch.sh は人間が居る前提なので対象外。
- `USAGE_PROBE_CMD` でプローブを差し替え可能（テスト・API キー課金・独自モニタ連携用。
  出力契約: `"<5h%> <5hリセットepoch> <7d%> <7dリセットepoch>"` または `none`）。

---

## 受け入れゲートを「効かせる」

gate は既定で **advisory（チェック未設定なら警告のみで通す）**。本気で守らせるには:

1. リポジトリに `harness/check.sh` をコミット（雛形 `control/harness-check.sample.sh`）、または
2. `config.env` の `CHECK_CMD` を設定（例 `CHECK_CMD="npm ci && npm run typecheck && npm test"`）。

`tests/`（`PROTECTED_PATHS`）はワーカー編集不可。改ざんブランチは gate が **exit 4** で land 拒否
（強制点はワーカーの手が届かない監督側に置く）。契約テストの質＝auto-land の安全性。
テストに秘密が要るならワークスペースの `secret.gate.env` へ（gate プロセスにだけ注入される）。

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
  `GATE_MERGE_BASE` が渡る）。失敗は exit 1（または 10 以上）で返すこと — **3/4/6 は gate.sh
  の予約値**（衝突/protected/test-gaming）。
- **F2P プリフライト**（`F2P_CHECK_CMD`、既定 off）: 「テストファイルを 1 つ実行するコマンド」
  を設定すると、planner の新規契約テストがコミット前に**現行 base 上で実行され、fail すること**
  を機械検証する。base で既に通るテストは何も規定しておらず、永遠に通らないテストはワーカーの
  ラウンドを全部燃やしてから発覚する — どちらもここで弾く。
- **verify→land の鮮度トークン**: verify PASS 時に (base, branch) の sha 対を記録し、両方が
  不変なら land の再ゲートをスキップする（半自律モードの二重ゲート解消。新コミット・rebase・
  他スライスの land があれば自動的に無効化され再ゲートする）。

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
loop harness apply /path/to/my-pack   # 外部産パック（pack spec v1）をパスで取込
loop harness status         # このワークスペースのハーネス/ゲートに何が入っているか
```

パックの設定は `gate.d/*.env`（**これを編集すると強制が発火する**。未設定の間は助言のみ）。
L2 ガードと L3 チェックが同じ設定ファイルを読むため、編集時ブロックとマージ時検査で規則が
食い違うことはない。詳細は `packs/README.md`。

**外部産パックの取り込み（pack spec v1）**: パック形式は交換形式でもある。他リポジトリで
作ったパック（ホスト全体スキル `loop-pack-author` で書き起こせる）は `apply <ディレクトリ>`
で取り込む。外部産には frontmatter 契約（enforces / when-to-remove 必須、origin / requires
推奨）と、L2 ガード 1 つにつき 1 ケース以上の selftest（stdin fixture → 期待 exit）が要求され、
**インストール前に**ステージ実行して契約違反なら取り込み中止。外部の lint ツール等はツール
本体を元リポジトリに残し、パックは薄いラッパーだけを運ぶ（「検査不能」を緑にしない規約を
含め `packs/README.md` 参照）。

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
検証は digest 再生成のたび（= land ごと）に**自動実行**され、違反は PROGRESS に
`ONTOLOGY_INVALID` として警告される（advisory — ループは止めない）。手動検査は
`loop ontology-check`。語彙の拡張は `memory/ontology/forms.md`（forms 層）へ。

---

## ツールキット自体のテスト

```bash
./tests-toolkit/run.sh          # bash -n / shellcheck(任意) / フック契約 / lib 単体（herdr 不要。件数は総括行が正）
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
mv secret.env secret.worker.env # v2.2 の secret.env は改名するだけ（secret.gate.env は同名のまま）
loop down --purge               # 旧コンテナ資産の掃除は手動: docker rm -f $(docker ps -aq --filter name=cw-) など
loop setup && loop up           # worktree 方式で再スポーン
```

- **v3.7 で sops+age を撤去**。旧 `secret.*.sops.env` を使っていた場合は一度 `sops decrypt` して
  平文の `secret.<scope>.env` に書き出す（脅威モデルの節を読んだ上で）。
- **broker は廃止**。ネットワーク隔離（--internal bridge）が無いホスト実行では「プロキシで鍵を
  隠す」保証が成立しないため（プロセスは外に出放題）。テスト時秘密は gate スコープで代替し、
  ワーカーには「秘密は渡らない」規約のまま。
- 旧 exchange bare repo / push-event / pre-receive/post-receive も廃止（worktree の refs 共有が
  同じ役割を構造的に果たす）。v2.2 が必要なら git タグ/履歴から取り出せる。


## 変更履歴

バージョンごとの変更点と「実運用で判明した不具合→対策」の記録は [`CHANGELOG.md`](CHANGELOG.md) へ
分離した。現行仕様の正は本 README、経緯を遡るときだけ CHANGELOG を読む。エンジン開発時の
回帰防止規約はリポジトリ直下の `CLAUDE.md`。
