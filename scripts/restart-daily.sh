#!/usr/bin/env bash
# 每天定时重启一次，清掉 Electron 长跑可能积累的内存/句柄
# 放进极空间「计划任务」里执行（每天 04:00），或自己 crontab：
#   0 4 * * * /路径/scripts/restart-daily.sh >> /tmp/workbuddy-restart.log 2>&1
set -euo pipefail
NAME="${1:-workbuddy-client}"
echo "$(date '+%F %T') 重启 $NAME"
docker restart "$NAME"
