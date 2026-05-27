#!/system/bin/sh

do_trim() {
    local pkg="$1"
    local keep_conf="$2"

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
        [ "$proc_name" = "$pkg" ] && continue

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

    local note
    note=$(get_pkg_label "$pkg")
    proc_log_begin "TRIM" "$pkg" "$note"
    local IFS_BAK="$IFS"
    IFS='|'
    for entry in $proc_names; do
        [ -z "$entry" ] && continue
        local epid eproc
        epid=$(echo "$entry" | cut -d':' -f1)
        eproc=$(echo "$entry" | cut -d':' -f2)
        proc_log_add "$epid" "$eproc"
    done
    IFS="$IFS_BAK"
    proc_log_flush

    log "TRIM [$pkg] 子进程:$pids"

    for pid in $pids; do kill -9 "$pid" 2>/dev/null; done
    sleep 0.2
    for pid in $pids; do kill -9 "$pid" 2>/dev/null; done
}

do_kill() {
    local pkg="$1"

    local note
    note=$(get_pkg_label "$pkg")
    proc_log_begin "KILL" "$pkg" "$note"
    local ps_out
    ps_out=$(ps -A 2>/dev/null)
    while IFS= read -r line; do
        case "$line" in *"$pkg"*) ;; *) continue ;; esac
        local proc_name pid
        proc_name=$(echo "$line" | awk '{print $NF}')
        pid=$(echo "$line" | awk '{print $2}')
        is_numeric "$pid" || continue
        [ "$pid" -le 500 ] && continue
        proc_log_add "$pid" "$proc_name"
    done << EOF
$(echo "$ps_out")
EOF
    proc_log_flush

    log "KILL [$pkg]"
    am force-stop "$pkg" 2>/dev/null
}