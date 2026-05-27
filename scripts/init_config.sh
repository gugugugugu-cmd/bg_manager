#!/system/bin/sh

MODDIR="/data/adb/modules/bg_manager"
CONFIG_DIR="$MODDIR/config"
APPS_CONF="$CONFIG_DIR/apps.conf"
KEEP_CONF="$CONFIG_DIR/trim_keep.conf"

# 后续内容不变...
mkdir -p "$CONFIG_DIR"

is_numeric() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac }

# ── trim_keep.conf ──────────────────────────────────────────
if [ ! -f "$KEEP_CONF" ]; then
    cat > "$KEEP_CONF" << 'EOF'
# 瘦身时保留的进程，一行一个进程名
# 这些进程在 trim 操作时不会被杀死
com.tencent.mm:push
com.tencent.mm.push
EOF
    echo "生成 trim_keep.conf"
fi

# ── apps.conf 头部（首次生成） ───────────────────────────────
# init_config.sh 里首次生成 apps.conf 时，[apps] 段要在注释之前
if [ ! -f "$APPS_CONF" ]; then
    cat > "$APPS_CONF" << 'EOF'
# ============================================================
# 后台管家配置文件
# ============================================================

[time]
# 后台时间 = (base + slot × step) 秒，最小 30 秒
base=60
step=15

[apps]
# 格式: 处理方式  包名  备注  档位,计数器  辅助标记
#
# 处理方式:
#   T = 瘦身（杀子进程，保留主进程）
#   K = 强杀（am force-stop）
#   M = 音乐类（有音频焦点时跳过，无音频时按 T 处理）
#
# 档位: 影响后台等待时间，可为负数
#   后台时间 = (base + 档位 × step) 秒
#
# 计数器: 仅对 T/M 有效，瘦身 N 次后改为强杀；0 = 不启用
#
# 辅助标记: 8位，前3位有效
#   第1位 = 通知保护（有通知时跳过）
#   第2位 = 音频保护（有音频焦点时跳过）
#   第3位 = 小窗保护（有画中画/小窗时跳过）
#
# 示例（去掉开头的 # 即可启用）:
# T com.tencent.mobileqq  QQ      -1,0  11100000
# K com.example.app       示例     0,0   00000000
# M com.netease.cloudmusic 网易云   0,0   01000000
#
EOF
fi

# ── 读取已存在的包名（注释行和非注释行都算） ────────────────
# 匹配 "# T pkg" 和 "T pkg" 两种格式，提取包名列到临时文件
EXISTING_TMP=$(mktemp)
grep -E '^#?[[:space:]]*[TKM][[:space:]]' "$APPS_CONF" 2>/dev/null \
    | awk '{
        for(i=1;i<=NF;i++){
            # 跳过 # 和 T/K/M，取第一个看起来像包名的字段
            if($i ~ /^[TKMtkm#]$/) continue
            if($i ~ /\./) { print $i; break }
        }
    }' \
    | sort -u > "$EXISTING_TMP"

# ── 扫描已安装第三方 App ─────────────────────────────────────
SCAN_TMP=$(mktemp)
pm list packages -3 2>/dev/null \
    | sed 's/^package://' \
    | sort -u > "$SCAN_TMP"

# 新增包名 = 扫描结果 - 已存在
NEW_PKGS=$(comm -23 "$SCAN_TMP" "$EXISTING_TMP")
NEW_COUNT=$(echo "$NEW_PKGS" | grep -c '[^[:space:]]')

if [ -n "$NEW_PKGS" ] && [ "$NEW_COUNT" -gt 0 ]; then
    # 先去掉旧的 #last_scan= 行，再追加新内容和新时间戳
    # 这样时间戳始终在文件末尾
    CONF_TMP=$(mktemp)
    grep -v '^#last_scan=' "$APPS_CONF" > "$CONF_TMP"
    mv "$CONF_TMP" "$APPS_CONF"

    {
        echo ""
        echo "# ── 自动扫描新增 $(date '+%Y-%m-%d %H:%M:%S') ──"
        for pkg in $NEW_PKGS; do
            # 尝试获取 App 标签
            label=$(pm dump "$pkg" 2>/dev/null \
                | grep -m1 'nonLocalizedLabel' \
                | grep -oE '"[^"]+"' | tr -d '"' | head -1)
            if [ -z "$label" ]; then
                label=$(echo "$pkg" | awk -F'.' '{print $NF}')
            fi
            label=$(echo "$label" | tr ' ' '_')
            echo "# T $pkg  $label  0,0  00000000"
        done
        echo "#last_scan=$(date +%s)"
    } >> "$APPS_CONF"

    echo "init_config 完成，新增 ${NEW_COUNT} 个包"
else
    # 没有新包，只更新时间戳
    CONF_TMP=$(mktemp)
    grep -v '^#last_scan=' "$APPS_CONF" > "$CONF_TMP"
    echo "#last_scan=$(date +%s)" >> "$CONF_TMP"
    mv "$CONF_TMP" "$APPS_CONF"

    echo "init_config 完成，无新增包"
fi

rm -f "$SCAN_TMP" "$EXISTING_TMP"