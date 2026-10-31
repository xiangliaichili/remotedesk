// Package store 提供 SQLite 持久化：账号、设备、会话、设置与一次性链接。
package store

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"strconv"
	"time"

	_ "modernc.org/sqlite"
)

// 业务实体（与数据库表一一对应）。

type User struct {
	ID           int64     `json:"id"`
	Username     string    `json:"username"`
	PasswordHash string    `json:"-"`
	// 手机号（短信验证码登录用），未绑定为 NULL
	Phone string `json:"phone,omitempty"`
	// 微信身份：openid 是单应用维度，unionid 是开放平台账号维度（多应用打通）
	WechatOpenID  string    `json:"-"`
	WechatUnionID string    `json:"-"`
	CreatedAt     time.Time `json:"created_at"`
}

// SMSRecord 是一条待校验的短信验证码。
type SMSRecord struct {
	Phone     string
	Code      string
	ExpiresAt time.Time
	Attempts  int
	SentAt    time.Time
}

// AuthState 是微信扫码登录的一次性状态（客户端轮询它拿结果）。
type AuthState struct {
	State      string
	Status     string // pending | ok | error
	UserID     int64
	DeviceID   string
	DeviceName string
	OS         string
	Err        string
	ExpiresAt  time.Time
}

type Device struct {
	ID          string    `json:"id"` // 全局唯一设备 ID
	UserID      int64     `json:"user_id"`
	Name        string    `json:"name"`
	OS          string    `json:"os"` // windows | android | harmonyos | linux | macos
	LastSeen    time.Time `json:"last_seen"`
	CreatedAt   time.Time `json:"created_at"`
	// 设备级设置（控制权限与提示行为）
	AutoAcceptSameAccount bool `json:"auto_accept_same_account"` // 同账号免同意登录开关
	MicEnabled            bool `json:"mic_enabled"`              // 语音权限（默认关闭）
	CameraEnabled         bool `json:"camera_enabled"`           // 摄像头权限（默认关闭）
}

// Session 表示一次远程控制会话。
type Session struct {
	ID            string    `json:"id"`
	ControllerID  string    `json:"controller_id"` // 控制端设备 ID
	TargetID      string    `json:"target_id"`     // 被控端设备 ID
	Status        string    `json:"status"`        // pending | active | ended
	AuthMode      string    `json:"auth_mode"`     // account | same_account | link
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// Link 表示一次性统一连接链接。
type Link struct {
	Code       string    `json:"code"`
	TargetID   string    `json:"target_id"`
	ExpiresAt  time.Time `json:"expires_at"`
	Used       bool      `json:"used"`
	CreatedAt  time.Time `json:"created_at"`
}

// Store 封装数据库访问。
type Store struct {
	db *sql.DB
}

// Open 打开（必要时创建）数据库并执行迁移。
func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	// SQLite 单写者场景下避免 busy 报错
	db.SetMaxOpenConns(1)
	if err := db.Ping(); err != nil {
		return nil, err
	}
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) migrate() error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS users (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			username TEXT UNIQUE NOT NULL,
			password_hash TEXT NOT NULL,
			created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
		)`,
		`CREATE TABLE IF NOT EXISTS devices (
			id TEXT PRIMARY KEY,
			user_id INTEGER NOT NULL,
			name TEXT NOT NULL,
			os TEXT NOT NULL,
			last_seen DATETIME,
			created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			auto_accept_same_account INTEGER NOT NULL DEFAULT 0,
			mic_enabled INTEGER NOT NULL DEFAULT 0,
			camera_enabled INTEGER NOT NULL DEFAULT 0
		)`,
		`CREATE TABLE IF NOT EXISTS sessions (
			id TEXT PRIMARY KEY,
			controller_id TEXT NOT NULL,
			target_id TEXT NOT NULL,
			status TEXT NOT NULL,
			auth_mode TEXT NOT NULL,
			created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
		)`,
		`CREATE TABLE IF NOT EXISTS links (
			code TEXT PRIMARY KEY,
			target_id TEXT NOT NULL,
			expires_at DATETIME NOT NULL,
			used INTEGER NOT NULL DEFAULT 0,
			created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
		)`,
		// 短信验证码：一个手机号同时只有一条有效记录，重发即覆盖
		`CREATE TABLE IF NOT EXISTS sms_codes (
			phone TEXT PRIMARY KEY,
			code TEXT NOT NULL,
			expires_at DATETIME NOT NULL,
			attempts INTEGER NOT NULL DEFAULT 0,
			sent_at DATETIME NOT NULL
		)`,
		// 微信扫码登录状态：客户端轮询 pending → ok/error
		`CREATE TABLE IF NOT EXISTS auth_states (
			state TEXT PRIMARY KEY,
			status TEXT NOT NULL,
			user_id INTEGER,
			device_id TEXT,
			device_name TEXT,
			os TEXT,
			err TEXT,
			expires_at DATETIME NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_devices_user ON devices(user_id)`,
		`CREATE INDEX IF NOT EXISTS idx_sessions_target ON sessions(target_id, status)`,
		`CREATE INDEX IF NOT EXISTS idx_links_code ON links(code)`,
	}
	for _, q := range stmts {
		if _, err := s.db.Exec(q); err != nil {
			return err
		}
	}

	// 老库补列：CREATE TABLE IF NOT EXISTS 不会修改已存在的表结构。
	// 新增列必须允许 NULL，否则老数据无法回填。
	columns := []struct{ name, decl string }{
		{"phone", "TEXT"},
		{"wechat_openid", "TEXT"},
		{"wechat_unionid", "TEXT"},
	}
	for _, c := range columns {
		if err := s.ensureColumn("users", c.name, c.decl); err != nil {
			return err
		}
	}
	// 唯一索引要在列补齐之后再建（NULL 不参与唯一性约束，未绑定的用户互不冲突）
	indexes := []string{
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_users_phone ON users(phone)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_users_wechat ON users(wechat_openid)`,
	}
	for _, q := range indexes {
		if _, err := s.db.Exec(q); err != nil {
			return err
		}
	}
	_ = s.CleanupExpired(context.Background())
	return nil
}

