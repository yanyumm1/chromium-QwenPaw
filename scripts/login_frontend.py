#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
无登录直连 VNC 网关 (v9 简化)
=============================
- 无登录页, 访问即进入 VNC 画面
- 适配手机端 noVNC: resize=scale, show_dot=0
"""
import os
from websockify.websocketproxy import WebSocketProxy, ProxyRequestHandler, LibProxyServer


def main():
    proxy = WebSocketProxy(
        listen_port=int(os.environ.get("VNC_PORT", "8080")),
        listen_host="",
        web=os.environ.get("VNC_WEB_DIR", "/usr/share/novnc"),
        target_host="127.0.0.1",
        target_port=int(os.environ.get("RFB_PORT", "5900")),
        web_auth=False,
    )
    # 无认证: 所有请求直接放行
    print(f"✅ VNC 直连网关: 0.0.0.0:{proxy.listen_port} → 127.0.0.1:{proxy.target_port}", flush=True)
    opts = proxy.__dict__.copy()
    opts["RequestHandlerClass"] = ProxyRequestHandler
    opts["auth_plugin"] = None
    opts["target_host"] = proxy.target_host
    opts["target_port"] = proxy.target_port
    opts["web"] = proxy.web
    opts["web_auth"] = False
    server = LibProxyServer(**opts)
    server.serve_forever()

if __name__ == "__main__":
    main()
