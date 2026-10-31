package api

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"fmt"
	"math/big"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/remotedesk/server/internal/store"
	"github.com/remotedesk/server/internal/wechat"
)

// 短信 / 微信登录的参数（集中在这里，方便调）。
const (
	smsCodeTTL      = 5 * time.Minute
	smsResendAfter  = 60 * time.Second
	smsMaxAttempts  = 5
	authStateTTL    = 10 * time.Minute
	wechatScopeNote = "snsapi_login"
)

// 中国大陆手机号（11 位，1 开头，第二位 3-9）。海外号码不在本期范围。
var phoneRe = regexp.MustCompile(`^1[3-9]\d{9}$`)

// deviceReq 是所有登录接口共用的设备信息字段。
type deviceReq struct {
	DeviceName string `json:"device_name"`
	OS         string `json:"os"`
	DeviceID   string `json:"device_id"`
}

// ---------- 登录方式自述 ----------

// handleAuthMethods 让客户端知道服务端支持哪些登录方式，未配置的入口就不显示。
func (a *API) handleAuthMethods(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"password": true,
		"sms": map[string]interface{}{
			"enabled": a.cfg.SMSEnabled(),
			"dev":     a.sms != nil && a.sms.Dev(),
			"through": providerName(a),
		},
		"wechat": map[string]interface{}{
			"enabled": a.cfg.WechatEnabled(),
			"dev":     a.cfg.AuthDev,
		},
	})
}

func providerName(a *API) string {
	if a.sms == nil {
		return "off"
	}
	return a.sms.Name()
}

// ---------- 手机验证码 ----------

type smsSendReq struct {
	Phone string `json:"phone"`
}

func (a *API) handleSMSSend(w http.ResponseWriter, r *http.Request) {
	if !a.cfg.SMSEnabled() {
		writeErr(w, http.StatusServiceUnavailable, "短信登录未开启（服务端 RD_SMS_PROVIDER=off）")
		return
	}
	var req smsSendReq
	if !a.readJSON(w, r, &req) {
		return
	}
	phone := trim(req.Phone)
	if !phoneRe.MatchString(phone) {
		writeErr(w, http.StatusBadRequest, "手机号格式不正确")
		return
	}

	// 同一手机号 60 秒内只发一条，防止被当短信轰炸工具
	if rec, err := a.store.GetSMS(context.Background(), phone); err == nil {
		if wait := smsResendAfter - time.Since(rec.SentAt); wait > 0 {
			w.Header().Set("Retry-After", fmt.Sprintf("%d", int(wait.Seconds())+1))
			writeErr(w, http.StatusTooManyRequests,
				fmt.Sprintf("发送太频繁，请 %d 秒后再试", int(wait.Seconds())+1))
			return
		}
	}

	code, err := sixDigits()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "生成验证码失败")
		return
	}
	if err := a.store.SaveSMS(context.Background(), phone, code, smsCodeTTL); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := a.sms.Send(context.Background(), phone, code); err != nil {
		// 发不出去就把记录删掉，避免用户拿不到码却要等 60 秒
		_ = a.store.DeleteSMS(context.Background(), phone)
		writeErr(w, http.StatusBadGateway, "短信发送失败："+err.Error())
		return
	}

	resp := map[string]interface{}{
		"status":       "ok",
		"ttl":          int(smsCodeTTL.Seconds()),
		"resend_after": int(smsResendAfter.Seconds()),
	}
	if a.sms.Dev() {
		// 本地联调：直接把码回给客户端，省去翻日志
		resp["dev_code"] = code
	}
	writeJSON(w, http.StatusOK, resp)
}

type smsLoginReq struct {
	Phone string `json:"phone"`
	Code  string `json:"code"`
	deviceReq
}

