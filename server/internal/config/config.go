// Package config 负责加载服务器配置。
// 优先级：命令行 flag > 环境变量 > .env > 默认值。
package config

import (
	"flag"
	"os"
	"path/filepath"
	"strconv"
	"strings"
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

	// ---------- 登录方式（v1.03） ----------

	// 短信服务商：mock（默认，只打印日志）/ aliyun / off（关闭短信登录）
	SMSProvider string
	// 短信签名与模板（阿里云控制台申请），模板里用 ${code} 占位
	SMSSign     string
	SMSTemplate string
	// 开发模式：日志打印验证码、响应里回 dev_code、开放 /api/auth/wechat/dev
	SMSDevMode bool
	// 阿里云 AccessKey（建议只授 dysms:SendSms 权限的 RAM 子账号）
	AliyunKeyID  string
	AliyunSecret string

	// 微信开放平台「网站应用」的 AppID / AppSecret（扫码登录用）
	WechatAppID  string
	WechatSecret string
	// 回调基址（对外可访问的地址，如 https://rd.example.com），用于拼 redirect_uri
	WechatRedirect string
	// 允许调用 /api/auth/wechat/dev 模拟扫码（仅本地联调）
	AuthDev bool
}

// Load 解析配置。
func Load() *Config {
	cfg := &Config{}

	// 先读 .env：命令行 flag > 环境变量 > .env > 默认值
	loadDotEnv()

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

	flag.StringVar(&cfg.SMSProvider, "sms-provider", envStr("RD_SMS_PROVIDER", "mock"), "短信服务商：mock|aliyun|off")
	flag.StringVar(&cfg.SMSSign, "sms-sign", envStr("RD_SMS_SIGN", ""), "短信签名（阿里云）")
	flag.StringVar(&cfg.SMSTemplate, "sms-template", envStr("RD_SMS_TEMPLATE", ""), "短信模板 CODE（阿里云）")
	flag.BoolVar(&cfg.SMSDevMode, "sms-dev", envBool("RD_SMS_DEV", false), "短信开发模式：日志打印验证码并在响应里回 dev_code")
	flag.StringVar(&cfg.AliyunKeyID, "aliyun-key-id", envStr("RD_ALIYUN_KEY_ID", ""), "阿里云 AccessKeyId")
	flag.StringVar(&cfg.AliyunSecret, "aliyun-key-secret", envStr("RD_ALIYUN_KEY_SECRET", ""), "阿里云 AccessKeySecret")

	flag.StringVar(&cfg.WechatAppID, "wechat-app-id", envStr("RD_WECHAT_APP_ID", ""), "微信开放平台网站应用 AppID")
	flag.StringVar(&cfg.WechatSecret, "wechat-app-secret", envStr("RD_WECHAT_APP_SECRET", ""), "微信开放平台网站应用 AppSecret")
	flag.StringVar(&cfg.WechatRedirect, "wechat-redirect", envStr("RD_WECHAT_REDIRECT", ""), "回调基址（如 https://rd.example.com）")
	flag.BoolVar(&cfg.AuthDev, "auth-dev", envBool("RD_AUTH_DEV", false), "开放 /api/auth/wechat/dev 模拟扫码（仅本地联调）")
	flag.Parse()

	return cfg
}

// WechatEnabled 微信扫码登录是否可用（缺 AppID/Secret 就当作没配）。
func (c *Config) WechatEnabled() bool {
	return c.WechatAppID != "" && c.WechatSecret != ""
}

// SMSEnabled 短信验证码登录是否可用。
func (c *Config) SMSEnabled() bool {
	return c.SMSProvider != "" && c.SMSProvider != "off"
}

// loadDotEnv 依次尝试当前目录与可执行文件同目录下的 .env，
// 找到第一个就加载。已存在的环境变量不会被覆盖，保证"命令行/系统环境变量优先"。
func loadDotEnv() {
	for _, p := range dotEnvCandidates() {
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		applyDotEnv(string(data))
		return
	}
}

// dotEnvCandidates 返回 .env 的候选路径（当前目录优先，其次 exe 所在目录）。
func dotEnvCandidates() []string {
	paths := []string{".env"}
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		paths = append(paths, filepath.Join(dir, ".env"))
	}
	return paths
}

// applyDotEnv 解析 KEY=VALUE 文本并写入环境变量（不覆盖已存在的）。
// 兼容：UTF-8 BOM、CRLF、`#` 注释、空行、`export KEY=VALUE`、值两侧的引号。
func applyDotEnv(text string) {
	text = strings.TrimPrefix(text, "\ufeff")
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(strings.TrimSuffix(raw, "\r"))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		if key == "" {
			continue
		}
		val = strings.TrimSpace(val)
		// 去掉成对引号；未加引号时保留 # 之后的内容（值里可能真有 #）
		if len(val) >= 2 && (val[0] == '"' || val[0] == '\'') && val[len(val)-1] == val[0] {
			val = val[1 : len(val)-1]
		}
		if _, exists := os.LookupEnv(key); exists {
			continue
		}
		_ = os.Setenv(key, val)
	}
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
