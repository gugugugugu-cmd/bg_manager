#!/system/bin/sh
# WebUI 后端接口
# 用法: api.sh <action> [args...]

# stderr 重定向到日志，不干扰 stdout 的 JSON 输出
exec 2>/data/local/tmp/bg_manager/api_err.log

MODDIR="/data/adb/modules/bg_manager"
CONFIG_DIR="$MODDIR/config"
SCRIPTS="$MODDIR/scripts"
APPS_CONF="$CONFIG_DIR/apps.conf"
KEEP_CONF="$CONFIG_DIR/trim_keep.conf"
LOG_DIR="/data/local/tmp/bg_manager"
PID_FILE="$LOG_DIR/main.pid"
STATE_DIR="$LOG_DIR/state"
OP_LOG="$LOG_DIR/operations.log"
RUN_LOG="$LOG_DIR/bg_manager.log"
RELOAD_FLAG="$LOG_DIR/reload.flag"
RESCAN_FLAG="$LOG_DIR/rescan.flag"

is_numeric() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac }

# 输出 JSON
ok()   { printf '{"ok":true,"data":%s}\n' "$1"; }
fail() { printf '{"ok":false,"error":"%s"}\n' "$1"; }

get_pid() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if is_numeric "$pid" && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi
    local pid
    pid=$(ps -A 2>/dev/null | grep 'main\.sh' | grep -v grep | awk '{print $2}' | head -1)
    if is_numeric "$pid" && [ "$pid" -gt 0 ]; then
        echo "$pid" > "$PID_FILE"
        echo "$pid"
        return 0
    fi
    echo "not_found"
    return 1
}

# ========== 新增辅助函数 ==========
pkg_is_running() {
    local pkg="$1"
    ps -A 2>/dev/null | awk -v p="$pkg" '
        {
            n = $NF
            if (n == p || index(n, p ":") == 1) {
                found = 1
                exit
            }
        }
        END {
            exit(found ? 0 : 1)
        }
    '
}
# ========== 辅助函数结束 ==========

# 转义 JSON 字符串内容
to_json_str() {
    sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}' | tr -d '\n'
}

case "$1" in

# ── 服务状态 ────────────────────────────────────────────────
status)
    pid=$(get_pid)
    pid_ok=$?
    if [ $pid_ok -eq 0 ]; then
        running="true"
    else
        running="false"
        pid=0
    fi
    enabled=$(grep -cE '^[TKM] ' "$APPS_CONF" 2>/dev/null || echo 0)
    last_log=$(tail -n 1 "$RUN_LOG" 2>/dev/null | to_json_str)
    ok "{\"running\":${running},\"pid\":${pid},\"enabled\":${enabled},\"last_log\":\"${last_log}\"}"
    ;;

# ── 运行日志 ────────────────────────────────────────────────
runlog)
    lines="${2:-80}"
    is_numeric "$lines" || lines=80
    content=$(tail -n "$lines" "$RUN_LOG" 2>/dev/null | to_json_str)
    ok "\"${content}\""
    ;;

# ── 操作日志 ────────────────────────────────────────────────
oplog)
    lines="${2:-100}"
    is_numeric "$lines" || lines=100
    content=$(tail -n "$lines" "$OP_LOG" 2>/dev/null | to_json_str)
    ok "\"${content}\""
    ;;

# ── App 状态列表（替换后版本）─────────────────────────────────
appstate)
    now=$(date +%s)
    result='['
    first=true

    tmp_apps=$(mktemp)
    grep -E '^[TKM] ' "$APPS_CONF" 2>/dev/null > "$tmp_apps"

    while IFS= read -r line; do
        [ -z "$line" ] && continue

        mode=$(echo "$line" | awk '{print $1}')
        pkg=$(echo "$line"  | awk '{print $2}')
        [ -z "$pkg" ] && continue

        sf="$STATE_DIR/${pkg}.state"
        if [ -f "$sf" ]; then
            last_active=$(grep '^last_active=' "$sf" 2>/dev/null | cut -d'=' -f2)
            timeout=$(grep '^timeout=' "$sf" 2>/dev/null | cut -d'=' -f2)
            counter_left=$(grep '^counter_left=' "$sf" 2>/dev/null | cut -d'=' -f2)
            counter_init=$(grep '^counter_init=' "$sf" 2>/dev/null | cut -d'=' -f2)
        else
            last_active=0
            timeout=60
            counter_left=0
            counter_init=0
        fi

        is_numeric "$last_active" || last_active=0
        is_numeric "$timeout" || timeout=60
        is_numeric "$counter_left" || counter_left=0
        is_numeric "$counter_init" || counter_init=0

        remaining=$(( last_active + timeout - now ))
        [ "$remaining" -lt 0 ] && remaining=0

        if pkg_is_running "$pkg"; then
            running="true"
        else
            running="false"
        fi

        if [ "$first" = true ]; then
            first=false
        else
            result="${result},"
        fi

        result="${result}{\"pkg\":\"${pkg}\",\"mode\":\"${mode}\",\"timeout\":${timeout},\"remaining\":${remaining},\"running\":${running},\"counter_left\":${counter_left},\"counter_init\":${counter_init}}"
    done < "$tmp_apps"

    rm -f "$tmp_apps"
    result="${result}]"
    ok "$result"
    ;;

