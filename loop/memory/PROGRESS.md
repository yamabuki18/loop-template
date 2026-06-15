# PROGRESS — ループの外部記憶（append-only 日誌）

> `loop.sh` / `watch.sh` が land・fail・escalation のたびに**追記**する機械可読＋人可読の履歴。
> 計画役Claudeは毎サイクル冒頭でここを読み、「何が通ったか・何が残っているか・何で詰まったか」を
> 踏まえて次の分解を行う。これが無いとループは毎回ゼロから始まる（temp.md ビルディングブロック⑥）。
>
> 形式（1イベント1行・TSV風）:
>   <UTC時刻>  <EVENT>  <task/slice>  <branch@sha>  <備考>
> EVENT: PLANNED | ASSIGNED | GATE_PASS | GATE_FAIL | LANDED | ESCALATED | GOAL_DONE

## Log
<!-- loop.sh がこの行より下に追記する。手で消さないこと。 -->
