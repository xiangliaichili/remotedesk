// remotedesk 中转服务器：账号、信令、中继、一次性链接。
// 一键部署见 deploy/ 与 Dockerfile。
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"github.com/remotedesk/server/internal/api"
	"github.com/remotedesk/server/internal/config"
	"github.com/remotedesk/server/internal/relay"
	"github.com/remotedesk/server/internal/signaling"
	"github.com/remotedesk/server/internal/store"
)

// version 由构建时注入：
//
//	go build -ldflags "-X main.version=1.2.3"
var version = "dev"

func main() {
	cfg := config.Load()
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	log.Printf("[server] remotedesk %s (%s/%s, go %s)",
		version, runtime.GOOS, runtime.GOARCH, runtime.Version())

	// 确保数据目录存在。
	// 报错时把完整路径打出来：MkdirAll 会一路向上递归，路径写错（比如中文被读成乱码）
	// 时它会在盘符根目录下建目录，只说 "Access is denied" 根本看不出问题在哪。
	dataDir := dirOf(cfg.DBPath)
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		log.Fatalf("create data dir %q: %v（检查 RD_DB=%q 是否指向可写路径）", dataDir, err, cfg.DBPath)
	}

	st, err := store.Open(cfg.DBPath)
	if err != nil {
		log.Fatalf("open store: %v", err)
	}
	defer st.Close()

	// TURN 中继（可选：启动失败不阻断服务，仅退化为纯 P2P）
	var rl *relay.Server
	if cfg.TurnAddr != "" && cfg.TurnAddr != "off" {
		rl, err = relay.New("remotedesk", cfg.TurnAddr)
		if err != nil {
			log.Printf("[relay] TURN start failed (degrading to P2P-only): %v", err)
			rl = nil
		} else {
			defer rl.Close()
			log.Printf("[relay] TURN listening on %s", cfg.TurnAddr)
		}
	}

	hub := signaling.NewHub(st, cfg.JWTSecret)
	router := api.New(st, hub, rl, cfg).Router()

	// 顶层路由：/ws 交给信令，/version 返回版本，其余交给 REST。
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", hub.ServeHTTP)
	mux.HandleFunc("/version", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = w.Write([]byte(`{"version":"` + version + `"}`))
	})
	mux.Handle("/", router)

	srv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("[server] listening on %s (public %s)", cfg.ListenAddr, cfg.PublicAddr)
		var err error
		if cfg.EnableTLS {
			err = srv.ListenAndServeTLS(cfg.CertFile, cfg.KeyFile)
		} else {
			err = srv.ListenAndServe()
		}
		if err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %v", err)
		}
	}()

	// 优雅退出
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	log.Println("[server] shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}

// dirOf 返回文件路径的目录部分（空则返回 "."）。
func dirOf(path string) string {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' || path[i] == '\\' {
			return path[:i]
		}
	}
	return "."
}
