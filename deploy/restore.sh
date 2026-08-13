#!/bin/bash
# ============================================================
# restore.sh - QwenPaw + FRP + Chromium 一键还原
#
# 使用流程:
#   1. 在 VPS 上: bash <(curl -Ls https://main.ssss.nyc.mn/frp.sh) 选 1 装服务端
#      记下: 监听IP / 监听端口 / 认证TOKEN
#   2. 在这台 qwenpaw 机器: cp config.env.example config.env 并填写
#   3. bash restore.sh
#
# 功能:
#   - 安装/配置 frp 客户端 (ssh + noVNC + qwenpaw 隧道)
#   - supervisor 托管: frpc/xvfb/xfce4/vnc-browser/chromium-gui/qwenpaw/备份
#   - NAS 持久化: qwenpaw 数据 + chromium 配置 定时备份, 重启自动恢复
#   - 开机自启 (supervisor autostart)
#
# 幂等: 可重复执行, 不会重复添加已有配置
# ============================================================
set -e

red()   { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow(){ echo -e "\e[1;33m$1\033[0m"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

# ============================================================
# 0. 加载配置 + 校验
# ============================================================
[ "$(id -u)" != "0" ] && { red "❌ 需要 root 权限"; exit 1; }

if [ ! -f "$CONFIG_FILE" ]; then
    red "❌ 未找到 config.env"
    yellow "请先: cp config.env.example config.env 并填写"
    exit 1
fi
set -a; . "$CONFIG_FILE"; set +a

# 校验必填 (禁止占位符残留)
check_var() {
    local v="$1"
    local val="${!v}"
    if [ -z "$val" ] || echo "$val" | grep -q "^YOUR_\|^your-\|^$"; then
        red "❌ 配置项 ${v} 未填写 (config.env 里的 ${v}=${val})"
        exit 1
    fi
}
check_var FRP_SERVER_IP
check_var FRP_TOKEN
check_var FRP_SSH_REMOTE_PORT
check_var FRP_VNC_REMOTE_PORT
check_var VNC_PASSWORD

# 默认值
: "${FRP_SERVER_PORT:=7000}"
: "${LOCAL_SSH_PORT:=22}"
: "${VNC_PORT:=8080}"
: "${QWENPAW_PORT:=8088}"
: "${RESOLUTION:=720x1280}"
: "${NAS_BASE_DIR:=/run/csi/mount-root/nas/4079184d856ecc166ed19d4887083405/workspaces/default}"
: "${QWENPAW_DATA_DIR:=/app/working}"
: "${QWENPAW_SECRET_DIR:=/app/working.secret}"
: "${BACKUP_INTERVAL:=1800}"

# chromium profile 默认放 NAS
: "${CHROMIUM_PROFILE_DIR:=${NAS_BASE_DIR}/browser/chromium-gui-profile}"

FRP_DIR=/home/frp

green "============================================="
green " QwenPaw + FRP + Chromium 一键还原"
green " 服务器: ${FRP_SERVER_IP}:${FRP_SERVER_PORT}"
green " 端口: SSH=${FRP_SSH_REMOTE_PORT} VNC=${FRP_VNC_REMOTE_PORT}$([ -n "$FRP_APP_REMOTE_PORT" ] && ! echo "$FRP_APP_REMOTE_PORT" | grep -q '^YOUR_' && echo " APP=${FRP_APP_REMOTE_PORT}")"
green "============================================="

# ============================================================
# 1. NAS 检查
# ============================================================
yellow "📂 检查 NAS 持久化..."
mkdir -p "$NAS_BASE_DIR"
if touch "${NAS_BASE_DIR}/.write_test" 2>/dev/null; then
    rm -f "${NAS_BASE_DIR}/.write_test"
    green "✅ NAS 可写: $NAS_BASE_DIR"
else
    yellow "⚠ NAS 不可写, 使用本地持久化: /data/persist"
    NAS_BASE_DIR=/data/persist
    mkdir -p "$NAS_BASE_DIR"
fi
mkdir -p "$NAS_BASE_DIR"/{qwenpaw-data,browser}
mkdir -p "$CHROMIUM_PROFILE_DIR"

# ============================================================
# 2. 安装依赖
# ============================================================
green "📦 安装依赖..."
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        xvfb x11vnc xfce4 chromium websockify novnc \
        supervisor curl wget tar xdotool dbus-x11 openssh-server rsync 2>/dev/null || \
    yellow "⚠ 部分包安装失败, 请手动安装缺失项"
elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache \
        xvfb x11vnc xfce4 chromium websockify novnc \
        supervisor curl wget tar xdotool dbus-x11 openssh rsync 2>/dev/null || \
    yellow "⚠ 部分包安装失败"
else
    red "❌ 不支持的包管理器 (仅支持 apt/apk)"
    exit 1
fi

# ============================================================
# 3. 安装 frp 客户端
# ============================================================
if [ ! -f "${FRP_DIR}/frpc" ]; then
    yellow "📥 下载 frp 客户端..."
    mkdir -p "$FRP_DIR" && cd "$FRP_DIR"
    FRP_VERSION="${FRP_VERSION:-0.70.0}"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) ARCH=amd64 ;;
        arm64|aarch64) ARCH=arm64 ;;
        *) red "不支持架构: $ARCH"; exit 1 ;;
    esac
    PKG="frp_${FRP_VERSION}_linux_${ARCH}.tar.gz"
    wget -q "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${PKG}" -O "/tmp/${PKG}"
    tar -zxf "/tmp/${PKG}" -C /tmp
    cp "/tmp/frp_${FRP_VERSION}_linux_${ARCH}/frpc" "$FRP_DIR/"
    rm -rf "/tmp/${PKG}" "/tmp/frp_${FRP_VERSION}_linux_${ARCH}"
    chmod +x "$FRP_DIR/frpc"
