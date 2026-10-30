# remotedesk 通信协议规范

所有客户端（Windows / Android / HarmonyOS）与服务端严格遵循本协议，保证互通。

---

## 1. 基础

- 服务端地址：`https://<domain>`（客户端可配置）
- REST 基址：`https://<domain>/api`
- 信令 WebSocket：`wss://<domain>/ws`
- 所有 REST 请求/响应均为 JSON，UTF-8。
- 鉴权：`Authorization: Bearer <JWT>`

---

## 2. 账号与设备

### 2.1 注册
`POST /api/register`
```json
{ "username": "alice", "password": "secret123", "device_name": "Alice-PC", "os": "windows", "device_id": "<客户端持久化的UUID，可空>" }
```
响应 `200`：
```json
{ "token": "<JWT>", "user_id": 1, "device_id": "<uuid>", "username": "alice" }
```
错误：`409 username already exists`，`400` 参数不合法（用户名≥3、密码≥6）。

### 2.2 登录
`POST /api/login`，请求体同注册（`device_id` 为空则服务端生成新设备）。
响应同注册。同一账号可在多台设备登录，**每台设备有独立 device_id**（客户端应本地持久化 device_id，重复登录复用同一 ID）。

### 2.3 设备列表
`GET /api/devices`（需鉴权）
```json
{ "devices": [ { "id": "...", "name": "Alice-PC", "os": "windows", "online": true } ] }
```

### 2.4 设置
`GET /api/settings` → `{ "auto_accept_same_account": false, "mic_enabled": false, "camera_enabled": false }`
`PUT /api/settings`，字段均可选：
```json
{ "auto_accept_same_account": true, "mic_enabled": false, "camera_enabled": false }
```

---

## 3. 信令 WebSocket

连接 `wss://<domain>/ws`，首帧必须鉴权：

```json
{ "type": "auth", "data": "<JWT>" }
```
成功返回：
```json
{ "type": "auth_ok", "data": { "device_id": "..." } }
```

### 3.1 消息类型

| type | 方向 | 字段 | 说明 |
|---|---|---|---|
| `auth` | C→S | `data`: JWT 字符串 | 鉴权 |
| `auth_ok` | S→C | `data.device_id` | 鉴权成功 |
| `heartbeat` | C→S | — | 心跳（建议 25s 一次） |
| `offer` | 双向 | `to`,`session_id`,`sdp` | SDP offer |
| `answer` | 双向 | `to`,`session_id`,`sdp` | SDP answer |
| `ice` | 双向 | `to`,`session_id`,`candidate` | ICE candidate |
| `cancel` | 双向 | `to`,`session_id` | 取消控制 |
| `list_devices` | C→S | — | 请求设备列表 |
| `devices` | S→C | `data`: DeviceInfo[] | 设备列表 |
| `session_req` | S→C(被控端) | `session_id`,`from`,`data.controller_name`,`data.auth_mode` | 请求控制，被控端弹窗同意/拒绝 |
| `session_ok` | S→C(控制端) | `session_id`,`data.turn` | 被控端已同意，附 TURN 凭证（**仅"需同意"路径推送**） |
| `session_deny` | S→C(控制端) | `session_id` | 被控端拒绝 |
| `control_start` | S→C(被控端) | `session_id`,`from`,`data.controller_name`,`data.turn` | 控制已开始（**必须弹窗提示，可随时取消**） |
| `control_end` | 双向 | `session_id` | 控制结束 |
| `error` | S→C | `data.message` | 错误 |

服务器转发 `offer/answer/ice/cancel` 时会自动填入 `from` 字段（发送方 device_id）。

---

## 4. 建立控制会话

### 4.1 三种连接方式

