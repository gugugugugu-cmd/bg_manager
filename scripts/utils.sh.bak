#!/system/bin/sh

LOG_DIR="/data/adb/modules/bg_manager/logs"
DEBUG_LOG="$LOG_DIR/debug.log"
OP_LOG="$LOG_DIR/operations.log"
PROC_LOG="$LOG_DIR/process.log"
STATE_DIR="$LOG_DIR/state"
LOG_MAX_LINES=200
LOG_KEEP_LINES=100

mkdir -p "$LOG_DIR" "$STATE_DIR"

# 内部调试日志
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$DEBUG_LOG"
    _rotate_file "$DEBUG_LOG"
}

# 控制操作日志（热重载/重扫/重启/停止）
op_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$OP_LOG"
    _rotate_file "$OP_LOG"
}

# 进程处理日志（TRIM/KILL）
proc_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$PROC_LOG"
    _rotate_file "$PROC_LOG"
}

_rotate_file() {
    local f="$1"
    local cnt
    cnt=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    [ "${cnt:-0}" -gt "$LOG_MAX_LINES" ] || return
    tail -n "$LOG_KEEP_LINES" "$f" > "${f}.tmp" 2>/dev/null \
        && mv "${f}.tmp" "$f" 2>/dev/null
}

is_numeric() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

get_child_pids() {
    local pkg="$1"
    local keep_conf="$2"
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
        [ "$proc_name" = "$pkg" ] && continue
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

get_main_pid() {
    local pkg="$1"
    local ps_out
    ps_out=$(ps -A 2>/dev/null)
    [ -z "$ps_out" ] && return
    echo "$ps_out" | while read -r line; do
        case "$line" in *"$pkg"*) ;; *) continue ;; esac
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

is_pkg_running() {
    local pkg="$1"
    ps -A 2>/dev/null | grep -q "$pkg"
}

DUMP_TIMEOUT=4
safe_dumpsys() {
    timeout "$DUMP_TIMEOUT" dumpsys "$@" 2>/dev/null
}

parse_time_config() {
    local conf="$1"
    local base=60 step=15
    local in_time=false
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/#.*//' | tr -d '[:space:]')
        [ -z "$line" ] && continue
        case "$line" in
            '[time]') in_time=true  ; continue ;;
            '['*']')  in_time=false ; continue ;;
        esac
        $in_time || continue
        case "$line" in
            base=*) base="${line#base=}" ;;
            step=*) step="${line#step=}" ;;
        esac
    done < "$conf"
    echo "$base $step"
}

parse_apps_config() {
    local conf="$1"
    local in_apps=false
    local has_section=false
    grep -q '^\[apps\]' "$conf" && has_section=true
    $has_section || in_apps=true

    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        local clean
        clean=$(echo "$line" | sed 's/#.*//' | sed 's/[[:space:]]*$//')
        [ -z "$clean" ] && continue
        case "$clean" in
            '[apps]') in_apps=true  ; continue ;;
            '[time]') in_apps=false ; continue ;;
            '['*']')  in_apps=false ; continue ;;
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

# ── 进程处理结构化日志 ───────────────────────────────────────

_proc_buf=""

proc_log_begin() {
    local action="$1" pkg="$2" note="$3" ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    _proc_buf="[${ts}] ${action} ${note}(${pkg})\n"
}

proc_log_add() {
    _proc_buf="${_proc_buf}  PID=${1} ${2}\n"
}

proc_log_flush() {
    [ -z "$_proc_buf" ] && return
    printf '%b' "$_proc_buf" >> "$PROC_LOG"
    printf '%b' "---------------\n" >> "$PROC_LOG"
    _proc_buf=""
    _rotate_file "$PROC_LOG"
}

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
    [ -z "$label" ] && label=$(echo "$pkg" | awk -F'.' '{print $NF}')
    echo "$label" > "$cache"
    echo "$label"
}