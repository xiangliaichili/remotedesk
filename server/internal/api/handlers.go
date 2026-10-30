package api

import (
	"context"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/remotedesk/server/internal/auth"
	"github.com/remotedesk/server/internal/link"
	"github.com/remotedesk/server/internal/signaling"
	"github.com/remotedesk/server/internal/store"
)

// ---------- 注册 / 登录 ----------

type registerReq struct {
	Username   string `json:"username"`
	Password   string `json:"password"`
	DeviceName string `json:"device_name"`
	OS         string `json:"os"`
	DeviceID   string `json:"device_id"` // 客户端本地持久化的稳定设备 ID，可空则服务端生成
}

type authResp struct {
	Token    string `json:"token"`
	UserID   int64  `json:"user_id"`
	DeviceID string `json:"device_id"`
	Username string `json:"username"`
}

func (a *API) handleRegister(w http.ResponseWriter, r *http.Request) {
	var req registerReq
	if !a.readJSON(w, r, &req) {
		return
	}
	req.Username = trim(req.Username)
	if len(req.Username) < 3 || len(req.Password) < 6 {
		writeErr(w, http.StatusBadRequest, "username>=3 chars, password>=6 chars required")
		return
	}
	hash, err := auth.HashPassword(req.Password)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "hash failed")
		return
	}
	user, err := a.store.CreateUser(context.Background(), req.Username, hash)
	if err != nil {
		if err == store.ErrUserExists {
			writeErr(w, http.StatusConflict, "username already exists")
			return
		}
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	deviceID := req.DeviceID
	if deviceID == "" {
		deviceID = uuid.NewString()
	}
	dev := &store.Device{ID: deviceID, UserID: user.ID, Name: orDefault(req.DeviceName, "未命名设备"), OS: orDefault(req.OS, "unknown")}
	if err := a.store.UpsertDevice(context.Background(), dev); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	a.respondAuth(w, user, deviceID)
}

func (a *API) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req registerReq
	if !a.readJSON(w, r, &req) {
		return
	}
	req.Username = trim(req.Username)
	user, err := a.store.GetUserByUsername(context.Background(), req.Username)
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "invalid username or password")
		return
	}
	if !auth.CheckPassword(user.PasswordHash, req.Password) {
		writeErr(w, http.StatusUnauthorized, "invalid username or password")
		return
	}
	deviceID := req.DeviceID
	if deviceID == "" {
		deviceID = uuid.NewString()
	}
	dev := &store.Device{ID: deviceID, UserID: user.ID, Name: orDefault(req.DeviceName, "未命名设备"), OS: orDefault(req.OS, "unknown")}
	if err := a.store.UpsertDevice(context.Background(), dev); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	a.respondAuth(w, user, deviceID)
}

func (a *API) respondAuth(w http.ResponseWriter, user *store.User, deviceID string) {
	token, err := auth.SignToken(a.cfg.JWTSecret, user.ID, user.Username, deviceID, 30*24*time.Hour)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "token signing failed")
		return
	}
	writeJSON(w, http.StatusOK, authResp{Token: token, UserID: user.ID, DeviceID: deviceID, Username: user.Username})
}

// ---------- 设备列表 ----------

func (a *API) handleListDevices(w http.ResponseWriter, r *http.Request) {
	claims := getClaims(r)
	devices, err := a.store.ListDevicesByUser(context.Background(), claims.UserID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := make([]signaling.DeviceInfo, 0, len(devices))
	for _, d := range devices {
		out = append(out, signaling.DeviceInfo{ID: d.ID, Name: d.Name, OS: d.OS, Online: a.hub.IsOnline(d.ID)})
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"devices": out})
}

// ---------- 会话 ----------

// lookupReq 用于“账号密码连接”时，先查出目标账号下有哪些设备供选择。
type lookupReq struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

func (a *API) handleSessionLookup(w http.ResponseWriter, r *http.Request) {
	var req lookupReq
	if !a.readJSON(w, r, &req) {
		return
	}
	user, err := a.store.GetUserByUsername(context.Background(), trim(req.Username))
	if err != nil || !auth.CheckPassword(user.PasswordHash, req.Password) {
		writeErr(w, http.StatusUnauthorized, "invalid username or password")
		return
	}
	devices, err := a.store.ListDevicesByUser(context.Background(), user.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := make([]signaling.DeviceInfo, 0, len(devices))
	for _, d := range devices {
		out = append(out, signaling.DeviceInfo{ID: d.ID, Name: d.Name, OS: d.OS, Online: a.hub.IsOnline(d.ID)})
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"devices": out})
}