// ensureColumn 在列不存在时执行 ALTER TABLE ADD COLUMN（SQLite 的加列是轻量操作）。
func (s *Store) ensureColumn(table, column, decl string) error {
	rows, err := s.db.Query(`PRAGMA table_info(` + table + `)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			cid       int
			name      string
			ctype     string
			notNull   int
			dfltValue sql.NullString
			pk        int
		)
		if err := rows.Scan(&cid, &name, &ctype, &notNull, &dfltValue, &pk); err != nil {
			return err
		}
		if name == column {
			return nil
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	_, err = s.db.Exec(`ALTER TABLE ` + table + ` ADD COLUMN ` + column + ` ` + decl)
	return err
}

func (s *Store) Close() error { return s.db.Close() }

// ---------- 用户 ----------

var ErrUserExists = errors.New("username already exists")
var ErrNotFound = errors.New("not found")

func (s *Store) CreateUser(ctx context.Context, username, passwordHash string) (*User, error) {
	res, err := s.db.ExecContext(ctx,
		`INSERT INTO users (username, password_hash) VALUES (?, ?)`,
		username, passwordHash)
	if err != nil {
		if isUniqueViolation(err) {
			return nil, ErrUserExists
		}
		return nil, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	return &User{ID: id, Username: username, PasswordHash: passwordHash}, nil
}

// userColumns 统一查询列顺序，新增列时只改这里（scanUser 跟着改）。
const userColumns = `id, username, password_hash, COALESCE(phone,''), COALESCE(wechat_openid,''), COALESCE(wechat_unionid,''), created_at`

type rowScanner interface {
	Scan(dest ...interface{}) error
}

func scanUser(row rowScanner) (*User, error) {
	u := &User{}
	err := row.Scan(&u.ID, &u.Username, &u.PasswordHash, &u.Phone, &u.WechatOpenID, &u.WechatUnionID, &u.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return u, nil
}

func (s *Store) GetUserByUsername(ctx context.Context, username string) (*User, error) {
	return scanUser(s.db.QueryRowContext(ctx,
		`SELECT `+userColumns+` FROM users WHERE username = ?`, username))
}

// GetUserByPhone 手机号登录用。
func (s *Store) GetUserByPhone(ctx context.Context, phone string) (*User, error) {
	return scanUser(s.db.QueryRowContext(ctx,
		`SELECT `+userColumns+` FROM users WHERE phone = ?`, phone))
}

// GetUserByID 微信轮询、令牌刷新等场景按主键取用户。
func (s *Store) GetUserByID(ctx context.Context, id int64) (*User, error) {
	return scanUser(s.db.QueryRowContext(ctx,
		`SELECT `+userColumns+` FROM users WHERE id = ?`, id))
}

// GetUserByWechat 微信登录用：先按 openid 匹配，再按 unionid 兜底
// （同一开放平台账号下换了应用，openid 会变而 unionid 不变）。
func (s *Store) GetUserByWechat(ctx context.Context, openID, unionID string) (*User, error) {
	u, err := scanUser(s.db.QueryRowContext(ctx,
		`SELECT `+userColumns+` FROM users WHERE wechat_openid = ?`, openID))
	if err == nil || err != ErrNotFound {
		return u, err
	}
	if unionID == "" {
		return nil, ErrNotFound
	}
	return scanUser(s.db.QueryRowContext(ctx,
		`SELECT `+userColumns+` FROM users WHERE wechat_unionid = ?`, unionID))
}

// unusablePassword 给「没有密码的账号」占位：不是合法 bcrypt 串，
// bcrypt.CompareHashAndPassword 永远失败，因此这些账号无法用密码登录。
const unusablePassword = "!"

// CreateUserWithPhone 首次用手机号登录时自动建号，用户名即手机号。
func (s *Store) CreateUserWithPhone(ctx context.Context, phone string) (*User, error) {
	res, err := s.db.ExecContext(ctx,
		`INSERT INTO users (username, password_hash, phone) VALUES (?, ?, ?)`,
		phone, unusablePassword, phone)
	if err != nil {
		if isUniqueViolation(err) {
			return nil, ErrUserExists
		}
		return nil, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	return &User{ID: id, Username: phone, PasswordHash: unusablePassword, Phone: phone}, nil
}

// CreateUserWithWechat 首次微信登录时自动建号，用户名用 wx_ + 随机后缀。
func (s *Store) CreateUserWithWechat(ctx context.Context, openID, unionID string) (*User, error) {
	var lastErr error
	for i := 0; i < 3; i++ {
		username := "wx_" + randomHex(5)
		res, err := s.db.ExecContext(ctx,
			`INSERT INTO users (username, password_hash, wechat_openid, wechat_unionid) VALUES (?, ?, ?, ?)`,
			username, unusablePassword, openID, nullable(unionID))
		if err == nil {
			id, err := res.LastInsertId()
			if err != nil {
				return nil, err
			}
			return &User{
				ID:            id,
				Username:      username,
				PasswordHash:  unusablePassword,
				WechatOpenID:  openID,
				WechatUnionID: unionID,
			}, nil
		}
		lastErr = err
		if !isUniqueViolation(err) {
			return nil, err
		}
	}
	return nil, lastErr
}

var ErrPhoneTaken = errors.New("phone already bound to another account")
var ErrWechatTaken = errors.New("wechat already bound to another account")

// BindPhone 给已有账号补绑手机号（例如先用微信登录、之后想用短信登录同一账号）。
func (s *Store) BindPhone(ctx context.Context, userID int64, phone string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE users SET phone = ? WHERE id = ?`, phone, userID)
	if err != nil && isUniqueViolation(err) {
		return ErrPhoneTaken
	}
	return err
}

