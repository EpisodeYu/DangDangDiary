#!/usr/bin/env bash
# DangDangDiary — 一键探活脚本，部署后或定时跑都行。
#
# 与 3GPP-Everything/deploy/scripts/healthcheck.sh 同构（同样的输出风格 / 退出码约定），
# 方便 ~/infra/monitor/check-all.sh 统一聚合。
#
# 架构回顾（见 docker-compose.yml / nginx/nginx.conf）：
#   公网 443 → ~/infra/ingress/nginx → dangdang-nginx:80
#                                       ├─ /api/  /docs  /openapi.json → fastapi:8000
#                                       └─ /media/                     → minio:9000
#   fastapi 依赖 postgres / redis / minio（compose depends_on）。
#
# 检查分两层：
#   A. 宿主直连各内部服务（绕过 ingress，能定位是哪一层挂）：
#        fastapi :8000/health、minio :9000/minio/health/live、postgres pg_isready、redis PING
#   B. 端到端经 ingress：https://$DOMAIN/openapi.json（走 ingress→dangdang-nginx→fastapi 全链路）
#        注意 /health 不在 dangdang-nginx 的 location 里（只反代 /api /docs /openapi.json /media），
#        经 ingress 打 /health 会 404，所以 e2e 用 /openapi.json。
#   C. 证书有效期（ingress 项目管理，< 7 天告警）。
#
# 退出码：全部通过 0；任意 FAIL 非 0（cron / check-all.sh 据此判定）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.yml"
ENV_FILE="$PROJECT_ROOT/.env"

# 域名归 ingress 项目管，从 ingress 的 .env 读取做端到端烟测。
# 如果 ingress 不在标准路径，传 INGRESS_ENV=/path/to/.env 覆盖。
INGRESS_ENV="${INGRESS_ENV:-$HOME/infra/ingress/.env}"
DOMAIN=""
if [[ -f "$INGRESS_ENV" ]]; then
    DOMAIN="$(grep -E '^DANGDANG_DOMAIN=' "$INGRESS_ENV" | tail -1 | cut -d= -f2- | tr -d '"' || true)"
fi

# 读 DB_USER / REDIS_PASSWORD（compose 用 ${DB_USER:-dangdang} / ${REDIS_PASSWORD}）。
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
DB_USER="${DB_USER:-dangdang}"

dc() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; GREEN=$'\033[0;32m'; RESET=$'\033[0m'
fail=0
check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}[OK]${RESET}     $name"
    else
        echo -e "${RED}[FAIL]${RESET}   $name"
        fail=$((fail+1))
    fi
}

echo "=== 业务容器状态 (dangdangdiary) ==="
dc ps

echo
echo "=== 宿主直连内部服务（定位故障层） ==="
# fastapi / minio 都把端口绑到了 127.0.0.1，宿主可直接 curl。
check "fastapi  :8000 /health" \
    curl -fsS --max-time 5 http://127.0.0.1:8000/health
check "minio    :9000 /minio/health/live" \
    curl -fsS --max-time 5 -o /dev/null http://127.0.0.1:9000/minio/health/live
# postgres 有 compose healthcheck，这里再主动 pg_isready 一次。
check "postgres pg_isready" \
    dc exec -T postgres pg_isready -U "$DB_USER"
# redis 设了 requirepass，--no-auth-warning 抑制告警噪声。
check "redis    PING" \
    dc exec -T redis redis-cli -a "${REDIS_PASSWORD:-}" --no-auth-warning ping

if [[ -n "$DOMAIN" ]]; then
    echo
    echo "=== 入口层端到端 (ingress→nginx→fastapi) ==="
    # /openapi.json 走完整链路（ingress→dangdang-nginx→fastapi:8000）且稳定返回 200。
    check "https://$DOMAIN/openapi.json (经 ingress 全链路)" \
        curl -fsS -k --max-time 10 -o /dev/null "https://$DOMAIN/openapi.json"

    echo
    echo "=== 证书有效期（ingress 项目管理） ==="
    CERT_FILE="$HOME/infra/ingress/certbot/conf/live/$DOMAIN/fullchain.pem"
    # 用 -L 验 symlink 存在；过期时间从外网拉（archive/ 是 root 0700，host 用户读不到）。
    if [[ -L "$CERT_FILE" ]]; then
        expiry=$(echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null \
            | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
        if [[ -n "$expiry" ]]; then
            expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
            days_left=$(( ($expiry_epoch - $(date +%s)) / 86400 ))
            if [[ $days_left -gt 30 ]]; then
                echo -e "${GREEN}[OK]${RESET}     证书还剩 $days_left 天"
            elif [[ $days_left -gt 7 ]]; then
                echo -e "${YELLOW}[WARN]${RESET}   证书快过期：$days_left 天"
            else
                echo -e "${RED}[FAIL]${RESET}   证书剩 $days_left 天，紧急"
                fail=$((fail+1))
            fi
        else
            echo -e "${YELLOW}[WARN]${RESET}   证书 symlink 在但取过期日期失败"
        fi
    else
        echo -e "${YELLOW}[INFO]${RESET}   未找到 $CERT_FILE；ingress 项目可能未初始化"
    fi
else
    echo
    echo -e "${YELLOW}[INFO]${RESET} 未从 $INGRESS_ENV 读到 DANGDANG_DOMAIN，跳过入口层探活"
fi

echo
if [[ $fail -eq 0 ]]; then
    echo -e "${GREEN}全部通过${RESET}"
    exit 0
else
    echo -e "${RED}$fail 项失败${RESET}"
    exit 1
fi