// sessionReq 定义建立控制会话的请求。
type sessionReq struct {
	TargetDeviceID string `json:"target_device_id"`
	Auth           struct {
		Mode     string `json:"mode"` // same_account | account | link
		Username string `json:"username"`
		Password string `json:"password"`
		LinkCode string `json:"link_code"`
	} `json:"auth"`
}

func (a *API) handleSessionRequest(w http.ResponseWriter, r *http.Request) {
	claims := getClaims(r)
	var req sessionReq
	if !a.readJSON(w, r, &req) {
		return
	}

	var targetID string
	var targetUserID int64
	autoAccept := false

	switch req.Auth.Mode {
	case "link":
		if req.Auth.LinkCode == "" {
			writeErr(w, http.StatusBadRequest, "missing link_code")
			return
		}
		id, err := link.Resolve(a.store, req.Auth.LinkCode)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "invalid or expired link")
			return
		}
		target, err := a.store.GetDevice(context.Background(), id)
		if err != nil {
			writeErr(w, http.StatusNotFound, "target device not found")
			return
		}
		targetID, targetUserID, autoAccept = target.ID, target.UserID, true
	case "account":
		if req.TargetDeviceID == "" {
			writeErr(w, http.StatusBadRequest, "missing target_device_id")
			return
		}
		user, err := a.store.GetUserByUsername(context.Background(), trim(req.Auth.Username))
		if err != nil || !auth.CheckPassword(user.PasswordHash, req.Auth.Password) {
			writeErr(w, http.StatusUnauthorized, "invalid username or password")
			return
		}
		target, err := a.store.GetDevice(context.Background(), req.TargetDeviceID)
		if err != nil || target.UserID != user.ID {
			writeErr(w, http.StatusNotFound, "target device not found")
			return
		}
		targetID, targetUserID, autoAccept = target.ID, target.UserID, false
	case "same_account":
		if req.TargetDeviceID == "" {
			writeErr(w, http.StatusBadRequest, "missing target_device_id")
			return
		}
		target, err := a.store.GetDevice(context.Background(), req.TargetDeviceID)
		if err != nil || target.UserID != claims.UserID {
			writeErr(w, http.StatusNotFound, "target device not found under your account")
			return
		}
		targetID, targetUserID = target.ID, target.UserID
		autoAccept = target.AutoAcceptSameAccount
	default:
		writeErr(w, http.StatusBadRequest, "invalid auth mode")
		return
	}

	if !a.hub.IsOnline(targetID) {
		writeErr(w, http.StatusConflict, "target device offline")
		return
	}

	sess := &store.Session{
		ID:           uuid.NewString(),
		ControllerID: claims.DeviceID,
		TargetID:     targetID,
		Status:       "pending",
		AuthMode:     req.Auth.Mode,
	}
	if autoAccept {
		sess.Status = "active"
	}
	if err := a.store.CreateSession(context.Background(), sess); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	_ = targetUserID // 保留：可扩展为目标账号维度统计

	if autoAccept {
		// 免同意：直接激活，但被控端仍弹出“正在被控制”提示（可随时取消）
		turn := a.activateSession(sess)
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"session_id": sess.ID,
			"status":     "active",
			"turn":       turn,
		})
		return
	}

	// 需被控端同意：弹窗请求
	a.hub.Send(targetID, signaling.Message{
		Type:      signaling.MsgSessionReq,
		From:      claims.DeviceID,
		SessionID: sess.ID,
		Data: map[string]interface{}{
			"controller_name": a.deviceName(claims.DeviceID),
			"auth_mode":       req.Auth.Mode,
		},
	})
	writeJSON(w, http.StatusOK, map[string]interface{}{"session_id": sess.ID, "status": "pending"})
}

// activateSession 将会话置为 active，并向被控端下发“控制开始”提示与 TURN 凭证。
// 返回本次会话使用的 TURN 配置，调用方据此回复控制端，保证两端拿到同一份临时凭证。
func (a *API) activateSession(sess *store.Session) signaling.TurnConfig {
	_ = a.store.UpdateSessionStatus(context.Background(), sess.ID, "active")
	turn := a.turnConfigForSession(sess.ID)
	a.hub.Send(sess.TargetID, signaling.Message{
		Type:      signaling.MsgControlStart,
		From:      sess.ControllerID,
		SessionID: sess.ID,
		Data: map[string]interface{}{
			"controller_name": a.deviceName(sess.ControllerID),
			"turn":            turn,
		},
	})
	return turn
}

