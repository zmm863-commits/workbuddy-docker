#!/usr/bin/env bash
# ------------------------------------------------------------
# WorkBuddy 官方 Linux 客户端 · 容器入口
#
# 首次启动：装依赖 → 查官方更新接口取最新 .deb → 下载并校验 sha256 → 解包
# 每次启动：清理残留 X 锁 → 复制配置 → DBus + fcitx5（中文输入）
#           → KasmVNC 桌面 → 官方客户端 → 收件箱上传页 → 守护 Xvnc 存活
#           收到 SIGTERM 时优雅关闭会话并清锁（避免下次启动卡住）
#
# 环境变量（都有默认值，正常只需要改 VNC_PASSWORD）：
#   VNC_USER            登录用户名，默认 root（可改成任意名字）
#   VNC_PASSWORD        访问密码；留空则随机生成并写入 state/vnc-password.txt
#
#   RESOLUTION          自适应模式的初始分辨率，默认 1440x900
#   FIXED_RESOLUTION    非空则固定该分辨率、不跟随浏览器窗口（例 1280x800）
#   PERF_PROFILE        性能档位 lite | balanced | quality，默认 balanced
#                         lite     画质 2~6 / 18fps
#                         balanced 画质 4~8 / 24fps
#                         quality  画质 6~9 / 30fps
#
#   KASM_PORT           容器内 KasmVNC 端口，默认 8444（别改）
#   UPLOAD_PORT         容器内上传页端口，默认 6082（别改）
#   DESKTOP_PUBLIC_PORT 浏览器访问的桌面端口，默认 23880（仅用于打印地址）
#   UPLOAD_PUBLIC_PORT  浏览器访问的上传页端口，默认 23881；设 none 则不注入桌面按钮
#
#   DEB_PLATFORM        auto | x64 | arm64，默认 auto（按 uname -m 判断）
#   DEB_URL/DEB_SHA256  成对填写可钉死版本；留空则自动取最新版（只填一个会报错退出）
#   UPDATE_API          官方更新接口，默认 copilot.tencent.com（失败回退 www.workbuddy.cn）
#
#   APP_READONLY=on     把客户端目录设为只读，防止自动更新写坏程序
#   APT_MIRROR          仅"非镜像运行"时才会用到；预构建镜像里依赖已装好，此值无效
#   KASM_DEB_URL        KasmVNC 安装包地址；同样只在非预构建环境下使用
# ------------------------------------------------------------
set -Eeuo pipefail

APP_HOME="${APP_HOME:-/opt/wb}"
# 官方没有公开下载页直链，但更新接口给出 url + sha256hash，这里自动取最新版
UPDATE_API="${UPDATE_API:-https://copilot.tencent.com/v2/update}"
DEB_PLATFORM="${DEB_PLATFORM:-auto}"     # auto | x64 | arm64
DEB_URL="${DEB_URL:-}"                   # 留空 = 自动解析
DEB_SHA256="${DEB_SHA256:-}"
DEB_VERSION=""

RESOLUTION="${RESOLUTION:-1920x1080}"            # 自适应模式的初始尺寸
FIXED_RESOLUTION="${FIXED_RESOLUTION:-}"        # 非空则固定该尺寸、不再跟随窗口（例：2560x1440）
KASM_PORT="${KASM_PORT:-8444}"
UPLOAD_PORT="${UPLOAD_PORT:-6082}"
# 浏览器实际访问的宿主端口（compose 映射后的端口）
PERF_PROFILE="${PERF_PROFILE:-balanced}"     # lite | balanced | quality
DESKTOP_PUBLIC_PORT="${DESKTOP_PUBLIC_PORT:-23880}"
UPLOAD_PUBLIC_PORT="${UPLOAD_PUBLIC_PORT:-23881}"
# none/off/0 = 不发布上传端口：不注入按钮、不打提示（文件走 SMB 收件箱）
case "$UPLOAD_PUBLIC_PORT" in
  none|off|0|"") UPLOAD_UI_DISABLED=1 ;;
  *) UPLOAD_UI_DISABLED=0 ;;
esac
APT_MIRROR="${APT_MIRROR:-}"
VNC_USER="${VNC_USER:-root}"              # 登录用户名（Basic 认证），默认 root
VNC_PASSWORD="${VNC_PASSWORD:-}"
KASM_DEB_URL="${KASM_DEB_URL:-https://github.com/kasmtech/KasmVNC/releases/download/v1.5.2/kasmvncserver_debian_bookworm_1.5.2_amd64.deb}"
KASM_DEB_MIRROR="${KASM_DEB_MIRROR:-}"

