// Package link 提供“统一链接”一次性连接码的生成与校验。
package link

import (
	"context"
	"crypto/rand"
	"math/big"
	"time"

	"github.com/remotedesk/server/internal/store"
)

const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // 去除易混淆字符

// Generate 生成一次性连接码。
func Generate(st *store.Store, targetID string, ttl time.Duration) (*store.Link, error) {
	code, err := randCode(8)
	if err != nil {
		return nil, err
	}
	l := &store.Link{
		Code:      code,
		TargetID:  targetID,
		ExpiresAt: time.Now().Add(ttl),
	}
	if err := st.CreateLink(context.Background(), l); err != nil {
		return nil, err
	}
	return l, nil
}

// Resolve 校验并消费一次性链接，返回目标设备 ID。
func Resolve(st *store.Store, code string) (string, error) {
	l, err := st.GetLink(context.Background(), code)
	if err != nil {
		return "", err
	}
	if l.Used {
		return "", store.ErrNotFound // 已使用视为无效
	}
	if time.Now().After(l.ExpiresAt) {
		return "", store.ErrNotFound // 已过期视为无效
	}
	if err := st.MarkLinkUsed(context.Background(), code); err != nil {
		return "", err
	}
	return l.TargetID, nil
}

func randCode(n int) (string, error) {
	b := make([]byte, n)
	for i := range b {
		idx, err := rand.Int(rand.Reader, big.NewInt(int64(len(alphabet))))
		if err != nil {
			return "", err
		}
		b[i] = alphabet[idx.Int64()]
	}
	return string(b), nil
}