// turnConfigForSession 为会话签发临时 TURN 凭证。
func (a *API) turnConfigForSession(sessionID string) signaling.TurnConfig {
	if a.relay == nil {
		return signaling.TurnConfig{}
	}
	cred := a.relay.Issue(30 * time.Minute)
	return a.turnConfig(cred.Username, cred.Password)
}

type acceptReq struct {
	SessionID string `json:"session_id"`
	Accept    bool   `json:"accept"`
}

func (a *API) handleSessionAccept(w http.ResponseWriter, r *http.Request) {
	claims := getClaims(r)
	var req acceptReq
	if !a.readJSON(w, r, &req) {
		return
	}
	sess, err := a.store.GetSession(context.Background(), req.SessionID)
	if err != nil {
		writeErr(w, http.StatusNotFound, "session not found")
		return
	}
	if sess.TargetID != claims.DeviceID {
		writeErr(w, http.StatusForbidden, "only the target can accept")
		return
	}
	if sess.Status != "pending" {
		writeErr(w, http.StatusConflict, "session already resolved")
		return
	}
	if !req.Accept {
		_ = a.store.UpdateSessionStatus(context.Background(), sess.ID, "ended")
		a.hub.Send(sess.ControllerID, signaling.Message{Type: signaling.MsgSessionDeny, From: sess.TargetID, SessionID: sess.ID})
		writeJSON(w, http.StatusOK, map[string]string{"status": "denied"})
		return
	}
	turn := a.activateSession(sess)
	a.hub.Send(sess.ControllerID, signaling.Message{
		Type:      signaling.MsgSessionOk,
		From:      sess.TargetID,
		SessionID: sess.ID,
		Data:      map[string]interface{}{"turn": turn},
	})
	writeJSON(w, http.StatusOK, map[string]interface{}{"status": "active", "turn": turn})
}

func (a *API) handleSessionCancel(w http.ResponseWriter, r *http.Request) {
	claims := getClaims(r)
	var req acceptReq
	if !a.readJSON(w, r, &req) {
		return
	}
	sess, err := a.store.GetSession(context.Background(), req.SessionID)
	if err != nil {
		writeErr(w, http.StatusNotFound, "session not found")
		return
	}
	if sess.ControllerID != claims.DeviceID && sess.TargetID != claims.DeviceID {
		writeErr(w, http.StatusForbidden, "not a participant")
		return
	}
	_ = a.store.UpdateSessionStatus(context.Background(), sess.ID, "ended")

	// 通知另一端“控制已结束”
	other := sess.TargetID
	if claims.DeviceID == sess.TargetID {
		other = sess.ControllerID
	}
	a.hub.Send(other, signaling.Message{Type: signaling.MsgControlEnd, From: claims.DeviceID, SessionID: sess.ID})
	writeJSON(w, http.StatusOK, map[string]string{"status": "ended"})
}

// ---------- 一次性链接 ----------

func (a *API) handleLinkCreate(w http.ResponseWriter, r *http.Request) {
	claims := getClaims(r)
	l, err := link.Generate(a.store, claims.DeviceID, time.Duration(a.cfg.LinkTTLMinutes)*time.Minute)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"code":        l.Code,
		"expires_at":  l.ExpiresAt,
		"ttl_minutes": a.cfg.LinkTTLMinutes,
	})
}

// ---------- 设置 ----------

type settingsReq struct {
	AutoAcceptSameAccount *bool `json:"auto_accept_same_account"`
	MicEnabled            *bool `json:"mic_enabled"`
	CameraEnabled         *bool `json:"camera_enabled"`
}

func (a *API) handleSettings(w http.ResponseWriter, r *http.Request) {
	claims := getClaims(r)
	if r.Method == http.MethodGet {
		dev, err := a.store.GetDevice(context.Background(), claims.DeviceID)
		if err != nil {
			writeErr(w, http.StatusNotFound, "device not found")
			return
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"auto_accept_same_account": dev.AutoAcceptSameAccount,
			"mic_enabled":              dev.MicEnabled,
			"camera_enabled":           dev.CameraEnabled,
		})
		return
	}
	if r.Method == http.MethodPut {
		var req settingsReq
		if !a.readJSON(w, r, &req) {
			return
		}
		if err := a.store.UpdateDeviceSettings(context.Background(), claims.DeviceID,
			req.AutoAcceptSameAccount, req.MicEnabled, req.CameraEnabled); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
		return
	}
	writeErr(w, http.StatusMethodNotAllowed, "method not allowed")
}

// ---------- 工具 ----------

func (a *API) deviceName(id string) string {
	if d, err := a.store.GetDevice(context.Background(), id); err == nil {
		return d.Name
	}
	return id
}

func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}
