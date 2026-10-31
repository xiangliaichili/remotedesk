// Package sms 负责发送短信验证码。
//
// 默认 mock：只把验证码写进服务器日志，不真正发短信，方便本地联调；
// 生产用 aliyun（阿里云短信服务，RPC 签名，无 SDK 依赖）。
package sms

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

// ErrDisabled 表示短信通道被关闭（RD_SMS_PROVIDER=off）。
var ErrDisabled = errors.New("sms disabled")

// Config 是构造 Provider 所需的最小配置，避免和 config 包互相引用。
type Config struct {
	Provider string
	Sign     string
	Template string
	KeyID    string
	Secret   string
	Dev      bool
}

// Provider 抽象「把一条验证码发出去」。
type Provider interface {
	Name() string
	// Dev 为 true 时，接口会把验证码回给客户端（仅限本地/内网联调）。
	Dev() bool
	Send(ctx context.Context, phone, code string) error
}

// New 按配置选择实现。未知取值一律按 mock 处理，避免配错了导致登录不可用。
func New(cfg Config) Provider {
	switch strings.ToLower(strings.TrimSpace(cfg.Provider)) {
	case "aliyun":
		return &aliyun{cfg: cfg, http: &http.Client{Timeout: 8 * time.Second}}
	case "off", "disabled", "none":
		return &off{}
	default:
		return &mock{dev: true}
	}
}

// ---------- mock ----------

type mock struct{ dev bool }

func (m *mock) Name() string { return "mock" }
func (m *mock) Dev() bool    { return m.dev }

func (m *mock) Send(ctx context.Context, phone, code string) error {
	log.Printf("[sms/mock] 验证码 phone=%s code=%s（未真实发送）", maskPhone(phone), code)
	return nil
}

// ---------- off ----------

type off struct{}

func (o *off) Name() string                                     { return "off" }
func (o *off) Dev() bool                                        { return false }
func (o *off) Send(ctx context.Context, phone, code string) error { return ErrDisabled }

// ---------- aliyun ----------

type aliyun struct {
	cfg  Config
	http *http.Client
}

func (a *aliyun) Name() string { return "aliyun" }
func (a *aliyun) Dev() bool    { return a.cfg.Dev }

const aliyunEndpoint = "https://dysmsapi.aliyuncs.com/"

func (a *aliyun) Send(ctx context.Context, phone, code string) error {
	if a.cfg.KeyID == "" || a.cfg.Secret == "" || a.cfg.Sign == "" || a.cfg.Template == "" {
		return errors.New("aliyun sms 未配置完整（需要 RD_ALIYUN_KEY_ID / KEY_SECRET / SMS_SIGN / SMS_TEMPLATE）")
	}
	templateParam, _ := json.Marshal(map[string]string{"code": code})

	params := map[string]string{
		"AccessKeyId":      a.cfg.KeyID,
		"Action":           "SendSms",
		"Format":           "JSON",
		"PhoneNumbers":     phone,
		"RegionId":         "cn-hangzhou",
		"SignName":         a.cfg.Sign,
		"SignatureMethod":  "HMAC-SHA1",
		"SignatureNonce":   randomNonce(),
		"SignatureVersion": "1.0",
		"TemplateCode":     a.cfg.Template,
		"TemplateParam":    string(templateParam),
		"Timestamp":        time.Now().UTC().Format("2006-01-02T15:04:05Z"),
		"Version":          "2017-05-25",
	}
	params["Signature"] = SignRPC(params, a.cfg.Secret)

	q := make([]string, 0, len(params))
	for k, v := range params {
		q = append(q, percentEncode(k)+"="+percentEncode(v))
	}
	sort.Strings(q)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, aliyunEndpoint+"?"+strings.Join(q, "&"), nil)
	if err != nil {
		return err
	}
	resp, err := a.http.Do(req)
	if err != nil {
		return fmt.Errorf("请求阿里云短信失败：%w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	var out struct {
		Code    string `json:"Code"`
		Message string `json:"Message"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return fmt.Errorf("阿里云短信返回无法解析（HTTP %d）", resp.StatusCode)
	}
	if out.Code != "OK" {
		return fmt.Errorf("阿里云短信发送失败：%s %s", out.Code, out.Message)
	}
	return nil
}

// SignRPC 计算阿里云 RPC 风格签名（HMAC-SHA1）。
// 抽成导出函数是为了让它可被单测覆盖——这是整段代码里最容易写错的地方。
func SignRPC(params map[string]string, secret string) string {
	keys := make([]string, 0, len(params))
	for k := range params {
		if k == "Signature" {
			continue
		}
		keys = append(keys, k)
	}
	sort.Strings(keys)
	pairs := make([]string, 0, len(keys))
	for _, k := range keys {
		pairs = append(pairs, percentEncode(k)+"="+percentEncode(params[k]))
	}
	stringToSign := http.MethodGet + "&" + percentEncode("/") + "&" + percentEncode(strings.Join(pairs, "&"))
	mac := hmac.New(sha1.New, []byte(secret+"&"))
	mac.Write([]byte(stringToSign))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

// percentEncode 是阿里云要求的编码规则（RFC3986 变体）。
func percentEncode(s string) string {
	e := url.QueryEscape(s)
	e = strings.ReplaceAll(e, "+", "%20")
	e = strings.ReplaceAll(e, "*", "%2A")
	e = strings.ReplaceAll(e, "%7E", "~")
	return e
}

func randomNonce() string {
	const chars = "0123456789abcdef"
	b := make([]byte, 16)
	n := time.Now().UnixNano()
	for i := range b {
		b[i] = chars[int(n>>(i*3))%len(chars)]
	}
	return string(b)
}

// maskPhone 日志脱敏：138****8000。
func maskPhone(p string) string {
	if len(p) < 7 {
		return p
	}
	return p[:3] + "****" + p[len(p)-4:]
}
