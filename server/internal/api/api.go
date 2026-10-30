// Package api 提供 HTTP REST 接口与远程控制会话编排。
package api

import (
	"encoding/json"
	"log"
	"net"
	"net/http"
	"net/url"
	"strings"

	"github.com/remotedesk/server/internal/config"
	"github.com/remotedesk/server/internal/relay"
	"github.com/remotedesk/server/internal/signaling"
	"github.com/remotedesk/server/internal/store"
)

// API 聚合各依赖。
type API struct {
	store *store.Store
	hub   *signaling.Hub
	relay *relay.Server
	cfg   *config.Config
}

// New 构造 API 处理器。
func New(st *store.Store, hub *signaling.Hub, rl *relay.Server, cfg *config.Config) *API {
	return &API{store: st, hub: hub, relay: rl, cfg: cfg}
}

// Router 返回完整的 HTTP 路由。
func (a *API) Router() http.Handler {
	mux := http.NewServeMux()

	// 公开接口
	mux.HandleFunc("/api/register", a.handleRegister)
	mux.HandleFunc("/api/login", a.handleLogin)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	// 鉴权接口
	mux.HandleFunc("/api/devices", a.auth(a.handleListDevices))
	mux.HandleFunc("/api/session/lookup", a.auth(a.handleSessionLookup))
	mux.HandleFunc("/api/session/request", a.auth(a.handleSessionRequest))
	mux.HandleFunc("/api/session/accept", a.auth(a.handleSessionAccept))
	mux.HandleFunc("/api/session/cancel", a.auth(a.handleSessionCancel))
	mux.HandleFunc("/api/link/create", a.auth(a.handleLinkCreate))
	mux.HandleFunc("/api/settings", a.auth(a.handleSettings))

	return a.logging(mux)
}

// turnConfig 根据配置构造下发给客户端的 STUN/TURN 地址。
func (a *API) turnConfig(username, credential string) signaling.TurnConfig {
	host := a.cfg.TurnRelayIP
	if host == "" {
		host = hostFromURL(a.cfg.PublicAddr)
	}
	if host == "" {
		host = "127.0.0.1"
	}
	return signaling.TurnConfig{
		URLs: []string{
			"stun:" + net.JoinHostPort(host, "3478"),
			"turn:" + net.JoinHostPort(host, "3478") + "?transport=udp",
		},
		Username:   username,
		Credential: credential,
	}
}

func hostFromURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	h := u.Hostname()
	return h
}

func (a *API) logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("[api] %s %s", r.Method, r.URL.Path)
		next.ServeHTTP(w, r)
	})
}

// ---------- 响应工具 ----------

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

type errorResponse struct {
	Error string `json:"error"`
}

func (a *API) readJSON(w http.ResponseWriter, r *http.Request, dst interface{}) bool {
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body: "+err.Error())
		return false
	}
	return true
}

func trim(s string) string { return strings.TrimSpace(s) }
