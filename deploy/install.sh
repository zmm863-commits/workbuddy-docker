#!/usr/bin/env bash
# ------------------------------------------------------------
# WorkBuddy 容器 · 一键安装（极空间 / 群晖 / 任意 Linux）
#
#   bash install.sh                       就地安装到当前（或部署包）目录
#   bash install.sh /任意/目录            安装到指定目录
#   bash install.sh --password 'MyPass'   指定访问密码
#   bash install.sh --start               装完直接 docker compose up -d
#
# 设计：不猜平台路径。只认「参数给的目标目录」或「脚本所在/当前目录」；
# compose 用相对路径（./home、./inbox 等），所以换谁、放哪都不用改文件。
# ------------------------------------------------------------
set -Eeuo pipefail

TARGET=""
START=0
PASSWORD="iloveppcat"      # 预置密码
PASSWORD_EXPLICIT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --start)       START=1; shift ;;
    --password)    PASSWORD="${2:-}"; PASSWORD_EXPLICIT=1; shift 2 ;;
    --password=*)  PASSWORD="${1#*=}"; PASSWORD_EXPLICIT=1; shift ;;
    -h|--help)     sed -n '2,12p' "$0"; exit 0 ;;
    -*)            echo "[install] 未知参数：$1" >&2; exit 1 ;;
    *)             TARGET="$1"; shift ;;
  esac
done

log() { echo "[install] $*"; }
die() { echo "[install] 错误：$*" >&2; exit 1; }

gen_pass() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 6
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-12
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_HAS_BUNDLE=0
[ -f "$SCRIPT_DIR/bootstrap/entrypoint.sh" ] && SCRIPT_HAS_BUNDLE=1

if [ -z "$TARGET" ]; then
  if [ "$SCRIPT_HAS_BUNDLE" = "1" ]; then TARGET="$SCRIPT_DIR"; else TARGET="$PWD"; fi
fi
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
log "目标目录：$TARGET"

# ---------- 1) 就位 ----------
if [ -f "$TARGET/bootstrap/entrypoint.sh" ]; then
  log "目录里已有部署文件，跳过复制/解包"
elif [ "$SCRIPT_HAS_BUNDLE" = "1" ] && [ "$SCRIPT_DIR" != "$TARGET" ]; then
  log "从部署包复制文件：$SCRIPT_DIR → $TARGET"
  cp -a "$SCRIPT_DIR"/. "$TARGET"/
elif [ "$SCRIPT_HAS_BUNDLE" = "1" ]; then
  log "就地安装：$TARGET"
else
  BUNDLE=""
  for cand in "$SCRIPT_DIR"/*.tar.gz "$SCRIPT_DIR"/../deploy/*.tar.gz "$PWD"/*.tar.gz; do
    if [ -f "$cand" ]; then BUNDLE="$cand"; break; fi
  done
  [ -n "$BUNDLE" ] || die "找不到 bootstrap/ 或 workbuddy-client-deploy.tar.gz；请在解压出的目录里运行本脚本"
  log "解包：$BUNDLE"
  tar -xzf "$BUNDLE" -C "$TARGET" --strip-components=1
fi

cd "$TARGET"
[ -f docker-compose.yml ] || die "缺少 docker-compose.yml"
mkdir -p inbox

# ---------- 2) 密码 ----------
PASS_FILE="$TARGET/vnc-password.txt"
if [ -n "${WB_PASSWORD:-}" ]; then
  PASSWORD="$WB_PASSWORD"; PASSWORD_EXPLICIT=1
fi
if [ "$PASSWORD_EXPLICIT" = "1" ]; then
  PASS="$PASSWORD"
  [ -n "$PASS" ] || PASS="$(gen_pass)"
  printf '%s\n' "$PASS" > "$PASS_FILE"; chmod 600 "$PASS_FILE"
  log "使用指定密码：$PASS（已写入 vnc-password.txt）"
elif [ -f "$PASS_FILE" ]; then
  PASS="$(cat "$PASS_FILE")"
  log "沿用已有密码（vnc-password.txt）"
else
  PASS="$PASSWORD"; [ -n "$PASS" ] || PASS="$(gen_pass)"
  printf '%s\n' "$PASS" > "$PASS_FILE"; chmod 600 "$PASS_FILE"
  log "访问密码：$PASS（已写入 vnc-password.txt）"
  [ "$PASS" = "iloveppcat" ] && log "提示：这是预置密码，正式用建议 --password 换一个"
fi
sed -i "s#VNC_PASSWORD: \"[^\"]*\"#VNC_PASSWORD: \"$PASS\"#" docker-compose.yml

# ---------- 3) 提示 ----------
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "${IP:-}" ] || IP="<本机IP>"
cat <<EOF

============================================================
安装完成：$TARGET

  桌面    http://$IP:23880/    用户 root，密码 $PASS
  传文件  http://$IP:23881/    或桌面右下角「📎 传文件」

体积参考：构建时装依赖约 600MB + 官方客户端 400~430MB，10~15 分钟
============================================================
EOF

# ---------- 4) 启动 ----------
if [ "$START" = "1" ]; then
  command -v docker >/dev/null 2>&1 || die "本机没有 docker 命令，请到极空间「容器 → 项目」里粘贴 docker-compose.yml 启动"
  log "构建并启动容器（首次 10~15 分钟）"
  docker compose up -d --build
  log "已启动；日志：docker compose logs -f"
else
  cat <<'EOF'
下一步（推荐 A）：
  A. 极空间/群晖图形界面：把本目录的 docker-compose.yml 全文粘进
     「Docker → Compose → 新建项目」，项目位置选本目录，
     确认构建上下文为当前目录 "."，创建（会先构建镜像，10~15 分钟）
  B. 有 docker CLI：cd 到本目录后  docker compose up -d --build
     （或安装时加 --start 让脚本直接起）
EOF
fi
