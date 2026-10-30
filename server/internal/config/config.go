// Package config 负责加载服务器配置。优先级：命令行 flag > 环境变量 > 默认值。
package config

import (
	"flag"
	"os"
	"strconv"
)

// Config 汇总服务器运行所需的全部配置项。
type Config struct {
	// HTTP/WebSocket 监听地址（REST API 与信令共用）
	ListenAddr string
	// 对外可访问的公网地址，客户端据此拼接信令 URL（如 wss://example.com/ws）
	PublicAddr string
	// TURN 中继监听地址（UDP），用于 P2P 失败时的流量兜底
	TurnAddr string
	// TURN 对外通告的 relay IP（通常为服务器公网 IP）
	TurnRelayIP string
	// SQLite 数据库文件路径
	DBPath string
	// JWT 签名密钥（生产环境务必通过环境变量覆盖）
	JWTSecret string
	// 是否启用 HTTPS（由反向代理终止 TLS 时填 false，仅对裸 HTTP 暴露的调试场景为 true）
	// 注意：正式部署建议使用 Caddy/Nginx 反向代理并启用 wss。
	EnableTLS bool
	// 证书路径（EnableTLS 为 true 时使用）
	CertFile string
	KeyFile  string
	// 心跳超时（秒），超过后设备判为离线
	HeartbeatTimeout int
	// 一次性链接默认有效期（分钟）
	LinkTTLMinutes int
}

// Load 解析配置。
func Load() *Config {
	cfg := &Config{}

	flag.StringVar(&cfg.ListenAddr, "listen", envStr("RD_LISTEN", ":8443"), "HTTP/WebSocket 监听地址")
	flag.StringVar(&cfg.PublicAddr, "public", envStr("RD_PUBLIC", "http://127.0.0.1:8443"), "对外公网地址（如 https://rd.example.com）")
	flag.StringVar(&cfg.TurnAddr, "turn-listen", envStr("RD_TURN_LISTEN", ":3478"), "TURN 监听地址")
	flag.StringVar(&cfg.TurnRelayIP, "turn-relay-ip", envStr("RD_TURN_RELAY_IP", ""), "TURN 中继对外 IP（留空则自动探测）")
	flag.StringVar(&cfg.DBPath, "db", envStr("RD_DB", "./data/remotedesk.db"), "SQLite 数据库路径")
	flag.StringVar(&cfg.JWTSecret, "jwt-secret", envStr("RD_JWT_SECRET", "change-me-in-production"), "JWT 签名密钥")
	flag.BoolVar(&cfg.EnableTLS, "tls", envBool("RD_TLS", false), "是否启用内置 HTTPS")
	flag.StringVar(&cfg.CertFile, "cert", envStr("RD_CERT", ""), "TLS 证书文件")
	flag.StringVar(&cfg.KeyFile, "key", envStr("RD_KEY", ""), "TLS 私钥文件")
	flag.IntVar(&cfg.HeartbeatTimeout, "heartbeat", envInt("RD_HEARTBEAT", 60), "心跳超时（秒）")
	flag.IntVar(&cfg.LinkTTLMinutes, "link-ttl", envInt("RD_LINK_TTL", 10), "一次性链接有效期（分钟）")
	flag.Parse()

	return cfg
}

func envStr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envBool(key string, def bool) bool {
	if v := os.Getenv(key); v != "" {
		if b, err := strconv.ParseBool(v); err == nil {
			return b
		}
	}
	return def
}

func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
