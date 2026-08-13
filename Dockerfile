# chromium-QwenPaw - 云端 Chromium 浏览器 (VNC + noVNC + Cloudflare Tunnel)
# 改造自 SAP-Auto-deploy-Firefox, 借鉴 komari-argo-hug 隧道机制

FROM alpine:latest

# 安装必要的软件包
RUN apk add --no-cache \
        mesa-dri-gallium \
        libpulse \
        curl \
        xdotool \
        xvfb \
        x11vnc \
        font-dejavu \
        chromium \
        websockify \
        novnc \
        bash \
        git \
        rsync \
        python3 && \
    rm -rf /var/cache/apk/*

# 创建非 root 用户
RUN adduser -D -s /bin/bash vncuser

# 复制启动脚本到容器
COPY start.sh /home/vncuser/start.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY start_cloudflared.py /app/start_cloudflared.py

# 赋予执行权限并设置归属
RUN chmod +x /home/vncuser/start.sh && \
    chown vncuser:vncuser /home/vncuser/start.sh && \
    chmod +x /usr/local/bin/entrypoint.sh && \
    chmod +x /app/start_cloudflared.py

# 切换到非 root 用户
USER vncuser
WORKDIR /home/vncuser

# 声明暴露的端口 (noVNC, 默认 8080; CF 会自动注入 $PORT 或 .env 覆盖)
EXPOSE 8080

# 默认启动命令
CMD ["/usr/local/bin/entrypoint.sh"]