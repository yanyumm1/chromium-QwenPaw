#!/bin/bash
# ============================================================
# deploy.sh - QwenPaw + FRP + Chromium 一键部署
#
# 用法:
#   1. cp config.env.example config.env
#   2. 编辑 config.env 填写你的值
#   3. bash deploy.sh
#
# 功能:
#   - 安装依赖 (frp, xvfb, x11vnc, xfce4, chromium, websockify, novnc, supervisor)
#   - 生成 frpc.toml (SSH + noVNC + qwenpaw 三条隧道)
#   - supervisor 托管: frpc / xvfb / xfce4 / chromium-gui / vnc-browser / qwenpaw
# ============================================================
set -e

red()   { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow(){ echo -e "\e[1;33m$1\033[0m"; }

# ---------- 0. 加载配置 ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [ ! -f "$CONFIG_FILE" ]; then
    red "❌ 未找到 config.env"
    yellow "请先: cp config.env.example config.env 并填写"
    exit 1
fi
set -a; . "$CONFIG_FILE"; set +a

# 检查必填项
check_var() {
    local v="$1"
    local val="${!v}"
    if [ -z "$val" ] || [ "$val" = "YOUR_${v}" ] || echo "$val" | grep -q "^YOUR_"; then
        red "❌ 配置项 ${v} 未填写 (config.env 里的 ${v}=${val})"
        exit 1
    fi
}
check_var FRP_SERVER_IP
check_var FRP_TOKEN
check_var FRP_SSH_REMOTE_PORT
check_var FRP_VNC_REMOTE_PORT
check_var VNC_PASSWORD

# ---------- 1. 检查 root ----------
[ "$(id -u)" != "0" ] && { red "需要 root 权限运行"; exit 1; }

# ---------- 2. 安装依赖 ----------
green "📦 安装依赖..."
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        xvfb x11vnc xfce4 chromium websockify novnc \
        supervisor curl wget tar xdotool dbus-x11 openssh-server
elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache \
        xvfb x11vnc xfce4 chromium websockify novnc \
        supervisor curl wget tar xdotool dbus-x11 openssh
else
    red "❌ 不支持的包管理器 (仅支持 apt/apk)"
    exit 1
fi

# ---------- 3. 下载安装 frp ----------
FRP_VERSION=${FRP_VERSION:-0.70.0}
FRP_DIR=/home/frp
mkdir -p "$FRP_DIR" && cd "$FRP_DIR"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    *) red "不支持的架构: $ARCH"; exit 1 ;;
esac

if [ ! -f "${FRP_DIR}/frpc" ]; then
    yellow "📥 下载 frp v${FRP_VERSION}..."
    FRP_PACKAGE="frp_${FRP_VERSION}_linux_${ARCH}.tar.gz"
    wget -q "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_PACKAGE}" -O "/tmp/${FRP_PACKAGE}"
    tar -zxf "/tmp/${FRP_PACKAGE}" -C /tmp
    cp "/tmp/frp_${FRP_VERSION}_linux_${ARCH}/frpc" "$FRP_DIR/"
    rm -rf "/tmp/${FRP_PACKAGE}" "/tmp/frp_${FRP_VERSION}_linux_${ARCH}"
    chmod +x "$FRP_DIR/frpc"
fi
green "✅ frpc 就绪: $FRP_DIR/frpc"

# ---------- 4. 生成 frpc.toml ----------
cat > "$FRP_DIR/frpc.toml" <<EOF
serverAddr = "${FRP_SERVER_IP}"
serverPort = ${FRP_SERVER_PORT:-7000}

auth.method = "token"
auth.token = "${FRP_TOKEN}"

log.to = "/var/log/frpc.log"
log.level = "error"
log.maxDays = 3

[[proxies]]
name = "ssh_$(hostname)"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${LOCAL_SSH_PORT:-22}
remotePort = ${FRP_SSH_REMOTE_PORT}

[[proxies]]
name = "novnc_$(hostname)"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${VNC_PORT:-8080}
remotePort = ${FRP_VNC_REMOTE_PORT}
EOF

# qwenpaw web 可选代理
if [ -n "$FRP_APP_REMOTE_PORT" ] && ! echo "$FRP_APP_REMOTE_PORT" | grep -q "^YOUR_"; then
    cat >> "$FRP_DIR/frpc.toml" <<EOF

[[proxies]]
name = "app_$(hostname)"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${QWENPAW_PORT:-8088}
remotePort = ${FRP_APP_REMOTE_PORT}
EOF
fi
green "✅ frpc.toml 已生成: $FRP_DIR/frpc.toml"

