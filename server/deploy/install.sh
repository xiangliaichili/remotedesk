#!/usr/bin/env bash
# remotedesk 一键部署脚本（Linux VPS）
# 用法：
#   sudo bash deploy/install.sh rd.example.com 203.0.113.10
# 参数：$1 = 对外域名（用于 HTTPS）；$2 = 服务器公网 IP（用于 TURN 中继）
set -euo pipefail

DOMAIN="${1:-}"
PUBLIC_IP="${2:-}"

if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash deploy/install.sh <域名> <公网IP>"
  exit 1
fi
if [[ -z "$DOMAIN" || -z "$PUBLIC_IP" ]]; then
  echo "用法：sudo bash deploy/install.sh <域名> <公网IP>"
  echo "示例：sudo bash deploy/install.sh rd.example.com 203.0.113.10"
  exit 1
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
fi

echo "==> 准备目录"
mkdir -p "$DATA_DIR"
id -u remotedesk >/dev/null 2>&1 || useradd --system --home "$INSTALL_DIR" --shell /usr/sbin/nologin remotedesk || true
chown -R remotedesk:remotedesk "$INSTALL_DIR"

echo "==> 构建服务器二进制"
if command -v go >/dev/null 2>&1; then
  ( cd "$(dirname "$0")/.." && go mod tidy && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$INSTALL_DIR/remotedesk" . )
else
  echo "未检测到 Go，正在安装 Go 1.23 ..."
  GO_VER=1.23.4
  ARCH=$(uname -m); case "$ARCH" in x86_64) GOARCH=amd64;; aarch64|arm64) GOARCH=arm64;; *) GOARCH=amd64;; esac
  curl -fsSL "https://go.dev/dl/go${GO_VER}.linux-${GOARCH}.tar.gz" -o /tmp/go.tgz
  tar -C /usr/local -xzf /tmp/go.tgz
  export PATH=$PATH:/usr/local/go/bin
  ( cd "$(dirname "$0")/.." && go mod tidy && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$INSTALL_DIR/remotedesk" . )
fi
chmod +x "$INSTALL_DIR/remotedesk"

echo "==> 写入环境配置"
cat > "$INSTALL_DIR/.env" <<EOF
RD_PUBLIC=https://${DOMAIN}
RD_LISTEN=:8443
RD_TURN_LISTEN=:3478
RD_TURN_RELAY_IP=${PUBLIC_IP}
RD_DB=${DATA_DIR}/remotedesk.db
RD_JWT_SECRET=${JWT_SECRET}
EOF
chown remotedesk:remotedesk "$INSTALL_DIR/.env"
chmod 600 "$INSTALL_DIR/.env"

echo "==> 安装 systemd 服务"
cp "$(dirname "$0")/remotedesk.service" /etc/systemd/system/remotedesk.service
systemctl daemon-reload
systemctl enable --now remotedesk

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
    # 简化：直接以命令行方式在 systemd 中运行
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

echo "==> 配置防火墙"
if command -v ufw >/dev/null 2>&1; then
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  ufw allow 3478/tcp || true
  ufw allow 3478/udp || true
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port=80/tcp || true
  firewall-cmd --permanent --add-port=443/tcp || true
  firewall-cmd --permanent --add-port=3478/tcp || true
  firewall-cmd --permanent --add-port=3478/udp || true
  firewall-cmd --reload || true
fi

echo
echo "=============================================="
echo " 部署完成！"
echo " 服务端:  https://${DOMAIN}"
echo " 健康检查: https://${DOMAIN}/healthz"
echo " 配置:    $INSTALL_DIR/.env"
echo " 日志:    journalctl -u remotedesk -f"
echo " 客户端填写服务器地址: https://${DOMAIN}"
echo "=============================================="