export APP_HOME DISPLAY=:1 HOME="$APP_HOME/home"
export XDG_RUNTIME_DIR="$APP_HOME/run"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# 平台选择：DEB_PLATFORM=auto|x64|arm64；auto 按 uname -m 判断
detect_platform() {
  local want="${1:-$DEB_PLATFORM}"
  case "$want" in
    x64|arm64) echo "$want"; return ;;
    auto|"") ;;
    *) log "警告：DEB_PLATFORM=\"$want\" 非法（只认 auto/x64/arm64），按 auto 处理" >&2 ;;
  esac
  case "$(uname -m)" in
    aarch64|arm64) echo arm64 ;;
    *) echo x64 ;;
  esac
}

# 从官方更新接口取最新 deb 地址与 sha256（两个域名互为兜底）
resolve_deb() {
  local plat="$1" host json url sha ver
  plat="$(detect_platform "$1")"
  for host in "$UPDATE_API" "https://www.workbuddy.cn/v2/update"; do
    json="$(curl -fsS --max-time 20 "$host?platform=workbuddy-linux-${plat}-deb" 2>/dev/null)" || continue
    url="$(printf '%s' "$json" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')"
    sha="$(printf '%s' "$json" | sed -n 's/.*"sha256hash":"\([^"]*\)".*/\1/p')"
    ver="$(printf '%s' "$json" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
    if [ -n "$url" ] && [ -n "$sha" ]; then
      DEB_URL="$url"; DEB_SHA256="$sha"; DEB_VERSION="$ver"
      log "官方最新版：${ver:-未知}（平台 ${plat}）"
      return 0
    fi
  done
  return 1
}

mkdir -p "$APP_HOME"/{app,home,run,logs,state,inbox}
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

# ---------- 1) 系统依赖 ----------
# 预构建镜像里已经装好（kasmvncserver 在），此时即使卷里没有 apt.done 也不重装
if [ -f "$APP_HOME/state/apt.done" ] || command -v kasmvncserver >/dev/null 2>&1; then
  log "依赖已就绪，跳过安装"
else
  log "首次启动：安装运行依赖（约 600MB，需要几分钟）"
  if [ -n "$APT_MIRROR" ]; then
    log "换用 apt 镜像：$APT_MIRROR"
    cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true
    SEC_MIRROR="${APT_MIRROR%/debian}/debian-security"
    cat > /etc/apt/sources.list <<EOF
deb $APT_MIRROR bookworm main
deb $APT_MIRROR bookworm-updates main
deb $SEC_MIRROR bookworm-security main
EOF
  fi
  apt-get update -qq
  log "开始安装（下载约 600MB，日志会陆续出现 Setting up ... 行）"
  T0=$(date +%s)
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils \
    fluxbox feh xdotool x11-xserver-utils \
    chromium \
    libgtk-3-0 libnotify4 libnss3 libxss1 libxtst6 xdg-utils libatspi2.0-0 \
    libsecret-1-0 libgbm1 libasound2 libdrm2 libxkbcommon0 libuuid1 \
    fonts-wqy-zenhei fonts-noto-cjk dbus-x11 \
    fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk3 fcitx5-frontend-gtk4
  touch "$APP_HOME/state/apt.done" 2>/dev/null || true
  log "依赖安装完成，用时 $(( $(date +%s) - T0 ))s"
fi

# ---------- 2) 官方客户端（只做一次，校验 sha256） ----------
# 只给其中一个视为配置错误，避免“以为钉死了版本、其实走自动解析”
if { [ -n "$DEB_URL" ] && [ -z "$DEB_SHA256" ]; } || { [ -z "$DEB_URL" ] && [ -n "$DEB_SHA256" ]; }; then
  log "错误：DEB_URL 与 DEB_SHA256 必须同时提供；本次不下载，请修正后重启"
  exit 1
fi

if [ ! -x "$APP_HOME/app/workbuddy" ] && [ -z "$DEB_URL" ]; then
  resolve_deb "$DEB_PLATFORM" || log "警告：更新接口不可用，尝试用 compose 里指定的 DEB_URL/DEB_SHA256"
fi

if [ ! -x "$APP_HOME/app/workbuddy" ]; then
  [ -n "$DEB_URL" ] && [ -n "$DEB_SHA256" ] || {
    log "错误：拿不到官方下载地址。请在 compose 里显式设置 DEB_URL 与 DEB_SHA256 后重启。"
    exit 1
  }
  log "下载官方 WorkBuddy Linux 客户端（约 400~430MB，无进度条，请耐心等）"
  T0=$(date +%s)
  curl -fL --retry 3 --no-progress-meter -o /tmp/wb.deb "$DEB_URL"
  log "下载完成：$(du -h /tmp/wb.deb | cut -f1)，用时 $(( $(date +%s) - T0 ))s；校验 sha256 …"
  echo "${DEB_SHA256}  /tmp/wb.deb" | sha256sum -c -
  rm -rf /tmp/wbx && mkdir -p /tmp/wbx
  dpkg-deb -x /tmp/wb.deb /tmp/wbx
  cp -a /tmp/wbx/opt/WorkBuddy/. "$APP_HOME/app/"
  rm -rf /tmp/wb.deb /tmp/wbx
  log "客户端就绪：$APP_HOME/app/workbuddy"
fi

# 可选：把客户端程序设为只读，防止它自动更新把程序写坏
if [ "${APP_READONLY:-off}" = "on" ] && [ -d "$APP_HOME/app" ]; then
  chmod -R a-w "$APP_HOME/app" 2>/dev/null || true
  log "客户端目录已设为只读（APP_READONLY=on）"
fi

# ---------- 3) DBus 会话 + 中文输入法 ----------
# fcitx5 依赖 DBus：没有会话总线时进程能起，但候选框永远不出
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  if command -v dbus-launch >/dev/null; then
    eval "$(dbus-launch --sh-syntax)"
    export DBUS_SESSION_BUS_ADDRESS
    log "DBus 会话：$DBUS_SESSION_BUS_ADDRESS"
  else
    log "警告：缺 dbus-launch，中文输入法将不可用"
  fi
fi
export GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx XMODIFIERS=@im=fcitx INPUT_METHOD=fcitx SDL_IM_MODULE=fcitx
mkdir -p "$HOME/.config/fcitx5"
if [ ! -f "$HOME/.config/fcitx5/profile" ] && [ -f "$APP_HOME/bootstrap/fcitx5-profile" ]; then
  cp "$APP_HOME/bootstrap/fcitx5-profile" "$HOME/.config/fcitx5/profile"
fi

# ---------- 4) 浏览器 + workbuddy:// 回调 ----------
cat > /usr/local/bin/wb-chromium <<'EOF'
#!/bin/sh
exec /usr/lib/chromium/chromium --no-sandbox --no-first-run --no-default-browser-check \
  --disable-dev-shm-usage --disable-gpu --password-store=basic "$@"
EOF
chmod +x /usr/local/bin/wb-chromium
for p in /usr/bin/chromium /usr/bin/chromium-browser; do
  [ -e "$p" ] && [ ! -e "$p.orig" ] && mv "$p" "$p.orig" && ln -sf /usr/local/bin/wb-chromium "$p"
done
export BROWSER=/usr/local/bin/wb-chromium

cat > /usr/share/applications/workbuddy.desktop <<EOF
[Desktop Entry]
Name=WorkBuddy
Exec=$APP_HOME/app/workbuddy %U
Type=Application
Terminal=false
MimeType=x-scheme-handler/workbuddy;
StartupWMClass=workbuddy
EOF
command -v update-desktop-database >/dev/null && update-desktop-database /usr/share/applications 2>/dev/null || true
command -v xdg-mime >/dev/null && xdg-mime default workbuddy.desktop x-scheme-handler/workbuddy 2>/dev/null || true

# ---------- 5) 收件箱（VNC 没有文件通道，靠它把文件送进来） ----------
ln -sfn "$APP_HOME/inbox" "$HOME/收件箱"
if [ -f "$APP_HOME/bootstrap/upload-server.mjs" ] && ! command -v node >/dev/null 2>&1; then
  log "警告：容器里没有 node，跳过收件箱上传页（文件仍可通过 SMB 收件箱传输）"
elif [ -f "$APP_HOME/bootstrap/upload-server.mjs" ]; then
  INBOX="$APP_HOME/inbox" UPLOAD_PORT="$UPLOAD_PORT" nohup node "$APP_HOME/bootstrap/upload-server.mjs" \
    > "$APP_HOME/logs/upload.log" 2>&1 &
  log "收件箱：http://<主机IP>:${UPLOAD_PUBLIC_PORT}/  →  $APP_HOME/inbox"
fi

# 给 KasmVNC 界面注入一个「传文件」悬浮按钮（不改它源码，只在入口页挂一段脚本）
inject_upload_button() {
  local www="/usr/share/kasmvnc/www"
  if [ "${UPLOAD_UI_DISABLED:-0}" = "1" ]; then
    log "未发布上传端口（UPLOAD_PUBLIC_PORT=none），跳过桌面按钮；传文件请用 SMB 收件箱"
    return 0
  fi
  if [ ! -d "$www" ]; then
    log "未找到 KasmVNC 前端目录，跳过按钮注入"
    return 0
  fi
  cat > "$www/wb-tools.js" <<JS
(function () {
  if (window.__wbToolsLoaded) return;
  window.__wbToolsLoaded = true;
  var url = location.protocol + '//' + location.hostname + ':${UPLOAD_PUBLIC_PORT}/';
  function add() {
    if (document.getElementById('wb-upload-btn')) return;
    var a = document.createElement('a');
    a.id = 'wb-upload-btn';
    a.href = url;
    a.target = '_blank';
    a.rel = 'noopener';
    a.title = '打开收件箱上传页（拖文件进去，再在 WorkBuddy 里选）';
    a.textContent = '📎 传文件';
    a.style.cssText = 'position:fixed;right:16px;bottom:16px;z-index:2147483000;display:flex;' +
      'align-items:center;gap:6px;padding:10px 16px;border-radius:999px;background:#1a73e8;' +
      'color:#fff;font:600 14px/1 system-ui,-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;' +
      'box-shadow:0 6px 20px rgba(0,0,0,.35);text-decoration:none;opacity:.95;transition:opacity .15s;';
    a.onmouseenter = function () { a.style.opacity = '1'; };
    a.onmouseleave = function () { a.style.opacity = '.95'; };
    document.body.appendChild(a);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', add);
  else add();
})();
JS
  if ! grep -q 'wb-tools.js' "$www/index.html" 2>/dev/null; then
    [ -f "$www/index.html.orig" ] || cp "$www/index.html" "$www/index.html.orig"
    sed -i 's#</body>#<script src="./wb-tools.js"></script></body>#' "$www/index.html"
    log "已在 KasmVNC 界面注入「传文件」按钮（指向端口 ${UPLOAD_PUBLIC_PORT}）"
  fi
}
inject_upload_button

# ---------- 6) 密码 ----------
if [ -z "$VNC_PASSWORD" ]; then
  # 不用 tr|head：pipefail 下 SIGPIPE 会让脚本直接退出
  if command -v openssl >/dev/null 2>&1; then
    VNC_PASSWORD="$(openssl rand -hex 6)"
  else
    VNC_PASSWORD="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-12)"
  fi
  echo "$VNC_PASSWORD" > "$APP_HOME/state/vnc-password.txt"
  chmod 600 "$APP_HOME/state/vnc-password.txt"
  log "未设 VNC_PASSWORD，已随机生成：$VNC_PASSWORD"
fi
# 统一落盘：健康检查要读它，忘了密码也能从这里找
printf '%s\n' "$VNC_PASSWORD" > "$APP_HOME/state/vnc-password.txt" 2>/dev/null || true
chmod 600 "$APP_HOME/state/vnc-password.txt" 2>/dev/null || true

# ---------- 7) 远程桌面（KasmVNC） ----------
if ! command -v kasmvncserver >/dev/null; then
  # 优先用 bootstrap 里自带的安装包（离线部署 / 内网）
  if [ -f "$APP_HOME/bootstrap/kasmvnc.deb" ]; then
    log "使用本地 KasmVNC 安装包"
    dpkg -i "$APP_HOME/bootstrap/kasmvnc.deb" >/dev/null 2>&1 \
      || DEBIAN_FRONTEND=noninteractive apt-get -f install -y -qq >/dev/null 2>&1 || true
  else
    log "安装 KasmVNC（约 3MB）"
    for url in "$KASM_DEB_URL" ${KASM_DEB_MIRROR:+"$KASM_DEB_MIRROR"}; do
      if curl -fL --retry 2 --connect-timeout 15 -o /tmp/kasmvnc.deb "$url"; then
        dpkg -i /tmp/kasmvnc.deb >/dev/null 2>&1 \
          || DEBIAN_FRONTEND=noninteractive apt-get -f install -y -qq >/dev/null 2>&1 || true
        rm -f /tmp/kasmvnc.deb
        break
      fi
      log "下载失败：$url"
    done
  fi
  if ! command -v kasmvncserver >/dev/null; then
    log "错误：KasmVNC 安装失败。请把 kasmvncserver_*.deb 放进 $APP_HOME/bootstrap/ 后重启容器，"
    log "      或设置 KASM_DEB_MIRROR 指向可访问的镜像。"
    exit 1
  fi
fi

log "启动 KasmVNC（端口 ${KASM_PORT}，HTTP + Basic 认证，用户 ${VNC_USER}）"
# 密码文件里可以存多个用户；先清空，保证只有 VNC_USER 这个账号有效（换用户名后旧账号立即失效）
rm -f "$HOME/.kasmpasswd" 2>/dev/null || true
printf '%s\n%s\n' "$VNC_PASSWORD" "$VNC_PASSWORD" | kasmvncpasswd -u "$VNC_USER" -w >/dev/null 2>&1 || true
chmod 600 "$HOME/.kasmpasswd" 2>/dev/null || true
mkdir -p "$HOME/.vnc"
touch "$HOME/.vnc/.de-was-selected"
# 分辨率策略：默认自适应；设了 FIXED_RESOLUTION 就写死并关掉 allow_resize
GEOMETRY="$RESOLUTION"
if [ -n "$FIXED_RESOLUTION" ]; then
  if [[ "$FIXED_RESOLUTION" =~ ^([0-9]{3,5})x([0-9]{3,5})$ ]]; then
    GEOMETRY="$FIXED_RESOLUTION"
    log "分辨率固定为 ${FIXED_RESOLUTION}（不跟随浏览器窗口）"
  else
    log "警告：FIXED_RESOLUTION="$FIXED_RESOLUTION" 格式不对（应形如 2560x1440），按自适应处理"
    FIXED_RESOLUTION=""
  fi
fi

if [ -f "$APP_HOME/bootstrap/kasmvnc.yaml" ]; then
  sed "s#/opt/wb/home#$HOME#g; s#websocket_port: 8444#websocket_port: ${KASM_PORT}#g" \
    "$APP_HOME/bootstrap/kasmvnc.yaml" > "$HOME/.vnc/kasmvnc.yaml"
  if [ -n "$FIXED_RESOLUTION" ]; then
    W="${FIXED_RESOLUTION%x*}"; H="${FIXED_RESOLUTION#*x}"
    sed -i "s/allow_resize: true/allow_resize: false/; s/width: 1920/width: ${W}/g; s/height: 1080/height: ${H}/g" \
      "$HOME/.vnc/kasmvnc.yaml"
  fi
fi
# 性能档位：直接在生成好的 kasmvnc.yaml 上覆盖画质/帧率（无需多份配置文件）
apply_perf_profile() {
  local f="$HOME/.vnc/kasmvnc.yaml" prof="$PERF_PROFILE"
  [ -f "$f" ] || return 0
  case "$prof" in
    quality)
      sed -i 's/^\s*min_quality:.*/    min_quality: 6/; s/^\s*max_quality:.*/    max_quality: 8/;
              s/^\s*jpeg_quality:.*/    jpeg_quality: 9/; s/^\s*webp_quality:.*/    webp_quality: 9/;
              s/^\s*max_frame_rate:.*/  max_frame_rate: 30/' "$f" ;;
    lite)
      sed -i 's/^\s*min_quality:.*/    min_quality: 2/; s/^\s*max_quality:.*/    max_quality: 6/;
              s/^\s*jpeg_quality:.*/    jpeg_quality: 5/; s/^\s*webp_quality:.*/    webp_quality: 5/;
              s/^\s*max_frame_rate:.*/  max_frame_rate: 18/' "$f" ;;
    balanced|*) prof="balanced" ;;
  esac
  PERF_MINQ="$(sed -n 's/^ *min_quality: *\([0-9]*\).*/\1/p' "$f" | head -1)"
  PERF_MAXQ="$(sed -n 's/^ *max_quality: *\([0-9]*\).*/\1/p' "$f" | head -1)"
  PERF_FPS="$(sed -n 's/^ *max_frame_rate: *\([0-9]*\).*/\1/p' "$f" | head -1)"
  log "性能档位：${prof}（画质 ${PERF_MINQ}~${PERF_MAXQ}，帧率 ${PERF_FPS}fps）"
}
apply_perf_profile