// BindWechat 给已有账号补绑微信。
func (s *Store) BindWechat(ctx context.Context, userID int64, openID, unionID string) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE users SET wechat_openid = ?, wechat_unionid = ? WHERE id = ?`,
		openID, nullable(unionID), userID)
	if err != nil && isUniqueViolation(err) {
		return ErrWechatTaken
	}
	return err
}

// ---------- 短信验证码 ----------

// SaveSMS 写入/覆盖某手机号的验证码，并把尝试次数清零。
func (s *Store) SaveSMS(ctx context.Context, phone, code string, ttl time.Duration) error {
	now := time.Now()
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO sms_codes (phone, code, expires_at, attempts, sent_at)
		VALUES (?, ?, ?, 0, ?)
		ON CONFLICT(phone) DO UPDATE SET
			code = excluded.code,
			expires_at = excluded.expires_at,
			attempts = 0,
			sent_at = excluded.sent_at`,
		phone, code, now.Add(ttl), now)
	return err
}

func (s *Store) GetSMS(ctx context.Context, phone string) (*SMSRecord, error) {
	r := &SMSRecord{}
	err := s.db.QueryRowContext(ctx,
		`SELECT phone, code, expires_at, attempts, sent_at FROM sms_codes WHERE phone = ?`, phone).
		Scan(&r.Phone, &r.Code, &r.ExpiresAt, &r.Attempts, &r.SentAt)
	if err == sql.ErrNoRows {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return r, nil
}

// IncSMSAttempt 校验失败时累加次数，超过阈值由调用方决定是否作废。
func (s *Store) IncSMSAttempt(ctx context.Context, phone string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE sms_codes SET attempts = attempts + 1 WHERE phone = ?`, phone)
	return err
}

func (s *Store) DeleteSMS(ctx context.Context, phone string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM sms_codes WHERE phone = ?`, phone)
	return err
}

