#!/bin/bash
# ============================================================
# 无交互一键部署: QwenPaw + VNC浏览器(Chromium)
# ============================================================
# 本地直接部署 (无需 FRP 隧道): VNC 浏览器桌面 + QwenPaw 面板都在本机端口
#
# 使用:
#   bash install.sh [-P 密码] [-r 分辨率]
#
# 常用可选:
#   -P, --password <PASS>   VNC 密码 + SSH root 密码 (默认 browser123)
#   -r, --resolution <RxR>  桌面分辨率 (默认 720x1280)
#   -V, --vnc-port <PORT>   noVNC 本地端口 (默认 8080)
#   -Q, --qwenpaw-port <PORT> QwenPaw 面板端口 (默认 8088)
#   -h, --help              显示帮助
#
# 环境变量扩展 (CDP_HEADED / CDP_START_URL):
#   CDP_HEADED=1   chromium-cdp 有头模式 (默认): AI 浏览器显示在 VNC, 人机同屏
#   CDP_HEADED=0   chromium-cdp 无头模式: 省内存, VNC 桌面显示独立 chromium-gui
#   CDP_START_URL=...  有头模式的启动页 (默认 Tampermonkey 扩展商店)
#
# 示例:
#   bash install.sh                                         # 默认 720x1280, noVNC:8080, 面板:8088
#   bash install.sh -P mypass -r 1280x720                   # 改密码 + 横屏
#   CDP_HEADED=0 bash install.sh                             # 无头模式
#
# 自动完成:
#   - 检测/修复本机 chromium CDP 模式 (browser_use 依赖)
#   - 自动探测 NAS 持久化路径 (不写死, 谁都能用)
#   - supervisor 托管全部服务 + 开机自启 + 数据定时备份到 NAS
#
# 幂等: 可重复执行, 已有配置自动跳过
# ============================================================
# 颜色/工具函数
red()   { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow(){ echo -e "\e[1;33m$1\033[0m"; }

# 显示帮助 (打印本文件头部注释, 去掉 # 前缀)
show_help() {
    awk 'NR>=2 && /^#/ { print substr($0, 3) } NR>=2 && !/^#/ { exit }' "$0"
    exit 0
}

# 默认配置 (环境变量优先, 命令行参数覆盖)
PASSWORD="${PASSWORD:-browser123}"               # 统一密码: VNC 密码 + SSH root 密码 (默认 browser123)
RESOLUTION="${RESOLUTION:-720x1280}"             # 桌面分辨率 (手机竖屏 720x1280 / 电脑横屏 1280x720)
VNC_PORT="${VNC_PORT:-8080}"                     # 本地 noVNC 端口
VNC_PASS="${VNC_PASS:-$PASSWORD}"                # VNC 密码 (默认 = PASSWORD)
QWENPAW_PORT="${QWENPAW_PORT:-8088}"             # 本地 qwenpaw app 端口
BACKUP_INTERVAL="${BACKUP_INTERVAL:-1800}"       # 数据备份间隔(秒), 默认 30 分钟
CDP_PORT="${CDP_PORT:-9222}"                     # chromium CDP 调试端口 (browser_use 用)
CDP_HEADED="${CDP_HEADED:-1}"                    # 1=有头模式(VNC可见,默认开) 0=无头模式(省内存)
CDP_START_URL="${CDP_START_URL:-https://chromewebstore.google.com/detail/tampermonkey/dhdgffkkebhmkfjojejmpbldmpobfkfo}"  # chromium-cdp 启动页

# 命令行参数解析
while [ $# -gt 0 ]; do
    case "$1" in
        -P|--password)     PASSWORD="$2"; VNC_PASS="$2"; shift 2 ;;
        -r|--resolution)   RESOLUTION="$2"; shift 2 ;;
        -V|--vnc-port)     VNC_PORT="$2"; shift 2 ;;
        -Q|--qwenpaw-port) QWENPAW_PORT="$2"; shift 2 ;;
        -h|--help)         show_help ;;
        *) red "❌ 未知参数: $1"; show_help ;;
    esac
done

# ============================================================
# 0. 基础检查
# ============================================================
set -e

