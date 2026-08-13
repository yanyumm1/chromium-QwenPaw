# VNC 浏览器竖屏分辨率调整总结（1280x800 → 720x1280）

## 概述
把 VNC 远程浏览器（chromium 桌面）从横屏 `1280x800` 调整为手机竖屏比例 `720x1280`。
改一处不够，**Xvfb 屏幕、chromium 窗口、x11vnc 几何三处必须同步改**，否则窗口放不下或显示错位。

## 涉及文件
| 文件 | 改动 |
|------|------|
| `/mnt/envd/vnc-browser/chromium-gui.sh` | `--window-size=720,1280` + 新增 `--start-fullscreen` |
| `/mnt/envd/vnc-browser/vnc-browser.sh` | x11vnc `-geometry 1280x800` → `720x1280` |
| `/etc/supervisor/conf.d/supervisord.conf` + `.template` | Xvfb `-screen 0 1280x800x24` → `720x1280x24` |

> ⚠️ **关键：模板也必须改！** 容器重启时 `/entrypoint.sh` 会用 `supervisord.conf.template` 覆盖 `supervisord.conf`（用 `envsubst` 渲染）。只改 conf 不改 template，重启后丢失。这次两个文件都改了。

## 三处配置详解

### 1. Xvfb 屏幕（最底层）
```ini
[program:xvfb]
command=/bin/sh -c "... exec /usr/bin/Xvfb :1 -screen 0 720x1280x24"
```
`xdpyinfo | grep dimensions` 验证：`720x1280 pixels (183x325mm)`

### 2. Chromium 窗口
```bash
exec /usr/bin/chromium \
  --no-sandbox \
  --window-size=720,1280 \
  --start-fullscreen \
  ...
```
- `--window-size=720,1280`：初始窗口大小
- `--start-fullscreen`：启动即全屏（关键！否则窗口只有 719x1279 且从 Y=27 开始，被顶部 xfce panel 挤出）

### 3. x11vnc 几何
```bash
x11vnc -display "${VNC_DISPLAY}" \
    -geometry 720x1280 \
    ...
```

## ⚠️ 坑 1：supervisor 改配置后必须 `reread + update`，`restart` 不够！
**现象：** 改了 `supervisord.conf` 后 `supervisorctl restart xvfb`，重启完 `xdpyinfo` 还是旧分辨率 1280x800。

**原因：** `supervisorctl restart` 只按**已加载的配置**重启进程，不会重新读取配置文件。改配置后必须：
```bash
supervisorctl reread   # 重新扫描配置, 显示 "xvfb: changed"
supervisorctl update   # 应用新配置, 显示 "xvfb: updated process group"
supervisorctl restart xvfb  # 再重启才用新配置
```

## ⚠️ 坑 2：Xvfb 重启会级联杀掉 DISPLAY 上所有程序
**现象：** 重启 xvfb 后，xfce4、chromium-gui、vnc-browser 全部挂掉。

**原因：** X server 断开 = DISPLAY :1 上所有 X 客户端全部失联退出。

**修复：** 必须按依赖顺序重启：
```bash
supervisorctl restart xvfb          # 先起屏幕
sleep 2
supervisorctl restart xfce4         # 再起桌面
sleep 4
supervisorctl restart chromium-gui  # 浏览器窗口
sleep 3
supervisorctl restart vnc-browser   # VNC 服务
```

## ⚠️ 坑 3：`--restore-last-session` 会覆盖全屏状态
**现象：** 加了 `--start-fullscreen` 重启后仍是普通窗口（Y=27 被 panel 挤下去）。

**原因：** chromium 恢复上次会话窗口状态，覆盖了 `--start-fullscreen`。

**修复：** 实测重启后自动全屏成功（`X=0 Y=0 WIDTH=720 HEIGHT=1280`），`--start-fullscreen` 生效。如果个别情况没全屏，手动：
```bash
WIN=$(xdotool search --onlyvisible --class "chromium" | tail -1)
xdotool windowactivate $WIN
xdotool key --window $WIN F11
```

## ⚠️ 坑 4：xfce4 "notification area lost selection" 弹窗
**现象：** xfce4 重启后偶尔弹出 "The notification area lost selection" 对话框，挡住屏幕。

**原因：** xfce4-panel 的通知区（systray）在重启后丢失 selection，Gtk 对话框不是独立 X window（`xdotool search --name` 搜不到）。

**处理：** 不是独立窗口无法用 xdotool 直接关。chromium 全屏后弹窗被盖住不影响使用；需要彻底清理时重启 xfce4 或点击对话框 Close。

## 验证清单
```bash
# 1. 屏幕分辨率
DISPLAY=:1 xdpyinfo | grep dimensions   # → 720x1280 pixels (183x325mm)

# 2. chromium 窗口几何（应满屏）
WIN=$(xdotool search --onlyvisible --class "chromium" | tail -1)
xdotool getwindowgeometry --shell $WIN  # → X=0 Y=0 WIDTH=720 HEIGHT=1280

# 3. 四个服务全部 RUNNING
supervisorctl status xvfb xfce4 chromium-gui vnc-browser

# 4. 浏览器访问
# http://YOUR_SERVER_IP:YOUR_PORT/vnc.html （frp YOUR_PORT → websockify 8080 → x11vnc 5900）
```

## 架构备忘（vnc-browser 链路）
```
浏览器 (noVNC 页面)
  → frp 公网 YOUR_SERVER_IP:YOUR_PORT
  → websockify :8080 (noVNC web + websocket 代理)
  → x11vnc :5900 (VNC 服务, -nopw 无密码, 访问控制靠外层)
  → Xvfb :1 (720x1280 屏幕)
  → xfce4 桌面 + chromium-gui (全屏浏览器)
```