fi
green "✅ frpc 就绪: $FRP_DIR/frpc"

# ============================================================
# 4. 生成 frpc.toml
# ============================================================
mkdir -p "$FRP_DIR"
cat > "$FRP_DIR/frpc.toml" <<EOF
serverAddr = "${FRP_SERVER_IP}"
serverPort = ${FRP_SERVER_PORT}

auth.method = "token"
auth.token = "${FRP_TOKEN}"

log.to = "/var/log/frpc.log"
log.level = "error"
log.maxDays = 3

[[proxies]]
name = "ssh_$(hostname)"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${LOCAL_SSH_PORT}
remotePort = ${FRP_SSH_REMOTE_PORT}

[[proxies]]
name = "novnc_$(hostname)"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${VNC_PORT}
remotePort = ${FRP_VNC_REMOTE_PORT}
EOF

if [ -n "$FRP_APP_REMOTE_PORT" ] && ! echo "$FRP_APP_REMOTE_PORT" | grep -q "^YOUR_"; then
    cat >> "$FRP_DIR/frpc.toml" <<EOF

[[proxies]]
name = "app_$(hostname)"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${QWENPAW_PORT}
remotePort = ${FRP_APP_REMOTE_PORT}
EOF
fi
green "✅ frpc.toml 已生成 (ssh+novnc$( [ -n "$FRP_APP_REMOTE_PORT" ] && ! echo "$FRP_APP_REMOTE_PORT" | grep -q '^YOUR_' && echo '+app') 隧道)"

# ============================================================
# 5. 准备 VNC 脚本
# ============================================================
VNC_DIR=/mnt/envd/vnc-browser
mkdir -p "$VNC_DIR"

# 从仓库复制 (若存在)
if [ -f "${SCRIPT_DIR}/../scripts/vnc-browser.sh" ]; then
    cp "${SCRIPT_DIR}/../scripts/vnc-browser.sh" "$VNC_DIR/"
fi
if [ -f "${SCRIPT_DIR}/../scripts/chromium-gui.sh" ]; then
    cp "${SCRIPT_DIR}/../scripts/chromium-gui.sh" "$VNC_DIR/"
fi

# 用 sed 把 chromium-gui.sh 里的 NAS 路径替换成实际值
if [ -f "$VNC_DIR/chromium-gui.sh" ]; then
    sed -i "s|NAS_DIR=\"[^\"]*\"|NAS_DIR=\"${CHROMIUM_PROFILE_DIR}\"|" "$VNC_DIR/chromium-gui.sh"
    sed -i "s|RESOLUTION|${RESOLUTION}|g" "$VNC_DIR/chromium-gui.sh" 2>/dev/null || true
