#!/bin/bash
# chromium-gui.sh - 在 DISPLAY :2 (Xvnc) 上启动 chromium (纯窗口, 无 xfce4)
# 注意: 必须用 exec 前台直启 (不要 & 后台 + 守护循环), 否则 supervisorctl stop
#       只杀脚本壳, chromium 变孤儿进程继续占桌面 → 白屏/抢屏 (2026-08-15 教训)
set -u
NAS_DIR="${CHROMIUM_PROFILE_DIR:-/run/csi/mount-root/nas/4079184d856ecc166ed19d4887083405/workspaces/default/browser/chromium-remote-profile}"
mkdir -p "$NAS_DIR"
for i in $(seq 1 30); do
  [ -S "/tmp/.X11-unix/X2" ] && break
  sleep 0.5
done
export DISPLAY=:2
# 不启动 xfce4, 纯 chromium 窗口 (720x1280 带地址栏)
exec /usr/bin/chromium \
  --no-sandbox \
  --test-type \
  --window-size=720,1280 \
  --window-position=0,0 \
  --user-data-dir="$NAS_DIR" \
  --disable-dev-shm-usage \
  --disable-gpu \
  --disable-software-rasterizer \
  --disable-background-networking \
  --hide-crash-restore-bubble \
  --disable-session-crashed-bubble \
  --disable-infobars \
  --no-first-run \
  --disable-features=Translate,BackForwardCache \
  --js-flags=--max-old-space-size=1024 \
  https://www.baidu.com
