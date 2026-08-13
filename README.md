# chromium-QwenPaw — 云端 Chromium 浏览器 (VNC + noVNC)

在服务器/容器里跑一个 **Chromium 浏览器 + xfce4 桌面**，通过 **noVNC 网页**让你在任何设备（手机也行）上远程操作这个浏览器。当前线上地址：`http://YOUR_SERVER_IP:YOUR_PORT/vnc.html`

> 本项目是 **SAP-Auto-deploy-Firefox** 的 Chromium 改造版，最终采用 **supervisor 托管 + frp 隧道** 方案（非 Docker/CF Tunnel），架构详见下文。

---

## 🚀 一键还原 QwenPaw（frp + Chromium 组合）

本仓库提供 `deploy/` 一键还原模板，把 **QwenPaw（AI 助手）+ Chromium 浏览器桌面** 通过 frp 隧道暴露到公网，支持手机/电脑远程操作。适合在任意一台 qwenpaw 机器上快速还原环境。

### 使用步骤（两步）

**第 1 步：在你的 VPS 公网服务器上装 FRP 服务端**

```bash
bash <(curl -Ls https://main.ssss.nyc.mn/frp.sh)
```

按菜单选 **1 安装 FRP 服务端 (公网服务器)**，脚本会输出：
- `监听IP`（服务器公网 IP）
- `监听端口`（默认 `7000`）
- `认证TOKEN`（随机生成的一串）

**记下这几个值**，等下填进模板。

**第 2 步：在任意 qwenpaw 机器上一键还原**

```bash
# 1. 进入 deploy 目录
cd deploy

# 2. 复制配置模板并填写 (填第1步拿到的值)
cp config.env.example config.env
vim config.env   # 填 FRP_SERVER_IP / FRP_TOKEN / 各端口 / VNC密码

# 3. 一键还原
bash restore.sh
```

### config.env 需要填写什么

| 配置项 | 来源 | 说明 |
|--------|------|------|
| `FRP_SERVER_IP` | frp.sh 输出的「监听IP」 | frp 服务端公网 IP |
| `FRP_SERVER_PORT` | frp.sh 输出的「监听端口」 | 默认 `7000` |
| `FRP_TOKEN` | frp.sh 输出的「认证TOKEN」 | 与服务端一致的 token |
| `FRP_SSH_REMOTE_PORT` | 自己定 | SSH 公网映射端口 |
| `FRP_VNC_REMOTE_PORT` | 自己定 | noVNC 公网端口（vnc.html） |
| `FRP_APP_REMOTE_PORT` | 自己定（可选） | QwenPaw 面板公网端口 |
| `VNC_PASSWORD` | 自己定 | noVNC 访问密码 |
| `RESOLUTION` | 自己定 | 桌面分辨率（默认 `720x1280`） |
| `NAS_BASE_DIR` | 自动检测 | 数据持久化目录 |
| `BACKUP_INTERVAL` | 自己定 | 定时备份间隔（默认 1800s） |

### 还原完成后

```
🌐 noVNC 浏览器: http://FRP_SERVER_IP:FRP_VNC_REMOTE_PORT/vnc.html
🌐 QwenPaw 面板: http://FRP_SERVER_IP:FRP_APP_REMOTE_PORT
🔑 SSH:          ssh -p FRP_SSH_REMOTE_PORT root@FRP_SERVER_IP
```

### ✨ 自带能力

- **开机自启**：所有服务由 supervisor 托管（`autostart=true`），容器/机器重启自动拉起
- **数据定时存 NAS**：qwenpaw 数据（config/聊天记录）+ chromium 配置每 `BACKUP_INTERVAL` 秒同步到 NAS
- **重启自动恢复**：启动时检查 NAS，有备份就自动恢复到本地，qwenpaw 和浏览器数据都不丢
- **幂等**：restore.sh 可重复执行，不会重复添加配置

