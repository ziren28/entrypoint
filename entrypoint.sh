#!/bin/sh
# 注意：V1.6 引入了智能筛选逻辑，不符合要求的节点将自动退出

# ==========================================
# 1. 基础参数提取 (环境变量注入)
# ==========================================
NODE_NAME=${NODE_NAME:-"zirun-node-$(date +%s)"}
FRPS_ADDR=${FRPS_SERVER_ADDR}
FRPS_PORT=${FRPS_SERVER_PORT}
FRP_TOKEN=${AUTH_TOKEN}
REMOTE_PORT=${ASSIGNED_PORT}

# 代理鉴权与通知
PROXY_USER=${PROXY_USER:-"maxking"}
PROXY_PASS=${PROXY_PASS:-"maxking2026"}
DINGTALK_URL=${DINGTALK_WEBHOOK:-""}
DING_KEY=${DINGTALK_KEYWORD:-"A"}
TARGET_COUNTRY=${TARGET_COUNTRY:-"ANY"}

# ==========================================
# 2. 核心服务：瞬间拉起 (先斩后奏)
# ==========================================
echo "🚀 [启动] 正在为节点 [$NODE_NAME] 建立穿透..."

GOST_AUTH="${PROXY_USER}:${PROXY_PASS}@"
cat <<EOF > /tmp/frpc.toml
serverAddr = "$FRPS_ADDR"
serverPort = $FRPS_PORT
auth.token = "$FRP_TOKEN"

[[proxies]]
name = "salad-$NODE_NAME"
type = "tcp"
localIP = "127.0.0.1"
localPort = 1080
remotePort = $REMOTE_PORT
EOF

# 后台并行启动，确保 1 秒内上线
/bin/gost -L "mixed://${GOST_AUTH}:1080" > /dev/null 2>&1 &
/bin/frpc -c /tmp/frpc.toml > /dev/null 2>&1 &

# ==========================================
# 3. 后台勤务：情报搜集、国家筛选、钉钉播报
# ==========================================
(
    # 3.1 采集地理情报 (使用 ipapi 获取 ISO 国家简码)
    echo "🔍 [分析] 正在扫描节点地理属性..."
    INFO=$(curl -s -m 8 https://ipapi.co/json/)
    REAL_COUNTRY_CODE=$(echo "$INFO" | jq -r '.country')  # 如: US, GB
    REAL_COUNTRY_NAME=$(echo "$INFO" | jq -r '.country_name')
    CITY=$(echo "$INFO" | jq -r '.city')
    ORG=$(echo "$INFO" | jq -r '.org')
    IP=$(echo "$INFO" | jq -r '.ip')

    # 3.2 核心逻辑：国家筛选 (Case Insensitive)
    # 将变量转为大写进行对比
    T_UP=$(echo "$TARGET_COUNTRY" | tr '[:lower:]' '[:upper:]')
    R_UP=$(echo "$REAL_COUNTRY_CODE" | tr '[:lower:]' '[:upper:]')

    if [ "$T_UP" != "ANY" ] && [ "$T_UP" != "$R_UP" ]; then
        echo "💀 [淘汰] 国籍不符！目标: $T_UP, 实际: $R_UP. 正在撤离..."
        
        # 发送销毁通知
        if [ -n "$DINGTALK_URL" ]; then
            MSG="### 💀 【${DING_KEY}-节点销毁】\n\n**国籍不匹配，自动下线！**\n\n📍 **实际位置**: $REAL_COUNTRY_NAME ($R_UP)\n🎯 **目标位置**: $T_UP\n🆔 **代号**: $NODE_NAME\n🌐 **IP**: $IP\n\n*(系统已自动回收该卡槽资源)*"
            curl -s -H "Content-Type: application/json" -d "{\"msgtype\":\"markdown\",\"markdown\":{\"title\":\"${DING_KEY}-节点销毁\",\"text\":\"$MSG\"}}" "$DINGTALK_URL" > /dev/null 2>&1
        fi
        
        # 强制自杀，停止计费
        pkill -9 frpc
        pkill -9 gost
        exit 1
    fi

    # 3.3 既然符合要求，开始执行测速 (5MB)
    echo "⚡ [分析] 国籍匹配，开始测量带宽..."
    SPEED_BPS=$(curl -m 10 -s -w "%{speed_download}" -o /dev/null https://speed.cloudflare.com/__down?bytes=5242880 || echo "0")
    SPEED_MBS=$(echo "$SPEED_BPS" | awk '{printf "%.2f", $1/1024/1024}')

    # 3.4 最终钉钉上线播报
    if [ -n "$DINGTALK_URL" ]; then
        PROXY_LINK="socks5h://${PROXY_USER}:${PROXY_PASS}@${FRPS_ADDR}:${REMOTE_PORT}"
        
        MSG="### 🌍 【${DING_KEY}-节点上线】\n\n"
        MSG="$MSG**💎 目标达成！**\n\n"
        MSG="$MSG📍 **位置**: $CITY | $ORG\n"
        MSG="$MSG🌐 **住宅IP**: $IP\n"
        MSG="$MSG🚀 **测速**: $SPEED_MBS MB/s\n"
        MSG="$MSG🆔 **代号**: $NODE_NAME\n"
        MSG="$MSG🔌 **端口**: $REMOTE_PORT\n\n"
        MSG="$MSG🔗 **代理链接 (长按复制)**:\n\`$PROXY_LINK\`\n\n"
        MSG="$MSG*(极速版 V1.6 - 校验码: ${DING_KEY})*"

        curl -s -H "Content-Type: application/json" -d "{
            \"msgtype\": \"markdown\",
            \"markdown\": {
                \"title\": \"${DING_KEY}-节点上线\",
                \"text\": \"$MSG\"
            }
        }" "$DINGTALK_URL" > /dev/null 2>&1
    fi
) &

# 保持主进程运行
wait
