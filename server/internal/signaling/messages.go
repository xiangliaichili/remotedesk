// Package signaling 实现 WebSocket 信令通道，负责在设备间转发 WebRTC 的 SDP/ICE。
package signaling

// 信令消息类型常量（与各端客户端保持一致）。
//
// 其中 offer / answer / ice / cancel 为双向消息：客户端既可发送也可接收，
// 值相同，因此每个只需定义一个常量。
const (
	MsgAuth      = "auth"         // 客户端 → 服务器：建立连接后鉴权
	MsgAuthOK    = "auth_ok"      // 服务器 → 客户端：鉴权成功
	MsgHeartbeat = "heartbeat"    // 客户端 → 服务器：心跳
	MsgError     = "error"        // 服务器 → 客户端：错误
	MsgOffer     = "offer"        // 双向：WebRTC SDP offer
	MsgAnswer    = "answer"       // 双向：WebRTC SDP answer
	MsgICE       = "ice"          // 双向：ICE candidate
	MsgCancel    = "cancel"       // 双向：任一端取消控制

	MsgListDevices = "list_devices" // 客户端 → 服务器：列出同账号设备
	MsgDevices     = "devices"      // 服务器 → 客户端：设备列表

	MsgSessionReq   = "session_req"   // 服务器 → 被控端：请求建立控制会话（弹窗提示）
	MsgSessionOk    = "session_ok"    // 服务器 → 控制端：会话建立成功（携带 TURN 凭证）
	MsgSessionDeny  = "session_deny"  // 服务器 → 控制端：被控端拒绝
	MsgControlStart = "control_start" // 服务器 → 被控端：控制已开始（弹“正在被控制”提示）
	MsgControlEnd   = "control_end"   // 服务器 → 任一端：控制已结束
)

// Message 为信令帧。
type Message struct {
	Type      string      `json:"type"`
	To        string      `json:"to,omitempty"`        // 目标设备 ID
	From      string      `json:"from,omitempty"`      // 来源设备 ID（服务器填充）
	SessionID string      `json:"session_id,omitempty"`
	SDP       string      `json:"sdp,omitempty"`
	Candidate string      `json:"candidate,omitempty"`
	Data      interface{} `json:"data,omitempty"` // 通用载荷（设备列表、TURN 凭证、错误信息等）
}

// TurnConfig 为下发给客户端的 TURN 配置。
type TurnConfig struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username"`
	Credential string   `json:"credential"`
}

// MediaPolicy 表示被控端开放给本次会话的媒体能力。
//
// 语义：Mic / Camera 为 true 表示「被控端允许对方接收本机的麦克风/摄像头」，
// 控制端据此决定是否发起 media_req；最终是否真的有轨道，由被控端运行时再确认
// （系统权限未授予、设备被占用时仍可能拿不到设备）。
type MediaPolicy struct {
	Mic    bool `json:"mic"`
	Camera bool `json:"camera"`
}

// DeviceInfo 为设备列表项。
type DeviceInfo struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	OS     string `json:"os"`
	Online bool   `json:"online"`
	// 设备级媒体权限位，便于控制端在连接前就提示「对方未开放麦克风/摄像头」
	MicEnabled    bool `json:"mic_enabled"`
	CameraEnabled bool `json:"camera_enabled"`
}