# ── 读取 apps.conf ───────────────────────────────────────────
get_apps_conf)
    if [ ! -f "$APPS_CONF" ]; then
        fail "apps.conf 不存在"
    else
        content=$(cat "$APPS_CONF" | to_json_str)
        ok "\"${content}\""
    fi
    ;;

# ── 保存 apps.conf ───────────────────────────────────────────
save_apps_conf)
    [ -z "$2" ] && fail "内容为空" && exit 0
    content=$(echo "$2" | base64 -d 2>/dev/null)
    if [ -z "$content" ]; then
        fail "base64解码失败"
        exit 0
    fi
    cp "$APPS_CONF" "${APPS_CONF}.bak" 2>/dev/null
    printf '%s' "$content" > "$APPS_CONF"
    chmod 644 "$APPS_CONF"
    ok '"saved"'
    ;;

# ── 读取 trim_keep.conf 整体 ─────────────────────────────────
get_keep_conf)
    if [ ! -f "$KEEP_CONF" ]; then
        fail "trim_keep.conf 不存在"
    else
        content=$(cat "$KEEP_CONF" | to_json_str)
        ok "\"${content}\""
    fi
    ;;

# ── 保存 trim_keep.conf 整体 ─────────────────────────────────
save_keep_conf)
    [ -z "$2" ] && fail "内容为空" && exit 0
    content=$(echo "$2" | base64 -d 2>/dev/null)
    if [ -z "$content" ]; then
        fail "base64解码失败"
        exit 0
    fi
    cp "$KEEP_CONF" "${KEEP_CONF}.bak" 2>/dev/null
    printf '%s' "$content" > "$KEEP_CONF"
    chmod 644 "$KEEP_CONF"
    ok '"saved"'
    ;;

# ── 读取某包名的保留进程 ─────────────────────────────────────
get_keep_procs)
    pkg="$2"
    [ -z "$pkg" ] && fail "缺少包名" && exit 0
    [ -f "$KEEP_CONF" ] || { ok '""'; exit 0; }

    result=$(awk -v pkg="$pkg" '
        /^# .*\(/ {
            if (index($0, "("pkg")") > 0) {
                in_block = 1
                next
            } else {
                in_block = 0
            }
        }
        /^#/ {
            if (in_block) in_block = 0
        }
        in_block && NF > 0 && !/^#/ {
            print $0
        }
    ' "$KEEP_CONF")
    content=$(printf "%s" "$result" | to_json_str)
    ok "\"${content}\""
    ;;

# ── 保存某包名的保留进程 ─────────────────────────────────────
save_keep_procs)
    pkg="$2"
    note="$3"
    encoded="$4"
    [ -z "$pkg" ] && fail "缺少包名" && exit 0

    new_procs=$(echo "$encoded" | base64 -d 2>/dev/null | sed '/^[[:space:]]*$/d; /^#/d')
    [ -z "$new_procs" ] && new_procs=""

    [ -f "$KEEP_CONF" ] || touch "$KEEP_CONF"

    TMP=$(mktemp)
    awk -v pkg="$pkg" '
        BEGIN { in_block = 0 }
        /^# .*\(/ {
            if (index($0, "("pkg")") > 0) {
                in_block = 1
                next
            } else if (in_block) {
                in_block = 0
                print
            } else {
                print
            }
            next
        }
        in_block { next }
        { print }
    ' "$KEEP_CONF" > "$TMP"

    if [ -n "$new_procs" ]; then
        [ -s "$TMP" ] && [ "$(tail -c1 "$TMP")" != "" ] && echo >> "$TMP"
        printf "\n# %s (%s)\n" "$note" "$pkg" >> "$TMP"
        printf "%s\n" "$new_procs" >> "$TMP"
    fi

    mv "$TMP" "$KEEP_CONF"
    chmod 644 "$KEEP_CONF"
    ok '"saved"'
    ;;

