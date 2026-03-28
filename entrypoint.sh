#!/bin/sh
# ==========================================
# Salad Agent v2.0 — 适配 v4.1 C2 中控
#
# 变更 (相对 v1.6):
#   - 心跳间隔 60s (中控 ALIVE_THRESHOLD=300s, 留足余量)
#   - 上报字段增加 agent_version, uptime
#   - 启动速度优化: 服务先拉起, 情报并行采集
#   - FRP 断线自动重启 (watchdog)
#   - 日志格式统一, 方便 Salad Cloud 查看
# ==========================================

set -e

# ==========================================
# 1. 基础参数 (环境变量由中控 _build_payload 注入)
# ==========================================
AGENT_VERSION="2.6"
NODE_NAME=${NODE_NAME:-"zirun-node-$(date +%s)"}
FRPS_ADDR=${FRPS_SERVER_ADDR}
FRPS_PORT=${FRPS_SERVER_PORT}
FRP_TOKEN=${AUTH_TOKEN}
REMOTE_PORT=${ASSIGNED_PORT}

PROXY_USER=${PROXY_USER:-"maxking"}
PROXY_PASS=${PROXY_PASS:-"maxking2026"}
DINGTALK_URL=${DINGTALK_WEBHOOK:-""}
DING_KEY=${DINGTALK_KEYWORD:-"A"}
TARGET_COUNTRY=${TARGET_COUNTRY:-"ANY"}

SSH_PUB_KEY=${SSH_MASTER_PUB_KEY:-""}
SSH_REM_PORT=${SSH_REMOTE_PORT:-"0"}

DISPLAY_ADDR=${FRPS_DISPLAY_ADDR:-$FRPS_ADDR}

BOOT_TIME=$(date +%s)
log() { echo "$(date '+%H:%M:%S') $1"; }

# ==========================================
# 2. 核心服务: 瞬间拉起 (先斩后奏)
# ==========================================
log "🚀 [启动] Agent $AGENT_VERSION | 节点 $NODE_NAME | 端口 $REMOTE_PORT"

# 2.1 启动 SSH 服务
if [ -n "$SSH_PUB_KEY" ]; then
    echo "$SSH_PUB_KEY" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    /usr/sbin/sshd -D -p 2222 \
        -o "PasswordAuthentication no" \
        -o "PermitRootLogin yes" \
        -o "ClientAliveInterval 30" \
        -o "ClientAliveCountMax 3" &
    log "🔑 [SSH] 远程终端已启动 (本地 2222 → 远程 $SSH_REM_PORT)"
fi

# 2.2 生成 FRP 配置
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

if [ -n "$SSH_PUB_KEY" ] && [ "$SSH_REM_PORT" != "0" ]; then
    cat <<EOF >> /tmp/frpc.toml

[[proxies]]
name = "ssh-$NODE_NAME"
type = "tcp"
localIP = "127.0.0.1"
localPort = 2222
remotePort = $SSH_REM_PORT
EOF
    log "🔗 [FRP] SSH 隧道已配置"
fi

# 2.3 启动 GOST + FRP
/bin/gost -L "mixed://${GOST_AUTH}:1080" > /dev/null 2>&1 &
GOST_PID=$!
/bin/frpc -c /tmp/frpc.toml > /tmp/frpc.log 2>&1 &
FRP_PID=$!
log "✅ [核心] GOST($GOST_PID) + FRP($FRP_PID) 已启动"

# ==========================================
# 3. FRP Watchdog (后台守护, 断线自动重启)
# ==========================================
(
    while true; do
        sleep 30
        if ! kill -0 $FRP_PID 2>/dev/null; then
            log "⚠️ [看门狗] FRP 进程已退出, 正在重启..."
            /bin/frpc -c /tmp/frpc.toml > /tmp/frpc.log 2>&1 &
            FRP_PID=$!
            log "🔄 [看门狗] FRP 已重启 PID=$FRP_PID"
        fi
    done
) &

