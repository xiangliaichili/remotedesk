package link

import (
	"path/filepath"
	"regexp"
	"testing"
	"time"

	"github.com/remotedesk/server/internal/store"
)

func newStore(t *testing.T) *store.Store {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

func TestGenerateFormat(t *testing.T) {
	st := newStore(t)

	re := regexp.MustCompile(`^[A-Z2-9]{8}$`)
	seen := make(map[string]bool, 64)
	for i := 0; i < 64; i++ {
		l, err := Generate(st, "device-"+string(rune('a'+i%26)), 10*time.Minute)
		if err != nil {
			t.Fatalf("生成连接码失败: %v", err)
		}
		if !re.MatchString(l.Code) {
			t.Fatalf("连接码格式不符: %q", l.Code)
		}
		if len(l.Code) != 8 {
			t.Fatalf("连接码长度应为 8，实际 %d", len(l.Code))
		}
		if seen[l.Code] {
			t.Fatalf("连接码重复: %q", l.Code)
		}
		seen[l.Code] = true
		if l.Used {
			t.Fatalf("新生成的连接码不应为已使用状态")
		}
		if time.Until(l.ExpiresAt) < 9*time.Minute {
			t.Fatalf("连接码有效期不足: %v", time.Until(l.ExpiresAt))
		}
	}
}

func TestAlphabetHasNoConfusingChars(t *testing.T) {
	for _, c := range []byte{'0', 'O', '1', 'I'} {
		for i := 0; i < len(alphabet); i++ {
			if alphabet[i] == c {
				t.Fatalf("字母表不应包含易混淆字符 %q", string(c))
			}
		}
	}
}

func TestResolveOnce(t *testing.T) {
	st := newStore(t)
	l, err := Generate(st, "device-xyz", time.Minute)
	if err != nil {
		t.Fatalf("生成失败: %v", err)
	}

	got, err := Resolve(st, l.Code)
	if err != nil {
		t.Fatalf("首次使用应成功，实际: %v", err)
	}
	if got != "device-xyz" {
		t.Fatalf("目标设备不匹配: %q", got)
	}

	if _, err := Resolve(st, l.Code); err == nil {
		t.Fatalf("连接码应一次性，第二次使用必须失败")
	}
}

func TestResolveExpired(t *testing.T) {
	st := newStore(t)
	l, err := Generate(st, "device-exp", -time.Second) // 已过期
	if err != nil {
		t.Fatalf("生成失败: %v", err)
	}
	if _, err := Resolve(st, l.Code); err == nil {
		t.Fatalf("过期连接码必须被拒绝")
	}
}

func TestResolveUnknown(t *testing.T) {
	st := newStore(t)
	if _, err := Resolve(st, "ZZZZZZZZ"); err == nil {
		t.Fatalf("不存在的连接码必须被拒绝")
	}
}