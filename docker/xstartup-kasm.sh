#!/bin/bash
# KasmVNC 会话启动脚本：X 由 KasmVNC 自己提供，这里只拉起桌面与客户端
export HOME="${HOME:-/opt/wb/home}"
export GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx XMODIFIERS=@im=fcitx INPUT_METHOD=fcitx SDL_IM_MODULE=fcitx
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/opt/wb/run}"
export BROWSER=/usr/local/bin/wb-chromium

mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

# 关掉 fluxbox 的壁纸逻辑（它会调 fbsetbg，容器里没有 display → 弹报错窗）
# 注意：init 文件末行可能没有换行，直接 >> 会把配置拼进上一行，必须先规范化
mkdir -p "$HOME/.fluxbox"
touch "$HOME/.fluxbox/init"
[ -n "$(tail -c 1 "$HOME/.fluxbox/init" 2>/dev/null)" ] && echo >> "$HOME/.fluxbox/init"
sed -i '/^session\.screen0\.rootCommand:/d' "$HOME/.fluxbox/init" 2>/dev/null || true
echo 'session.screen0.rootCommand: /bin/true' >> "$HOME/.fluxbox/init"

# 先清掉 fluxbox 可能弹出的壁纸报错，再给一个纯色背景
echo 'session.screen0.rootCommand: /bin/true' >> "$HOME/.fluxbox/init" 2>/dev/null || true
fluxbox > /opt/wb/logs/fluxbox.log 2>&1 &
sleep 1
command -v xsetroot >/dev/null && xsetroot -solid '#20242a' 2>/dev/null || true
# fluxbox 的 fbsetbg 有时晚几百毫秒才弹壁纸报错，这里盯 6 秒干掉它
( for _ in $(seq 1 12); do
    pkill -x xmessage 2>/dev/null
    command -v xrefresh >/dev/null && xrefresh >/dev/null 2>&1
    sleep 0.5
  done ) &

command -v fcitx5 >/dev/null && fcitx5 -d > /opt/wb/logs/fcitx5.log 2>&1 &
sleep 1

cd "$HOME" || cd /tmp
/opt/wb/app/workbuddy --no-sandbox --disable-gpu --disable-dev-shm-usage \
  >> /opt/wb/logs/workbuddy.log 2>&1 &

# 会话保持：客户端退出则整个会话结束，交给 restart 策略
wait
