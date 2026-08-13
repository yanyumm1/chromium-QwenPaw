#!/bin/bash
# backup-loop.sh - NAS 持久化: 启动恢复 + 定时备份
# 由 install.sh 生成/调用, supervisor 托管 (qwenpaw-backup)
# 环境变量: NAS_BASE_DIR / QWENPAW_DATA_DIR / QWENPAW_SECRET_DIR / CHROMIUM_PROFILE_DIR / BACKUP_INTERVAL
: "${NAS_BASE_DIR:=/data/persist}"
: "${QWENPAW_DATA_DIR:=/app/working}"
: "${QWENPAW_SECRET_DIR:=/app/working.secret}"
: "${CHROMIUM_PROFILE_DIR:=${NAS_BASE_DIR}/browser/chromium-gui-profile}"
: "${BACKUP_INTERVAL:=1800}"

log() { echo "[backup $(date '+%F %T')] $*"; }

nas_ok() {
    [ -d "$NAS_BASE_DIR" ] && touch "${NAS_BASE_DIR}/.write_test" 2>/dev/null && { rm -f "${NAS_BASE_DIR}/.write_test"; return 0; }
    return 1
}

# 目录同步 (tar, 保留权限, 简易 delete)
sync_dir() {
    local src="$1" dst="$2"; shift 2
    mkdir -p "$dst"
    if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
        tar cf - -C "$src" --exclude='*.pyc' --exclude='__pycache__' . 2>/dev/null | tar xf - -C "$dst" 2>/dev/null
        find "$dst" -mindepth 1 -maxdepth 1 2>/dev/null | while read -r item; do
            local base; base=$(basename "$item")
            [ ! -e "$src/$base" ] && rm -rf "$item"
        done
    fi
}

# 恢复 (启动时): NAS → 本地
do_restore() {
    nas_ok || { log "NAS 不可用, 跳过恢复"; return 1; }
    local qb="${NAS_BASE_DIR}/qwenpaw-data"
    if [ -d "$qb/working" ] && [ -n "$(ls -A "$qb/working" 2>/dev/null)" ]; then
        mkdir -p "$QWENPAW_DATA_DIR"
        tar cf - -C "$qb/working" . 2>/dev/null | tar xf - -C "$QWENPAW_DATA_DIR" 2>/dev/null
        log "✅ 恢复 qwenpaw 数据 → $QWENPAW_DATA_DIR"
    fi
    if [ -d "$qb/working.secret" ] && [ -n "$(ls -A "$qb/working.secret" 2>/dev/null)" ]; then
        mkdir -p "$QWENPAW_SECRET_DIR"
        tar cf - -C "$qb/working.secret" . 2>/dev/null | tar xf - -C "$QWENPAW_SECRET_DIR" 2>/dev/null
        log "✅ 恢复 secret → $QWENPAW_SECRET_DIR"
    fi
    if [ -d "${CHROMIUM_PROFILE_DIR}" ] && [ -n "$(ls -A "${CHROMIUM_PROFILE_DIR}" 2>/dev/null)" ]; then
        log "✅ chromium profile 已在 NAS: $CHROMIUM_PROFILE_DIR"
    fi
}

# 备份 (定时): 本地 → NAS
do_backup() {
    nas_ok || { log "NAS 不可用, 跳过备份"; return 1; }
    local qb="${NAS_BASE_DIR}/qwenpaw-data"
    mkdir -p "$qb"
    sync_dir "$QWENPAW_DATA_DIR" "$qb/working"
    sync_dir "$QWENPAW_SECRET_DIR" "$qb/working.secret" 2>/dev/null || true
    log "✅ 备份完成 → $qb"
}

case "${1:-loop}" in
    restore) do_restore ;;
    once)    do_backup ;;
    loop)
        do_restore
        while true; do
            sleep "$BACKUP_INTERVAL"
            do_backup
        done
        ;;
esac
