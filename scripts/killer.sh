#!/system/bin/sh
# 进程处理：trim（杀子进程）和 kill（强杀整包）
# 依赖 utils.sh 中的 log / op_log_* / get_child_pids / get_pkg_label

# 瘦身：杀掉包名的所有子进程，保留主进程和白名单进程
do_trim() {
    local pkg="$1"
    local keep_conf="$2"

    # 收集子进程信息（pid + 进程名）
    local ps_out
    ps_out=$(ps -A 2>/dev/null)
    [ -z "$ps_out" ] && return

    local pids="" proc_names=""
    while IFS= read -r line; do
        case "$line" in *"$pkg"*) ;; *) continue ;; esac

        local proc_name pid
        proc_name=$(echo "$line" | awk '{print $NF}')
        pid=$(echo "$line" | awk '{print $2}')

        is_numeric "$pid" || continue
        [ "$pid" -le 500 ] && continue
        [ "$proc_name" = "$pkg" ] && continue  # 跳过主进程

        # 白名单检查
        if [ -f "$keep_conf" ]; then
            local skip=false
            while IFS= read -r kl; do
                kl=$(echo "$kl" | tr -d '[:space:]')
                [ -z "$kl" ] && continue
                case "$kl" in '#'*) continue ;; esac
                [ "$proc_name" = "$kl" ] && skip=true && break
            done < "$keep_conf"
            $skip && continue
        fi

        pids="$pids $pid"
        proc_names="$proc_names|${pid}:${proc_name}"
    done << EOF
$(echo "$ps_out")
EOF

    [ -z "$pids" ] && return

    # 写操作日志
    local note
    note=$(get_pkg_label "$pkg")
    op_log_begin "TRIM" "$pkg" "$note"
    local IFS_BAK="$IFS"
    IFS='|'
    for entry in $proc_names; do
        [ -z "$entry" ] && continue
        local epid eproc
        epid=$(echo "$entry" | cut -d':' -f1)
        eproc=$(echo "$entry" | cut -d':' -f2)
        op_log_proc "$epid" "$eproc"
    done
    IFS="$IFS_BAK"
    op_log_end

    log "TRIM [$pkg] 子进程:$pids"

    # 第一遍
    for pid in $pids; do
        kill -9 "$pid" 2>/dev/null
    done
    # 延迟后再杀一次
    sleep 0.2
    for pid in $pids; do
        kill -9 "$pid" 2>/dev/null
    done
}

# 强杀：am force-stop 整个包
do_kill() {
    local pkg="$1"

    local note
    note=$(get_pkg_label "$pkg")
    op_log_begin "KILL" "$pkg" "$note"
    # 记录当前所有进程
    local ps_out
    ps_out=$(ps -A 2>/dev/null)
    while IFS= read -r line; do
        case "$line" in *"$pkg"*) ;; *) continue ;; esac
        local proc_name pid
        proc_name=$(echo "$line" | awk '{print $NF}')
        pid=$(echo "$line" | awk '{print $2}')
        is_numeric "$pid" || continue
        [ "$pid" -le 500 ] && continue
        op_log_proc "$pid" "$proc_name"
    done << EOF
$(echo "$ps_out")
EOF
    op_log_end

    log "KILL [$pkg]"
    am force-stop "$pkg" 2>/dev/null
}