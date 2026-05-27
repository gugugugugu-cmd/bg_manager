#!/system/bin/sh
# 工具函数：日志、配置解析、ps 操作

LOG_DIR="/data/local/tmp/bg_manager"
LOG_FILE="$LOG_DIR/bg_manager.log"
LOG_MAX_LINES=200
LOG_KEEP_LINES=100

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    _rotate_log
}

_rotate_log() {
    local cnt
    cnt=$(wc -l < "$LOG_FILE" 2>/dev/null | tr -d ' ')
    [ "${cnt:-0}" -gt "$LOG_MAX_LINES" ] || return
    tail -n "$LOG_KEEP_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null \
        && mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null
}

is_numeric() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# 获取包名的所有子进程 PID（排除主进程，排除白名单）
# 用法: get_child_pids <pkgName> <trim_keep_conf>
get_child_pids() {
    local pkg="$1"
    local keep_conf="$2"
    local ps_out
    ps_out=$(ps -A 2>/dev/null)
    [ -z "$ps_out" ] && return

    echo "$ps_out" | while read -r line; do
        # 只处理包含包名的行
        case "$line" in
            *"$pkg"*) ;;
            *) continue ;;
        esac

        # 提取进程名（最后一列）和 PID（第二列）
        local proc_name pid
        proc_name=$(echo "$line" | awk '{print $NF}')
        pid=$(echo "$line" | awk '{print $2}')

        # PID 合法性校验
        is_numeric "$pid" || continue
        [ "$pid" -le 500 ] && continue

        # 主进程（进程名 == 包名）跳过
        [ "$proc_name" = "$pkg" ] && continue

        # 白名单检查
        if [ -f "$keep_conf" ]; then
            local in_keep=false
            while IFS= read -r keep_line; do
                keep_line=$(echo "$keep_line" | tr -d '[:space:]')
                [ -z "$keep_line" ] && continue
                case "$keep_line" in '#'*) continue ;; esac
                if [ "$proc_name" = "$keep_line" ]; then
                    in_keep=true
                    break
                fi
            done < "$keep_conf"
            $in_keep && continue
        fi

        echo "$pid"
    done
}

# 获取包名的主进程 PID
get_main_pid() {
    local pkg="$1"
    local ps_out
    ps_out=$(ps -A 2>/dev/null)
    [ -z "$ps_out" ] && return

    echo "$ps_out" | while read -r line; do
        case "$line" in
            *"$pkg"*) ;;
            *) continue ;;
        esac
        local proc_name pid
        proc_name=$(echo "$line" | awk '{print $NF}')
        pid=$(echo "$line" | awk '{print $2}')
        is_numeric "$pid" || continue
        [ "$pid" -le 500 ] && continue
        if [ "$proc_name" = "$pkg" ]; then
            echo "$pid"
            return
        fi
    done
}

# 检查包名进程是否存在（任意进程）
is_pkg_running() {
    local pkg="$1"
    ps -A 2>/dev/null | grep -q "$pkg"
}

# 安全 dumpsys，带超时
DUMP_TIMEOUT=4
safe_dumpsys() {
    timeout "$DUMP_TIMEOUT" dumpsys "$@" 2>/dev/null
}

# 解析 apps.conf 的 [time] 段
# 输出: BASE_TIME STEP_TIME
parse_time_config() {
    local conf="$1"
    local base=60 step=15
    local in_time=false
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/#.*//' | tr -d '[:space:]')
        [ -z "$line" ] && continue
        case "$line" in
            '[time]') in_time=true ; continue ;;
            '['*']') in_time=false ; continue ;;
        esac
        $in_time || continue
        case "$line" in
            base=*) base="${line#base=}" ;;
            step=*) step="${line#step=}" ;;
        esac
    done < "$conf"
    echo "$base $step"
}

# 解析 apps.conf 的 [apps] 段
# 每行输出: MODE PKG NOTE SLOT COUNTER FLAGS
# scripts/utils.sh 里的 parse_apps_config，在读取每行后加 trim
parse_apps_config() {
    local conf="$1"
    local in_apps=false
    while IFS= read -r line; do
        # 去掉行首行尾空格
        line=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        # 去注释
        local clean
        clean=$(echo "$line" | sed 's/#.*//' | sed 's/[[:space:]]*$//')
        [ -z "$clean" ] && continue
        case "$clean" in
            '[apps]') in_apps=true ; continue ;;
            '['*']') in_apps=false ; continue ;;
        esac
        $in_apps || continue

        local mode pkg note slot_cnt flags
        mode=$(echo "$clean"     | awk '{print $1}')
        pkg=$(echo "$clean"      | awk '{print $2}')
        note=$(echo "$clean"     | awk '{print $3}')
        slot_cnt=$(echo "$clean" | awk '{print $4}')
        flags=$(echo "$clean"    | awk '{print $5}')

        [ -z "$pkg" ] && continue
        case "$mode" in T|K|M) ;; *) continue ;; esac

        local slot counter
        slot=$(echo "$slot_cnt"    | cut -d',' -f1)
        counter=$(echo "$slot_cnt" | cut -d',' -f2)

        is_numeric "$(echo "$slot" | tr -d '-')" || slot=0
        is_numeric "$counter" || counter=0
        [ -z "$flags" ] && flags="00000000"

        echo "$mode $pkg $note $slot $counter $flags"
    done < "$conf"
}

# ── 结构化操作日志 ───────────────────────────────────────────

OP_LOG="$LOG_DIR/operations.log"
OP_LOG_MAX=300
OP_LOG_KEEP=150

# 写操作日志，格式与 Thanox 管家日志对齐
# 用法: op_log_begin <action> <pkg> <note>
#       op_log_proc  <pid> <proc_name>   （可多次调用）
#       op_log_end
_op_buf=""

op_log_begin() {
    local action="$1"   # TRIM 或 KILL
    local pkg="$2"
    local note="$3"
    local ts
    ts=$(date '+%m/%d %H:%M:%S')
    _op_buf="[${ts}] ${action} ${note}(${pkg})\n"
}

op_log_proc() {
    local pid="$1"
    local proc_name="$2"
    _op_buf="${_op_buf}  PID=${pid} ${proc_name}\n"
}

op_log_end() {
    [ -z "$_op_buf" ] && return
    printf '%b' "$_op_buf" >> "$OP_LOG"
    printf '%b' "---------------\n" >> "$OP_LOG"
    _op_buf=""
    _rotate_op_log
}

_rotate_op_log() {
    local cnt
    cnt=$(wc -l < "$OP_LOG" 2>/dev/null | tr -d ' ')
    [ "${cnt:-0}" -gt "$OP_LOG_MAX" ] || return
    tail -n "$OP_LOG_KEEP" "$OP_LOG" > "${OP_LOG}.tmp" 2>/dev/null \
        && mv "${OP_LOG}.tmp" "$OP_LOG" 2>/dev/null
}

# 获取包名的 label（缓存到 state 目录避免重复 pm dump）
get_pkg_label() {
    local pkg="$1"
    local cache="$STATE_DIR/${pkg}.label"
    if [ -f "$cache" ]; then
        cat "$cache"
        return
    fi
    local label
    label=$(pm dump "$pkg" 2>/dev/null \
        | grep -m1 'nonLocalizedLabel' \
        | grep -oE '"[^"]+"' | tr -d '"' | head -1)
    if [ -z "$label" ]; then
        label=$(echo "$pkg" | awk -F'.' '{print $NF}')
    fi
    echo "$label" > "$cache"
    echo "$label"
}