sed "s#/opt/wb#$APP_HOME#g" "$APP_HOME/bootstrap/xstartup-kasm.sh" > "$HOME/.vnc/xstartup"
chmod +x "$HOME/.vnc/xstartup"

# 容器重启后 /tmp 里的 X 锁与 socket 仍在，KasmVNC 会因此拒绝启动 —— 先清干净
# 只返回"活着"的 Xvnc：僵尸进程（状态 Z）不算，否则容器会误以为桌面还在
xvnc_pids() {
  local p
  if command -v pgrep >/dev/null 2>&1; then
    for p in $(pgrep -x Xvnc 2>/dev/null); do
      [ "$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)" = "Z" ] || echo "$p"
    done
  else
    ps -eo pid,stat,comm 2>/dev/null | awk '$3=="Xvnc" && $2 !~ /Z/{print $1}'
  fi
}
xvnc_alive() { [ -n "$(xvnc_pids)" ]; }

reset_x_display() {
  local d="${1#:}" pids
  kasmvncserver -kill ":$d" >/dev/null 2>&1 || true
  pids="$(xvnc_pids)"
  [ -n "$pids" ] && kill $pids 2>/dev/null || true
  rm -f "/tmp/.X${d}-lock" "/tmp/.X11-unix/X${d}" "$HOME/.vnc/"*.pid 2>/dev/null || true
}
reset_x_display :1

