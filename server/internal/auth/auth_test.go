package auth

import (
	"testing"
	"time"
)

func TestHashAndCheckPassword(t *testing.T) {
	const pw = "secret123"
	h, err := HashPassword(pw)
	if err != nil {
		t.Fatalf("哈希失败: %v", err)
	}
	if h == pw {
		t.Fatalf("不能明文存储密码")
	}
	if !CheckPassword(h, pw) {
		t.Fatalf("正确密码应校验通过")
	}
	if CheckPassword(h, "wrong") {
		t.Fatalf("错误密码必须校验失败")
	}
	if CheckPassword("", pw) {
		t.Fatalf("空哈希必须校验失败")
	}
}

func TestHashPasswordUnique(t *testing.T) {
	a, _ := HashPassword("same")
	b, _ := HashPassword("same")
	if a == b {
		t.Fatalf("bcrypt 应加随机盐，两次哈希不应相同")
	}
}

func TestSignAndParseToken(t *testing.T) {
	const secret = "test-secret-key-0123456789"
	tok, err := SignToken(secret, 42, "alice", "device-1", time.Hour)
	if err != nil {
		t.Fatalf("签发失败: %v", err)
	}
	if tok == "" {
		t.Fatalf("token 不应为空")
	}

	c, err := ParseToken(secret, tok)
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if c.UserID != 42 || c.Username != "alice" || c.DeviceID != "device-1" {
		t.Fatalf("claims 不匹配: %+v", c)
	}
}

func TestParseTokenWrongSecret(t *testing.T) {
	tok, err := SignToken("secret-a", 1, "u", "d", time.Hour)
	if err != nil {
		t.Fatalf("签发失败: %v", err)
	}
	if _, err := ParseToken("secret-b", tok); err == nil {
		t.Fatalf("换密钥必须校验失败")
	}
}

func TestParseTokenExpired(t *testing.T) {
	tok, err := SignToken("s", 1, "u", "d", -time.Minute)
	if err != nil {
		t.Fatalf("签发失败: %v", err)
	}
	if _, err := ParseToken("s", tok); err == nil {
		t.Fatalf("过期 token 必须被拒绝")
	}
}

func TestParseTokenGarbage(t *testing.T) {
	for _, s := range []string{"", "abc", "a.b.c", "Bearer xxx"} {
		if _, err := ParseToken("s", s); err == nil {
			t.Fatalf("非法 token %q 必须被拒绝", s)
		}
	}
}