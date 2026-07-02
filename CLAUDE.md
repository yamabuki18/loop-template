# loop-template — 開発ガイド（このリポジトリ自体を改修するときに読む）

自律開発ループのテンプレート（エンジン）。**ホスト側は決定論的な bash のみ**が動き、知能
（計画・実装）は使い捨て Docker コンテナ内の Claude に委譲する設計。運用者向けドキュメントは
`loop/README.md`（日本語）。ここは「エンジンを開発する側」のための地図。

## レイアウト

```
loop/
  bin/loop            薄い CLI ディスパッチャ（init/update/version + control/*.sh へ転送）
  control/            エンジン本体（全 bash スクリプト + Dockerfile + フック）
    lib.sh            共有ライブラリ。全スクリプトが source する。パス解決の唯一の起点
    loop.sh           完全自律オーケストレータ（心拍）。watch.sh は半自律版
    plan.sh           ヘッドレス計画役 Claude（コンテナ）を回し slices.json を得る
    gate.sh           受け入れゲート（クリーンコンテナで試しマージ+チェック）
    worker-harness/   ワーカーコンテナ内の Claude Code フック（決定論ガード）
    hooks/            exchange bare repo の pre/post-receive
  skills/ memory/     プロジェクト知識のテンプレ（VISION/ARCHITECTURE/RULES, backlog/PROGRESS）
  tests-toolkit/      Docker 不要の回帰テスト（フック契約 + bash -n + shellcheck）
```

## テスト（改修したら必ず回す）

```bash
bash loop/tests-toolkit/run.sh    # Docker 不要・数秒で終わる
```

フックは「stdin に JSON → exit code（0=許可, 2=ブロック）」の純粋な契約。テストはこの契約を
直接叩く。`control/` を触ったら run.sh を通してから完了とすること。

## 罠と規約（守らないと過去のバグが再発する）

- **`lib.sh` は `set -euo pipefail` を有効化する。** source した側の script 内で
  「失敗しうるコマンド」は必ず `if` / `||` で包む。裸のパイプライン失敗が -e で
  スクリプトごと殺し、FAIL 処理経路が死んだ前例がある（verify.sh の D1 コメント参照）。
- **D1〜D11 のコメントは過去バグの回帰防止点。** 該当行を変更するときはコメントの理由を
  読み、テストが固定していることを確認してから。
- **パス解決は 2 モードある**（lib.sh 冒頭）:
  - legacy: `control/` の親 = プロジェクトルート、config/secret は `control/` 直下
  - workspace: `.loop-workspace` マーカーを持つディレクトリ = payload、エンジンは中央設置
  スクリプトは `$ROOT` `$CONFIG_DIR` `$CONTROL_DIR` を必ず経由し、相対パスを直書きしない。
- **強制点はワーカーの手が届かない側に置く**（escalation ladder）: 助言は
  `CLAUDE.worker.md`(L1)、クライアントフック(L2)、ホスト側 gate / pre-receive(L3/L4)。
  「絶対に守らせたいルール」をプロンプトに足すのは誤り。ハーネス/gate に足す。
- **コンテナの `dev` ユーザは host uid と一致が必須**（bind-mount 書き込み）。Dockerfile の
  `HOST_UID` build-arg を経由し、setup.sh が `$(id -u)` を渡す。
- スクリプト内コメントは英語、運用ドキュメント（README 等）は日本語。

## 秘匿モデル（変更時に壊しやすい不変条件）

- ワーカー/計画役コンテナにはホストの `$HOME`・SSH 鍵・`/mnt/c` を**一切マウントしない**。
  渡してよいのは: 自分の exchange bare repo、`cred_docker_args()` が選んだ 1 つの資格情報のみ。
- `secret.gate.env` は gate コンテナ（Claude なし）専用。ワーカーには決して渡さない。
- 新しいマウントや `-e` を足すときは、この不変条件を破っていないか必ず確認する。
