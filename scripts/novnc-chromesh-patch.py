#!/usr/bin/env python3
"""noVNC chrome.sh 风格补丁 (幂等):
1. ui.js: 连接后侧边控制栏保持展开 (去掉 2 秒自动收起)
2. base.css: 底部状态栏常显 (参考 chrome.sh 底部工具栏)
3. ui.js: resize 默认 scale (iOS Safari 铺满)
4. vnc.html: 锁定 viewport (iOS Safari 修复 2026-08-18)
    iOS Safari 对 noVNC 整体放大后, 页面缩放机制会把桌面缩小到整页, 造成"缩放不正常"
    (安卓 Chrome 不放大整体页面故正常). 锁定 viewport 后 resize=scale 的 canvas 按
    视口铺满, 不受 Safari 缩放影响.
5. base.css: 单页无左右滑动 (html/body overflow-x hidden + 控制栏收起时不占位)
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

# 2. ui.js: 连接后不自动收起侧边栏 (保持展开, 手机上能直接看到工具)
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

# 4. vnc.html: 锁定 viewport (iOS Safari 修复 2026-08-18)
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

# 5. base.css: 单页无左右滑动
#    - html/body 禁止横向溢出 (控制栏手柄/内容不应撑出视口)
#    - 控制栏收起时 (默认) 整条手柄区域隐藏, 避免手机上左右滑
patch_file(
    CSS,
    marker="参考 chrome.sh, 单页无左右滑动",
    old="html, body {\n  width: 100%;\n  height: 100%;",
    new="html, body {\n  width: 100%;\n  height: 100%;\n  overflow-x: hidden !important;\n  overflow-y: hidden !important;",
)
patch_file(
    CSS,
    marker="参考 chrome.sh, 控制栏收起时不占位",
    old="""#noVNC_control_bar_anchor {
  position: fixed;
  left: 0;
  top: 0;
  width: 1px;
  height: 100%;""",
    new="""#noVNC_control_bar_anchor {
  position: fixed;
  left: 0;
  top: 0;
  width: 1px;
  height: 100%;
  /* 2026-08-18: 单页模式, 控制栏收起时整条不占位 (默认收起, 点手柄才展开) */
  pointer-events: none;""",
)

print(f"=== 完成: {len(changed)} 个文件被修改 ===")
sys.exit(0)
