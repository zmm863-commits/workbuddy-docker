#!/usr/bin/env bash
# 同时推送到两个远端（需先配置 origin=GitHub、gitee=Gitee）
#   git remote add origin https://github.com/zmm863-commits/workbuddy-docker.git
#   git remote add gitee  https://gitee.com/paopaocat/workbuddy-docker.git
set -euo pipefail
cd "$(dirname "$0")/.."
for r in origin gitee; do
  if git remote get-url "$r" >/dev/null 2>&1; then
    echo "→ 推送到 $r"
    git -c http.lowSpeedLimit=0 -c http.lowSpeedTime=0 push "$r" main
  else
    echo "跳过 $r（未配置）"
  fi
done
