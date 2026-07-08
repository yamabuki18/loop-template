# v3 手動スモーク手順（herdr 実機・1回だけ通す）

自動テスト（run.sh / e2e-nocreds.sh）が固定できない「実 herdr・実 Claude」の結合点を検証する
チェックリスト。v3 の外部依存で最もリスクが高いのは **(A) CLAUDE_CONFIG_DIR の onboarding
pre-seed が効くか** と **(B) `agent_send` の Enter 送出が Claude TUI に確実に届くか** の 2 点。

## 準備

```bash
mkdir -p /tmp/smoke-proj && cd /tmp/smoke-proj && git init -b main
echo hi > readme.md && git add -A && git commit -m init
loop here && loop secrets init && loop secrets edit worker   # OAuth トークンを設定
loop setup && loop doctor                                    # 全項目 ok/warn を確認
```

## チェックリスト

1. **up**: `loop up` → herdr にアタッチされ、`loop`（loop.sh が入力済み・未実行）と
   `dashboard`（戦況板が描画）と `w1..w3` のペインが並ぶ。
2. **(A) onboarding pre-seed**: 各 wN ペインで Claude が**ダイアログ無しで**プロンプトに
   到達している（テーマ選択・trust ダイアログ・bypass 警告が出ない）。
   - ✗ の場合: `spawn.sh` の `.claude.json` seed が効いていない。フォールバック:
     `worker-run.sh` を `claude --settings "$CLAUDE_CONFIG_DIR/settings.json"` 起動に変更し、
     HOME を退避する方式を検討（計画済みの代替、CLAUDE.md 参照）。
3. **(B) nudge**: `loop assign w1 --brief "create src/hello.txt containing hi" src/` →
   w1 ペインに指示文が入力され**送信までされる**（❯ に残らない）。
   - ✗ の場合: `lib.sh agent_send` の sleep/Enter 送出を調整（`herdr pane run` 方式に切替可）。
4. **コミット可視**: w1 が実装後、`git -C ~/.loop/workspaces/<slug>/canonical log work/w1`
   にコミットが見える（push 不要の確認）。
5. **フック 3 種**: w1 の Claude に以下を頼み、全てブロックされることを確認:
   - `git push origin HEAD` → HARNESS ブロック（全 push 遮断）
   - `tests/x.txt` の作成 → 保護パス
   - `/tmp/x` への書き込み → worktree 外
   - `cat ~/.config/sops/age/keys.txt` → guard-secrets
6. **FAIL→PASS ループ**: canonical に失敗する `harness/check.sh` をコミット →
   `loop verify w1` → FAIL で `state/workers/w1/harness/feedback.md` が書かれ w1 が再着手。
   check を通る状態にして `loop verify w1` → PASS → `loop land w1` → base 前進 →
   `loop sync --others w1`。
7. **agent 状態**: `loop status` の STATE 列が w1 の作業中 `working` / 完了後 `idle` を反映。
8. **loop 完走**: backlog にゴール 1 行を書き、loop ペインで Enter → PLAN → ASSIGN →
   VERIFY → LANDED → GOAL_DONE → LOOP_DONE まで人手ゼロで到達。`loop publish` で
   プロジェクトに `loop/main` が現れる。
9. **codex（導入済みの場合）**: `codex login` 後にゴールをもう 1 本 → PROGRESS に
   CODEX_VERDICT（または未導入なら CODEX_SKIP）が出る。
10. **down/up 再開**: `loop down` → `loop up` でワーカーが同じブランチのまま復帰。
    `loop down --purge` 後、`git -C canonical worktree list` が canonical 1 行だけになり、
    プロジェクト repo は無傷。

## 結果記録

| # | 項目 | 結果 | 備考 |
|---|------|------|------|
| 2 | onboarding pre-seed | ☐ | |
| 3 | agent_send Enter | ☐ | |
| 8 | loop 完走 | ☐ | |
