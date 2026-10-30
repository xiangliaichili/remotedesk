// Package store 提供 SQLite 持久化：账号、设备、会话、设置与一次性链接。
package store

import (
	"context"
	"database/sql"
	"errors"
	"time"

	_ "modernc.org/sqlite"
)

// 业务实体（与数据库表一一对应）。

type User struct {
	ID           int64     `json:"id"`
	Username     string    `json:"username"`
	PasswordHash string    `json:"-"`
	CreatedAt    time.Time `json:"created_at"`
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
		`CREATE INDEX IF NOT EXISTS idx_devices_user ON devices(user_id)`,
		`CREATE INDEX IF NOT EXISTS idx_sessions_target ON sessions(target_id, status)`,
		`CREATE INDEX IF NOT EXISTS idx_links_code ON links(code)`,
	}
	for _, q := range stmts {
		if _, err := s.db.Exec(q); err != nil {
			return err
		}
	}
	return nil
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

func (s *Store) GetUserByUsername(ctx context.Context, username string) (*User, error) {
	u := &User{}
	err := s.db.QueryRowContext(ctx,
		`SELECT id, username, password_hash, created_at FROM users WHERE username = ?`,
		username).Scan(&u.ID, &u.Username, &u.PasswordHash, &u.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return u, nil
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