**A. 同账号设备连接（账号密码登录后）**
1. 控制端已登录，`GET /api/devices` 得到同账号设备列表。
2. `POST /api/session/request`
```json
{ "target_device_id": "<被控设备>", "auth": { "mode": "same_account" } }
```
- 若被控端设置 `auto_accept_same_account=true`：立即 `active`，被控端收到 `control_start` 弹窗。
- 否则：`pending`，被控端收到 `session_req` 弹窗，需同意。

**B. 账号密码连接他人设备**
1. `POST /api/session/lookup` `{ "username": "...", "password": "..." }` → 目标账号设备列表。
2. `POST /api/session/request`
```json
{ "target_device_id": "<被控设备>", "auth": { "mode": "account", "username": "...", "password": "..." } }
```
被控端需弹窗同意。

**C. 统一链接（免登录）**
1. 被控端：`POST /api/link/create` → `{ "code": "ABCD2345", "expires_at": "...", "ttl_minutes": 10 }`
2. 控制端：`POST /api/session/request`
```json
{ "auth": { "mode": "link", "link_code": "ABCD2345" } }
```
链接即授权，立即 `active`，被控端收到 `control_start` 弹窗。

### 4.2 会话响应
- 立即激活（A-auto / C）：`{ "session_id": "...", "status": "active", "turn": { "urls": [...], "username": "...", "credential": "..." } }`
- 待同意（A-manual / B）：`{ "session_id": "...", "status": "pending" }`（**不含 turn**）

> 立即激活时，**控制端从本次 HTTP 响应里取 `turn`**，服务端不会额外推送 `session_ok`；
> 被控端仍会收到 `control_start`（同样带 `turn`，用于弹控制提示）。两端拿到的 `turn` 内容一致。

### 4.3 被控端同意/拒绝
`POST /api/session/accept` `{ "session_id": "...", "accept": true }`
- 同意：服务端置 active，响应 `{ "status": "active", "turn": {...} }`，同时向控制端推
  `session_ok`（`data.turn`）、向被控端推 `control_start`（`data.turn` + `data.controller_name`）。
- 拒绝：响应 `{ "status": "denied" }`，向控制端推 `session_deny`；被控端不会收到 `control_start`。

### 4.4 任一端取消
`POST /api/session/cancel` `{ "session_id": "..." }` → 对端收到 `control_end`。
也可直接通过信令 `cancel` 消息取消。任一端（控制端/被控端）都可调用，服务端不做角色限制。

---

## 5. WebRTC 与数据通道

### 5.1 ICE 配置
使用会话下发的 `turn.urls` 作为 `iceServers`（同时含 `stun:` 与 `turn:`，服务端 3478 端口）。
`turn.username` / `turn.credential` 为临时凭证（30 分钟有效）。

### 5.2 协商流程
1. 控制端创建 `RTCPeerConnection`，创建 `control`/`meta`/`file` 三条 DataChannel，发送 `offer`。
2. 被控端 `setRemoteDescription` → 添加屏幕视频轨 → 创建 answer → 信令 `answer`。
3. 双方通过信令 `ice` 交换 candidate。
4. 连接 `connected` 后可开始控制/传输。

**SDP 与 ICE 的编码格式（三端统一，务必遵守）**：
- `offer`/`answer` 的 `sdp` 字段是 **纯 SDP 文本**（即 `pc.localDescription.sdp`），
  **不要**再包一层 `JSON.stringify({type,sdp})`。
- `ice` 的 `candidate` 字段是 **JSON 字符串**：`"{\"candidate\":\"...\",\"sdpMid\":\"0\",\"sdpMLineIndex\":0}"`。

### 5.3 数据通道（双方一致）

| label | 方向 | 承载内容 |
|---|---|---|
| `control` | 控制端→被控端 | **仅** 输入事件 JSON（第 6 节） |
| `meta` | 双向 | **仅** JSON：文件控制帧（`file_*`）、画面尺寸（`screen`）、权限协商 |
| `file` | 双向 | **仅** 二进制数据块（不带任何 JSON） |

