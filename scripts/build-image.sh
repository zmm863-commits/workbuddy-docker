#!/usr/bin/env bash
# 在任意有 docker（或 podman）的机器上预构建镜像，产出可导入极空间的 tar
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TAG="${TAG:-workbuddy-client:5.6.2}"
OUT="${OUT:-workbuddy-client-5.6.2.tar}"

docker build -t "$TAG" .
docker save "$TAG" -o "$OUT"
ls -lh "$OUT"
echo
echo "到极空间：镜像 → 导入 → 选 $OUT"
echo "然后把 compose 里的 image/debian 两行换成 workbuddy-client:5.6.2，删掉 command"