[ "$(id -u)" != "0" ] && { red "❌ 需要 root 权限运行 (sudo bash install.sh ...)"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

green "============================================================"
green " QwenPaw + VNC浏览器(Chromium) 一键部署"
green " 本地端口: noVNC=${VNC_PORT} qwenpaw面板=${QWENPAW_PORT}"
green " 分辨率: ${RESOLUTION}  密码: ${VNC_PASS}"
green "============================================================"

# ============================================================
# 1. NAS 路径自动探测 (不写死, 任意机器可用)
# ============================================================
detect_nas() {
    [ -n "${NAS_BASE_DIR:-}" ] && { echo "$NAS_BASE_DIR"; return; }
    local candidate=""
    case "$PWD" in
        /run/csi/mount-root/nas/*|/mnt/nas/*|/nas/*|/data/nas/*)
            candidate="$PWD"
            ;;
    esac
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
    if [ -n "$candidate" ] && [ -d "$candidate" ] && touch "$candidate/.write_test" 2>/dev/null; then
        rm -f "$candidate/.write_test"
        echo "$candidate"
        return
    fi
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

QWENPAW_DATA_DIR="${QWENPAW_DATA_DIR:-/app/working}"
QWENPAW_SECRET_DIR="${QWENPAW_SECRET_DIR:-/app/working.secret}"
CHROMIUM_PROFILE_DIR="${CHROMIUM_PROFILE_DIR:-${NAS_BASE_DIR}/browser/chromium-gui-profile}"
mkdir -p "$NAS_BASE_DIR"/{qwenpaw-data,browser}
mkdir -p "$CHROMIUM_PROFILE_DIR"

# ============================================================
# 2. chromium CDP 模式检测与修复 (browser_use 依赖)
# ============================================================
check_cdp() {
    yellow "🔍 检查 chromium CDP 模式..."

    CHROMIUM_BIN="$(command -v chromium || command -v chromium-browser || command -v google-chrome || echo /usr/bin/chromium)"
    if [ ! -x "$CHROMIUM_BIN" ]; then
        red "❌ 未找到 chromium, 请先安装 (apt install chromium)"
        exit 1
    fi

    # chromium-cdp 启动命令 (有头/无头二选一)
    #   有头 (CDP_HEADED=1): 显示在 VNC 桌面, 能直接看到 AI 在浏览器里干什么
    #   无头 (CDP_HEADED=0): 后台运行, 省内存, 适合纯自动化不关心界面
    if [ "${CDP_HEADED:-1}" = "1" ]; then
        CDP_CMD="${CHROMIUM_BIN} --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-setuid-sandbox --remote-debugging-port=${CDP_PORT} --remote-debugging-address=127.0.0.1 --user-data-dir=/tmp/chromium-cdp-profile --window-size=${RESOLUTION} --window-position=0,0 --lang=zh-CN --accept-lang=zh-CN,zh ${CDP_START_URL}"
        CDP_ENV='environment=DISPLAY=":1"'
        CDP_GUI_AUTOSTART=false   # cdp 有头已占 VNC 桌面, 不再自动起独立的 chromium-gui
    else
        CDP_CMD="${CHROMIUM_BIN} --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-setuid-sandbox --remote-debugging-port=${CDP_PORT} --remote-debugging-address=127.0.0.1 --user-data-dir=/tmp/chromium-cdp-profile about:blank"
        CDP_ENV=""
        CDP_GUI_AUTOSTART=true    # cdp 无头时, VNC 桌面显示独立 chromium-gui (Bing)
    fi
    green "✅ chromium: $CHROMIUM_BIN"

    cdp_ok() {
        curl -s --max-time 3 "http://127.0.0.1:${CDP_PORT}/json/version" 2>/dev/null | grep -q "webSocketDebuggerUrl"
    }

    SUP_CONF=/etc/supervisor/conf.d/supervisord.conf
    [ -d /etc/supervisor/conf.d ] || SUP_CONF=/etc/supervisor/supervisord.conf
    local has_sup=no
    if [ -f "$SUP_CONF" ] && grep -q "\[program:chromium-cdp\]" "$SUP_CONF" 2>/dev/null; then
        has_sup=yes
    fi

    if cdp_ok; then
        green "✅ CDP 端口 ${CDP_PORT} 正常响应 (chromium 已就绪)"
        [ "$has_sup" = "yes" ] && green "✅ chromium-cdp 已由 supervisor 托管 (开机自启)" || has_sup=no
    else
        red "❌ CDP 端口 ${CDP_PORT} 无响应, 需要启动/修复 chromium"
        has_sup=no
    fi

    if [ "$has_sup" != "yes" ]; then
        yellow "🔧 配置 supervisor 托管 chromium-cdp..."
        mkdir -p "$(dirname "$SUP_CONF")"
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
command=${CDP_CMD}
${CDP_ENV}
autostart=true
autorestart=true
priority=60
startsecs=5
stderr_logfile=/var/log/chromium-cdp.err.log
stdout_logfile=/var/log/chromium-cdp.out.log
EOF
            green "✅ chromium-cdp program 已添加"
        fi

        supervisorctl reread 2>/dev/null || true
        supervisorctl update 2>/dev/null || true
        supervisorctl start chromium-cdp 2>/dev/null || true
        sleep 3

        if cdp_ok; then
            green "✅ chromium CDP 修复成功 (端口 ${CDP_PORT})"
        else
            yellow "⚠ supervisor 启动失败, 手动启动兜底..."
            nohup $CDP_CMD \
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

    if cdp_ok; then
        green "✅ CDP 检测通过: http://127.0.0.1:${CDP_PORT}/json/version"
    else
        red "❌ CDP 最终验证失败, browser_use 将无法工作"
        exit 1
    fi
}

# ============================================================
# 2.5 Xvnc (TigerVNC) 检测安装 —— v5 动态分辨率架构依赖
# ============================================================
# v5 用 Xvnc 替代 Xvfb+x11vnc: Xvnc 自带 RandR 动态分辨率 + 内置 VNC server
# 新机器若只有 Xvfb 没有 Xvnc, 自动 apt 安装 tigervnc-standalone-server
if ! command -v Xvnc >/dev/null 2>&1; then
    yellow "🔧 未找到 Xvnc (TigerVNC), 自动安装 tigervnc-standalone-server..."
    apt-get update -qq && apt-get install -y -qq tigervnc-standalone-server x11-apps
    command -v Xvnc >/dev/null 2>&1 && green "✅ Xvnc 安装完成: $(Xvnc -version 2>&1 | head -1)" \
        || { red "❌ Xvnc 安装失败, 请手动 apt install tigervnc-standalone-server"; exit 1; }
else
    green "✅ Xvnc 已就绪: $(Xvnc -version 2>&1 | head -1)"
fi

# ============================================================
# 2.6 noVNC + websockify 检测安装 —— v8 登录层依赖
# ============================================================
# noVNC 前端 (vnc.html) + websockify 库 (login_frontend.py 的 WebSocket 桥)
if [ ! -d /usr/share/novnc ] || [ ! -f /usr/share/novnc/vnc.html ]; then
    yellow "🔧 未找到 noVNC, 自动安装 novnc + python3-websockify..."
    apt-get update -qq && apt-get install -y -qq novnc python3-websockify
    [ -f /usr/share/novnc/vnc.html ] && green "✅ noVNC 安装完成: $(ls /usr/share/novnc/vnc.html)" \
        || { red "❌ noVNC 安装失败, 请手动 apt install novnc"; exit 1; }
else
    green "✅ noVNC 已就绪: $(ls /usr/share/novnc/vnc.html)"
fi
python3 -c "import websockify" 2>/dev/null && green "✅ python3-websockify 已就绪" \
    || { yellow "🔧 安装 python3-websockify..."; apt-get install -y -qq python3-websockify; }

# ============================================================
# 4. supervisor 配置 (托管全部服务 + 内联备份循环)
# ============================================================
SUP_CONF=/etc/supervisor/conf.d/supervisord.conf
[ -d /etc/supervisor/conf.d ] || SUP_CONF=/etc/supervisor/supervisord.conf
mkdir -p "$(dirname "$SUP_CONF")"

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

# VNC 浏览器桌面服务 (noVNC 本地端口 ${VNC_PORT})
VNC_DIR=/mnt/envd/vnc-browser
mkdir -p "$VNC_DIR"

    cat > "$VNC_DIR/chromium-gui.sh" <<EOF
#!/bin/bash
# chromium-gui.sh - 在 DISPLAY :1 (xfce4 桌面) 上启动带窗口的 chromium
# 注意: 必须用 exec 前台直启 (不要 & 后台 + 守护循环), 否则 supervisorctl stop
#       只杀脚本壳, chromium 变孤儿进程继续占桌面 → 白屏/抢屏 (2026-08-15 教训)
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
  --window-position=0,0 \\
  --user-data-dir="\$NAS_DIR" \\
  --disable-dev-shm-usage \\
  --disable-gpu \\
  --disable-software-rasterizer \\
  --disable-background-networking \\
  --hide-crash-restore-bubble \\
  --disable-session-crashed-bubble \\
  --disable-infobars \\
  --no-first-run \\
  --disable-features=Translate,BackForwardCache \\
  --js-flags=--max-old-space-size=1024 \\
  ${CDP_START_URL}
EOF

    cat > "$VNC_DIR/vnc-browser.sh" <<EOF
#!/bin/bash
# vnc-browser.sh - 暴露 Xvnc 桌面 (DISPLAY :1) 为 noVNC 网页浏览器 (带登录层)
# 架构: Xvnc (TigerVNC) + login_frontend.py (websockify + 账号密码登录页) + noVNC vnc.html
set -u
VNC_PORT="\${VNC_PORT:-${VNC_PORT}}"
VNC_DISPLAY="\${VNC_DISPLAY:-:1}"
VNC_USER="\${VNC_USER:-qwenpaw}"
VNC_PASS="\${VNC_PASS:-${VNC_PASS}}"
RFB_PORT=5900
LOG_DIR=/var/log
VNC_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
mkdir -p /root/.vnc
printf '%s\n' "\${VNC_PASS}" > /root/.vnc/passwdfile
chmod 600 /root/.vnc/passwdfile
echo "=== vnc-browser 启动 (port \${VNC_PORT}, display \${VNC_DISPLAY}) ==="
for old in \$(pgrep -f "login_frontend.py|websockify.*\${VNC_PORT}"); do
  [ -n "\$old" ] && kill "\$old" 2>/dev/null
done
sleep 1
for i in \$(seq 1 50); do
  [ -S "/tmp/.X11-unix/X\${VNC_DISPLAY#:}" ] && break
  sleep 0.2
done
[ ! -S "/tmp/.X11-unix/X\${VNC_DISPLAY#:}" ] && { echo "❌ DISPLAY \${VNC_DISPLAY} 不存在"; exit 1; }
rm -f /tmp/.X\${VNC_DISPLAY#:}-lock 2>/dev/null || true
# noVNC chrome.sh 风格补丁 (幂等): resize=scale + 控制栏收起 + 单页无横向滚动
if [ -f "\$VNC_DIR/novnc-chromesh-patch.py" ]; then
  python3 "\$VNC_DIR/novnc-chromesh-patch.py" 2>/dev/null || echo "⚠️ noVNC patch 失败"
fi
# 登录层 + websockify 桥 (替代直接 websockify): 根路径=登录页, cookie 校验 WS
export VNC_PORT VNC_USER VNC_PASS VNC_WEB_DIR="/usr/share/novnc" RFB_PORT
python3 "\$VNC_DIR/login_frontend.py" > "\${LOG_DIR}/novnc.log" 2>&1 &
WEB_PID=\$!
sleep 2
echo "✅ 登录页: http://localhost:\${VNC_PORT}/   (账号 \${VNC_USER} / 密码 \${VNC_PASS})"
echo "✅ 登录后单页: /vnc.html?autoconnect=1&resize=scale (无横向滚动)"
echo "✅ 切分辨率: \$VNC_DIR/vnc-resize.sh phone|desktop|WxH"
wait "\${WEB_PID}" 2>/dev/null
EOF

    cat > "$VNC_DIR/novnc-chromesh-patch.py" <<'PYEOF'
#!/usr/bin/env python3
"""noVNC chrome.sh 风格补丁 (幂等):
1. ui.js: 连接后侧边控制栏保持展开 (去掉 2 秒自动收起)
2. base.css: 底部状态栏常显 (参考 chrome.sh 底部工具栏)
3. ui.js: resize 默认 scale (iOS Safari 铺满)
4. vnc.html: 锁定 viewport (iOS Safari 修复 2026-08-18)
    iOS Safari 对 noVNC 整体放大后, 页面缩放机制会把桌面缩小到整页, 造成"缩放不正常"
    (安卓 Chrome 不放大整体页面故正常). 锁定 viewport 后 resize=scale 的 canvas 按
    视口铺满, 不受 Safari 缩放影响.
用法: python3 /mnt/envd/vnc-browser/novnc-chromesh-patch.py
"""
import re
import sys
import os

NOVNC = "/usr/share/novnc"
UJS = os.path.join(NOVNC, "app/ui.js")
CSS = os.path.join(NOVNC, "app/styles/base.css")
VNC_HTML = os.path.join(NOVNC, "vnc.html")

changed = []

def patch_file(path, marker, old, new):
    """如果 marker 不存在就做替换 (幂等)"""
    if not os.path.isfile(path):
        print(f"  ⚠️ 不存在: {path}")
        return
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    if marker in content:
        print(f"  ⏭️ 已打过补丁 (跳过): {os.path.basename(path)}")
        return
    if old in content:
        content = content.replace(old, new, 1)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        changed.append(path)
        print(f"  ✅ patched: {path}")
    else:
        print(f"  ❌ 找不到 old 内容: {os.path.basename(path)}")

print("=== noVNC chrome.sh 风格补丁 ===")

# 1. ui.js: resize 默认 scale
patch_file(
    UJS,
    marker="initSetting('resize', 'scale')",
    old="UI.initSetting('resize', 'off');",
    new="UI.initSetting('resize', 'scale');",
)

# 2. ui.js: 连接后不自动收起侧边栏
patch_file(
    UJS,
    marker="参考 chrome.sh, 侧边工具栏保持展开",
    old="            // Hide the controlbar after 2 seconds\n            UI.closeControlbarTimeout = setTimeout(UI.closeControlbar, 2000);",
    new="            // 2026-08-18: 参考 chrome.sh, 侧边工具栏保持展开 (不自动收起)\n            // UI.closeControlbarTimeout = setTimeout(UI.closeControlbar, 2000);\n            UI.keepControlbar();\n            UI.openControlbar();",
)

# 3. base.css: 底部状态栏常显 (bottom + 一直可见)
patch_file(
    CSS,
    marker="参考 chrome.sh, 底部工具栏常显",
    old="""#noVNC_status {
  position: fixed;
  top: 0;
  left: 0;
  width: 100%;
  z-index: 100;
  transform: translateY(-100%);

  cursor: pointer;

  transition: 0.5s ease-in-out;

  visibility: hidden;
  opacity: 0;""",
    new="""#noVNC_status {
  position: fixed;
  bottom: 0;
  left: 0;
  width: 100%;
  z-index: 100;
  /* 2026-08-18: 参考 chrome.sh, 底部工具栏常显 (原 top:-100% 隐藏) */
  transform: none;

  cursor: pointer;

  transition: 0.5s ease-in-out;

  visibility: visible;
  opacity: 1;""",
)

# 4. vnc.html: 锁定 viewport (iOS Safari 修复)
_VIEWPORT_OLD = [
    '<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0">',
    '<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">',
]
_VIEWPORT_NEW = '<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no, viewport-fit=cover">'
if os.path.isfile(VNC_HTML):
    content = open(VNC_HTML, encoding="utf-8").read()
    if _VIEWPORT_NEW in content:
        print("  ⏭️ 已打过补丁 (跳过): vnc.html viewport")
    else:
        changed_vp = False
        for old_vp in _VIEWPORT_OLD:
            if old_vp in content:
                content = content.replace(old_vp, _VIEWPORT_NEW, 1)
                changed_vp = True
                break
        if changed_vp:
            open(VNC_HTML, "w", encoding="utf-8").write(content)
            changed.append(VNC_HTML)
            print("  ✅ patched: vnc.html viewport 锁定")
        else:
            print("  ❌ 找不到 vnc.html 旧 viewport 内容")

print(f"=== 完成: {len(changed)} 个文件被修改 ===")
sys.exit(0)
PYEOF
    chmod +x "$VNC_DIR/novnc-chromesh-patch.py"

    cat > "$VNC_DIR/login_frontend.py" <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
单网页登录层 for noVNC (v8 改造)
================================
参考 jlesage/docker-baseimage-gui 的 WEB_AUTHENTICATION 思路：
  - 访问 http://host:PORT/       → 返回漂亮登录页 (账号 + 密码, 移动端自适应, 无左右滑动)
  - POST /login                 → 校验账号密码, 通过则种 cookie (VNC_AUTH=1, 24h)
  - 静态资源(vnc.html, app/*)   → 校验 cookie, 未登录一律 403 重定向登录页
  - websockify WS 升级请求      → 校验 cookie, 未登录拒绝
  - 登录后进入 noVNC 单页 (vnc.html?autoconnect=1&resize=scale), 画面铺满无横向滚动

依赖: websockify 库 (自带), 标准库, 零第三方
"""
import os
import sys
import hmac
import time
import hashlib
import urllib.parse
import http.cookies as cookies_mod
from websockify import websocketproxy
from websockify import auth_plugins as auth

# ---------------- 配置 ----------------
WEB_DIR = os.environ.get("VNC_WEB_DIR", "/usr/share/novnc")
AUTH_SECRET = os.environ.get("VNC_AUTH_SECRET", "qwenpaw-novnc-secret")
USERNAME = os.environ.get("VNC_AUTH_USER", "admin")
PASSWORD = os.environ.get("VNC_AUTH_PASS", "pingmikeAs")
COOKIE_NAME = "VNC_AUTH"
COOKIE_TTL = 24 * 3600
# 允许不登录就能访问的路径 (登录页/登录 POST)
PUBLIC_PATHS = {"/", "/index.html", "/login", "/favicon.ico"}

class LoginError(auth.AuthenticationError):
    pass

# ---------------- 自定义认证插件: 校验 cookie ----------------
class CookieAuth(auth.BasePlugin):
    def __init__(self, src=None):
        super().__init__(src)

    def authenticate(self, headers, target_host, target_port):
        cookie = headers.get('Cookie', '')
        if not cookie:
            raise LoginError(
                response_code=403,
                response_headers={"Location": "/"},
                response_msg="Not logged in",
            )
        c = cookies_mod.SimpleCookie()
        try:
            c.load(cookie)
        except Exception:
            raise LoginError(response_code=403, response_headers={"Location": "/"}, response_msg="Bad cookie")
        token = c.get(COOKIE_NAME)
        if token is None:
            raise LoginError(response_code=403, response_headers={"Location": "/"}, response_msg="Not logged in")
        if not valid_token(token.value):
            raise LoginError(response_code=403, response_headers={"Location": "/"}, response_msg="Invalid token")

def valid_token(tok):
    try:
        ts, sig = tok.split(".", 1)
        ts = int(ts)
    except Exception:
        return False
    if time.time() - ts > COOKIE_TTL or ts > time.time() + 300:
        return False
    expect = make_sig(ts)
    return hmac.compare_digest(expect, sig)

def make_sig(ts):
    return hmac.new(AUTH_SECRET.encode(), ("%d:%s:%s" % (ts, USERNAME, PASSWORD)).encode(), hashlib.sha256).hexdigest()

# ---------------- 自定义 RequestHandler ----------------
class LoginHandler(websocketproxy.ProxyRequestHandler):
    def do_GET(self):
        # 根路径 → 登录页; 其余(静态资源 + WS 升级)校验 cookie
        if self.path in ("/", "/index.html"):
            html = LOGIN_PAGE
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html.encode())))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(html.encode())
            return
        super().do_GET()

    def do_POST(self):
        if self.path != "/login":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace")
        data = urllib.parse.parse_qs(body)
        user = (data.get("username") or [""])[0]
        pw = (data.get("password") or [""])[0]
        if user == USERNAME and pw == PASSWORD:
            ts = int(time.time())
            tok = "%d.%s" % (ts, make_sig(ts))
            self.send_response(302)
            self.send_header("Location", "/vnc.html?autoconnect=1&resize=scale&show_dot=0")
            self.send_header("Set-Cookie", "%s=%s; Path=/; Max-Age=%d; HttpOnly; SameSite=Lax" % (COOKIE_NAME, tok, COOKIE_TTL))
            self.end_headers()
        else:
            self.send_response(302)
            self.send_header("Location", "/?error=1")
            self.end_headers()

    # 静态资源 + WS 都要认证; 登录页/登录 POST 除外
    def auth_connection(self):
        if self.path.split("?")[0] in PUBLIC_PATHS:
            return
        super().auth_connection()

