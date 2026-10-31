package sms

import (
	"context"
	"encoding/base64"
	"strings"
	"testing"
)

func TestPercentEncode(t *testing.T) {
	cases := map[string]string{
		"a b":      "a%20b",
		"a+b":      "a%2Bb",
		"a*b":      "a%2Ab",
		"~test":    "~test",
		"100%":     "100%25",
		"中文":       "%E4%B8%AD%E6%96%87",
		"a/b?c=d&": "a%2Fb%3Fc%3Dd%26",
	}
	for in, want := range cases {
		if got := percentEncode(in); got != want {
			t.Errorf("percentEncode(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSignRPCStable(t *testing.T) {
	params := map[string]string{
		"AccessKeyId":      "test-key",
		"Action":           "SendSms",
		"Format":           "JSON",
		"PhoneNumbers":     "13800138000",
		"RegionId":         "cn-hangzhou",
		"SignName":         "remotedesk",
		"SignatureMethod":  "HMAC-SHA1",
		"SignatureNonce":   "abc123",
		"SignatureVersion": "1.0",
		"TemplateCode":     "SMS_000000",
		"TemplateParam":    `{"code":"123456"}`,
		"Timestamp":        "2026-01-01T00:00:00Z",
		"Version":          "2017-05-25",
	}
	first := SignRPC(params, "secret")
	second := SignRPC(params, "secret")
	if first != second {
		t.Fatalf("签名不稳定：%q vs %q", first, second)
	}
	raw, err := base64.StdEncoding.DecodeString(first)
	if err != nil {
		t.Fatalf("签名不是合法 base64：%v", err)
	}
	if len(raw) != 20 {
		t.Fatalf("HMAC-SHA1 应为 20 字节，实际 %d", len(raw))
	}
	if other := SignRPC(params, "secret2"); other == first {
		t.Fatal("换密钥后签名不应相同")
	}
	// Signature 字段本身不参与计算
	withSig := map[string]string{"Signature": "xxx"}
	for k, v := range params {
		withSig[k] = v
	}
	if SignRPC(withSig, "secret") != first {
		t.Fatal("Signature 字段不应参与签名计算")
	}
}

func TestNewProvider(t *testing.T) {
	if p := New(Config{Provider: "mock"}); p.Name() != "mock" || !p.Dev() {
		t.Fatalf("mock 应默认 dev 模式，实际 %s dev=%v", p.Name(), p.Dev())
	}
	if p := New(Config{Provider: ""}); p.Name() != "mock" {
		t.Fatalf("空配置应退化为 mock，实际 %s", p.Name())
	}
	if p := New(Config{Provider: "off"}); p.Name() != "off" {
		t.Fatalf("off 未生效：%s", p.Name())
	}
	if p := New(Config{Provider: "aliyun", Dev: true}); p.Name() != "aliyun" || !p.Dev() {
		t.Fatalf("aliyun 配置错误：%s dev=%v", p.Name(), p.Dev())
	}
}

func TestOffProviderRejects(t *testing.T) {
	p := New(Config{Provider: "off"})
	if err := p.Send(context.Background(), "13800138000", "123456"); err != ErrDisabled {
		t.Fatalf("off 通道应返回 ErrDisabled，实际 %v", err)
	}
}

func TestAliyunRequiresConfig(t *testing.T) {
	p := New(Config{Provider: "aliyun"})
	err := p.Send(context.Background(), "13800138000", "123456")
	if err == nil || !strings.Contains(err.Error(), "未配置完整") {
		t.Fatalf("缺配置时应明确报错，实际 %v", err)
	}
}

func TestMaskPhone(t *testing.T) {
	if got := maskPhone("13800138000"); got != "138****8000" {
		t.Fatalf("maskPhone = %q", got)
	}
	if got := maskPhone("123"); got != "123" {
		t.Fatalf("短号码应原样返回，实际 %q", got)
	}
}
