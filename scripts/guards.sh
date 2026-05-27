#!/system/bin/sh
# 保护条件检测

# 加载工具函数（调用方负责 source）

# 检查包名是否在前台
is_foreground() {
    local pkg="$1"
    local fg
    # 优先用 window 焦点
    fg=$(safe_dumpsys window \
        | grep -E 'mCurrentFocus|mFocusedApp' \
        | head -1 \
        | grep -oE '[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+' \
        | head -1)
    [ "$fg" = "$pkg" ] && return 0

    # 备用：activity 栈顶
    fg=$(safe_dumpsys activity activities \
        | grep -E 'mResumedActivity|topResumedActivity' \
        | head -1 \
        | grep -oE '[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+' \
        | head -1)
    [ "$fg" = "$pkg" ] && return 0

    return 1
}

# 检查包名是否持有音频焦点
has_audio_focus() {
    local pkg="$1"
    safe_dumpsys audio \
        | grep -A2 'AudioFocus' \
        | grep -q "$pkg"
}

# 检查包名是否有可见通知
has_notification() {
    local pkg="$1"
    safe_dumpsys notification \
        | grep -q "pkg=$pkg"
}

# 检查包名是否有小窗（画中画 / freeform）
has_pip_or_freeform() {
    local pkg="$1"
    # 画中画
    safe_dumpsys activity activities \
        | grep -i 'PinnedTask\|PipActivity\|pip' \
        | grep -q "$pkg" && return 0
    # Freeform 小窗
    safe_dumpsys activity activities \
        | grep -i 'freeform' \
        | grep -q "$pkg" && return 0
    return 1
}

# 检查包名是否有 VoIP 前台服务（微信专项）
has_voip_service() {
    local pkg="$1"
    safe_dumpsys activity services "$pkg" \
        | grep -qi 'VoipNewForegroundService\|VoipForegroundService'
}

# 屏幕是否亮着
is_screen_on() {
    safe_dumpsys power | grep -q 'mWakefulness=Awake'
}

# 综合保护判断
# 用法: should_skip <pkg> <flags> <mode>
# flags: 8位字符串，第1位=通知保护，第2位=音频保护，第3位=小窗保护
# 返回 0 = 跳过（受保护），1 = 不跳过
should_skip() {
    local pkg="$1"
    local flags="$2"
    local mode="$3"

    local flag_notify flag_audio flag_pip
    flag_notify=$(echo "$flags" | cut -c1)
    flag_audio=$(echo  "$flags" | cut -c2)
    flag_pip=$(echo    "$flags" | cut -c3)

    # 前台始终跳过
    is_foreground "$pkg" && return 0

    # VoIP 始终跳过（不受 flags 控制）
    has_voip_service "$pkg" && return 0

    # 音频保护
    [ "$flag_audio" = "1" ] && has_audio_focus "$pkg" && return 0

    # 通知保护
    [ "$flag_notify" = "1" ] && has_notification "$pkg" && return 0

    # 小窗保护
    [ "$flag_pip" = "1" ] && has_pip_or_freeform "$pkg" && return 0

    return 1
}