// ---------- 微信登录状态 ----------

func (s *Store) SaveAuthState(ctx context.Context, st *AuthState, ttl time.Duration) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO auth_states (state, status, user_id, device_id, device_name, os, err, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(state) DO UPDATE SET
			status = excluded.status,
			expires_at = excluded.expires_at`,
		st.State, orPending(st.Status), nullableInt(st.UserID), st.DeviceID, st.DeviceName, st.OS, st.Err,
		time.Now().Add(ttl))
	return err
}

func (s *Store) SetAuthStateResult(ctx context.Context, state, status string, userID int64, errMsg string) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE auth_states SET status = ?, user_id = ?, err = ? WHERE state = ?`,
		status, nullableInt(userID), errMsg, state)
	return err
}

func (s *Store) GetAuthState(ctx context.Context, state string) (*AuthState, error) {
	st := &AuthState{}
	var userID sql.NullInt64
	err := s.db.QueryRowContext(ctx, `
		SELECT state, status, user_id, COALESCE(device_id,''), COALESCE(device_name,''), COALESCE(os,''),
		       COALESCE(err,''), expires_at
		FROM auth_states WHERE state = ?`, state).
		Scan(&st.State, &st.Status, &userID, &st.DeviceID, &st.DeviceName, &st.OS, &st.Err, &st.ExpiresAt)
	if err == sql.ErrNoRows {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if userID.Valid {
		st.UserID = userID.Int64
	}
	return st, nil
}

// CleanupExpired 清理过期验证码与登录状态（启动时与后台各跑一次）。
func (s *Store) CleanupExpired(ctx context.Context) error {
	now := time.Now()
	if _, err := s.db.ExecContext(ctx, `DELETE FROM sms_codes WHERE expires_at < ?`, now); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM auth_states WHERE expires_at < ?`, now)
	return err
}

// ---------- 设备 ----------

func (s *Store) UpsertDevice(ctx context.Context, d *Device) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO devices (id, user_id, name, os, last_seen, created_at, auto_accept_same_account, mic_enabled, camera_enabled)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			user_id = excluded.user_id,
			name = excluded.name,
			os = excluded.os,
			last_seen = excluded.last_seen`,
		d.ID, d.UserID, d.Name, d.OS, time.Now(), time.Now(),
		boolToInt(d.AutoAcceptSameAccount), boolToInt(d.MicEnabled), boolToInt(d.CameraEnabled))
	return err
}

