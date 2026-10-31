#!/usr/bin/env bash
# remotedesk 一键部署脚本（Linux）
#
# 用法（三选一）：
#   sudo bash deploy/install.sh rd.example.com 203.0.113.10   # 生产：域名 + 公网 IP，Caddy 自动 HTTPS
#   sudo bash deploy/install.sh --ip-only 203.0.113.10        # 只有 IP：http://IP:8080 直连（无证书）
#   sudo bash deploy/install.sh --local                      # 本机/内网验证：自动探测内网 IP，端口 8080
#
# 三种模式的差别只有「有没有 TLS、客户端填什么地址」，服务端代码完全一样。
# 没有域名的场景经常被卡住，所以单独做了 --ip-only / --local。
set -euo pipefail

MODE="tls"
DOMAIN=""
PUBLIC_IP=""
PORT="8080"

usage() {
  sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

case "${1:-}" in
  -h|--help|"") usage ;;
  --ip-only)
    MODE="ip"
    PUBLIC_IP="${2:-}"
    [[ -z "$PUBLIC_IP" ]] && { echo "用法：sudo bash deploy/install.sh --ip-only <公网IP>"; exit 1; }
    ;;
  --local)
    MODE="ip"
    PUBLIC_IP=""
    ;;
  *)
    MODE="tls"
    DOMAIN="${1:-}"
    PUBLIC_IP="${2:-}"
    if [[ -z "$DOMAIN" || -z "$PUBLIC_IP" ]]; then
      echo "用法：sudo bash deploy/install.sh <域名> <公网IP>"
      echo "或：  sudo bash deploy/install.sh --ip-only <公网IP>"
      echo "或：  sudo bash deploy/install.sh --local"
      exit 1
    fi
    ;;
esac

if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash deploy/install.sh ..."
  exit 1
fi

# --local：自动探测内网 IP
if [[ "$MODE" == "ip" && -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)
  [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="127.0.0.1"
  echo "==> 未指定 IP，自动探测到：$PUBLIC_IP"
fi

if [[ "$MODE" == "tls" ]]; then
  PUBLIC_URL="https://${DOMAIN}"
  LISTEN=":8443"
else
  PUBLIC_URL="http://${PUBLIC_IP}:${PORT}"
  LISTEN=":${PORT}"
fi

INSTALL_DIR=/opt/remotedesk
DATA_DIR=$INSTALL_DIR/data
JWT_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 48)

echo "==> 安装依赖"
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y curl ca-certificates tar
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl ca-certificates tar
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y curl ca-certificates tar
fi

echo "==> 准备目录"
mkdir -p "$DATA_DIR"
id -u remotedesk >/dev/null 2>&1 || useradd --system --home "$INSTALL_DIR" --shell /usr/sbin/nologin remotedesk || true
chown -R remotedesk:remotedesk "$INSTALL_DIR"

echo "==> 构建服务器二进制"
if ! command -v go >/dev/null 2>&1; then
  echo "    未检测到 Go，正在安装 Go 1.23 ..."
  GO_VER=1.23.4
  ARCH=$(uname -m); case "$ARCH" in x86_64) GOARCH=amd64;; aarch64|arm64) GOARCH=arm64;; *) GOARCH=amd64;; esac
  curl -fsSL "https://go.dev/dl/go${GO_VER}.linux-${GOARCH}.tar.gz" -o /tmp/go.tgz
  tar -C /usr/local -xzf /tmp/go.tgz
  export PATH=$PATH:/usr/local/go/bin