# 收到停止信号时优雅收尾：社区反复踩的坑就是容器被 SIGTERM 杀掉后留锁，下次起不来
cleanup_on_exit() {
  log "收到停止信号，关闭 KasmVNC 会话并清理 X 锁"
  kasmvncserver -kill :1 >/dev/null 2>&1 || true
  local pids; pids="$(xvnc_pids)"
  [ -n "$pids" ] && kill $pids 2>/dev/null || true
  rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 "$HOME/.vnc/"*.pid 2>/dev/null || true
  exit 0
}
trap cleanup_on_exit TERM INT

log "执行：kasmvncserver :1 -geometry $GEOMETRY -depth 24"
set +e
kasmvncserver :1 -geometry "$GEOMETRY" -depth 24 > "$APP_HOME/logs/kasmvnc-start.log" 2>&1
KASM_RC=$?
set -e
log "kasmvncserver 返回码=${KASM_RC}"
if [ "$KASM_RC" -ne 0 ]; then
  log "错误：KasmVNC 启动失败，见 $APP_HOME/logs/kasmvnc-start.log"
  tail -n 15 "$APP_HOME/logs/kasmvnc-start.log" 2>/dev/null | while IFS= read -r line; do log "  | $line"; done
  exit 1
fi
log "KasmVNC 进程检查：Xvnc=$(xvnc_pids | tr '\n' ' ')"