# ── 切换 App 启用状态 ────────────────────────────────────────
toggle_app)
    pkg="$2"
    [ -z "$pkg" ] && fail "缺少包名" && exit 0
    if grep -qE "^[TKM] ${pkg} " "$APPS_CONF" 2>/dev/null; then
        sed -i "s/^\([TKM] ${pkg} \)/# \1/" "$APPS_CONF"
        ok '"disabled"'
    elif grep -qE "^# [TKM] ${pkg} " "$APPS_CONF" 2>/dev/null; then
        sed -i "s/^# \([TKM] ${pkg} \)/\1/" "$APPS_CONF"
        ok '"enabled"'
    else
        fail "包名不存在"
    fi
    ;;

# ── 修改 App 参数（支持传入备注）────────────────────────────────
update_app)
    pkg="$2" mode="$3" slot="$4" counter="$5" flags="$6" note="$7"
    [ -z "$pkg" ]  && fail "缺少包名"     && exit 0
    [ -z "$mode" ] && fail "缺少处理方式" && exit 0
    case "$mode" in T|K|M) ;; *) fail "无效的处理方式" && exit 0 ;; esac

    if [ -z "$note" ]; then
        note=$(grep -E "^#? *[TKM] ${pkg} " "$APPS_CONF" | head -1 | awk '{
            for(i=1;i<=NF;i++){
                if($i ~ /^[TKM#]$/) continue
                if($i ~ /\./) continue
                if($i != "") { print $i; exit }
            }
        }')
        [ -z "$note" ] && note=$(echo "$pkg" | awk -F'.' '{print $NF}')
    fi

    note=$(echo "$note" | tr ' ' '_')

    if grep -qE "^#? *[TKM] ${pkg} " "$APPS_CONF" 2>/dev/null; then
        if grep -qE "^[TKM] ${pkg} " "$APPS_CONF"; then
            prefix=""
        else
            prefix="# "
        fi
        new_line="${prefix}${mode} ${pkg}  ${note}  ${slot},${counter}  ${flags}"
        awk -v pkg="$pkg" -v newline="$new_line" '
            $0 ~ "^#? *[TKM] "pkg" " { print newline; next }
            { print }
        ' "$APPS_CONF" > "${APPS_CONF}.tmp" && mv "${APPS_CONF}.tmp" "$APPS_CONF"
        ok '"updated"'
    else
        fail "包名不存在"
    fi
    ;;

# ── 服务控制（使用 flag 文件 + 信号，无需管道）───────────────
reload)
    pid=$(get_pid)
    if [ $? -ne 0 ]; then
        fail "服务未运行 (${pid})"
        exit 0
    fi
    touch "$RELOAD_FLAG"
    ok '"reloading"'
    ;;

rescan)
    pid=$(get_pid)
    if [ $? -ne 0 ]; then
        fail "服务未运行 (${pid})"
        exit 0
    fi
    touch "$RESCAN_FLAG"
    ok '"rescanning"'
    ;;

restart)
    pid=$(get_pid)
    if [ $? -eq 0 ]; then
        kill -TERM "$pid" 2>/dev/null
        sleep 1
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$PID_FILE"
    sh "$MODDIR/service.sh" &
    i=0
    while [ ! -f "$PID_FILE" ] && [ "$i" -lt 20 ]; do
        sleep 0.5
        i=$(( i + 1 ))
    done
    pid=$(get_pid)
    if [ $? -eq 0 ]; then
        ok "{\"pid\":${pid}}"
    else
        fail "启动失败，请查看 boot.log"
    fi
    ;;

stop)
    pid=$(get_pid)
    if [ $? -ne 0 ]; then
        fail "服务未运行 (${pid})"
        exit 0
    fi
    kill -TERM "$pid" 2>/dev/null && ok '"stopped"' || fail "发送信号失败"
    ;;

*)
    fail "未知操作: $1"
    ;;

esac