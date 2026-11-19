# WorkBuddy 官方客户端 · 预构建镜像（把依赖、KasmVNC、官方客户端全部烤进去）
# 构建后创建容器是秒级，不再首次下载 1GB 东西。
#
# 构建：docker build -t workbuddy-client:1.0.0 .
# 导出：docker save workbuddy-client:1.0.0 -o workbuddy-client-1.0.0.tar
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    APP_HOME=/opt/wb \
    RESOLUTION=1920x1080 \
    KASM_PORT=8444 \
    UPLOAD_PORT=6082 \
    UPLOAD_PUBLIC_PORT=8091

# ---- 1) 系统依赖（X11 / VNC / 浏览器 / 输入法 / 字体）----
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils tzdata \
      fluxbox feh xdotool x11-xserver-utils \
      chromium \
      libgtk-3-0 libnotify4 libnss3 libxss1 libxtst6 xdg-utils libatspi2.0-0 \
      libsecret-1-0 libgbm1 libasound2 libdrm2 libxkbcommon0 libuuid1 \
      fonts-wqy-zenhei fonts-noto-cjk dbus-x11 nodejs \
      fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 \
    && rm -rf /var/lib/apt/lists/*

# ---- 2) KasmVNC（远程桌面）----
ARG KASM_URL=https://github.com/kasmtech/KasmVNC/releases/download/v1.5.2/kasmvncserver_debian_bookworm_1.5.2_amd64.deb
RUN apt-get update \
    && curl -fL --retry 3 --no-progress-meter -o /tmp/kasmvnc.deb "$KASM_URL" \
    && (dpkg -i /tmp/kasmvnc.deb || apt-get -f install -y) \
    && rm -f /tmp/kasmvnc.deb \
    && rm -rf /var/lib/apt/lists/* \
    && command -v kasmvncserver

# ---- 3) 官方 WorkBuddy 客户端（构建时自动取最新版 + 强制校验 sha256）----
# 官方下载页只写“请到系统应用商店下载”，但更新接口会给出 url 与 sha256hash：
#   https://copilot.tencent.com/v2/update?platform=workbuddy-linux-{x64,arm64}-deb
# 因此这里不写死版本号；TARGETARCH 由 buildx 自动提供（docker build --platform 也会设置）。
ARG TARGETARCH=amd64
ARG DEB_PLATFORM=""          # 显式指定 x64|arm64；留空则按 TARGETARCH 推断
ARG DEB_URL=""
ARG DEB_SHA256=""
RUN set -e; \
    if { [ -n "$DEB_URL" ] && [ -z "$DEB_SHA256" ]; } || { [ -z "$DEB_URL" ] && [ -n "$DEB_SHA256" ]; }; then \
      echo "DEB_URL 与 DEB_SHA256 必须同时提供（否则无法校验）"; exit 1; \
    fi; \
    if [ -n "$DEB_URL" ] && [ -n "$DEB_SHA256" ]; then \
      URL="$DEB_URL"; SHA="$DEB_SHA256"; VER="自定义"; P="自定义"; \
    else \
      if [ -n "$DEB_PLATFORM" ]; then P="$DEB_PLATFORM"; \
      else case "$TARGETARCH" in amd64) P=x64 ;; arm64) P=arm64 ;; *) echo "不支持的架构：$TARGETARCH"; exit 1 ;; esac; fi; \
      URL=""; SHA=""; \
      for host in "https://copilot.tencent.com/v2/update" "https://www.workbuddy.cn/v2/update"; do \
        JSON="$(curl -fsS --max-time 20 "$host?platform=workbuddy-linux-$P-deb" || true)"; \
        URL="$(printf '%s' "$JSON" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')"; \
        SHA="$(printf '%s' "$JSON" | sed -n 's/.*"sha256hash":"\([^"]*\)".*/\1/p')"; \
        VER="$(printf '%s' "$JSON" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"; \
        if [ -n "$URL" ] && [ -n "$SHA" ]; then break; fi; \
      done; \
      [ -n "$URL" ] && [ -n "$SHA" ] || { echo "拿不到官方下载地址（接口不可用）"; exit 1; }; \
    fi; \
    echo "官方版本：$VER 平台：$P"; \
    mkdir -p /opt/wb/app; \
    curl -fL --retry 3 --no-progress-meter -o /tmp/wb.deb "$URL"; \
    echo "$SHA  /tmp/wb.deb" | sha256sum -c -; \
    mkdir -p /tmp/wbx && dpkg-deb -x /tmp/wb.deb /tmp/wbx; \
    cp -a /tmp/wbx/opt/WorkBuddy/. /opt/wb/app/; \
    chmod +x /opt/wb/app/workbuddy; \
    rm -rf /tmp/wb.deb /tmp/wbx

# ---- 4) 启动脚本与配置 ----
COPY docker/entrypoint.sh      /opt/wb/bootstrap/entrypoint.sh
COPY docker/kasmvnc.yaml       /opt/wb/bootstrap/kasmvnc.yaml
COPY docker/xstartup-kasm.sh   /opt/wb/bootstrap/xstartup-kasm.sh
COPY docker/upload-server.mjs  /opt/wb/bootstrap/upload-server.mjs
COPY docker/healthcheck.sh     /opt/wb/bootstrap/healthcheck.sh
COPY docker/fcitx5-profile     /opt/wb/bootstrap/fcitx5-profile

# 标记：依赖已就绪（卷里没有 state 时也不重装，entrypoint 会按“能力探测”判断）
RUN chmod +x /opt/wb/bootstrap/entrypoint.sh /opt/wb/bootstrap/xstartup-kasm.sh /opt/wb/bootstrap/healthcheck.sh \
    && mkdir -p /opt/wb/home /opt/wb/run /opt/wb/logs /opt/wb/state /opt/wb/inbox \
    && printf 'baked\n' > /opt/wb/state/apt.done

VOLUME ["/opt/wb/home", "/opt/wb/logs", "/opt/wb/state", "/opt/wb/inbox"]
EXPOSE 8444 6082

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD bash /opt/wb/bootstrap/healthcheck.sh

CMD ["bash", "/opt/wb/bootstrap/entrypoint.sh"]
