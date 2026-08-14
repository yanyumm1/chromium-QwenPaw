#!/bin/bash
# vnc-browser.sh - 暴露 Xvnc 桌面 (DISPLAY :1) 为 noVNC 网页浏览器
# 架构: Xvnc (TigerVNC, 自带动态分辨率) + websockify (8080) + noVNC (vnc.html)
set -u
VNC_PORT="${VNC_PORT:-8080}"
VNC_DISPLAY="${VNC_DISPLAY:-:1}"
VNC_PASS="${VNC_PASS:-pingmikeAs}"
RFB_PORT=5900
LOG_DIR=/var/log
PASS_FILE=/root/.vnc/passwdfile
mkdir -p /root/.vnc
# 写密码文件 (供 noVNC 认证使用; Xvnc 用 -SecurityTypes None 时不需要, 保留以备后续)
printf '%s\n' "${VNC_PASS}" > "${PASS_FILE}"
chmod 600 "${PASS_FILE}"
echo "=== vnc-browser 启动 (port ${VNC_PORT}, display ${VNC_DISPLAY}) ==="
for old in $(pgrep -f "websockify.*${VNC_PORT}"); do
  [ -n "$old" ] && kill "$old" 2>/dev/null
done
sleep 1
for i in $(seq 1 50); do
  [ -S "/tmp/.X11-unix/X${VNC_DISPLAY#:}" ] && break
  sleep 0.2
done
[ ! -S "/tmp/.X11-unix/X${VNC_DISPLAY#:}" ] && { echo "❌ DISPLAY ${VNC_DISPLAY} 不存在"; exit 1; }
rm -f /tmp/.X${VNC_DISPLAY#:}-lock 2>/dev/null || true
# 生成入口页: 根路径 / 自动跳转 vnc.html (完整 UI, 默认收起控制栏, autoconnect)
cat > /usr/share/novnc/index.html <<'INDEXEOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>VNC Browser</title>
<script>
// 自动跳转到 vnc.html (完整 UI, 控制栏默认收起, 支持缩放切换)
var base = location.pathname.replace(/index\.html$/, '');
var target = base + 'vnc.html?autoconnect=1&resize=scale&show_dot=0';
if (location.search) target += '&' + location.search.replace(/^\?/, '');
location.replace(target);
</script></head><body>
<p>Redirecting to <a href="vnc.html?autoconnect=1&amp;resize=scale&amp;show_dot=0">VNC Browser...</a></p>
</body></html>
INDEXEOF
# vnc.html 完整 UI 本身控制栏默认收起 (点击蓝色边缘手柄展开), 无需 patch
# 确保 vnc.html 允许用户缩放 (幂等)
AUTO="/usr/share/novnc/vnc.html"
if [ -f "$AUTO" ]; then
  sed -i 's/maximum-scale=1.0, user-scalable=no/maximum-scale=3.0/g' "$AUTO"
fi
# websockify: 保留 (Xvnc 是原生 VNC 服务器, websockify 做 WebSocket 桥接)
websockify --web /usr/share/novnc ${VNC_PORT} localhost:${RFB_PORT} > "${LOG_DIR}/novnc.log" 2>&1 &
WEB_PID=$!
sleep 2
echo "✅ noVNC: http://localhost:${VNC_PORT}/vnc.html?autoconnect=1 (手机竖屏 720x1280)"
echo "✅ 电脑横屏: 控制栏 -> Settings -> Scaling Mode 或 VNC 客户端发 SetDesktopSize"
wait "${WEB_PID}" 2>/dev/null
