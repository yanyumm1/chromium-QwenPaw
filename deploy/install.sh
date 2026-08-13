#!/bin/bash
# ============================================================
# install.sh - QwenPaw + FRP + Chromium 一键部署 (单文件版)
# ============================================================
# 使用流程:
#   1. 在你的 VPS 公网服务器上运行 (装 FRP 服务端):
#        bash <(curl -Ls https://main.ssss.nyc.mn/frp.sh)
#      选 1 安装服务端, 拿到: 监听IP / 监听端口 / 认证TOKEN
#   2. 在任意 qwenpaw 机器上, 下载本脚本, 填好下面 4 个变量
#   3. bash install.sh   一键部署完成
#
# 自动完成:
#   - 检测/修复本机 chromium CDP 模式 (browser_use 依赖, 有问题先修好)
#   - 自动探测 NAS 持久化路径 (不写死, 谁都能用)
#   - 安装 frp 客户端 + 生成 frpc.toml (qwenpaw + ssh + noVNC 隧道)
#   - supervisor 托管全部服务 + 开机自启
#   - 数据定时备份到 NAS, 重启自动恢复
#
# 幂等: 可重复执行, 已有配置自动跳过
# ============================================================

# ============================================================
# >>> 用户配置区: 只需填下面 4 个变量 <<<
# ============================================================

# ① FRP 服务端公网 IP (VPS 上 frp.sh 输出的 "监听IP")
FRP_SERVER_IP=""

# ② FRP 服务端监听端口 (frp.sh 默认 7000)
FRP_SERVER_PORT=7000

# ③ FRP 认证 TOKEN (frp.sh 输出的 "认证TOKEN")
FRP_TOKEN=""

# ④ qwenpaw 公网链接端口 (frp 映射到公网的端口, 自己定一个不冲突的)
#    部署完成后访问: http://<FRP_SERVER_IP>:<QWENPAW_REMOTE_PORT>
QWENPAW_REMOTE_PORT=""

# ============================================================
# >>> 以下一般不用改 <<<
# ============================================================
FRP_SSH_REMOTE_PORT=6000      # SSH 公网映射端口 (可选, 留空不建 SSH 隧道)
FRP_VNC_REMOTE_PORT=6080      # noVNC 公网映射端口 (可选, 留空不建 VNC 隧道)
VNC_PASSWORD="qwenpaw"        # noVNC 访问密码
RESOLUTION="720x1280"         # 桌面分辨率 (手机竖屏 720x1280 / 电脑横屏 1280x720)
LOCAL_SSH_PORT=22             # 本地 SSH 端口
VNC_PORT=8080                 # 本地 noVNC 端口
QWENPAW_PORT=8088             # 本地 qwenpaw app 端口
BACKUP_INTERVAL=1800          # 数据备份间隔(秒), 默认 30 分钟
CDP_PORT=9222                 # chromium CDP 调试端口 (browser_use 用)

