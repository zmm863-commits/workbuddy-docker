#!/usr/bin/env bash
# 打包部署物：tar.gz + zip（极空间图形界面解压用）
# 内容：Dockerfile（按 bootstrap/ 布局）+ 唯一的 docker-compose.yml（创建时构建）+ bootstrap/
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/deploy/workbuddy-client-deploy.tar.gz"
ZIP="${ROOT}/deploy/workbuddy-client-deploy.zip"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
D="$STAGE/workbuddy-client-deploy"

mkdir -p "$D/bootstrap"
cp "$ROOT"/docker/{entrypoint.sh,kasmvnc.yaml,xstartup-kasm.sh,upload-server.mjs,fcitx5-profile} "$D/bootstrap/"
cp "$ROOT"/docker/docker-compose.yml "$D/"
cp "$ROOT"/docker/docker-compose.autoheal.yml "$D/"          # 可选加固（叠加使用）
cp "$ROOT"/deploy/install.sh "$D/"
cp "$ROOT"/deploy/部署说明.md "$D/"
cp "$ROOT"/README.md "$D/"
# 包里根目录的 Dockerfile 面向 bootstrap/ 布局，由根 Dockerfile 派生，避免两份漂移
sed 's#^COPY docker/#COPY bootstrap/#' "$ROOT/Dockerfile" > "$D/Dockerfile"

tar -czf "$OUT" -C "$STAGE" workbuddy-client-deploy
echo "已生成：$OUT"; du -h "$OUT"

python3 - "$ROOT" "$ZIP" <<'ZBUNDLE'
import sys, zipfile, pathlib
root, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
files = [
    ('bootstrap-src','')  # 占位，下面单独处理
]
pairs = [
    ('docker/entrypoint.sh',      'bootstrap/entrypoint.sh'),
    ('docker/kasmvnc.yaml',       'bootstrap/kasmvnc.yaml'),
    ('docker/xstartup-kasm.sh',   'bootstrap/xstartup-kasm.sh'),
    ('docker/upload-server.mjs',  'bootstrap/upload-server.mjs'),
    ('docker/fcitx5-profile',     'bootstrap/fcitx5-profile'),
    ('docker/docker-compose.yml', 'docker-compose.yml'),
    ('docker/docker-compose.autoheal.yml','docker-compose.autoheal.yml'),
    ('deploy/install.sh',         'install.sh'),
    ('deploy/部署说明.md',          'DEPLOY.md'),
    ('README.md',                 'README.md'),
]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for src, dst in pairs:
        z.write(root / src, 'workbuddy-client-deploy/' + dst)
    # Dockerfile：把 COPY docker/ 换成 COPY bootstrap/
    text = (root / 'Dockerfile').read_text(encoding='utf-8').replace('COPY docker/', 'COPY bootstrap/')
    z.writestr('workbuddy-client-deploy/Dockerfile', text)
print('已生成：' + str(out))
ZBUNDLE
du -h "$ZIP"