LOGIN_PAGE = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no, viewport-fit=cover">
<title>Chromium 云端浏览器</title>
<style>
:root { --bg1:#0f2027; --bg2:#203a43; --bg3:#2c5364; --accent:#00d4ff; }
* { margin:0; padding:0; box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
html,body { height:100%; overflow:hidden; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif; }
body {
  display:flex; align-items:center; justify-content:center;
  background:linear-gradient(135deg,var(--bg1),var(--bg2),var(--bg3));
}
.card {
  width:min(92vw, 400px); padding:38px 30px 30px; border-radius:22px;
  background:rgba(255,255,255,.92); backdrop-filter:blur(14px);
  box-shadow:0 24px 60px rgba(0,0,0,.45); text-align:center;
  animation:up .45s ease;
}
@keyframes up { from { transform:translateY(18px); opacity:0 } to { transform:none; opacity:1 } }
.logo { width:64px; height:64px; margin:0 auto 12px; border-radius:18px;
  background:linear-gradient(135deg,#00d4ff,#7b2ff7); display:flex; align-items:center; justify-content:center;
  font-size:28px; color:#fff; box-shadow:0 8px 22px rgba(0,212,255,.35); }
h1 { font-size:20px; color:#1b2a38; margin-bottom:4px; }
.sub { font-size:13px; color:#7a8a99; margin-bottom:24px; }
.field { margin-bottom:12px; }
label { display:block; text-align:left; font-size:12px; color:#5a6b7a; margin-bottom:5px; font-weight:600; }
input { width:100%; padding:13px 16px; border-radius:12px; border:1.5px solid #dde5ec;
  font-size:15px; outline:none; background:#f6f9fc; color:#1b2a38; transition:.2s; }
input:focus { border-color:var(--accent); background:#fff; box-shadow:0 0 0 3px rgba(0,212,255,.18); }
button { width:100%; margin-top:8px; padding:13px; border:none; border-radius:12px;
  background:linear-gradient(135deg,#00b4d8,#4b7bec); color:#fff; font-size:16px; font-weight:600;
  cursor:pointer; box-shadow:0 8px 20px rgba(0,180,216,.35); transition:.2s; }
button:active { transform:scale(.97); }
.err { display:none; margin-top:14px; padding:10px; border-radius:10px; background:#fff0f0; color:#d64040; font-size:13px; }
.secure { margin-top:16px; font-size:11px; color:#9aa8b5; }
</style>
</head>
<body>
<div class="card">
  <div class="logo">🌐</div>
  <h1>Chromium 云端浏览器</h1>
  <div class="sub">登录后进入远程桌面</div>
  <form method="post" action="/login" id="f">
    <div class="field">
      <label for="u">账号</label>
      <input type="text" id="u" name="username" placeholder="请输入账号" autocomplete="username" autofocus required>
    </div>
    <div class="field">
      <label for="p">密码</label>
      <input type="password" id="p" name="password" placeholder="请输入密码" autocomplete="current-password" required>
    </div>
    <button type="submit">进 入</button>
  </form>
  <div class="err" id="err">账号或密码不对哦，再试一次~</div>
  <div class="secure">🔒 单页面 · 无左右滑动 · 移动端适配</div>
</div>
<script>
if (location.search.indexOf('error=1') >= 0) { document.getElementById('err').style.display='block'; }
</script>
</body>
</html>
"""

def main():
    server = websocketproxy.WebSocketProxy(
        listen_port=int(os.environ.get("VNC_PORT", "8080")),
        listen_host="",
        web=WEB_DIR,
        RequestHandlerClass=LoginHandler,
        auth_plugin=CookieAuth(),
        target_host="127.0.0.1",
        target_port=int(os.environ.get("RFB_PORT", "5900")),
        web_auth=True,
    )
    server.start_server()

if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$VNC_DIR/login_frontend.py"

    cat > "$VNC_DIR/vnc-resize.sh" <<'EOF'
#!/bin/bash
# vnc-resize.sh - 动态切换虚拟桌面分辨率 (Xvnc TigerVNC 原生支持 RandR)
# 用法: vnc-resize.sh phone|desktop|WxH|status
set -u
DISPLAY="${DISPLAY:-:1}"
export DISPLAY

get_size() {
  xrandr --query | grep -oP '\d+x\d+(?=\s)' | head -1
}

case "${1:-}" in
  phone|mobile|竖屏)
    xrandr -s 720x1280 2>&1 ;;
  desktop|pc|横屏)
    xrandr -s 1280x720 2>&1 ;;
  ''|status|current)
    echo "当前分辨率: $(get_size)" ;;
  *)
    if echo "$1" | grep -qE '^[0-9]+x[0-9]+$'; then
      xrandr -s "$1" 2>&1
    else
      echo "用法: $0 [phone|desktop|WxH]"
      exit 1
    fi ;;
esac
echo "当前分辨率: $(get_size)"
EOF

    chmod +x "$VNC_DIR"/chromium-gui.sh "$VNC_DIR"/vnc-browser.sh "$VNC_DIR"/vnc-resize.sh "$VNC_DIR"/login_frontend.py "$VNC_DIR"/novnc-chromesh-patch.py
    green "✅ VNC/Chromium 脚本已生成: $VNC_DIR"

    append_program xvfb "command=/bin/sh -c \"rm -f /tmp/.X1-lock /tmp/.X11-unix/X1; mkdir -p /tmp/.X11-unix /root/.vnc; exec /usr/bin/Xvnc :1 -geometry ${RESOLUTION} -depth 24 -SecurityTypes None -localhost -AcceptSetDesktopSize=1 -AlwaysShared -rfbport 5900\"
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
environment=VNC_PORT=\"${VNC_PORT}\",VNC_PASS=\"${VNC_PASS}\"
stderr_logfile=/var/log/vnc-browser.err.log
stdout_logfile=/var/log/vnc-browser.out.log"

    append_program chromium-gui "command=${VNC_DIR}/chromium-gui.sh
autostart=${CDP_GUI_AUTOSTART}
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

# 内联备份循环 (每 BACKUP_INTERVAL 秒同步 qwenpaw 数据到 NAS, 重启自动恢复)
append_program qwenpaw-backup "command=/bin/sh -c 'while true; do
  mkdir -p ${NAS_BASE_DIR}/qwenpaw-data/working ${NAS_BASE_DIR}/qwenpaw-data/working.secret
  [ -d ${QWENPAW_DATA_DIR} ] && tar cf - -C ${QWENPAW_DATA_DIR} --exclude=\"*.pyc\" --exclude=__pycache__ . 2>/dev/null | tar xf - -C ${NAS_BASE_DIR}/qwenpaw-data/working 2>/dev/null
  [ -d ${QWENPAW_SECRET_DIR} ] && tar cf - -C ${QWENPAW_SECRET_DIR} . 2>/dev/null | tar xf - -C ${NAS_BASE_DIR}/qwenpaw-data/working.secret 2>/dev/null
  sleep ${BACKUP_INTERVAL}
done'
autostart=true
autorestart=true
priority=70
startsecs=5
stderr_logfile=/var/log/qwenpaw-backup.err.log
stdout_logfile=/var/log/qwenpaw-backup.out.log"

green "✅ supervisor 配置完成"

# ============================================================
# 5. 启动前恢复 NAS 数据
# ============================================================
yellow "♻️  从 NAS 恢复数据..."
QB="${NAS_BASE_DIR}/qwenpaw-data"
if [ -d "$QB/working" ] && [ -n "$(ls -A "$QB/working" 2>/dev/null)" ]; then
    mkdir -p "$QWENPAW_DATA_DIR"
    tar cf - -C "$QB/working" . 2>/dev/null | tar xf - -C "$QWENPAW_DATA_DIR" 2>/dev/null
    green "✅ 恢复 qwenpaw 数据 → $QWENPAW_DATA_DIR"
fi
if [ -d "$QB/working.secret" ] && [ -n "$(ls -A "$QB/working.secret" 2>/dev/null)" ]; then
    mkdir -p "$QWENPAW_SECRET_DIR"
    tar cf - -C "$QB/working.secret" . 2>/dev/null | tar xf - -C "$QWENPAW_SECRET_DIR" 2>/dev/null
    green "✅ 恢复 secret → $QWENPAW_SECRET_DIR"
fi

# ============================================================
# 6. 启动全部服务 + 输出
# ============================================================
green "🚀 启动服务..."
supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true
for svc in xvfb xfce4 vnc-browser chromium-gui qwenpaw qwenpaw-backup; do
    supervisorctl start "$svc" 2>/dev/null || true
    sleep 1
done
sleep 3

clear
green "============================================================"
green "✅ QwenPaw 一键部署完成!"
green ""
green " 🖥  noVNC 浏览器桌面 (本地):"
green "    http://localhost:${VNC_PORT}/vnc.html   (密码 = ${VNC_PASS})"
green ""
green " 🌐 QwenPaw 面板 (本地):"
green "    http://localhost:${QWENPAW_PORT}"
green ""
green " 💾 数据持久化:"
green "    NAS: ${NAS_BASE_DIR}"
green "    每 ${BACKUP_INTERVAL}s 自动备份, 重启自动恢复"
green ""
green " 🌐 chromium CDP: ${CDP_PORT} (browser_use 用)"
green "============================================================"
echo ""
yellow "服务状态:"
supervisorctl status 2>/dev/null || true
echo ""
green "✅ 全部完成! 如服务未启动请检查: supervisorctl status"