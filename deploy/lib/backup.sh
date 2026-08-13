#!/bin/bash
# ============================================================
# lib/backup.sh - NAS 持久化: qwenpaw 数据 + chromium profile
#
# 提供函数:
#   backup_restore_all          - 启动时调用: 从 NAS 恢复数据(若 NAS 有)
#   backup_snapshot_once        - 立即备份一次到 NAS
#   backup_loop                 - 定时备份循环 (supervisor 托管)
#
# 原理:
#   - NAS (持久化盘) 保存两份数据:
#     ${NAS_BASE_DIR}/qwenpaw-data/     ← qwenpaw 完整数据 (/app/working + secret)
#     ${NAS_BASE_DIR}/browser/chromium-gui-profile  ← chromium 浏览器配置
#   - 启动时若 NAS 有备份 → 恢复到本地 → qwenpaw/chromium 用 NAS 数据
#   - 运行中每 BACKUP_INTERVAL 秒同步本地 → NAS
#
# 注意: 不依赖 rsync (容器可能没装), 用 tar/cp 实现
# ============================================================

# ---------- 配置 (由 restore.sh 注入) ----------
: "${NAS_BASE_DIR:=/run/csi/mount-root/nas/4079184d856ecc166ed19d4887083405/workspaces/default}"
: "${QWENPAW_DATA_DIR:=/app/working}"
: "${QWENPAW_SECRET_DIR:=/app/working.secret}"
: "${CHROMIUM_PROFILE_DIR:=${NAS_BASE_DIR}/browser/chromium-gui-profile}"
: "${BACKUP_INTERVAL:=1800}"

# 备份根
QP_BACKUP_DIR="${NAS_BASE_DIR}/qwenpaw-data"
QP_BACKUP_WORKING="${QP_BACKUP_DIR}/working"
QP_BACKUP_SECRET="${QP_BACKUP_DIR}/working.secret"

# 日志
backup_log() { echo "[backup $(date '+%F %T')] $*"; }

# ---------- 检测 NAS 是否可用 ----------
nas_available() {
    [ -d "$NAS_BASE_DIR" ] && touch "${NAS_BASE_DIR}/.write_test" 2>/dev/null && { rm -f "${NAS_BASE_DIR}/.write_test"; return 0; }
    return 1
}

# ---------- 目录同步 (tar 管道, 保留权限) ----------
# sync_dir <src> <dst> [排除模式...]
sync_dir() {
    local src="$1" dst="$2"; shift 2
    local excludes=()
    for p in "$@"; do excludes+=("--exclude=$p"); done
    mkdir -p "$dst"
    if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
        # 用 tar 同步 (删除 dst 中 src 没有的文件 = --delete 效果)
        tar cf - -C "$src" "${excludes[@]}" . 2>/dev/null | tar xf - -C "$dst" 2>/dev/null
        # 清理 dst 里 src 没有的 (简易 delete)
        find "$dst" -mindepth 1 -maxdepth 1 2>/dev/null | while read -r item; do
            local base; base=$(basename "$item")
            [ ! -e "$src/$base" ] && rm -rf "$item"
        done
        return 0
    fi
    return 1
}

# ---------- NAS → 本地 恢复 (重启时调用) ----------
backup_restore_all() {
    backup_log "=== 检查 NAS 数据恢复 ==="
    nas_available || { backup_log "⚠ NAS 不可用, 跳过恢复"; return 0; }

    # 恢复 qwenpaw working
    if [ -d "$QP_BACKUP_WORKING" ] && [ -n "$(ls -A "$QP_BACKUP_WORKING" 2>/dev/null)" ]; then
        backup_log "从 NAS 恢复 qwenpaw 数据: $QP_BACKUP_WORKING → $QWENPAW_DATA_DIR"
        mkdir -p "$QWENPAW_DATA_DIR"
        sync_dir "$QP_BACKUP_WORKING" "$QWENPAW_DATA_DIR" '*.log' '*.log.*' '.qwenpaw_restore.lock' \
            && backup_log "✅ qwenpaw working 恢复完成" || backup_log "⚠ qwenpaw working 恢复失败"
    else
        backup_log "NAS 无 qwenpaw working 备份, 使用全新数据"
    fi

    # 恢复 qwenpaw secret (密钥等)
    if [ -d "$QP_BACKUP_SECRET" ] && [ -n "$(ls -A "$QP_BACKUP_SECRET" 2>/dev/null)" ]; then
        backup_log "从 NAS 恢复 qwenpaw secret"
        mkdir -p "$QWENPAW_SECRET_DIR"
        sync_dir "$QP_BACKUP_SECRET" "$QWENPAW_SECRET_DIR" \
            && backup_log "✅ qwenpaw secret 恢复完成" || backup_log "⚠ qwenpaw secret 恢复失败"
    else
        backup_log "NAS 无 qwenpaw secret 备份, 使用全新密钥"
    fi

    # chromium profile 直接用 NAS 目录 (chromium-gui.sh 已指向 NAS, 无需额外恢复)
    if [ -d "$CHROMIUM_PROFILE_DIR" ]; then
        backup_log "✅ chromium 数据使用 NAS 直连: $CHROMIUM_PROFILE_DIR"
    fi
}

# ---------- 本地 → NAS 备份 ----------
backup_snapshot_once() {
    backup_log "=== 执行一次备份 ==="
    nas_available || { backup_log "⚠ NAS 不可用, 跳过备份"; return 0; }

    mkdir -p "$QP_BACKUP_WORKING" "$QP_BACKUP_SECRET" "$QWENPAW_SECRET_DIR"

    # 备份 qwenpaw working (排除日志, 可恢复时重新生成)
    if [ -d "$QWENPAW_DATA_DIR" ]; then
        sync_dir "$QWENPAW_DATA_DIR" "$QP_BACKUP_WORKING" '*.log' '*.log.*' '.qwenpaw_restore.lock'
        backup_log "✅ qwenpaw working 备份完成 ($(du -sh "$QP_BACKUP_WORKING" 2>/dev/null | cut -f1))"
    fi

    # 备份 qwenpaw secret
    if [ -d "$QWENPAW_SECRET_DIR" ]; then
        sync_dir "$QWENPAW_SECRET_DIR" "$QP_BACKUP_SECRET"
        backup_log "✅ qwenpaw secret 备份完成"
    fi

    # chromium profile 已在 NAS 直连, 无需额外备份
    backup_log "chromium 数据已 NAS 直连, 跳过重复备份"
}

# ---------- 定时备份循环 ----------
backup_loop() {
    backup_log "启动定时备份循环 (间隔 ${BACKUP_INTERVAL}s)..."
    while true; do
        sleep "$BACKUP_INTERVAL"
        backup_snapshot_once
    done
}

# ---------- CLI 入口 ----------
case "${1:-}" in
    restore) backup_restore_all ;;
    backup)  backup_snapshot_once ;;
    loop)    backup_loop ;;
    *)
        echo "用法: backup.sh [restore|backup|loop]" >&2
        exit 1
        ;;
esac