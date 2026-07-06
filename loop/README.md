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
  （canonical が checkout 中という git の構造的制約）、`git push` 全面遮断（フック）。

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
| **半自律** | `./control/watch.sh` | コミット検知で gate 自動実行・FAIL は自動差し戻し。**land は人間**が判断（`land.sh`） |
| **手動** | `assign.sh`→`verify.sh`→`land.sh` | 1 ステップずつ。デバッグ・初期の信頼構築向け |

`loop.sh` と `watch.sh` は**同時に動かさない**（両方が gate を駆動して競合する）。

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
  doctor.sh [--quick]   前提検査・自己診断（herdr/sops/age/codex・孤児検出・エンジン ver）
  setup.sh [repo]       初回初期化（canonical 作成・BASE_BRANCH 検証・secrets init）
  up.sh                 冪等な日次起動（herdr workspace＋ワーカー＋loop/dashboard ペイン）
  down.sh [--purge]     停止（--purge で worktree/ブランチ/state も破棄。サーバは残す）
  scaffold.sh <dir>     別プロジェクトへテンプレ展開／ --install-host-guard

ループ
  loop.sh               ★完全自律オーケストレータ（心拍）
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
  gate.sh <w>           使い捨て worktree で試しマージ＋チェック（exit3=衝突 / exit4=tests/改ざん）
                        PASS 後に codex レビューを併走（verdict は state/gate/<w>.codex.json）
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
- **#2 並列**：ワーカーは canonical の **git worktree**（refs/objects 共有）。コミット即可視なので
  exchange も push も不要。縦割り（各ワーカーが自分のディレクトリだけ）＋ owned-paths を
  `harness-guard-paths` で**強制**。base は canonical が checkout 済み＝ワーカーは**構造的に**触れない。
- **#3 秘匿**：ディスク上の秘密は常に暗号化（sops+age）。`secret_exec` がスコープ別に 1 プロセス
  へだけ注入。gate/codex の秘密は Claude 非経由。ワーカーには `harness-guard-secrets`（L2）。
  マージ/push は監督独占（`harness-guard-git` が全 push・ref 手術・worktree 操作を遮断）。
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

---

## ツールキット自体のテスト

```bash
./tests-toolkit/run.sh          # bash -n / shellcheck(任意) / フック契約 / lib 単体（herdr 不要・143 ケース）
./tests-toolkit/e2e-nocreds.sh  # gate/verify/land/sync の全経路 e2e（資格情報・herdr・Docker 全て不要）
```

フックは「stdin JSON → exit code」の純粋な契約なので隔離して回帰検証できる。テストは失敗する
`herdr` シムを PATH に置き、`$HOME` も付け替える——**実サーバや実際の鍵には決して触れない**。
v3 で e2e が CI（GitHub Actions）でも回るようになった（Docker 依存が消えたため）。

---

## カスタマイズの勘所

- ワーカー既定数 → `config.env` の `WORKER_COUNT`。臨時追加は `spawn.sh <name>`。
- ワーカー行動規約 → `control/CLAUDE.worker.md`（助言L1）。破られ続けたものだけフック/構造テストへ昇格。
- ガードの強制点 → `control/worker-harness/`（L2 フック）と gate（L3）。「絶対に守らせたい」は
  プロンプトではなくここに足す。
- codex のモデル/閾値 → `CODEX_MODEL` / `SECOND_OPINION_*`（前掲の表）。

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
