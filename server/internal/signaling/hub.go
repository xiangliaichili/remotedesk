package signaling

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/remotedesk/server/internal/auth"
	"github.com/remotedesk/server/internal/store"
)

// Hub 管理所有在线设备的信令连接，负责消息路由。
type Hub struct {
	mu      sync.RWMutex
	clients map[string]*Client // key: deviceID

	store  *store.Store
	secret string // JWT 密钥，用于鉴权
}

// NewHub 创建信令中心。
func NewHub(st *store.Store, jwtSecret string) *Hub {
	return &Hub{
		clients: make(map[string]*Client),
		store:   st,
		secret:  jwtSecret,
	}
}

// IsOnline 判断设备是否在线。
func (h *Hub) IsOnline(deviceID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	_, ok := h.clients[deviceID]
	return ok
}

// Send 向指定设备投递一条消息。返回是否投递成功。
func (h *Hub) Send(deviceID string, msg Message) bool {
	h.mu.RLock()
	c, ok := h.clients[deviceID]
	h.mu.RUnlock()
	if !ok {
		return false
	}
	return c.send(msg)
}

// register 在鉴权通过后登记设备连接。
func (h *Hub) register(c *Client) {
	h.mu.Lock()
	if old, ok := h.clients[c.deviceID]; ok {
		// 同设备重复连接：关闭旧连接
		old.close()
	}
	h.clients[c.deviceID] = c
	h.mu.Unlock()
	_ = h.store.TouchDevice(context.Background(), c.deviceID)
}

func (h *Hub) unregister(deviceID string) {
	h.mu.Lock()
	delete(h.clients, deviceID)
	h.mu.Unlock()
}

// route 处理来自某设备的业务消息（offer/answer/ice/cancel/list_devices）。
func (h *Hub) route(from *Client, msg Message) {
	msg.From = from.deviceID

	switch msg.Type {
	case MsgOffer, MsgAnswer, MsgICE, MsgCancel:
		if msg.To == "" {
			from.sendErr("missing target 'to'")
			return
		}
		if !h.Send(msg.To, msg) {
			from.sendErr("target device offline")
		}
	case MsgListDevices:
		devices, err := h.store.ListDevicesByUser(context.Background(), from.userID)
		if err != nil {
			from.sendErr("failed to list devices")
			return
		}
		list := make([]DeviceInfo, 0, len(devices))
		for _, d := range devices {
			list = append(list, DeviceInfo{
				ID:     d.ID,
				Name:   d.Name,
				OS:     d.OS,
				Online: h.IsOnline(d.ID),
			})
		}
		from.send(Message{Type: MsgDevices, Data: list})
	case MsgHeartbeat:
		_ = h.store.TouchDevice(context.Background(), from.deviceID)
	default:
		from.sendErr("unknown message type: " + msg.Type)
	}
}

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	CheckOrigin:     func(r *http.Request) bool { return true }, // 客户端为原生应用，不依赖浏览器同源
}

// ServeHTTP 处理 WebSocket 升级与鉴权。
func (h *Hub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	c := &Client{conn: conn, hub: h, sendCh: make(chan Message, 64)}
	go c.writePump()
	c.readPump()
}

// Client 表示一条已鉴权的信令连接。
type Client struct {
	conn     *websocket.Conn
	hub      *Hub
	sendCh   chan Message
	deviceID string
	userID   int64
	once     sync.Once
}

// readPump 持续读取并分发消息。
func (c *Client) readPump() {
	defer func() {
		if c.deviceID != "" {
			c.hub.unregister(c.deviceID)
		}
		c.close()
	}()

	c.conn.SetReadDeadline(time.Now().Add(120 * time.Second))
	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(120 * time.Second))
		return nil
	})

	for {
		var msg Message
		if err := c.conn.ReadJSON(&msg); err != nil {
			return
		}
		if msg.Type == MsgAuth {
			if !c.authenticate(msg) {
				return
			}
			continue
		}
		if c.deviceID == "" {
			c.sendErr("not authenticated")
			return
		}
		c.hub.route(c, msg)
	}
}

func (c *Client) authenticate(msg Message) bool {
	tokenStr, _ := msg.Data.(string)
	// Data 可能是 string；前端也可能用 {token:...}，这里兼容两种
	if m, ok := msg.Data.(map[string]interface{}); ok {
		if t, ok := m["token"].(string); ok {
			tokenStr = t
		}
	}
	if tokenStr == "" {
		c.sendErr("missing token")
		return false
	}
	claims, err := auth.ParseToken(c.hub.secret, tokenStr)
	if err != nil {
		c.sendErr("invalid token")
		return false
	}
	c.deviceID = claims.DeviceID
	c.userID = claims.UserID
	c.hub.register(c)
	c.send(Message{Type: MsgAuthOK, Data: map[string]string{"device_id": c.deviceID}})
	log.Printf("[signaling] device %s online (user %d)", c.deviceID, c.userID)
	return true
}

func (c *Client) writePump() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case msg, ok := <-c.sendCh:
			c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if !ok {
				c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			if err := c.conn.WriteJSON(msg); err != nil {
				return
			}
		case <-ticker.C:
			c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

func (c *Client) send(msg Message) bool {
	select {
	case c.sendCh <- msg:
		return true
	default:
		return false
	}
}

func (c *Client) sendErr(text string) {
	_ = c.send(Message{Type: MsgError, Data: map[string]string{"message": text}})
}

func (c *Client) close() {
	c.once.Do(func() {
		_ = c.conn.Close()
	})
}

// Marshal 序列化消息（供 API 层复用，保持字段一致）。
func Marshal(m Message) []byte {
	b, _ := json.Marshal(m)
	return b
}