fi
( cd "$(dirname "$0")/.." && go mod tidy && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$INSTALL_DIR/remotedesk" . )
chmod +x "$INSTALL_DIR/remotedesk"

echo "==> 写入环境配置"
# 登录方式的额外配置：如果安装时已经在环境变量里给了，就原样写进 .env；
# 没给的保持注释，后续手工编辑 /opt/remotedesk/.env 再 systemctl restart 即可。
extra_env=""
add_env() {
  local key="$1" val="${2:-}"
  if [[ -n "$val" ]]; then
    extra_env="${extra_env}${key}=${val}"$'\n'
  fi
}
add_env RD_SMS_PROVIDER     "${RD_SMS_PROVIDER:-}"
add_env RD_SMS_SIGN         "${RD_SMS_SIGN:-}"
add_env RD_SMS_TEMPLATE     "${RD_SMS_TEMPLATE:-}"
add_env RD_ALIYUN_KEY_ID    "${RD_ALIYUN_KEY_ID:-}"
add_env RD_ALIYUN_KEY_SECRET "${RD_ALIYUN_KEY_SECRET:-}"
add_env RD_WECHAT_APP_ID    "${RD_WECHAT_APP_ID:-}"
add_env RD_WECHAT_APP_SECRET "${RD_WECHAT_APP_SECRET:-}"
add_env RD_WECHAT_REDIRECT  "${RD_WECHAT_REDIRECT:-}"

cat > "$INSTALL_DIR/.env" <<EOF
# ---------- 基础配置（安装脚本自动生成，勿随意改动） ----------
RD_PUBLIC=${PUBLIC_URL}
RD_LISTEN=${LISTEN}
RD_TURN_LISTEN=:3478
RD_TURN_RELAY_IP=${PUBLIC_IP}
RD_DB=${DATA_DIR}/remotedesk.db
RD_JWT_SECRET=${JWT_SECRET}

# ---------- 登录方式（可选） ----------
# 短信验证码登录：off=关闭（客户端隐藏入口）/ mock=只写日志（联调用）/ aliyun=真实发送
# 想开启手机登录：改成 aliyun，并填好下面四项，然后 systemctl restart remotedesk
RD_SMS_PROVIDER=${RD_SMS_PROVIDER:-off}
#RD_SMS_SIGN=你的短信签名
#RD_SMS_TEMPLATE=SMS_123456789
#RD_ALIYUN_KEY_ID=LTAI...
#RD_ALIYUN_KEY_SECRET=...
#
# 微信扫码登录：在微信开放平台建「网站应用」，回调域填 ${PUBLIC_IP}（有域名则填域名）
# 填好 AppID/Secret 后自动生效，客户端登录页会多出「微信登录」标签
#RD_WECHAT_APP_ID=wx...
#RD_WECHAT_APP_SECRET=...
RD_WECHAT_REDIRECT=${PUBLIC_URL}
#
# 开发调试开关：上线务必保持 0（=1 会回传验证码、开放模拟扫码接口）
RD_SMS_DEV=0
RD_AUTH_DEV=0

# ---------- 安装时通过环境变量传入的值 ----------
${extra_env}
EOF
chown remotedesk:remotedesk "$INSTALL_DIR/.env"
chmod 600 "$INSTALL_DIR/.env"

echo "==> 安装 systemd 服务"
cp "$(dirname "$0")/remotedesk.service" /etc/systemd/system/remotedesk.service
systemctl daemon-reload
systemctl enable remotedesk >/dev/null 2>&1 || true
systemctl restart remotedesk

if [[ "$MODE" == "tls" ]]; then
  echo "==> 安装 Caddy（自动 HTTPS 反向代理）"
  if ! command -v caddy >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
      apt-get update -y && apt-get install -y caddy
    else
      curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=amd64" -o /usr/local/bin/caddy
      chmod +x /usr/local/bin/caddy
    fi
  fi
  mkdir -p /etc/caddy
  cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN} {
    encode zstd gzip
    reverse_proxy 127.0.0.1:8443
}
EOF
  systemctl enable --now caddy || (caddy start --config /etc/caddy/Caddyfile || true)
  systemctl reload caddy || true
else
  echo "==> 跳过 Caddy（--ip-only / --local 模式使用明文 HTTP）"
  echo "    说明：客户端是原生程序，不依赖浏览器的安全上下文；"
  echo "    WebRTC 媒体仍是 DTLS-SRTP 端到端加密，只是信令没走 TLS。"
fi

echo "==> 配置防火墙"
if command -v ufw >/dev/null 2>&1; then
  if [[ "$MODE" == "tls" ]]; then
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
  else
    ufw allow "${PORT}/tcp" || true
  fi
  ufw allow 3478/tcp || true
  ufw allow 3478/udp || true
elif command -v firewall-cmd >/dev/null 2>&1; then
  if [[ "$MODE" == "tls" ]]; then
    firewall-cmd --permanent --add-port=80/tcp || true
    firewall-cmd --permanent --add-port=443/tcp || true
  else
    firewall-cmd --permanent --add-port="${PORT}/tcp" || true
  fi
  firewall-cmd --permanent --add-port=3478/tcp || true
  firewall-cmd --permanent --add-port=3478/udp || true
  firewall-cmd --reload || true
fi

echo "==> 健康检查"
ok=""
for i in $(seq 1 20); do
  sleep 1
  if curl -fsS --max-time 3 "http://127.0.0.1:${LISTEN#:}/healthz" >/dev/null 2>&1; then
    ok="yes"; break
  fi
done

echo
echo "=============================================="
if [[ -n "$ok" ]]; then
  echo " 部署完成 ✅  服务已通过健康检查"
else
  echo " 服务已安装，但健康检查未通过（可能还在启动）"
  echo " 排查：journalctl -u remotedesk -n 50 --no-pager"
fi
echo
echo " 客户端「服务器地址」填："
echo "   ${PUBLIC_URL}"
echo
echo " 健康检查: ${PUBLIC_URL}/healthz"
echo " 配置:     ${INSTALL_DIR}/.env"
echo " 日志:     journalctl -u remotedesk -f"
echo
if [[ "$MODE" == "tls" ]]; then
  echo " 别忘了：域名 A 记录要指向 ${PUBLIC_IP}，且放行 80/443（签证书用）"
else
  echo " 无域名模式：请确认 ${PUBLIC_IP}:${PORT} 已放行，且客户端能直连该 IP"
fi
echo " TURN 中继若不通，检查 3478 的 TCP+UDP 与 RD_TURN_RELAY_IP 是否为公网 IP"
echo "=============================================="
