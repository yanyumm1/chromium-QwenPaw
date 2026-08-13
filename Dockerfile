FROM alpine:latest

# 安装必要的软件包
RUN apk update && \
    apk add --no-cache \
        mesa-dri-gallium \
        libpulse \
        curl \
        xdotool \
        xvfb \
        x11vnc \
        font-dejavu \
        firefox \
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

# 赋予执行权限并设置归属
RUN chmod +x /home/vncuser/start.sh && \
    chown vncuser:vncuser /home/vncuser/start.sh

# 切换到非 root 用户
USER vncuser
WORKDIR /home/vncuser

# 声明暴露的端口（仅声明，CF 会自动注入 $PORT）
EXPOSE 8080

# 默认启动命令
CMD ["/home/vncuser/start.sh"]