> 原理同下方架构：frpc 把本地 8080(noVNC)/8088(qwenpaw)/22(ssh) 映射到公网，supervisor 托管 chromium 桌面 + qwenpaw 进程。

---

## 🏗️ 架构总览

```
你的手机/电脑浏览器 (noVNC 页面)
        │
        ▼
  frp 公网入口 YOUR_SERVER_IP:YOUR_PORT   ←── frpc 隧道, 直连服务器
        │
        ▼
  websockify :8080   (noVNC 网页 + WebSocket 代理)
        │
        ▼
  x11vnc :5900   (把 X 桌面变成 VNC 服务, -nopw 无密码)
        │
        ▼
  Xvfb :1   (虚拟屏幕, 720x1280 竖屏)
        │
        ├── xfce4 桌面 (任务栏/窗口管理器)
        └── chromium-gui (全屏浏览器窗口)
```

**所有进程都由 supervisor 托管**，开机自启、崩溃自动拉起，配置在
`/etc/supervisor/conf.d/supervisord.conf`。

---

## 📂 需要的文件

| 文件 | 作用 | 位置 |
|------|------|------|
| `chromium-gui.sh` | 启动全屏 chromium 窗口（720x1280, 数据持久化 NAS） | `/mnt/envd/vnc-browser/` |
| `vnc-browser.sh` | 启动 x11vnc + websockify(noVNC) | `/mnt/envd/vnc-browser/` |
| `supervisord.conf` + `.template` | supervisor 托管 xvfb/xfce4/chromium/vnc | `/etc/supervisor/conf.d/` |
| `frpc.toml` | frp 客户端配置（把 8080 映射到公网 YOUR_PORT） | `/home/frp/` |
| `frpc` | frp 客户端二进制 | `/home/frp/` |

仓库内对应文件：
- `chromium-gui.sh` ↔ `scripts/chromium-gui.sh`
- `vnc-browser.sh` ↔ `scripts/vnc-browser.sh`
- 部署说明：见下方「部署步骤」

---

## 🚀 部署步骤（从零搭建）

> 以下基于 CentOS/Debian 类系统 + root 权限，容器环境同理。

### 1. 安装依赖

```bash
# X 虚拟屏幕 + 桌面 + 浏览器 + VNC 工具
apt update && apt install -y \
    xvfb x11vnc xfce4 chromium websockify novnc \
    supervisor curl xdotool dbus-x11
# 或 alpine: apk add xvfb x11vnc xfce4 chromium websockify novnc supervisor xdotool dbus-x11
```

### 2. 准备脚本

```bash
mkdir -p /mnt/envd/vnc-browser
cp chromium-gui.sh /mnt/envd/vnc-browser/
cp vnc-browser.sh /mnt/envd/vnc-browser/
chmod +x /mnt/envd/vnc-browser/*.sh
```

### 3. 配置 supervisor

在 `/etc/supervisor/conf.d/supervisord.conf` 追加以下 program（**注意：模板也要同步改**，容器重启会用 template 覆盖 conf）：

```ini
[program:xvfb]          # 虚拟屏幕, 必须先起
command=/bin/sh -c "rm -f /tmp/.X1-lock /tmp/.X11-unix/X1; mkdir -p /tmp/.X11-unix; exec /usr/bin/Xvfb :1 -screen 0 720x1280x24"
autostart=true
autorestart=true
priority=10
environment=DISPLAY=":1"

[program:xfce4]         # 桌面环境
command=/bin/sh -c 'export DISPLAY=:1; for i in $(seq 1 200); do [ -S /tmp/.X11-unix/X1 ] && break; sleep 0.1; done; exec dbus-run-session startxfce4'
autostart=true
autorestart=true
priority=20
environment=DISPLAY=":1"

[program:vnc-browser]   # x11vnc + noVNC
command=/mnt/envd/vnc-browser/vnc-browser.sh
autostart=true
autorestart=true
priority=58
startsecs=5
environment=VNC_PORT="8080",VNC_PASS="your-vnc-password"
stderr_logfile=/var/log/vnc-browser.err.log
stdout_logfile=/var/log/vnc-browser.out.log

[program:chromium-gui]  # 浏览器窗口
command=/mnt/envd/vnc-browser/chromium-gui.sh
autostart=true
autorestart=true
priority=65
startsecs=10
stderr_logfile=/var/log/chromium-gui.err.log
stdout_logfile=/var/log/chromium-gui.out.log
```

