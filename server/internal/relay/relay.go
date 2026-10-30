// Package relay 提供 TURN 中继服务器：P2P 直连失败时兜底转发 WebRTC 流量。
// 使用临时凭证（每次会话生成），AuthHandler 动态校验，凭证 TTL 到期后自动失效。
package relay

import (
	"crypto/rand"
	"encoding/hex"
	"net"
	"sync"
	"time"

	"github.com/pion/logging"
	"github.com/pion/turn/v4"
)

// Credentials 为一次会话的临时 TURN 凭证。
type Credentials struct {
	Username string
	Password string
	Expires  time.Time
}

// Server 封装 TURN 服务器与凭证管理。
type Server struct {
	mu          sync.RWMutex
	creds       map[string]Credentials // key: username
	realm       string
	udpListener net.PacketConn
	turnServer  *turn.Server
}

// New 启动 TURN 服务器。
func New(realm, listenAddr string) (*Server, error) {
	udp, err := net.ListenPacket("udp4", listenAddr)
	if err != nil {
		return nil, err
	}
	s := &Server{
		creds:       make(map[string]Credentials),
		realm:       realm,
		udpListener: udp,
	}

	ts, err := turn.NewServer(turn.ServerConfig{
		Realm:       realm,
		LoggerFactory: logging.NewDefaultLoggerFactory(),
		AuthHandler: s.authHandler,
		PacketConnConfigs: []turn.PacketConnConfig{
			{
				PacketConn: udp,
				RelayAddressGenerator: &turn.RelayAddressGeneratorStatic{
					RelayAddress: net.ParseIP("0.0.0.0"), // 由宿主网卡出站
					Address:      "0.0.0.0",
				},
			},
		},
	})
	if err != nil {
		udp.Close()
		return nil, err
	}
	s.turnServer = ts

	// 后台清理过期凭证
	go s.cleanupLoop()
	return s, nil
}

func (s *Server) authHandler(username, realm string, srcAddr net.Addr) ([]byte, bool) {
	s.mu.RLock()
	c, ok := s.creds[username]
	s.mu.RUnlock()
	if !ok || time.Now().After(c.Expires) {
		return nil, false
	}
	return turn.GenerateAuthKey(username, s.realm, c.Password), true
}

// Issue 生成一组临时凭证并注册。
func (s *Server) Issue(ttl time.Duration) Credentials {
	c := Credentials{
		Username: randHex(8),
		Password: randHex(16),
		Expires:  time.Now().Add(ttl),
	}
	s.mu.Lock()
	s.creds[c.Username] = c
	s.mu.Unlock()
	return c
}

// Revoke 主动作废凭证（会话结束时调用）。
func (s *Server) Revoke(username string) {
	s.mu.Lock()
	delete(s.creds, username)
	s.mu.Unlock()
}

func (s *Server) cleanupLoop() {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for range t.C {
		now := time.Now()
		s.mu.Lock()
		for u, c := range s.creds {
			if now.After(c.Expires) {
				delete(s.creds, u)
			}
		}
		s.mu.Unlock()
	}
}

func (s *Server) Close() error {
	if s.turnServer != nil {
		_ = s.turnServer.Close()
	}
	if s.udpListener != nil {
		return s.udpListener.Close()
	}
	return nil
}

func randHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