fi
chmod +x "$VNC_DIR"/*.sh 2>/dev/null || true

# vnc-browser.sh 用环境变量 VNC_PASS
green "✅ VNC 脚本就绪: $VNC_DIR"

# ============================================================
# 6. supervisor 配置
# ============================================================
SUP_CONF=/etc/supervisor/conf.d/supervisord.conf
[ -d /etc/supervisor/conf.d ] || SUP_CONF=/etc/supervisor/supervisord.conf
mkdir -p "$(dirname "$SUP_CONF")"

# 若主配置不存在则创建基础段
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

# 幂等追加 program
append_program() {
    local name="$1" body="$2"
    if grep -q "\[program:${name}\]" "$SUP_CONF"; then
        yellow "⏭ [program:${name}] 已存在, 跳过"
        return 0
    fi
    cat >> "$SUP_CONF" <<EOF

[program:${name}]
${body}
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

append_program vnc-browser "command=${VNC_DIR}/vnc-browser.sh
autostart=true
autorestart=true
priority=58
startsecs=5
environment=VNC_PORT=\"${VNC_PORT}\",VNC_PASS=\"${VNC_PASSWORD}\"
stderr_logfile=/var/log/vnc-browser.err.log
stdout_logfile=/var/log/vnc-browser.out.log"

append_program chromium-gui "command=${VNC_DIR}/chromium-gui.sh
autostart=true
autorestart=true
priority=65
startsecs=10
stderr_logfile=/var/log/chromium-gui.err.log
stdout_logfile=/var/log/chromium-gui.out.log"

append_program qwenpaw "command=qwenpaw app --host 0.0.0.0 --port ${QWENPAW_PORT}
autostart=true
autorestart=unexpected
startretries=5
startsecs=10
priority=30
stopwaitsecs=30
environment=DISPLAY=\":1\",PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=\"/usr/bin/chromium\",QWENPAW_RUNNING_IN_CONTAINER=\"1\"
stderr_logfile=/var/log/app.err.log
stdout_logfile=/var/log/app.out.log"

# 备份循环 (定时存 NAS)
append_program qwenpaw-backup "command=bash ${SCRIPT_DIR}/lib/backup.sh loop
autostart=true
autorestart=true
priority=70
startsecs=5
environment=NAS_BASE_DIR=\"${NAS_BASE_DIR}\",QWENPAW_DATA_DIR=\"${QWENPAW_DATA_DIR}\",QWENPAW_SECRET_DIR=\"${QWENPAW_SECRET_DIR}\",CHROMIUM_PROFILE_DIR=\"${CHROMIUM_PROFILE_DIR}\",BACKUP_INTERVAL=\"${BACKUP_INTERVAL}\"
stderr_logfile=/var/log/qwenpaw-backup.err.log
stdout_logfile=/var/log/qwenpaw-backup.out.log"

green "✅ supervisor 配置完成"

# ============================================================
# 7. NAS 数据恢复 (重启时从 NAS 拉回)
# ============================================================
yellow "♻️  检查 NAS 数据恢复..."
NAS_BASE_DIR="$NAS_BASE_DIR" QWENPAW_DATA_DIR="$QWENPAW_DATA_DIR" QWENPAW_SECRET_DIR="$QWENPAW_SECRET_DIR" \
    bash "${SCRIPT_DIR}/lib/backup.sh" restore || true

# ============================================================
# 8. 启动服务
# ============================================================
green "🚀 启动服务..."
supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true

# 按依赖顺序启动
for svc in frpc xvfb xfce4 vnc-browser chromium-gui qwenpaw qwenpaw-backup; do
    supervisorctl start "$svc" 2>/dev/null || true
    sleep 2
done

# ============================================================
# 9. 验证 + 输出
# ============================================================
sleep 3
clear
green "============================================="
green "✅ QwenPaw 一键还原完成!"
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
green ""
green " 💾 数据持久化:"
green "    qwenpaw 数据 → ${NAS_BASE_DIR}/qwenpaw-data"
green "    chromium 配置 → ${CHROMIUM_PROFILE_DIR}"
green "    每 ${BACKUP_INTERVAL}s 自动备份到 NAS, 重启自动恢复"
green "============================================="
echo ""
yellow "服务状态:"
supervisorctl status 2>/dev/null || true