func (a *API) handleSMSLogin(w http.ResponseWriter, r *http.Request) {
	if !a.cfg.SMSEnabled() {
		writeErr(w, http.StatusServiceUnavailable, "短信登录未开启")
		return
	}
	var req smsLoginReq
	if !a.readJSON(w, r, &req) {
		return
	}
	phone := trim(req.Phone)
	code := trim(req.Code)
	if !phoneRe.MatchString(phone) {
		writeErr(w, http.StatusBadRequest, "手机号格式不正确")
		return
	}
	if len(code) != 6 {
		writeErr(w, http.StatusBadRequest, "验证码为 6 位数字")
		return
	}

	ctx := context.Background()
	rec, err := a.store.GetSMS(ctx, phone)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "请先获取验证码")
		return
	}
	if time.Now().After(rec.ExpiresAt) {
		_ = a.store.DeleteSMS(ctx, phone)
		writeErr(w, http.StatusBadRequest, "验证码已过期，请重新获取")
		return
	}
	if rec.Attempts >= smsMaxAttempts {
		_ = a.store.DeleteSMS(ctx, phone)
		writeErr(w, http.StatusTooManyRequests, "尝试次数过多，请重新获取验证码")
		return
	}
	if subtle.ConstantTimeCompare([]byte(rec.Code), []byte(code)) != 1 {
		_ = a.store.IncSMSAttempt(ctx, phone)
		left := smsMaxAttempts - rec.Attempts - 1
		writeErr(w, http.StatusUnauthorized, fmt.Sprintf("验证码不正确，还可尝试 %d 次", maxInt(left, 0)))
		return
	}
	// 通过即作废，防重放
	_ = a.store.DeleteSMS(ctx, phone)

	user, err := a.store.GetUserByPhone(ctx, phone)
	if err == store.ErrNotFound {
		user, err = a.store.CreateUserWithPhone(ctx, phone)
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	a.finishLogin(w, user, req.DeviceID, req.DeviceName, req.OS)
}

// ---------- 微信扫码登录 ----------

type wechatURLReq struct {
	deviceReq
	// 可选：自定义回调基址（多域名部署时用），不填取服务端配置
	RedirectBase string `json:"redirect_base"`
}

func (a *API) handleWechatURL(w http.ResponseWriter, r *http.Request) {
	if !a.cfg.WechatEnabled() {
		writeErr(w, http.StatusServiceUnavailable,
			"微信登录未配置（需要 RD_WECHAT_APP_ID / RD_WECHAT_APP_SECRET）")
		return
	}
	var req wechatURLReq
	if !a.readJSON(w, r, &req) {
		return
	}
	base := strings.TrimRight(orDefault(strings.TrimSpace(req.RedirectBase), a.publicBase()), "/")
	if base == "" {
		writeErr(w, http.StatusInternalServerError, "服务端未配置 RD_PUBLIC / RD_WECHAT_REDIRECT，无法生成回调地址")
		return
	}
	state := uuid.NewString()
	st := &store.AuthState{
		State:      state,
		Status:     "pending",
		DeviceID:   req.DeviceID,
		DeviceName: req.DeviceName,
		OS:         req.OS,
	}
	if err := a.store.SaveAuthState(context.Background(), st, authStateTTL); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	redirect := base + "/api/auth/wechat/callback"
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"state":      state,
		"url":        wechat.AuthURL(a.cfg.WechatAppID, redirect, state),
		"expires_in": int(authStateTTL.Seconds()),
		"scope":      wechatScopeNote,
	})
}

// handleWechatCallback 是微信授权后浏览器跳回来的地址，返回一个给人看的 HTML 页。
func (a *API) handleWechatCallback(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	state := q.Get("state")
	code := q.Get("code")
	if state == "" || code == "" {
		writeCallbackPage(w, false, "授权参数缺失，请回到客户端重新发起登录")
		return
	}
	st, err := a.store.GetAuthState(context.Background(), state)
	if err != nil {
		writeCallbackPage(w, false, "登录会话已失效，请回到客户端重新发起")
		return
	}
	if time.Now().After(st.ExpiresAt) {
		_ = a.store.SetAuthStateResult(context.Background(), state, "error", 0, "登录会话已过期")
		writeCallbackPage(w, false, "登录会话已过期，请回到客户端重新发起")
		return
	}

	p, err := wechat.Exchange(r.Context(), a.cfg.WechatAppID, a.cfg.WechatSecret, code)
	if err != nil {
		_ = a.store.SetAuthStateResult(context.Background(), state, "error", 0, err.Error())
		writeCallbackPage(w, false, "微信授权失败："+err.Error())
		return
	}
	user, err := a.upsertWechatUser(r.Context(), p.OpenID, p.UnionID)
	if err != nil {
		_ = a.store.SetAuthStateResult(context.Background(), state, "error", 0, err.Error())
		writeCallbackPage(w, false, "创建账号失败："+err.Error())
		return
	}
	_ = a.store.SetAuthStateResult(context.Background(), state, "ok", user.ID, "")
	writeCallbackPage(w, true, "登录成功，请回到客户端")
}

type wechatPollReq struct {
	State string `json:"state"`
}

