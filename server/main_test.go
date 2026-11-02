package main

import (
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/remotedesk/server/internal/config"
)

// 自检页是用户用浏览器打开 http://127.0.0.1:8443 第一眼看到的东西。
// 以前这个地址是空白 404，被误判成"服务器没起来"；现在改成页面后，
// 占位符漏替换、地址拼错、关键说明丢失都会直接暴露在用户眼前，所以钉住。
func TestRenderRootPage(t *testing.T) {
	h := renderRootPage(&config.Config{
		ListenAddr: ":8443",
		PublicAddr: "http://192.168.1.10:8443",
		DBPath:     "D:/data/remotedesk.db",
	}, time.Now())

	if m := regexp.MustCompile(`__[A-Z]+__`).FindString(h); m != "" {
		t.Fatalf("模板占位符没有被替换：%s", m)
	}
	for _, want := range []string{
		"http://127.0.0.1:8443",
		"http://192.168.1.10:8443",
		"D:/data/remotedesk.db",
		"服务器运行中",
		"这个网页不是客户端",
		version,
	} {
		if !strings.Contains(h, want) {
			t.Errorf("页面里缺少 %q", want)
		}
	}
}

// 监听地址写成 0.0.0.0:9443 时，展示用的本机地址只能取端口，
// 拼成 http://127.0.0.10.0.0:9443 这种明显错误必须挡住。
func TestRenderRootPageWildcardListen(t *testing.T) {
	h := renderRootPage(&config.Config{
		ListenAddr: "0.0.0.0:9443",
		PublicAddr: "",
	}, time.Now())

	if !strings.Contains(h, "http://127.0.0.1:9443") {
		t.Error("通配监听地址下没有拼出正确的本机地址")
	}
	if strings.Contains(h, "127.0.0.10.0.0") {
		t.Error("通配监听地址被当成主机名拼进了展示地址")
	}
	if !strings.Contains(h, "未探测到") {
		t.Error("缺少局域网地址时的提示文案没有了")
	}
}
