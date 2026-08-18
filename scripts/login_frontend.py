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
USERNAME = os.environ.get("VNC_AUTH_USER", "qwenpaw")
PASSWORD = os.environ.get("VNC_AUTH_PASS", "123456")
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
        if self.path.split("?")[0] in ("/", "/index.html"):
            html = LOGIN_PAGE
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html.encode())))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(html.encode())
            return
        # 未登录: 一律 302 回登录页 (不依赖 websockify 的 auth 抛异常, 避免挂起)
        if not self.has_valid_cookie():
            self.send_response(302)
            self.send_header("Location", "/")
            self.send_header("Content-Length", "0")
            self.end_headers()
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

    def has_valid_cookie(self):
        cookie = self.headers.get("Cookie", "")
        if not cookie:
            return False
        c = cookies_mod.SimpleCookie()
        try:
            c.load(cookie)
        except Exception:
            return False
        token = c.get(COOKIE_NAME)
        return token is not None and valid_token(token.value)

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
