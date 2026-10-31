package wechat

import (
	"net/url"
	"strings"
	"testing"
)

func TestAuthURL(t *testing.T) {
	u := AuthURL("wxappid", "https://rd.example.com/api/auth/wechat/callback", "state-1")
	if !strings.HasPrefix(u, authEndpoint+"?") {
		t.Fatalf("前缀不对：%s", u)
	}
	if !strings.HasSuffix(u, "#wechat_redirect") {
		t.Fatalf("缺少 #wechat_redirect：%s", u)
	}
	parsed, err := url.Parse(strings.SplitN(u, "#", 2)[0])
	if err != nil {
		t.Fatalf("URL 无法解析：%v", err)
	}
	q := parsed.Query()
	want := map[string]string{
		"appid":         "wxappid",
		"response_type": "code",
		"scope":         "snsapi_login",
		"state":         "state-1",
		"redirect_uri":  "https://rd.example.com/api/auth/wechat/callback",
	}
	for k, v := range want {
		if got := q.Get(k); got != v {
			t.Errorf("%s = %q, want %q", k, got, v)
		}
	}
}

func TestParseAccessToken(t *testing.T) {
	p, err := ParseAccessToken([]byte(`{"access_token":"t","openid":"o1","unionid":"u1"}`))
	if err != nil {
		t.Fatalf("正常响应不应报错：%v", err)
	}
	if p.OpenID != "o1" || p.UnionID != "u1" {
		t.Fatalf("解析结果不对：%+v", p)
	}

	// unionid 可能缺失（未绑定开放平台）
	p, err = ParseAccessToken([]byte(`{"access_token":"t","openid":"o2"}`))
	if err != nil || p.UnionID != "" {
		t.Fatalf("缺少 unionid 时应成功且为空，实际 %+v %v", p, err)
	}

	if _, err := ParseAccessToken([]byte(`{"errcode":40029,"errmsg":"invalid code"}`)); err == nil ||
		!strings.Contains(err.Error(), "40029") {
		t.Fatalf("应返回带错误码的错误，实际 %v", err)
	}

	if _, err := ParseAccessToken([]byte(`{"access_token":"t"}`)); err == nil {
		t.Fatal("缺少 openid 应报错")
	}

	if _, err := ParseAccessToken([]byte(`not json`)); err == nil {
		t.Fatal("非法 JSON 应报错")
	}
}
