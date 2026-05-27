#!/system/bin/sh

MODDIR="/data/adb/modules/bg_manager"
SCRIPTS="$MODDIR/scripts"
LOG_DIR="$MODDIR/logs"
LOG="$LOG_DIR/boot.log"

mkdir -p "$LOG_DIR"

# 其余内容不变
log_boot() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

log_boot "service.sh 启动，等待系统就绪..."

until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
done

log_boot "系统就绪..."

chmod 755 "$MODDIR/scripts/"*.sh
chmod 644 "$MODDIR/config/"*.conf 2>/dev/null
chmod 755 "$MODDIR/webroot/api.sh"

sh "$SCRIPTS/init_config.sh"

log_boot "启动主服务..."

# exec 替换当前进程，PID 不变，main.sh 里的 $$ 就是最终 PID
exec sh "$SCRIPTS/main.sh"