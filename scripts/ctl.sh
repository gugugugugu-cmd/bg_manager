#!/system/bin/sh
# bg_manager 控制脚本
# 用法: ctl.sh <reload|rescan|restart|stop|status|log|oplog>

MODDIR="${0%/*}/.."
LOG_DIR="/data/local/tmp/bg_manager"
PID_FILE="$LOG_DIR/main.pid"
LOG_FILE="$LOG_DIR/bg_manager.log"
OP_LOG="$LOG_DIR/operations.log"

get_pid() {
    [ -f "$PID_FILE" ] || return 1
    local pid
    pid=$(cat "$PID_FILE")
    # 确认进程还活着
    kill -0 "$pid" 2>/dev/null || return 1
    echo "$pid"
}

cmd_reload() {
    local pid
    pid=$(get_pid) || { echo "服务未运行"; exit 1; }
    kill -USR1 "$pid"
    echo "已发送热重载信号 → PID=$pid"
    echo "配置将在下一轮检查时生效"
}

cmd_rescan() {
    local pid
    pid=$(get_pid) || { echo "服务未运行"; exit 1; }
    kill -USR2 "$pid"
    echo "已发送重扫信号 → PID=$pid"
    echo "将重新扫描已安装 App 并更新 apps.conf"
}

cmd_restart() {
    local pid
    pid=$(get_pid)
    if [ -n "$pid" ]; then
        echo "停止当前服务 PID=$pid..."
        kill -TERM "$pid" 2>/dev/null
        local i=0
        while kill -0 "$pid" 2>/dev/null && [ $i -lt 10 ]; do
            sleep 0.5
            i=$(( i + 1 ))
        done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    fi
    echo "启动服务..."
    sh "$MODDIR/service.sh" &
    # 等 service.sh 写入 PID 文件（不需要等 sleep 20 结束）
    # main.sh 一启动就写 PID，service.sh exec 到 main.sh 很快
    local i=0
    while [ ! -f "$PID_FILE" ] && [ $i -lt 20 ]; do
        sleep 0.5
        i=$(( i + 1 ))
    done
    pid=$(get_pid)
    if [ -n "$pid" ]; then
        echo "服务已启动 PID=$pid"
    else
        echo "启动失败，请查看日志"
    fi
    ;;

cmd_stop() {
    local pid
    pid=$(get_pid) || { echo "服务未运行"; exit 1; }
    kill -TERM "$pid"
    echo "已停止 PID=$pid"
}

cmd_status() {
    local pid
    pid=$(get_pid)
    if [ -n "$pid" ]; then
        echo "状态: 运行中 PID=$pid"
        # 显示最近一条日志
        echo "最近日志:"
        tail -n 5 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
    else
        echo "状态: 未运行"
    fi

    # 显示各 App 的计时状态
    local state_dir="$LOG_DIR/state"
    if [ -d "$state_dir" ]; then
        echo ""
        echo "App 状态:"
        local now
        now=$(date +%s)
        for sf in "$state_dir"/*.state; do
            [ -f "$sf" ] || continue
            local pkg last_active timeout mode remaining
            pkg=$(basename "$sf" .state)
            last_active=$(grep '^last_active=' "$sf" | cut -d'=' -f2)
            timeout=$(grep '^timeout=' "$sf" | cut -d'=' -f2)
            mode=$(grep '^mode=' "$sf" | cut -d'=' -f2)
            remaining=$(( last_active + timeout - now ))
            [ "$remaining" -lt 0 ] && remaining=0
            printf "  %-40s mode=%-2s timeout=%-4ss 距下次处理=%ss\n" \
                "$pkg" "$mode" "$timeout" "$remaining"
        done
    fi
}

cmd_log() {
    echo "=== 运行日志 (最近50行) ==="
    tail -n 50 "$LOG_FILE" 2>/dev/null || echo "日志文件不存在"
}

cmd_oplog() {
    echo "=== 操作日志 (最近100行) ==="
    tail -n 100 "$OP_LOG" 2>/dev/null || echo "操作日志不存在"
}

case "$1" in
    reload)  cmd_reload  ;;
    rescan)  cmd_rescan  ;;
    restart) cmd_restart ;;
    stop)    cmd_stop    ;;
    status)  cmd_status  ;;
    log)     cmd_log     ;;
    oplog)   cmd_oplog   ;;
    *)
        echo "用法: ctl.sh <命令>"
        echo ""
        echo "命令:"
        echo "  reload   重新加载 apps.conf（不重启服务）"
        echo "  rescan   重新扫描已安装 App，更新 apps.conf 后重载"
        echo "  restart  重启服务"
        echo "  stop     停止服务"
        echo "  status   查看运行状态和各 App 计时"
        echo "  log      查看运行日志"
        echo "  oplog    查看操作日志（trim/kill 记录）"
        ;;
esac