// handleWechatPoll 由客户端轮询：扫码完成后这里才会返回 token。
func (a *API) handleWechatPoll(w http.ResponseWriter, r *http.Request) {
	var req wechatPollReq
	if !a.readJSON(w, r, &req) {
		return
	}
	state := trim(req.State)
	if state == "" {
		writeErr(w, http.StatusBadRequest, "缺少 state")
		return
	}
	st, err := a.store.GetAuthState(context.Background(), state)
	if err != nil {
		writeErr(w, http.StatusNotFound, "登录会话不存在或已过期")
		return
	}
	if time.Now().After(st.ExpiresAt) {
		writeJSON(w, http.StatusOK, map[string]interface{}{"status": "expired"})
		return
	}
	switch st.Status {
	case "ok":
		user, err := a.store.GetUserByID(context.Background(), st.UserID)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "账号不存在")
			return
		}
		// 一次性：消费掉状态，避免同一 state 反复换 token
		_ = a.store.SetAuthStateResult(context.Background(), state, "consumed", 0, "")
		a.finishLogin(w, user, st.DeviceID, st.DeviceName, st.OS)
	case "error":
		writeJSON(w, http.StatusOK, map[string]interface{}{"status": "error", "message": st.Err})
	case "consumed":
		// 已经换过一次 token，不允许复用（防重放）
		writeJSON(w, http.StatusOK, map[string]interface{}{"status": "consumed"})
	default:
		writeJSON(w, http.StatusOK, map[string]interface{}{"status": "pending"})
	}
}

type wechatDevReq struct {
	State   string `json:"state"`
	OpenID  string `json:"openid"`
	UnionID string `json:"unionid"`
}

// handleWechatDev 只在 RD_AUTH_DEV=1 时可用：跳过微信，直接模拟"用户扫完码"。
func (a *API) handleWechatDev(w http.ResponseWriter, r *http.Request) {
	if !a.cfg.AuthDev {
		writeErr(w, http.StatusForbidden, "模拟登录未开启（需要 RD_AUTH_DEV=1）")
		return
	}
	var req wechatDevReq
	if !a.readJSON(w, r, &req) {
		return
	}
	if trim(req.State) == "" || trim(req.OpenID) == "" {
		writeErr(w, http.StatusBadRequest, "缺少 state 或 openid")
		return
	}
	if _, err := a.store.GetAuthState(context.Background(), trim(req.State)); err != nil {
		writeErr(w, http.StatusNotFound, "登录会话不存在")
		return
	}
	user, err := a.upsertWechatUser(r.Context(), trim(req.OpenID), trim(req.UnionID))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	_ = a.store.SetAuthStateResult(context.Background(), trim(req.State), "ok", user.ID, "")
	writeJSON(w, http.StatusOK, map[string]interface{}{"status": "ok", "user_id": user.ID})
}

// ---------- 公共收尾 ----------

// upsertWechatUser 按 openid/unionid 找账号，没有就建。
func (a *API) upsertWechatUser(ctx context.Context, openID, unionID string) (*store.User, error) {
	user, err := a.store.GetUserByWechat(ctx, openID, unionID)
	if err == store.ErrNotFound {
		return a.store.CreateUserWithWechat(ctx, openID, unionID)
	}
	return user, err
}

// finishLogin 是所有登录方式的统一出口：落设备 + 签 JWT + 返回 authResp。
func (a *API) finishLogin(w http.ResponseWriter, user *store.User, deviceID, deviceName, osName string) {
	if user == nil {
		writeErr(w, http.StatusInternalServerError, "账号不存在")
		return
	}
	if deviceID == "" {
		deviceID = uuid.NewString()
	}
	dev := &store.Device{
		ID:     deviceID,
		UserID: user.ID,
		Name:   orDefault(deviceName, "未命名设备"),
		OS:     orDefault(osName, "unknown"),
	}
	if err := a.store.UpsertDevice(context.Background(), dev); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	a.respondAuth(w, user, deviceID)
}

// publicBase 返回对外可访问的基址，用于拼微信回调地址。
func (a *API) publicBase() string {
	if a.cfg.WechatRedirect != "" {
		return a.cfg.WechatRedirect
	}
	return a.cfg.PublicAddr
}

// sixDigits 生成 6 位数字验证码（密码学随机，避免可预测）。
func sixDigits() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// writeCallbackPage 给微信内置浏览器看的极简页面（不引外部资源）。
func writeCallbackPage(w http.ResponseWriter, ok bool, msg string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	title := "授权失败"
	color := "#ef4444"
	if ok {
		title = "授权成功"
		color = "#22c55e"
	}
	fmt.Fprintf(w, `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>remotedesk · %s</title></head>
<body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
background:#0f1216;color:#e6edf3;font:16px/1.6 -apple-system,'HarmonyOS Sans','Microsoft YaHei',sans-serif">
<div style="text-align:center;padding:24px">
<div style="font-size:20px;font-weight:600;color:%s;margin-bottom:12px">%s</div>
<div style="color:#8b97a6;font-size:14px">%s</div>
<div style="color:#8b97a6;font-size:12px;margin-top:24px">可以关闭本页，回到 remotedesk 客户端</div>
</div></body></html>`, title, color, title, msg)
}
