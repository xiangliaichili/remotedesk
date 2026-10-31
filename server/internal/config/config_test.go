package config

import (
	"os"
	"testing"
)

// TestApplyDotEnv 覆盖 .env 解析的边界：BOM、CRLF、注释、export 前缀、引号、空值。
func TestApplyDotEnv(t *testing.T) {
	keys := []string{"RD_TEST_ALPHA", "RD_TEST_BETA", "RD_TEST_GAMMA", "RD_TEST_KEEP"}
	for _, k := range keys {
		os.Unsetenv(k)
	}
	t.Cleanup(func() {
		for _, k := range keys {
			os.Unsetenv(k)
		}
	})

	// 已存在的环境变量不应被 .env 覆盖
	if err := os.Setenv("RD_TEST_KEEP", "from-system"); err != nil {
		t.Fatal(err)
	}

	text := "\ufeff# 注释行\r\n" +
		"\r\n" +
		"RD_TEST_ALPHA=plain\r\n" +
		"export RD_TEST_BETA=\"quoted value\"\r\n" +
		"RD_TEST_GAMMA=\r\n" +
		"RD_TEST_KEEP=from-dotenv\r\n" +
		"没有等号的行\r\n"

	applyDotEnv(text)

	cases := map[string]string{
		"RD_TEST_ALPHA": "plain",
		"RD_TEST_BETA":  "quoted value",
		"RD_TEST_GAMMA": "",
		"RD_TEST_KEEP":  "from-system",
	}
	for k, want := range cases {
		if got := os.Getenv(k); got != want {
			t.Errorf("%s = %q, want %q", k, got, want)
		}
	}
}

// TestApplyDotEnvKeepsHash 值里带 # 时不应被截断（只有整行以 # 开头才算注释）。
func TestApplyDotEnvKeepsHash(t *testing.T) {
	const k = "RD_TEST_HASH"
	os.Unsetenv(k)
	t.Cleanup(func() { os.Unsetenv(k) })

	applyDotEnv(k + "=abc#123\n")
	if got := os.Getenv(k); got != "abc#123" {
		t.Errorf("%s = %q, want %q", k, got, "abc#123")
	}
}

// TestDotEnvCandidates 至少包含当前目录，避免空切片导致配置完全读不到。
func TestDotEnvCandidates(t *testing.T) {
	paths := dotEnvCandidates()
	if len(paths) == 0 || paths[0] != ".env" {
		t.Fatalf("dotEnvCandidates() = %v, want 首项 .env", paths)
	}
}