```bash
supervisorctl reread && supervisorctl update
```

### 4. 配置 frp 隧道（公网访问）

下载 frpc，写配置 `/home/frp/frpc.toml`：

```toml
serverAddr = "你的服务器IP"
serverPort = YOUR_FRP_SERVER_PORT

auth.method = "token"
auth.token = "你的token"

[[proxies]]
name = "novnc_qwenpaw"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8080
remotePort = YOUR_PORT    # 公网访问端口
```

```bash
/home/frp/frpc -c /home/frp/frpc.toml   # 或加 supervisor 托管
```

### 5. 验证

```bash
# 1. 屏幕分辨率
DISPLAY=:1 xdpyinfo | grep dimensions   # → 720x1280 pixels

# 2. chromium 窗口几何（应满屏）
WIN=$(xdotool search --onlyvisible --class "chromium" | tail -1)
xdotool getwindowgeometry --shell $WIN  # → X=0 Y=0 WIDTH=720 HEIGHT=1280

# 3. 四个服务全部 RUNNING
supervisorctl status xvfb xfce4 chromium-gui vnc-browser

# 4. 浏览器访问
# http://你的服务器IP:YOUR_PORT/vnc.html
```

---

## 🎨 分辨率调整（手机竖屏）

把 1280x800 横屏改成 720x1280 竖屏，**三处必须同步改**：

| 文件 | 改动 |
|------|------|
| `chromium-gui.sh` | `--window-size=720,1280` + `--start-fullscreen` |
| `vnc-browser.sh` | x11vnc `-geometry 720x1280` |
| `supervisord.conf`（+template） | Xvfb `-screen 0 720x1280x24` |

```bash
# 改完配置必须这样重启（restart 不够, 要先 reread+update）
supervisorctl reread
supervisorctl update
supervisorctl restart xvfb
sleep 2
supervisorctl restart xfce4
sleep 4
supervisorctl restart chromium-gui
sleep 3
supervisorctl restart vnc-browser
```

> ⚠️ Xvfb 重启会级联杀掉 DISPLAY 上所有程序，必须**按依赖顺序**重启：xvfb → xfce4 → chromium-gui → vnc-browser。

---

## 🐛 常见坑

1. **supervisor 改配置后必须 `reread + update`**，`restart` 不会读新配置
2. **`--restore-last-session` 会覆盖全屏状态**：不加它，让 `--start-fullscreen` 生效
3. **xfce4 通知区偶尔弹窗**：被 chromium 全屏盖住，不影响使用
4. **VNC 无密码**（`-nopw`）：访问控制靠 frp 端口 + 外层，不要暴露到公网裸奔

---

## 🔄 数据持久化

chromium 浏览器配置（书签/登录态）保存在 NAS：
```
/run/csi/mount-root/nas/.../browser/chromium-gui-profile
```
容器重启数据不丢（softlink 方式），对应 chromium 启动参数 `--user-data-dir="$NAS_DIR"`。

---

## 📜 参考

- 改造自 [SAP-Auto-deploy-Firefox](https://github.com/yanyumm1/Sap-FireFox-QwenPaw)
- 隧道机制借鉴 [komari-argo-hug](https://github.com/pingmike2/komari-argo-hug)（本仓库保留 `start_cloudflared.py` 备选方案）
- 详细排障记录：`VNC浏览器-竖屏分辨率调整总结.md`