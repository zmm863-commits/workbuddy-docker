#!/usr/bin/env bash
# 健康检查：用 Basic 认证探测远程桌面是否可访问
# 密码来自 state/vnc-password.txt（entrypoint 每次启动都会写入）
set -euo pipefail
user="${VNC_USER:-root}"
pass="$(cat /opt/wb/state/vnc-password.txt 2>/dev/null || echo x)"
exec curl -fsS -u "${user}:${pass}" "http://127.0.0.1:${KASM_PORT:-8444}/" >/dev/null