func (s *Store) GetDevice(ctx context.Context, id string) (*Device, error) {
	d := &Device{}
	var auto, mic, cam int
	err := s.db.QueryRowContext(ctx, `
		SELECT id, user_id, name, os, last_seen, created_at, auto_accept_same_account, mic_enabled, camera_enabled
		FROM devices WHERE id = ?`, id).
		Scan(&d.ID, &d.UserID, &d.Name, &d.OS, &d.LastSeen, &d.CreatedAt, &auto, &mic, &cam)
	if err == sql.ErrNoRows {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	d.AutoAcceptSameAccount = intToBool(auto)
	d.MicEnabled = intToBool(mic)
	d.CameraEnabled = intToBool(cam)
	return d, nil
}

func (s *Store) ListDevicesByUser(ctx context.Context, userID int64) ([]*Device, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, user_id, name, os, last_seen, created_at, auto_accept_same_account, mic_enabled, camera_enabled
		FROM devices WHERE user_id = ? ORDER BY last_seen DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Device
	for rows.Next() {
		d := &Device{}
		var auto, mic, cam int
		if err := rows.Scan(&d.ID, &d.UserID, &d.Name, &d.OS, &d.LastSeen, &d.CreatedAt, &auto, &mic, &cam); err != nil {
			return nil, err
		}
		d.AutoAcceptSameAccount = intToBool(auto)
		d.MicEnabled = intToBool(mic)
		d.CameraEnabled = intToBool(cam)
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *Store) TouchDevice(ctx context.Context, id string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE devices SET last_seen = ? WHERE id = ?`, time.Now(), id)
	return err
}

// UpdateDeviceSettings 更新设备级权限设置（免同意、语音、摄像头）。
func (s *Store) UpdateDeviceSettings(ctx context.Context, id string, autoAccept, mic, camera *bool) error {
	_, err := s.db.ExecContext(ctx, `
		UPDATE devices SET
			auto_accept_same_account = COALESCE(?, auto_accept_same_account),
			mic_enabled = COALESCE(?, mic_enabled),
			camera_enabled = COALESCE(?, camera_enabled)
		WHERE id = ?`,
		boolPtrToInt(autoAccept), boolPtrToInt(mic), boolPtrToInt(camera), id)
	return err
}

// ---------- 会话 ----------

func (s *Store) CreateSession(ctx context.Context, sess *Session) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO sessions (id, controller_id, target_id, status, auth_mode, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		sess.ID, sess.ControllerID, sess.TargetID, sess.Status, sess.AuthMode, time.Now(), time.Now())
	return err
}

func (s *Store) GetSession(ctx context.Context, id string) (*Session, error) {
	sess := &Session{}
	err := s.db.QueryRowContext(ctx, `
		SELECT id, controller_id, target_id, status, auth_mode, created_at, updated_at
		FROM sessions WHERE id = ?`, id).
		Scan(&sess.ID, &sess.ControllerID, &sess.TargetID, &sess.Status, &sess.AuthMode, &sess.CreatedAt, &sess.UpdatedAt)
	if err == sql.ErrNoRows {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return sess, nil
}

func (s *Store) UpdateSessionStatus(ctx context.Context, id, status string) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE sessions SET status = ?, updated_at = ? WHERE id = ?`, status, time.Now(), id)
	return err
}

// ---------- 一次性链接 ----------

func (s *Store) CreateLink(ctx context.Context, l *Link) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO links (code, target_id, expires_at, used, created_at)
		VALUES (?, ?, ?, ?, ?)`,
		l.Code, l.TargetID, l.ExpiresAt, boolToInt(l.Used), time.Now())
	return err
}

func (s *Store) GetLink(ctx context.Context, code string) (*Link, error) {
	l := &Link{}
	var used int
	err := s.db.QueryRowContext(ctx, `
		SELECT code, target_id, expires_at, used, created_at FROM links WHERE code = ?`, code).
		Scan(&l.Code, &l.TargetID, &l.ExpiresAt, &used, &l.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	l.Used = intToBool(used)
	return l, nil
}

func (s *Store) MarkLinkUsed(ctx context.Context, code string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE links SET used = 1 WHERE code = ?`, code)
	return err
}

// ---------- 工具 ----------

func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	// modernc.org/sqlite 的唯一约束错误文本
	msg := err.Error()
	return contains(msg, "UNIQUE constraint failed") || contains(msg, "constraint failed")
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || len(sub) == 0 || indexOf(s, sub) >= 0)
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func intToBool(i int) bool { return i != 0 }

// boolPtrToInt 将 *bool 转为可空 int，用于 COALESCE 更新。
func boolPtrToInt(b *bool) *int {
	if b == nil {
		return nil
	}
	v := boolToInt(*b)
	return &v
}

// nullable 空串存 NULL：唯一索引对 NULL 不生效，未绑定的用户才不会互相冲突。
func nullable(s string) interface{} {
	if s == "" {
		return nil
	}
	return s
}

func nullableInt(n int64) interface{} {
	if n == 0 {
		return nil
	}
	return n
}

func orPending(s string) string {
	if s == "" {
		return "pending"
	}
	return s
}

// randomHex 生成 n 字节随机数的十六进制串（用户名后缀、验证码盐等用途）。
func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		// 熵源不可用时退化为时间戳，宁可弱一点也不阻塞登录
		return strconv.FormatInt(time.Now().UnixNano(), 16)[:n*2]
	}
	return hex.EncodeToString(b)
}