# ---------- 5. 准备 VNC 脚本 ----------
mkdir -p /mnt/envd/vnc-browser
cp "${SCRIPT_DIR}/../scripts/chromium-gui.sh" /mnt/envd/vnc-browser/ 2>/dev/null || true
cp "${SCRIPT_DIR}/../scripts/vnc-browser.sh" /mnt/envd/vnc-browser/ 2>/dev/null || true
chmod +x /mnt/envd/vnc-browser/*.sh 2>/dev/null || true

# 若仓库没有脚本, 生成标准版
if [ ! -f /mnt/envd/vnc-browser/vnc-browser.sh ]; then
    red "⚠ 未找到 vnc-browser.sh, 请确保 scripts/ 目录存在"
    exit 1
fi

# 配置 VNC 密码 (写入 vnc-browser 环境)
VNC_PASS="$VNC_PASSWORD"

# ---------- 6. supervisor 配置 ----------
SUP_CONF=/etc/supervisor/conf.d/supervisord.conf
[ -d /etc/supervisor/conf.d ] || SUP_CONF=/etc/supervisor/supervisord.conf
mkdir -p /etc/supervisor/conf.d

# 备份现有配置
[ -f "$SUP_CONF" ] && cp "$SUP_CONF" "${SUP_CONF}.bak-$(date +%Y%m%d-%H%M%S)"

# 生成配置 (若不存在则创建, 存在则追加)
if [ ! -f "$SUP_CONF" ]; then
    cat > "$SUP_CONF" <<'EOF'
[supervisord]
user=root
logfile=/var/log/supervisord.log
pidfile=/var/log/supervisord.pid
nodaemon=true

[unix_http_server]
file=/var/run/supervisor.sock
chmod=0700

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock
EOF
fi

# 追加 program (幂等: 已存在则跳过)
append_program() {
    local name="$1"
    if grep -q "\[program:${name}\]" "$SUP_CONF"; then
        yellow "⏭ [program:${name}] 已存在, 跳过"
        return 0
    fi
    cat >> "$SUP_CONF" <<EOF

[program:${name}]
$2
EOF
    green "✅ [program:${name}] 已添加"
}

append_program frpc "command=${FRP_DIR}/frpc -c ${FRP_DIR}/frpc.toml
autostart=true
autorestart=true
stderr_logfile=/var/log/frpc.err.log
stdout_logfile=/var/log/frpc.out.log"

append_program xvfb "command=/bin/sh -c \"rm -f /tmp/.X1-lock /tmp/.X11-unix/X1; mkdir -p /tmp/.X11-unix; exec /usr/bin/Xvfb :1 -screen 0 ${RESOLUTION}x24\"
autostart=true
autorestart=true
priority=10
environment=DISPLAY=\":1\"
stderr_logfile=/var/log/xvfb.err.log
stdout_logfile=/var/log/xvfb.out.log"

append_program xfce4 "command=/bin/sh -c 'export DISPLAY=:1; for i in \$(seq 1 200); do [ -S /tmp/.X11-unix/X1 ] && break; sleep 0.1; done; exec dbus-run-session startxfce4'
autostart=true
autorestart=true
priority=20
environment=DISPLAY=\":1\"
stderr_logfile=/var/log/xfce4.err.log
stdout_logfile=/var/log/xfce4.out.log"

append_program vnc-browser "command=/mnt/envd/vnc-browser/vnc-browser.sh
autostart=true
autorestart=true
priority=58
startsecs=5
environment=VNC_PORT=\"${VNC_PORT:-8080}\",VNC_PASS=\"${VNC_PASSWORD}\"
stderr_logfile=/var/log/vnc-browser.err.log
stdout_logfile=/var/log/vnc-browser.out.log"

append_program chromium-gui "command=/mnt/envd/vnc-browser/chromium-gui.sh
autostart=true
autorestart=true
priority=65
startsecs=10
stderr_logfile=/var/log/chromium-gui.err.log
stdout_logfile=/var/log/chromium-gui.out.log"

append_program qwenpaw "command=qwenpaw app --host 0.0.0.0 --port ${QWENPAW_PORT:-8088}
autostart=true
autorestart=unexpected
startretries=5
startsecs=10
priority=30
stopwaitsecs=30
environment=DISPLAY=\":1\",PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=\"/usr/bin/chromium\",QWENPAW_RUNNING_IN_CONTAINER=\"1\"
stderr_logfile=/var/log/app.err.log
stdout_logfile=/var/log/app.out.log"

# ---------- 7. 启动 ----------
green "🚀 启动服务..."
supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true

# 确保 chromium-gui.sh 里的持久化目录存在
CHROMIUM_PROFILE_DIR="${CHROMIUM_PROFILE_DIR:-/data/chromium-profile}"
mkdir -p "$CHROMIUM_PROFILE_DIR"

# 按依赖顺序启动
for svc in frpc xvfb xfce4 vnc-browser chromium-gui qwenpaw; do
    supervisorctl start "$svc" 2>/dev/null || true
    sleep 2
done

# ---------- 8. 输出访问信息 ----------
sleep 3
clear
green "============================================="
green "✅ QwenPaw + Chromium 部署完成!"
green ""
green " 🌐 noVNC 浏览器:"
green "    http://${FRP_SERVER_IP}:${FRP_VNC_REMOTE_PORT}/vnc.html"
green "    VNC密码: ${VNC_PASSWORD}"
green ""
if [ -n "$FRP_APP_REMOTE_PORT" ] && ! echo "$FRP_APP_REMOTE_PORT" | grep -q "^YOUR_"; then
    green " 🌐 QwenPaw 面板:"
    green "    http://${FRP_SERVER_IP}:${FRP_APP_REMOTE_PORT}"
fi
green ""
green " 🔑 SSH 连接:"
green "    ssh -p ${FRP_SSH_REMOTE_PORT} root@${FRP_SERVER_IP}"
green "============================================="
echo ""
yellow "服务状态:"
supervisorctl status 2>/dev/null || true
