#!/usr/bin/env bash
# 交叉编译中转服务器：一条命令产出 Linux / Windows / macOS 可执行文件。
# 用法： ./scripts/build-server.sh [版本号]
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-0.1.0}"
OUT="dist/server"
mkdir -p "$OUT"

if ! command -v go >/dev/null 2>&1; then
  echo "未检测到 Go，请先安装 Go 1.22+（https://go.dev/dl/）" >&2
  exit 1
fi

echo "==> go mod tidy"
(cd server && go mod tidy)

build() {
  local goos="$1" goarch="$2" suffix="$3"
  local name="remotedesk-server-${goos}-${goarch}${suffix}"
  echo "==> $name"
  (cd server && CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
    go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o "../${OUT}/${name}" .)
}

build linux amd64 ""
build linux arm64 ""
build windows amd64 ".exe"
build darwin arm64 ""
build darwin amd64 ""

echo
echo "完成，产物位于 ${OUT}/"
ls -lh "$OUT"