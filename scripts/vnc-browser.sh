#!/bin/bash
# vnc-browser.sh - 暴露 Xvnc 桌面 (DISPLAY :1) 为 noVNC 网页浏览器 (带登录层)
# 架构: Xvnc (TigerVNC) + login_frontend.py (websockify + 账号密码登录页) + noVNC (vnc.html)
set -u
VNC_PORT="${VNC_PORT:-8080}"
VNC_DISPLAY="${VNC_DISPLAY:-:1}"
VNC_USER="${VNC_USER:-admin}"
VNC_PASS="${VNC_PASS:-pingmikeAs}"
RFB_PORT=5900
LOG_DIR=/var/log
VNC_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p /root/.vnc
# 写密码文件 (保留以备后续改 VncAuth)
printf '%s\n' "${VNC_PASS}" > /root/.vnc/passwdfile
chmod 600 /root/.vnc/passwdfile
echo "=== vnc-browser 启动 (port ${VNC_PORT}, display ${VNC_DISPLAY}) ==="
# 清理旧进程
for old in $(pgrep -f "login_frontend.py|websockify.*${VNC_PORT}"); do
  [ -n "$old" ] && kill "$old" 2>/dev/null
done
sleep 1
for i in $(seq 1 50); do
  [ -S "/tmp/.X11-unix/X${VNC_DISPLAY#:}" ] && break
  sleep 0.2
done
[ ! -S "/tmp/.X11-unix/X${VNC_DISPLAY#:}" ] && { echo "❌ DISPLAY ${VNC_DISPLAY} 不存在"; exit 1; }
rm -f /tmp/.X${VNC_DISPLAY#:}-lock 2>/dev/null || true
# noVNC chrome.sh 风格补丁 (幂等): resize=scale + 控制栏收起 + 单页无横向滚动
if [ -f "$VNC_DIR/novnc-chromesh-patch.py" ]; then
  python3 "$VNC_DIR/novnc-chromesh-patch.py" 2>/dev/null || echo "⚠️ noVNC patch 失败"
fi
# 登录层 + websockify 桥 (替代直接 websockify): 根路径=登录页, cookie 校验 WS
export VNC_PORT VNC_USER VNC_PASS VNC_WEB_DIR="/usr/share/novnc" RFB_PORT
python3 "$VNC_DIR/login_frontend.py" > "${LOG_DIR}/novnc.log" 2>&1 &
WEB_PID=$!
sleep 2
echo "✅ 登录页: http://localhost:${VNC_PORT}/   (账号 ${VNC_USER} / 密码 ${VNC_PASS})"
echo "✅ 登录后单页: /vnc.html?autoconnect=1&resize=scale (无横向滚动)"
echo "✅ 切分辨率: $VNC_DIR/vnc-resize.sh phone|desktop|WxH"
wait "${WEB_PID}" 2>/dev/null