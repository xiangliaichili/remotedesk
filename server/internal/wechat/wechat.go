// Package wechat 实现「微信开放平台 · 网站应用」扫码登录的 OAuth2 流程。
//
// 只用到三个接口：
//  1. 拼授权页 URL（客户端打开浏览器/内嵌二维码）
//  2. code 换 access_token + openid/unionid
//  3. 可选：拉昵称头像（失败不影响登录）
package wechat

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

const (
	authEndpoint  = "https://open.weixin.qq.com/connect/qrconnect"
	tokenEndpoint = "https://api.weixin.qq.com/sns/oauth2/access_token"
	userEndpoint  = "https://api.weixin.qq.com/sns/userinfo"
)

// Profile 是从微信拿到的身份信息。
type Profile struct {
	OpenID    string
	UnionID   string
	Nickname  string
	HeadImage string
}

// AuthURL 生成扫码授权页地址。state 用于防 CSRF 并关联本次登录请求。
func AuthURL(appID, redirectURI, state string) string {
	q := url.Values{}
	q.Set("appid", appID)
	q.Set("redirect_uri", redirectURI)
	q.Set("response_type", "code")
	q.Set("scope", "snsapi_login")
	q.Set("state", state)
	return authEndpoint + "?" + q.Encode() + "#wechat_redirect"
}

// Exchange 用 code 换身份。unionid 只有绑定了开放平台账号才返回，可能为空。
func Exchange(ctx context.Context, appID, secret, code string) (*Profile, error) {
	q := url.Values{}
	q.Set("appid", appID)
	q.Set("secret", secret)
	q.Set("code", code)
	q.Set("grant_type", "authorization_code")

	client := &http.Client{Timeout: 8 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, tokenEndpoint+"?"+q.Encode(), nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("请求微信失败：%w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if err != nil {
		return nil, err
	}

	p, err := ParseAccessToken(body)
	if err != nil {
		return nil, err
	}

	// 昵称头像拿不到不算失败：有些账号没有授权 userinfo 权限
	if token, ok := p.tokenFromBody(body); ok {
		if nick, avatar, err := fetchUserInfo(ctx, client, token, p.OpenID); err == nil {
			p.Nickname, p.HeadImage = nick, avatar
		}
	}
	return p, nil
}

// tokenFromBody 只是为了避免把 access_token 放进 Profile 暴露给调用方，
// 这里单独解析一次原始 body。
func (p *Profile) tokenFromBody(body []byte) (string, bool) {
	var raw struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(body, &raw); err != nil || raw.AccessToken == "" {
		return "", false
	}
	return raw.AccessToken, true
}

// ParseAccessToken 解析 code 换 token 的响应，errcode 非 0 视为失败。
// 抽成导出函数便于单测（微信真实接口不能在测试里调）。
func ParseAccessToken(body []byte) (*Profile, error) {
	var raw struct {
		AccessToken string `json:"access_token"`
		OpenID      string `json:"openid"`
		UnionID     string `json:"unionid"`
		ErrCode     int    `json:"errcode"`
		ErrMsg      string `json:"errmsg"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, fmt.Errorf("微信返回无法解析：%w", err)
	}
	if raw.ErrCode != 0 {
		return nil, fmt.Errorf("微信授权失败：%d %s", raw.ErrCode, raw.ErrMsg)
	}
	if raw.OpenID == "" {
		return nil, fmt.Errorf("微信未返回 openid")
	}
	return &Profile{OpenID: raw.OpenID, UnionID: raw.UnionID}, nil
}

func fetchUserInfo(ctx context.Context, client *http.Client, token, openID string) (string, string, error) {
	q := url.Values{}
	q.Set("access_token", token)
	q.Set("openid", openID)
	q.Set("lang", "zh_CN")
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, userEndpoint+"?"+q.Encode(), nil)
	if err != nil {
		return "", "", err
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if err != nil {
		return "", "", err
	}
	var raw struct {
		Nickname  string `json:"nickname"`
		HeadImage string `json:"headimgurl"`
		ErrCode   int    `json:"errcode"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return "", "", err
	}
	if raw.ErrCode != 0 {
		return "", "", fmt.Errorf("userinfo errcode %d", raw.ErrCode)
	}
	return raw.Nickname, raw.HeadImage, nil
}
