#!/usr/bin/env bash
# entrypoint.sh - 容器启动入口 (借鉴 komari-argo-hug)
# 1. 加载 .env
# 2. 启动 cloudflared 隧道 (动态库模式)
# 3. 启动 VNC 浏览器服务
set -e

error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; }
info() { echo -e "\033[32m\033[01m$*\033[0m"; }

echo "=== chromium-QwenPaw entrypoint ==="

# 1. 加载 .env (如果存在)
if [ -f /app/.env ]; then
    info "加载 .env 配置..."
    set -a
    . /app/.env
    set +a
fi

# 2. 导出默认值
export PORT="${PORT:-8080}"
export VNC_PASSWORD="${VNC_PASSWORD:-password}"
export RESOLUTION="${RESOLUTION:-1280x720}"
export ARGO_DOMAIN="${ARGO_DOMAIN:-}"
export ARGO_AUTH="${ARGO_AUTH:-}"

# 3. 启动 cloudflared 隧道 (动态库模式, 类似 komari-argo-hug)
if [ -n "$ARGO_AUTH" ]; then
    info "启动 Cloudflare 隧道 (动态库模式)..."
    # 后台启动, 失败不阻塞
    env ARGO_AUTH="$ARGO_AUTH" python3 /app/start_cloudflared.py > /tmp/cloudflared.log 2>&1 &
    CLOUDFLARED_PID=$!
    echo "  隧道进程 PID: $CLOUDFLARED_PID"
else
    info "未设置 ARGO_AUTH, 跳过隧道 (仅本地 VNC 可用)"
fi

# 4. 启动 VNC 浏览器 (start.sh 会保持前台)
info "启动 VNC 浏览器服务 (PORT=${PORT})..."
exec /home/vncuser/start.sh