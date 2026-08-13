#!/bin/bash
# chromium-gui.sh - 在 DISPLAY :1 (xfce4 桌面) 上启动带窗口的 chromium
# 数据持久化到 NAS, supervisor 托管, 借鉴 chrome.sh 的启动参数
set -u

# NAS 持久化目录 (软链方式, 容器重启不丢)
NAS_DIR="/run/csi/mount-root/nas/4079184d856ecc166ed19d4887083405/workspaces/default/browser/chromium-gui-profile"
mkdir -p "$NAS_DIR"

# 等待 DISPLAY :1 就绪
for i in $(seq 1 30); do
  [ -S "/tmp/.X11-unix/X1" ] && break
  sleep 0.5
done

export DISPLAY=:1

exec /usr/bin/chromium \
  --no-sandbox \
  --test-type \
  --window-size=720,1280 \
  --start-fullscreen \
  --user-data-dir="$NAS_DIR" \
  --disable-dev-shm-usage \
  --disable-gpu \
  --disable-software-rasterizer \
  --disable-background-networking \
  --restore-last-session \
  --hide-crash-restore-bubble \
  --disable-session-crashed-bubble \
  --disable-infobars \
  --no-first-run \
  --disable-features=Translate,BackForwardCache \
  --js-flags=--max-old-space-size=1024 \
  about:blank
