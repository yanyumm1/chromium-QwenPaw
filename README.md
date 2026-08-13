# Auto Firefox (Sap-FireFox-QwenPaw)

云端 Firefox 浏览器（VNC + noVNC），支持 Cloudflare Tunnel 隧道访问。
改造自 SAP Cloud Foundry 部署方案，借鉴 [komari-argo-hug](https://github.com/pingmike2/komari-argo-hug) 的隧道机制。

## ✨ 功能

- 🦊 Firefox 浏览器 + xfce 桌面
- 🖥️ noVNC 网页访问（浏览器打开即用）
- 🌐 Cloudflare Tunnel 隧道（动态库模式，无需官方二进制）
- 💾 GitHub 备份/还原 Firefox 配置（可选）
- 📊 哪吒监控（可选）

## 🚀 快速开始

### 1. 配置 .env

复制 `.env.example` 为 `.env` 并填写：

```bash
cp .env.example .env
```

必填项：

| 变量 | 说明 |
|------|------|
| `ARGO_AUTH` | Cloudflare Tunnel token（Zero Trust → Networks → Tunnels） |
| `PORT` | noVNC 端口（默认 `8080`） |
| `VNC_PASSWORD` | VNC 密码（默认 `password`，建议修改） |

### 2. 构建镜像

```bash
docker build -t firefox-vnc .
```

### 3. 运行

```bash
docker run -d \
  --name firefox-vnc \
  -p 8080:8080 \
  --env-file .env \
  firefox-vnc
```

访问 `http://localhost:8080/vnc.html`，密码 `VNC_PASSWORD`。

### 4. Cloudflare Tunnel 配置

隧道自动用 `ARGO_AUTH` token 连接，无需额外配置。在 CF 后台加一条规则：

```
Public hostname: 你的域名
Type: HTTP
URL: localhost:8080
```

## 🛰️ 隧道机制（借鉴 komari-argo-hug）

- `start_cloudflared.py`：从 GitHub Releases 下载 `bot-{arch}.so` 动态库（ctypes 封装 cloudflared），调用 `StartCloudflared` 启动隧道
- `Release.yml`：每日 UTC 02:00 自动同步上游 `bot.so` 到 Releases，SHA256 对比，有变化才发布
- 支持 amd64 / arm64 / freebsd 自动适配

## 💾 Firefox 配置备份（可选）

设置以下环境变量启用 GitHub 备份：

| 变量 | 说明 |
|------|------|
| `GBACKUP_USER` | GitHub 用户名 |
| `GBACKUP_REPO` | 备份仓库 |
| `GBACKUP_TOKEN` | GitHub PAT |
| `AUTO_BACKUP` | `YES` 启用定时备份（默认 30 分钟） |
| `AUTO_RESTORE` | `YES` 启动时自动还原 |

## 📊 哪吒监控（可选）

设置 `NEZHA_SERVER` / `NEZHA_KEY` 启用。

## ⚠️ 注意事项

- 本项目仅用于学习交流，禁止商业用途
- 建议设置强 `VNC_PASSWORD`，避免空密码
- 隧道 token 属于敏感信息，请勿提交 `.env` 到仓库