> 三条通道的职责严格分离，客户端不得在同一条通道里混发 JSON 与二进制。
> 原因：Android 的 `DataChannel.Buffer` 只有 `binary` 标志，无法可靠区分「小体积 JSON」
> 与「小体积二进制块」（例如传一个 300 字节的 .json 文件会被误判）。

### 5.4 画面尺寸同步（`meta` 通道）

被控端在 `meta` 通道 open 时、以及采集启动/分辨率变化时发送：

```json
{"t":"screen","w":1920,"h":1080}
```

控制端据此把 0..1 归一化坐标还原成像素坐标（配合视频实际显示区域做 letterbox 反算）。
若控制端尚未收到该消息，可按视频轨道的 `videoWidth/videoHeight` 兜底。

---

## 6. 远程输入事件（`control` 通道，JSON 文本）

坐标统一使用 **0..1 归一化**（相对被控屏幕），与分辨率无关。

```json
{"t":"mouse_move","x":0.42,"y":0.31}
{"t":"mouse_down","x":0.42,"y":0.31,"button":0}
{"t":"mouse_up","x":0.42,"y":0.31,"button":0}
{"t":"mouse_wheel","dx":0,"dy":-120}
{"t":"key","action":"down","code":"KeyA","key":"a","mods":["ctrl","shift"]}
{"t":"key","action":"up","code":"KeyA","key":"a"}
{"t":"text","text":"中文输入"}
{"t":"touch","action":"down","x":0.5,"y":0.5,"id":0}
{"t":"touch","action":"move","x":0.51,"y":0.52,"id":0}
{"t":"touch","action":"up","x":0.51,"y":0.52,"id":0}
{"t":"clipboard","text":"..."}
```

`button`: 0=左键, 1=中键, 2=右键。

---

## 7. 文件传输（`meta` 控制帧 + `file` 二进制块）

控制帧走 `meta` 通道（JSON），数据块走 `file` 通道（二进制）。同一时刻一个通道传输一个文件。

发送端：
1. `meta`：`{"t":"file_offer","id":"<uuid>","name":"报告.pdf","size":123456,"dir":""}`
2. 接收端：`meta` 回 `{"t":"file_accept","id":"<uuid>"}` 或 `{"t":"file_reject","id":"<uuid>"}`
3. 发送端在 `file` 通道连续发送二进制块（每块 ≤ 64KB，DataChannel 保序）
4. `meta`：`{"t":"file_done","id":"<uuid>"}`
5. 接收端校验后 `meta` 回 `{"t":"file_ack","id":"<uuid>","ok":true}`

实现约定：
- 发送端每块建议 48KB；`bufferedAmount` 超过阈值（1~2MB）时暂停等待 `bufferedamountlow`
- 接收端按块顺序 **seek + write** 写入，天然支持断点与乱序补偿
- 接收目录：Windows `下载\remotedesk-received`；Android 应用外部私有目录 `remotedesk-received`；
  HarmonyOS `filesDir/received`。重名文件自动追加 ` (n)`
- 进度（可选）：`meta` 上 `{"t":"file_progress","id":"<uuid>","received":102400}`

---

## 8. 控制提示与权限

- 被控端在会话进入 active 时**必须**弹出「正在被 X 控制」提示窗，提供「取消控制」按钮。
- 「取消控制」调用 `POST /api/session/cancel` 并关闭本地连接。
- 麦克风/摄像头默认关闭；被控端可在设置中开启/关闭，开启状态通过 `meta` 通道同步给控制端。
- 被控端可随时在提示窗或托盘退出控制。

---

## 9. 错误码

| HTTP | 含义 |
|---|---|
| 400 | 参数错误 |
| 401 | 未鉴权/凭证错误 |
| 403 | 无权操作该会话 |
| 404 | 目标不存在/链接失效 |
| 409 | 用户名已存在 / 目标离线 / 会话已处理 |
| 500 | 服务端错误 |
