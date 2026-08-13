#!/bin/bash
# vnc-browser.sh - 暴露 xfce4 桌面 (DISPLAY :1) 为 noVNC 网页浏览器
# 用途: 通过 cloudflared 隧道在浏览器里远程操作桌面 (chromium/firefox)
# 设计借鉴 system-panel 经验: supervisor 托管 + PORT 可配置 + NAS 持久化
#
# 环境变量:
#   VNC_PORT   - websockify/noVNC 监听端口 (默认 8080)
#   VNC_PASS   - VNC 密码 (默认 your-vnc-password)
#   VNC_DISPLAY - 要暴露的 X display (默认 :1, 与 xvfb/xfce4 共用)

set -u

VNC_PORT="${VNC_PORT:-8080}"
VNC_PASS="${VNC_PASS:-your-vnc-password}"
VNC_DISPLAY="${VNC_DISPLAY:-:1}"
RFB_PORT=5900
LOG_DIR=/var/log
VNC_PASS_DIR=/root/.vnc

echo "=== vnc-browser 启动 ==="
echo "端口: ${VNC_PORT}  密码: ${VNC_PASS}  display: ${VNC_DISPLAY}"

# 0. 清理旧进程 (supervisor 重启时旧 x11vnc/websockify 可能成孤儿占端口)
for old in $(pgrep -f "x11vnc -display ${VNC_DISPLAY}") $(pgrep -f "websockify.*${VNC_PORT}"); do
  [ -n "$old" ] && kill "$old" 2>/dev/null && echo "✅ 清理旧进程 ${old}"
done
sleep 1

# 0. 不需要 VNC 密码文件 - 用 -nopw 无密码模式 (借鉴 chrome.sh 的 Xvnc -SecurityTypes None)
# 访问控制交给外层 (frp 端口 + noVNC 页面), 避免密码鉴权问题
mkdir -p "${VNC_PASS_DIR}"
rm -f "${VNC_PASS_DIR}/passwd" "${VNC_PASS_DIR}/passwd-plain" 2>/dev/null || true
echo "✅ VNC 无密码模式 (-nopw)"

# 1. 检查 DISPLAY 存在 (等待 xvfb)
for i in $(seq 1 50); do
  [ -S "/tmp/.X11-unix/X${VNC_DISPLAY#:}" ] && break
  sleep 0.2
done
if [ ! -S "/tmp/.X11-unix/X${VNC_DISPLAY#:}" ]; then
  echo "❌ DISPLAY ${VNC_DISPLAY} 不存在, xvfb 未启动?"
  exit 1
fi
echo "✅ DISPLAY ${VNC_DISPLAY} 就绪"

# 2. 清理旧锁
rm -f /tmp/.X${VNC_DISPLAY#:}-lock 2>/dev/null || true

# 3. 启动 x11vnc (把 X 桌面变成 VNC 服务)
#    用 --forever 保持; -nopw 无密码 (借鉴 chrome.sh Xvnc -SecurityTypes None)
x11vnc -display "${VNC_DISPLAY}" \
    -forever -shared \
    -rfbport ${RFB_PORT} \
    -nopw \
    -noxdamage -repeat \
    -listen 0.0.0.0 \
    -geometry 720x1280 \
    -pointer_mode 1 -wait 5 -defer 5 \
    > "${LOG_DIR}/x11vnc.log" 2>&1 &
X11_PID=$!
echo "✅ x11vnc 启动 (pid ${X11_PID}, port ${RFB_PORT})"

# 4. 启动 websockify (noVNC web 页面 + websocket 代理 8080 -> 5900)
websockify --web /usr/share/novnc ${VNC_PORT} localhost:${RFB_PORT} \
    > "${LOG_DIR}/novnc.log" 2>&1 &
WEB_PID=$!
echo "✅ websockify/noVNC 启动 (pid ${WEB_PID}, port ${VNC_PORT})"

# 5. 验证
sleep 2
echo "=== 验证 ==="
if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/${RFB_PORT}" 2>/dev/null; then
  echo "✅ VNC ${RFB_PORT} 可连"
else
  echo "❌ VNC ${RFB_PORT} 不可连"
fi
if timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/${VNC_PORT}" 2>/dev/null; then
  echo "✅ noVNC ${VNC_PORT} 可连"
  curl -s -o /dev/null -w "  novnc.html HTTP %{http_code}\n" "http://127.0.0.1:${VNC_PORT}/vnc.html" 2>/dev/null || true
else
  echo "❌ noVNC ${VNC_PORT} 不可连"
fi

echo "========================================"
echo "✅ 浏览器桌面服务已启动!"
echo "   noVNC: http://localhost:${VNC_PORT}/vnc.html"
echo "   VNC密码: ${VNC_PASS}"
echo "========================================"

# 保持前台运行 (supervisor 需要)
wait -n "${X11_PID}" "${WEB_PID}" 2>/dev/null || wait "${X11_PID}" "${WEB_PID}"