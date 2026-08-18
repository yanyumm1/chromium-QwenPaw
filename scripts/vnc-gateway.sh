#!/bin/bash
# vnc-gateway.sh - 无登录直连 VNC 网关 (v9 简化)
# 无认证, 手机/PC 直接访问即进入 VNC 远程桌面
set -u

WEB_DIR="${VNC_WEB_DIR:-/usr/share/novnc}"
RFB_PORT="${RFB_PORT:-5900}"
LISTEN_PORT="${VNC_PORT:-8080}"

echo "✅ VNC 直连网关: 0.0.0.0:${LISTEN_PORT} → 127.0.0.1:${RFB_PORT} (无认证)"
exec websockify \
  --web="$WEB_DIR" \
  "${LISTEN_PORT}" \
  "127.0.0.1:${RFB_PORT}"