# ============================================================
# 0. 基础检查
# ============================================================
set -e
red()   { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow(){ echo -e "\e[1;33m$1\033[0m"; }

[ "$(id -u)" != "0" ] && { red "❌ 需要 root 权限运行"; exit 1; }

# 校验必填项
if [ -z "$FRP_SERVER_IP" ] || [ -z "$FRP_TOKEN" ] || [ -z "$QWENPAW_REMOTE_PORT" ]; then
    red "❌ 请先填写脚本开头的 4 个变量:"
    red "   FRP_SERVER_IP, FRP_TOKEN, QWENPAW_REMOTE_PORT (FRP_SERVER_PORT 有默认值)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRP_DIR=/home/frp

green "============================================================"
green " QwenPaw + FRP + Chromium 一键部署"
green " FRP服务器: ${FRP_SERVER_IP}:${FRP_SERVER_PORT}"
green " 公网端口: qwenpaw=${QWENPAW_REMOTE_PORT} vnc=${FRP_VNC_REMOTE_PORT} ssh=${FRP_SSH_REMOTE_PORT}"
green "============================================================"

# ============================================================
# 1. NAS 路径自动探测 (不写死, 任意机器可用)
# ============================================================
# 探测原理 (按优先级):
#   1. 环境变量 NAS_BASE_DIR 已指定 → 直接用
#   2. 当前工作目录 $PWD 在 NAS 树里 → 推导工作区根
#   3. 找 /run/csi/mount-root/nas/*/workspaces/* (取最新修改的)
#   4. 都没找到 → fallback 本地 /data/persist
detect_nas() {
    # 已显式指定
    [ -n "${NAS_BASE_DIR:-}" ] && { echo "$NAS_BASE_DIR"; return; }

    local candidate=""

    # ① 当前目录在 NAS 树里
    case "$PWD" in
        /run/csi/mount-root/nas/*|/mnt/nas/*|/nas/*|/data/nas/*)
            candidate="$PWD"
            ;;
    esac

    # ② 常见 NAS 挂载点找 workspaces/<agent>
    if [ -z "$candidate" ]; then
        for base in /run/csi/mount-root/nas /mnt/nas /nas /data/nas; do
            [ -d "$base" ] || continue
            local found
            found=$(find "$base" -maxdepth 3 -type d -name workspaces 2>/dev/null | head -1)
            if [ -n "$found" ]; then
                candidate="$found/$(ls -t "$found" 2>/dev/null | head -1)"
                break
            fi
        done
    fi

    # ③ qwenpaw 数据目录推导 (容器内无 NAS 挂载但 /app/working 在 NAS)
    if [ -z "$candidate" ] && [ -n "${QWENPAW_WORKING_DIR:-}" ]; then
        local derived="${QWENPAW_WORKING_DIR%/workspaces/*}"
        case "$derived" in
            /run/csi/mount-root/nas/*|/mnt/nas/*) candidate="$derived" ;;
        esac
    fi

    # 可写性检查
    if [ -n "$candidate" ] && [ -d "$candidate" ] && touch "$candidate/.write_test" 2>/dev/null; then
        rm -f "$candidate/.write_test"
        echo "$candidate"
        return
    fi

    # ④ fallback 本地
    echo "/data/persist"
}

yellow "📂 探测 NAS 持久化路径..."
NAS_BASE_DIR="$(detect_nas)"
mkdir -p "$NAS_BASE_DIR" 2>/dev/null || true
if touch "$NAS_BASE_DIR/.write_test" 2>/dev/null; then
    rm -f "$NAS_BASE_DIR/.write_test"
    green "✅ NAS 可写: $NAS_BASE_DIR"
else
    yellow "⚠ NAS 不可写, 使用本地持久化: /data/persist"
    NAS_BASE_DIR=/data/persist
    mkdir -p "$NAS_BASE_DIR"
fi

# 数据目录
QWENPAW_DATA_DIR="${QWENPAW_DATA_DIR:-/app/working}"
QWENPAW_SECRET_DIR="${QWENPAW_SECRET_DIR:-/app/working.secret}"
CHROMIUM_PROFILE_DIR="${CHROMIUM_PROFILE_DIR:-${NAS_BASE_DIR}/browser/chromium-gui-profile}"
QP_BACKUP_DIR="${NAS_BASE_DIR}/qwenpaw-data"
mkdir -p "$NAS_BASE_DIR"/{qwenpaw-data,browser}
mkdir -p "$CHROMIUM_PROFILE_DIR"

# ============================================================
# 2. chromium CDP 模式检测与修复 (browser_use 依赖)
# ============================================================
# CDP 模式 = chromium 以 --headless=new --remote-debugging-port=<port> 运行
# browser_use 通过 CDP (默认 127.0.0.1:9222) 控制浏览器。
# 检测: ① chromium 二进制存在? ② 9222 端口响应 /json/version? ③ supervisor 托管?
# 修复: 装 chromium → supervisor 写 chromium-cdp program → 启动并验证
check_cdp() {
    yellow "🔍 检查 chromium CDP 模式..."

    # ① chromium 二进制
    CHROMIUM_BIN="$(command -v chromium || command -v chromium-browser || command -v google-chrome || echo /usr/bin/chromium)"
    if [ ! -x "$CHROMIUM_BIN" ]; then
        yellow "⚠ 未找到 chromium, 安装中..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>/dev/null || true
        apt-get install -y -qq chromium 2>/dev/null || apt-get install -y -qq chromium-browser 2>/dev/null || {
            red "❌ chromium 安装失败, 请手动安装"; exit 1; }
        CHROMIUM_BIN="$(command -v chromium || echo /usr/bin/chromium)"
    fi
    green "✅ chromium: $CHROMIUM_BIN"

    # ② CDP 端口是否已响应
    cdp_ok() {
        curl -s --max-time 3 "http://127.0.0.1:${CDP_PORT}/json/version" 2>/dev/null | grep -q "webSocketDebuggerUrl"
    }

    # ③ supervisor 托管检查
    SUP_CONF=/etc/supervisor/conf.d/supervisord.conf
    [ -d /etc/supervisor/conf.d ] || SUP_CONF=/etc/supervisor/supervisord.conf
    local has_sup=no
    if [ -f "$SUP_CONF" ] && grep -q "\[program:chromium-cdp\]" "$SUP_CONF" 2>/dev/null; then
        has_sup=yes
    fi

    if cdp_ok; then
        green "✅ CDP 端口 ${CDP_PORT} 正常响应 (chromium 已就绪)"
        if [ "$has_sup" = "yes" ]; then
            green "✅ chromium-cdp 已由 supervisor 托管 (开机自启)"
        else
            yellow "⚠ CDP 有响应但 supervisor 未托管, 补充托管配置..."
            has_sup=no
        fi
    else
        red "❌ CDP 端口 ${CDP_PORT} 无响应, 需要启动/修复 chromium"
        has_sup=no
    fi

    # 修复: supervisor 托管 chromium-cdp
    if [ "$has_sup" != "yes" ]; then
        yellow "🔧 配置 supervisor 托管 chromium-cdp..."
        mkdir -p "$(dirname "$SUP_CONF")"
        # 主配置基础段 (若不存在)
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

        if ! grep -q "\[program:chromium-cdp\]" "$SUP_CONF" 2>/dev/null; then
            cat >> "$SUP_CONF" <<EOF

[program:chromium-cdp]
command=${CHROMIUM_BIN} --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-setuid-sandbox --remote-debugging-port=${CDP_PORT} --remote-debugging-address=127.0.0.1 --user-data-dir=/tmp/chromium-cdp-profile about:blank
autostart=true
autorestart=true
priority=60
startsecs=5
stderr_logfile=/var/log/chromium-cdp.err.log
stdout_logfile=/var/log/chromium-cdp.out.log
EOF
            green "✅ chromium-cdp program 已添加"
        fi

        # 启动
        supervisorctl reread 2>/dev/null || true
        supervisorctl update 2>/dev/null || true
        supervisorctl start chromium-cdp 2>/dev/null || true
        sleep 3

        if cdp_ok; then
            green "✅ chromium CDP 修复成功 (端口 ${CDP_PORT})"
        else
            # 直接手动启动兜底
            yellow "⚠ supervisor 启动失败, 手动启动兜底..."
            nohup "$CHROMIUM_BIN" --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-setuid-sandbox --remote-debugging-port=${CDP_PORT} --remote-debugging-address=127.0.0.1 --user-data-dir=/tmp/chromium-cdp-profile about:blank \
                >/var/log/chromium-cdp.out.log 2>&1 &
            sleep 3
            if cdp_ok; then
                green "✅ chromium CDP 手动启动成功 (端口 ${CDP_PORT})"
            else
                red "❌ chromium CDP 启动失败, 请检查 /var/log/chromium-cdp.err.log"
                exit 1
            fi
        fi
    fi

    # 最终验证
    if cdp_ok; then
        green "✅ CDP 检测通过: http://127.0.0.1:${CDP_PORT}/json/version"
    else
        red "❌ CDP 最终验证失败, browser_use 将无法工作"
        exit 1
    fi
}

# ============================================================
# 3. 安装依赖
# ============================================================
install_deps() {
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>/dev/null || true
        apt-get install -y -qq \
            xvfb x11vnc xfce4 chromium websockify novnc \
            supervisor curl wget tar xdotool dbus-x11 openssh-server \
            xfonts-base 2>/dev/null || \
        yellow "⚠ 部分包安装失败, 请检查 apt"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache \
            xvfb x11vnc xfce4 chromium websockify novnc \
            supervisor curl wget tar xdotool dbus-x11 openssh \
            xfonts-base 2>/dev/null || \
        yellow "⚠ 部分包安装失败"
    else
        red "❌ 不支持的包管理器 (仅 apt/apk)"
        exit 1
    fi
}

# ============================================================
# 4. 安装 frp 客户端
# ============================================================
install_frp() {
    if [ ! -f "${FRP_DIR}/frpc" ]; then
        yellow "📥 下载 frp 客户端..."
        mkdir -p "$FRP_DIR"
        FRP_VERSION="${FRP_VERSION:-0.70.0}"
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64|amd64) ARCH=amd64 ;;
            arm64|aarch64) ARCH=arm64 ;;
            *) red "❌ 不支持架构: $ARCH"; exit 1 ;;
        esac
        PKG="frp_${FRP_VERSION}_linux_${ARCH}.tar.gz"
        wget -q "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${PKG}" -O "/tmp/${PKG}"
        tar -zxf "/tmp/${PKG}" -C /tmp
        cp "/tmp/frp_${FRP_VERSION}_linux_${ARCH}/frpc" "$FRP_DIR/"
        rm -rf "/tmp/${PKG}" "/tmp/frp_${FRP_VERSION}_linux_${ARCH}"
        chmod +x "$FRP_DIR/frpc"
    fi
    green "✅ frpc 就绪: $FRP_DIR/frpc"
}

# ============================================================
# 5. 生成 frpc.toml
# ============================================================
write_frpc_toml() {
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
name = "qwenpaw_$(hostname)"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${QWENPAW_PORT}
remotePort = ${QWENPAW_REMOTE_PORT}
EOF

    # 可选: SSH 隧道
    if [ -n "$FRP_SSH_REMOTE_PORT" ]; then
        cat >> "$FRP_DIR/frpc.toml" <<EOF

[[proxies]]
name = "ssh_$(hostname)"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${LOCAL_SSH_PORT}
remotePort = ${FRP_SSH_REMOTE_PORT}
EOF
    fi

    # 可选: noVNC 隧道
    if [ -n "$FRP_VNC_REMOTE_PORT" ]; then
        cat >> "$FRP_DIR/frpc.toml" <<EOF

[[proxies]]
name = "novnc_$(hostname)"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${VNC_PORT}
remotePort = ${FRP_VNC_REMOTE_PORT}
EOF
    fi
    green "✅ frpc.toml 已生成 (qwenpaw + ssh + novnc 隧道)"
}

# ============================================================
# 6. 生成 VNC/Chromium 脚本 (内联)
# ============================================================
write_vnc_scripts() {
    VNC_DIR=/mnt/envd/vnc-browser
    mkdir -p "$VNC_DIR"

    cat > "$VNC_DIR/chromium-gui.sh" <<EOF
#!/bin/bash
# chromium-gui.sh - 在 DISPLAY :1 (xfce4 桌面) 上启动带窗口的 chromium
# 数据持久化到 NAS (自动探测路径), supervisor 托管
set -u
NAS_DIR="${CHROMIUM_PROFILE_DIR}"
mkdir -p "\$NAS_DIR"
for i in \$(seq 1 30); do
  [ -S "/tmp/.X11-unix/X1" ] && break
  sleep 0.5
done
export DISPLAY=:1
exec /usr/bin/chromium \\
  --no-sandbox \\
  --test-type \\
  --window-size=${RESOLUTION/x/,} \\
  --start-fullscreen \\
  --user-data-dir="\$NAS_DIR" \\
  --disable-dev-shm-usage \\
  --disable-gpu \\
  --disable-software-rasterizer \\
  --disable-background-networking \\
  --restore-last-session \\
  --hide-crash-restore-bubble \\
  --disable-session-crashed-bubble \\
  --disable-infobars \\
  --no-first-run \\
  --disable-features=Translate,BackForwardCache \\
  --js-flags=--max-old-space-size=1024 \\
  about:blank
EOF

    cat > "$VNC_DIR/vnc-browser.sh" <<EOF
#!/bin/bash
# vnc-browser.sh - 暴露 xfce4 桌面 (DISPLAY :1) 为 noVNC 网页浏览器
set -u
VNC_PORT="\${VNC_PORT:-${VNC_PORT}}"
VNC_DISPLAY="\${VNC_DISPLAY:-:1}"
RFB_PORT=5900
LOG_DIR=/var/log
echo "=== vnc-browser 启动 (port \${VNC_PORT}, display \${VNC_DISPLAY}) ==="
for old in \$(pgrep -f "x11vnc -display \${VNC_DISPLAY}") \$(pgrep -f "websockify.*\${VNC_PORT}"); do
  [ -n "\$old" ] && kill "\$old" 2>/dev/null
done
sleep 1
for i in \$(seq 1 50); do
  [ -S "/tmp/.X11-unix/X\${VNC_DISPLAY#:}" ] && break
  sleep 0.2
done
[ ! -S "/tmp/.X11-unix/X\${VNC_DISPLAY#:}" ] && { echo "❌ DISPLAY \${VNC_DISPLAY} 不存在"; exit 1; }
rm -f /tmp/.X\${VNC_DISPLAY#:}-lock 2>/dev/null || true
x11vnc -display "\${VNC_DISPLAY}" -forever -shared -rfbport \${RFB_PORT} -nopw -noxdamage -repeat -listen 0.0.0.0 -geometry ${RESOLUTION} -pointer_mode 1 -wait 5 -defer 5 > "\${LOG_DIR}/x11vnc.log" 2>&1 &
X11_PID=\$!
websockify --web /usr/share/novnc \${VNC_PORT} localhost:\${RFB_PORT} > "\${LOG_DIR}/novnc.log" 2>&1 &
WEB_PID=\$!
sleep 2
echo "✅ noVNC: http://localhost:\${VNC_PORT}/vnc.html"
wait -n "\${X11_PID}" "\${WEB_PID}" 2>/dev/null || wait "\${X11_PID}" "\${WEB_PID}"
EOF

    chmod +x "$VNC_DIR"/chromium-gui.sh "$VNC_DIR"/vnc-browser.sh
    green "✅ VNC/Chromium 脚本已生成: $VNC_DIR"
}

# ============================================================
# 7. supervisor 配置 (全部服务托管, 开机自启)
# ============================================================
SUP_CONF=/etc/supervisor/conf.d/supervisord.conf
[ -d /etc/supervisor/conf.d ] || SUP_CONF=/etc/supervisor/supervisord.conf
mkdir -p "$(dirname "$SUP_CONF")"

# 主配置基础段 (若不存在)
ensure_supervisor_base() {
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
}

# 幂等追加 program
append_program() {
    local name="$1" body="$2"
    if grep -q "\[program:${name}\]" "$SUP_CONF" 2>/dev/null; then
        yellow "⏭ [program:${name}] 已存在, 跳过"
        return 0
    fi
    cat >> "$SUP_CONF" <<EOF

[program:${name}]
${body}
EOF
    green "✅ [program:${name}] 已添加"
}

# frpc
append_program frpc "command=${FRP_DIR}/frpc -c ${FRP_DIR}/frpc.toml
autostart=true
autorestart=true
stderr_logfile=/var/log/frpc.err.log
stdout_logfile=/var/log/frpc.out.log"

# xvfb (虚拟屏幕)
append_program xvfb "command=/bin/sh -c \"rm -f /tmp/.X1-lock /tmp/.X11-unix/X1; mkdir -p /tmp/.X11-unix; exec /usr/bin/Xvfb :1 -screen 0 ${RESOLUTION}x24\"
autostart=true
autorestart=true
priority=10
environment=DISPLAY=\":1\"
stderr_logfile=/var/log/xvfb.err.log
stdout_logfile=/var/log/xvfb.out.log"

# xfce4 桌面
append_program xfce4 "command=/bin/sh -c 'export DISPLAY=:1; for i in \$(seq 1 200); do [ -S /tmp/.X11-unix/X1 ] && break; sleep 0.1; done; exec dbus-run-session startxfce4'
autostart=true
autorestart=true
priority=20
environment=DISPLAY=\":1\"
stderr_logfile=/var/log/xfce4.err.log
stdout_logfile=/var/log/xfce4.out.log"

# vnc-browser (noVNC)
append_program vnc-browser "command=${VNC_DIR}/vnc-browser.sh
autostart=true
autorestart=true
priority=58
startsecs=5
environment=VNC_PORT=\"${VNC_PORT}\"
stderr_logfile=/var/log/vnc-browser.err.log
stdout_logfile=/var/log/vnc-browser.out.log"

# chromium-gui (窗口浏览器)
append_program chromium-gui "command=${VNC_DIR}/chromium-gui.sh
autostart=true
autorestart=true
priority=65
startsecs=10
stderr_logfile=/var/log/chromium-gui.err.log
stdout_logfile=/var/log/chromium-gui.out.log"

# qwenpaw app
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
append_program qwenpaw-backup "command=bash ${SCRIPT_DIR}/backup-loop.sh
autostart=true
autorestart=true
priority=70
startsecs=5
environment=NAS_BASE_DIR=\"${NAS_BASE_DIR}\",QWENPAW_DATA_DIR=\"${QWENPAW_DATA_DIR}\",QWENPAW_SECRET_DIR=\"${QWENPAW_SECRET_DIR}\",CHROMIUM_PROFILE_DIR=\"${CHROMIUM_PROFILE_DIR}\",BACKUP_INTERVAL=\"${BACKUP_INTERVAL}\"
stderr_logfile=/var/log/qwenpaw-backup.err.log
stdout_logfile=/var/log/qwenpaw-backup.out.log"

green "✅ supervisor 配置完成"

# ============================================================
# 8. 主流程
# ============================================================
# 顺序: 装依赖(含 chromium/curl) → CDP 检测修复 → frp → 脚本 → supervisor → 启动
green "📦 安装系统依赖..."
install_deps
green "✅ 依赖安装完成"

# 检测/修复 chromium CDP 模式 (browser_use 依赖, 有问题先修好)
check_cdp

install_frp
write_frpc_toml
write_vnc_scripts
ensure_supervisor_base

# 启动时立即恢复 NAS 数据
yellow "♻️  从 NAS 恢复数据..."
NAS_BASE_DIR="$NAS_BASE_DIR" QWENPAW_DATA_DIR="$QWENPAW_DATA_DIR" QWENPAW_SECRET_DIR="$QWENPAW_SECRET_DIR" CHROMIUM_PROFILE_DIR="$CHROMIUM_PROFILE_DIR" \
    bash "${SCRIPT_DIR}/backup-loop.sh" restore || true

# ============================================================
# 9. 启动全部服务 + 验证
# ============================================================
green "🚀 启动服务..."
supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true
for svc in frpc xvfb xfce4 vnc-browser chromium-gui qwenpaw qwenpaw-backup; do
    supervisorctl start "$svc" 2>/dev/null || true
    sleep 1
done
sleep 3

# ============================================================
# 10. 输出
# ============================================================
clear
green "============================================================"
green "✅ QwenPaw 一键部署完成!"
green ""
green " 🌐 QwenPaw 面板:"
green "    http://${FRP_SERVER_IP}:${QWENPAW_REMOTE_PORT}"
green ""
if [ -n "$FRP_VNC_REMOTE_PORT" ]; then
    green " 🖥  noVNC 浏览器桌面:"
    green "    http://${FRP_SERVER_IP}:${FRP_VNC_REMOTE_PORT}/vnc.html"
fi
green ""
if [ -n "$FRP_SSH_REMOTE_PORT" ]; then
    green " 🔑 SSH:"
    green "    ssh -p ${FRP_SSH_REMOTE_PORT} root@${FRP_SERVER_IP}"
fi
green ""
green " 💾 数据持久化:"
green "    NAS: ${NAS_BASE_DIR}"
green "    qwenpaw 数据备份: ${NAS_BASE_DIR}/qwenpaw-data"
green "    chromium 配置: ${CHROMIUM_PROFILE_DIR}"
green "    每 ${BACKUP_INTERVAL}s 自动备份, 重启自动恢复"
green ""
green " 🌐 chromium CDP: ${CDP_PORT} (browser_use 用)"
green "============================================================"
echo ""
yellow "服务状态:"
supervisorctl status 2>/dev/null || true
echo ""
green "✅ 全部完成! 如服务未启动请检查: supervisorctl status"