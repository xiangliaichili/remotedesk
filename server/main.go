// remotedesk 中转服务器：账号、信令、中继、一次性链接。
// 一键部署见 deploy/ 与 Dockerfile。
package main

import (
	"context"
	"html"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strings"
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
	started := time.Now()
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

	// 顶层路由：/ws 交给信令，/version 返回版本，/ 交给自检页，其余交给 REST。
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", hub.ServeHTTP)
	mux.HandleFunc("/version", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = w.Write([]byte(`{"version":"` + version + `"}`))
	})
	mux.Handle("/", rootOrREST(router, cfg, started))

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

// ---------- GET / 自检页 ----------

// rootOrREST 把 GET / 交给自检页，其余请求原样交给 REST 路由。
//
// 以前 / 直接落到 ServeMux 的默认 404（响应体为空）。用户按脚本提示用浏览器
// 打开 http://127.0.0.1:8443，看到的是一片空白，于是判断"服务器没起来"反复重启，
// 而实际上服务器一直是好的。这个页面把运行状态和下一步动作直接写出来。
func rootOrREST(rest http.Handler, cfg *config.Config, started time.Time) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			rest.ServeHTTP(w, r)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			rest.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = io.WriteString(w, renderRootPage(cfg, started))
	})
}

// renderRootPage 填充自检页模板。
//
// 用 strings.NewReplacer 而不是 fmt.Sprintf：页面里有 CSS（width:100% 之类），
// 当成格式串解析会被误认成动词，go vet 也会报错。
func renderRootPage(cfg *config.Config, started time.Time) string {
	// ListenAddr 可能是 ":8443" 或 "0.0.0.0:8443"，展示用地址只取端口段。
	port := cfg.ListenAddr
	if i := strings.LastIndex(port, ":"); i >= 0 {
		port = port[i:]
	}
	lan := cfg.PublicAddr
	if lan == "" {
		lan = "未探测到（用 ipconfig 查本机 IPv4）"
	}
	return strings.NewReplacer(
		"__VERSION__", html.EscapeString(version),
		"__PLATFORM__", html.EscapeString(runtime.GOOS+"/"+runtime.GOARCH+" · "+runtime.Version()),
		"__UPTIME__", html.EscapeString(time.Since(started).Round(time.Second).String()),
		"__LOOP__", html.EscapeString("http://127.0.0.1"+port),
		"__LAN__", html.EscapeString(lan),
		"__DATA__", html.EscapeString(cfg.DBPath),
	).Replace(rootTmpl)
}

// rootTmpl 是 / 的页面骨架。占位符写成 __XXX__，避免与 CSS 里的百分号冲突。
const rootTmpl = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>remotedesk · 服务器运行中</title>
<style>
  *{box-sizing:border-box}
  body{margin:0;padding:44px 20px 60px;background:#0f1115;color:#e6e8eb;
       font:15px/1.65 -apple-system,"Segoe UI","Microsoft YaHei","PingFang SC",sans-serif}
  .wrap{max-width:780px;margin:0 auto}
  .head{display:flex;align-items:center;gap:12px}
  .dot{width:10px;height:10px;border-radius:50%;background:#34d399;flex:none;
       box-shadow:0 0 0 4px rgba(52,211,153,.15)}
  h1{font-size:22px;margin:0;font-weight:600;letter-spacing:.2px}
  .sub{color:#8b93a1;font-size:13px;margin:8px 0 30px 22px}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:12px;margin-bottom:30px}
  .card{background:#171a21;border:1px solid #232833;border-radius:10px;padding:14px 16px}
  .k{font-size:12px;color:#8b93a1;margin-bottom:7px}
  .v{font-size:15px;font-weight:600;word-break:break-all;line-height:1.45}
  .v a{color:#60a5fa;text-decoration:none}
  .v a:hover{text-decoration:underline}
  h2{font-size:15px;margin:0 0 14px;color:#c9d1d9;font-weight:600}
  ol{margin:0;padding-left:22px}
  ol li{margin-bottom:11px;color:#b8c0cc}
  ol li b{color:#e6e8eb}
  .note{margin-top:28px;padding:15px 17px;border-radius:10px;font-size:13.5px;
        background:rgba(96,165,250,.08);border:1px solid rgba(96,165,250,.25);color:#b8c0cc}
  .note b{color:#60a5fa}
  .foot{margin-top:24px;color:#6b7280;font-size:12px;word-break:break-all}
  code{background:#232833;padding:1px 6px;border-radius:4px;font-size:12.5px;color:#e6e8eb}
</style>
</head>
<body>
<div class="wrap">
  <div class="head"><span class="dot"></span><h1>remotedesk 服务器运行中</h1></div>
  <p class="sub">版本 __VERSION__ · __PLATFORM__ · 已运行 __UPTIME__</p>

  <div class="grid">
    <div class="card">
      <div class="k">本机地址 · 这台电脑填这个</div>
      <div class="v"><a href="__LOOP__">__LOOP__</a></div>
    </div>
    <div class="card">
      <div class="k">局域网地址 · 手机 / 其他电脑填这个</div>
      <div class="v">__LAN__</div>
    </div>
    <div class="card">
      <div class="k">数据目录</div>
      <div class="v">__DATA__</div>
    </div>
  </div>

  <h2>接下来三步</h2>
  <ol>
    <li><b>打开客户端</b>：Windows 双击 remotedesk.exe；手机装 .apk。</li>
    <li><b>填服务器地址</b>：本机用「本机地址」，手机用「局域网地址」，然后保存。</li>
    <li><b>注册并登录同一个账号</b>：两台设备会互相可见，点「连接」开始远程控制。</li>
  </ol>

  <div class="note">
    <b>这个网页不是客户端。</b>它只用来确认服务器活着。
    远程控制界面在客户端程序里，网页上本来就不提供画面 —— 看到这一页说明服务一切正常。
  </div>

  <p class="foot">探针：<code>/healthz</code> · <code>/version</code> · <code>/ws</code></p>
</div>
</body>
</html>
`