# ==========================================
# 4. 后台勤务: 情报采集 + 国家筛选 + 上报 + 心跳
# ==========================================
(
    # 4.1 采集地理情报
    log "🔍 [情报] 正在扫描节点地理属性..."
    INFO=$(curl -s -m 8 https://ipapi.co/json/ || echo "{}")
    REAL_COUNTRY_CODE=$(echo "$INFO" | jq -r '.country // "?"')
    REAL_COUNTRY_NAME=$(echo "$INFO" | jq -r '.country_name // "Unknown"')
    CITY=$(echo "$INFO" | jq -r '.city // "Unknown"')
    ORG=$(echo "$INFO" | jq -r '.org // "Unknown"')
    IP=$(echo "$INFO" | jq -r '.ip // "0.0.0.0"')

    # 4.2 国家筛选
    T_UP=$(echo "$TARGET_COUNTRY" | tr '[:lower:]' '[:upper:]')
    R_UP=$(echo "$REAL_COUNTRY_CODE" | tr '[:lower:]' '[:upper:]')

    if [ "$T_UP" != "ANY" ] && [ "$T_UP" != "$R_UP" ]; then
        log "💀 [淘汰] 国籍不符! 目标: $T_UP, 实际: $R_UP ($REAL_COUNTRY_NAME)"

        if [ -n "$COMMAND_CENTER_URL" ]; then
            curl -s -m 5 -X POST "$COMMAND_CENTER_URL/api/report" \
              -H "Content-Type: application/json" \
              -H "X-Report-Token: ${REPORT_SECRET}" \
              -d "{\"node_name\":\"$NODE_NAME\",\"status\":\"eliminated\",\"ip\":\"$IP\",\"country\":\"$R_UP\",\"country_name\":\"$REAL_COUNTRY_NAME\",\"city\":\"$CITY\",\"org\":\"$ORG\",\"port\":$REMOTE_PORT,\"agent_version\":\"$AGENT_VERSION\"}" \
              > /dev/null 2>&1
        fi

        if [ -n "$DINGTALK_URL" ]; then
            MSG="### 💀 【${DING_KEY}-节点淘汰】\n\n**国籍不匹配**\n\n📍 实际: $REAL_COUNTRY_NAME ($R_UP)\n🎯 目标: $T_UP\n🆔 $NODE_NAME\n🌐 $IP"
            curl -s -H "Content-Type: application/json" -d "{\"msgtype\":\"markdown\",\"markdown\":{\"title\":\"${DING_KEY}-淘汰\",\"text\":\"$MSG\"}}" "$DINGTALK_URL" > /dev/null 2>&1
        fi

        pkill -9 frpc; pkill -9 gost
        exit 1
    fi

    # 4.3 测速
    log "⚡ [测速] 国籍匹配 ($R_UP), 开始测量带宽..."
    SPEED_BPS=$(curl -m 10 -s -w "%{speed_download}" -o /dev/null https://speed.cloudflare.com/__down?bytes=5242880 || echo "0")
    SPEED_MBS=$(echo "$SPEED_BPS" | awk '{printf "%.2f", $1/1024/1024}')
    log "📊 [测速] $SPEED_MBS MB/s | $CITY, $REAL_COUNTRY_NAME | $ORG"

    # 4.4 构造上报 JSON (复用于心跳)
    PROXY_LINK="socks5h://${PROXY_USER}:${PROXY_PASS}@${DISPLAY_ADDR}:${REMOTE_PORT}"
    REPORT_JSON="{\"node_name\":\"$NODE_NAME\",\"status\":\"online\",\"ip\":\"$IP\",\"country\":\"$R_UP\",\"country_name\":\"$REAL_COUNTRY_NAME\",\"city\":\"$CITY\",\"org\":\"$ORG\",\"speed\":\"$SPEED_MBS\",\"port\":$REMOTE_PORT,\"ssh_port\":$SSH_REM_PORT,\"proxy_link\":\"$PROXY_LINK\",\"agent_version\":\"$AGENT_VERSION\"}"

    # 4.5 首次上报
    if [ -n "$COMMAND_CENTER_URL" ]; then
        HTTP_CODE=$(curl -s -m 5 -o /tmp/sala_report_resp.txt -w "%{http_code}" -X POST "$COMMAND_CENTER_URL/api/report" \
          -H "Content-Type: application/json" \
          -H "X-Report-Token: ${REPORT_SECRET}" \
          -d "$REPORT_JSON")
        if [ "$HTTP_CODE" = "200" ]; then
            log "📡 [上报] Dashboard 已接收 (HTTP 200)"
        else
            RESP=$(tr -d '\r\n' < /tmp/sala_report_resp.txt 2>/dev/null | head -c 400)
            log "⚠️ [上报] Dashboard 失败 HTTP=${HTTP_CODE:-?} body=${RESP:-empty}"
        fi
    fi

    # 4.6 钉钉上线播报
    if [ -n "$DINGTALK_URL" ]; then
        MSG="### 🌍 【${DING_KEY}-节点上线】\n\n"
        MSG="$MSG📍 **位置**: $CITY | $ORG\n"
        MSG="$MSG🌐 **IP**: $IP\n"
        MSG="$MSG🚀 **测速**: $SPEED_MBS MB/s\n"
        MSG="$MSG🆔 **代号**: $NODE_NAME\n"
        MSG="$MSG🔌 **端口**: $REMOTE_PORT\n\n"
        MSG="$MSG🔗 **代理链接**:\n\`$PROXY_LINK\`\n\n"
        MSG="$MSG*(Agent $AGENT_VERSION)*"
        curl -s -H "Content-Type: application/json" -d "{\"msgtype\":\"markdown\",\"markdown\":{\"title\":\"${DING_KEY}-上线\",\"text\":\"$MSG\"}}" "$DINGTALK_URL" > /dev/null 2>&1
    fi

    # 4.7 心跳循环 (每 60s, 中控 ALIVE_THRESHOLD=300s)
    if [ -n "$COMMAND_CENTER_URL" ]; then
        HEARTBEAT_SEQ=0
        while true; do
            sleep 60
            HEARTBEAT_SEQ=$((HEARTBEAT_SEQ + 1))
            UPTIME=$(( $(date +%s) - BOOT_TIME ))
            HB_JSON="{\"node_name\":\"$NODE_NAME\",\"status\":\"online\",\"ip\":\"$IP\",\"country\":\"$R_UP\",\"country_name\":\"$REAL_COUNTRY_NAME\",\"city\":\"$CITY\",\"org\":\"$ORG\",\"speed\":\"$SPEED_MBS\",\"port\":$REMOTE_PORT,\"ssh_port\":$SSH_REM_PORT,\"proxy_link\":\"$PROXY_LINK\",\"agent_version\":\"$AGENT_VERSION\",\"uptime\":$UPTIME}"
            HTTP_CODE=$(curl -s -m 5 -o /tmp/sala_hb.txt -w "%{http_code}" -X POST "$COMMAND_CENTER_URL/api/report" \
              -H "Content-Type: application/json" \
              -H "X-Report-Token: ${REPORT_SECRET}" \
              -d "$HB_JSON")
            if [ "$HTTP_CODE" != "200" ]; then
                log "⚠️ [心跳#$HEARTBEAT_SEQ] HTTP=${HTTP_CODE:-?} $(tr -d '\r\n' < /tmp/sala_hb.txt 2>/dev/null | head -c 200)"
            fi
        done
    fi
) &

# 保持主进程运行
wait