# ---------- 8) 就绪 ----------
log "桌面已就绪：http://<主机IP>:${DESKTOP_PUBLIC_PORT}/  （用户 ${VNC_USER}，密码见上；容器内 ${KASM_PORT}）"
if [ -n "$FIXED_RESOLUTION" ]; then
  log "画质：${PERF_MINQ:-4}~${PERF_MAXQ:-8} / ${PERF_FPS:-24}fps（${PERF_PROFILE}）；分辨率固定 ${FIXED_RESOLUTION}；支持双向复制粘贴"
else
  log "画质：${PERF_MINQ:-4}~${PERF_MAXQ:-8} / ${PERF_FPS:-24}fps（${PERF_PROFILE}）；分辨率自适应浏览器窗口（初始 ${RESOLUTION}）；支持双向复制粘贴"
fi
if [ "${UPLOAD_UI_DISABLED:-0}" = "1" ]; then
  log "传文件：上传页未发布端口，请用极空间「共享文件夹」写入收件箱目录"
else
  log "传文件：桌面右下角「📎 传文件」按钮，或直接开 http://<主机IP>:${UPLOAD_PUBLIC_PORT}/"
fi
log "输入中文：Ctrl+Space 切换"

# 跟随 Xvnc 生命周期：不能用裸 wait —— 后台任务（上传页等）一退出就会把容器带走
log "进入守护循环（跟随 Xvnc 生命周期）"
while xvnc_alive; do sleep 5; done
log "Xvnc 已退出，容器结束（restart: unless-stopped 会拉起）"
