# RemoteDesk 架构设计

本文说明系统为什么这样设计、关键取舍在哪、以及出问题该看哪一层。

---

## 1. 总体拓扑

```
                     ┌──────────────────────────────────────┐
                     │        Go 中转服务器（一台 VPS）      │
                     │                                      │
   ┌──────────┐      │  ┌────────────┐   ┌───────────────┐  │      ┌──────────┐
   │ Windows  │◄─────┼─►│ REST /api  │   │ WebSocket /ws │◄─┼─────►│ Android  │
   │  (Tauri) │ WSS  │  │ 账号/设备  │   │  信令转发      │  │ WSS  │ (Kotlin) │
   └────┬─────┘      │  └─────┬──────┘   └───────┬───────┘  │      └────┬─────┘
        │            │        │                  │          │           │
        │            │  ┌─────▼──────┐   ┌───────▼───────┐  │           │
        │            │  │  SQLite    │   │  TURN :3478   │  │           │
        │            │  │ users/     │   │  （中继兜底）  │  │           │
        │            │  │ devices/   │   └───────┬───────┘  │           │
        │            │  │ sessions/  │           │          │           │
        │            │  │ links      │           │          │           │
        │            │  └────────────┘           │          │           │
        │            └────────────────────────────┼──────────┘           │
        │                                         │                      │
        └──────────── WebRTC（P2P 直连 / TURN 中继，DTLS-SRTP 加密）──────┘
```

**关键点：媒体流与文件内容永远不经过服务器。** 服务器只做三件事：

1. **账号与设备目录** —— 谁在线、属于哪个账号、有哪些权限位
2. **信令交换** —— 帮两端交换 SDP 与 ICE candidate，然后就可以退场
3. **TURN 中继** —— 只能在 NAT 打洞失败（如对称 NAT、双 4G）时兜底转发加密字节流

因此服务器是**低带宽**的：1000 个在线会话的服务器，真正需要中继的可能只有几十个。

---

## 2. 为什么选 WebRTC 而不是自研流协议

| 方案 | 优点 | 缺点 | 结论 |
| --- | --- | --- | --- |
| **WebRTC** | 三端都有成熟实现；自带丢包重传/拥塞控制/NAT 穿透/DTLS 加密；TURN 生态成熟 | 信令要自己写；三端 API 差异大 | ✅ 采用 |
| 自研 TCP 流 + H.264 | 完全可控 | NAT 穿透要自建、弱网体验差、要自己实现拥塞控制 | ❌ |
| VNC/RFB 协议 | 成熟、简单 | 只适合局域网；公网要自己套 TLS 和穿透 | ❌ |
| 走服务器中转（像向日葵免费版） | 实现简单 | 服务器带宽成本爆炸，1080p 一小时几十 GB | ❌ |

WebRTC 的**数据通道**顺带解决了文件传输（不需要另开端口，也不需要额外鉴权——
通道本身就活在同一条已加密的 P2P 连接里）。

---

## 3. 三种连接方式的授权模型

三种方式的差别**只在"谁批准了这次连接"**，批准之后走的完全是同一条链路。

| 方式 | 发起方提供 | 谁批准 | 结果 |
| --- | --- | --- | --- |
| **A 同账号** | 自己的 JWT + 目标 device_id | 被控端的 `auto_accept_same_account` 设置 | 开→直接连；关→被控端弹窗 |
| **B 账号密码** | **对方的**用户名 + 密码 | 被控端人工点同意 | 始终弹窗 |
| **C 统一连接码** | 8 位随机码 | 被控端生成码这个动作本身就是批准 | 直接连 |

服务端在 `handleSessionRequest` 里做三件事，然后统一走 `activateSession`：

```go
switch req.Auth.Mode {
case "link":          // 码即授权
    targetID, err = link.Resolve(st, req.Auth.LinkCode)
    autoAccept = true
case "account":       // 校验对方账号密码 + 设备归属
    u := getUserByUsername(req.Auth.Username)
    if !bcrypt.Check(u.PasswordHash, req.Auth.Password) { 401 }
    if target.UserID != u.ID { 403 }
    autoAccept = false
case "same_account":  // 同一账号，看被控端设置
    autoAccept = target.AutoAcceptSameAccount
}
```

> **安全细节**：B 方式校验的是**目标账号的密码**，不是"我的密码"。
> 也就是说，A 想控制 B 的电脑，必须知道 B 的账号密码——这是"帮家人修电脑"的正确语义。

---

## 4. "免同意" 与 "控制提示" 是两件事

用户需求里这两条经常被混为一谈，实现在两个完全不同的层：

| | 免同意（`auto_accept_same_account`） | 控制提示（协议强制） |
| --- | --- | --- |
| 是什么 | 被控端**不弹确认框**就直接连上 | 连上之后**必须显示**"正在被 X 控制"横幅 |
| 在哪实现 | 服务端 `handleSessionRequest` 的 `autoAccept` 分支 | 客户端 UI + `control_start` 消息 |
| 能不能关 | 用户可以开/关 | **不能关**，协议强制项 |
| 目的 | 省掉每次都要点"同意"的麻烦 | 让用户随时知道自己在被看着，并能一键断开 |

所以即使用户开了"免同意"，被控端依然会收到 `control_start` 并显示横幅与取消按钮。
这不是 UI 建议，是 `docs/protocol.md` 第 8 节的硬要求。

---

## 5. 三条数据通道为什么必须分开

WebRTC 的 DataChannel 是**有序可靠**的（默认 `ordered: true`），
但不同类型的数据放在一条通道上会互相阻塞：

```
错误做法：一条通道混发
  [输入事件 20B][文件块 48KB][输入事件 20B][文件块 48KB]...
  → 传大文件时，鼠标事件排在 48KB 块后面，操作延迟肉眼可见

正确做法：三条独立通道
  control: [鼠标][鼠标][键盘]...        ← 永远不排队
  meta:    [file_offer][screen]...      ← 小 JSON，不排队
  file:    [48KB][48KB][48KB]...        ← 慢慢传，独占
```

另一个原因是**接收端无法可靠区分 JSON 与二进制**：
Android 的 `DataChannel.Buffer` 只有 `binary` 标志，一个 300 字节的 `.json` 文件
和一条 300 字节的 `file_offer` 消息在通道上长得一样。分开通道后这个歧义彻底消失。

---

## 6. 被控端的采集路径（三端各不相同）

| 端 | 采集方式 | 编码 | 送进 WebRTC 的方式 |
| --- | --- | --- | --- |
| Windows | Rust `xcap` 抓屏 | JPEG q70 | Tauri 事件 → canvas → `captureStream(15)` |
| Android | `MediaProjection` + `ScreenCapturerAndroid` | WebRTC 自带 | 直接 `VideoSource` → `VideoTrack` |
| HarmonyOS | ArkWeb 内 `canvas`（由原生喂帧） | JPEG | `captureStream` |

**Windows 为什么绕一圈？** WebView2 的 `getDisplayMedia` 需要额外的 picker 权限配置，
且在不同 Windows 版本上行为不一致。改用 Rust 抓屏后行为完全可预测，代价是多一次
JPEG 编解码（1080p 单帧约 8~15ms）。如果要更高帧率，可换成
Rust 侧 H.264 硬编 + `MediaStreamTrackGenerator`（WebCodecs），接口已预留。

**Android 为什么用原生？** `ScreenCapturerAndroid` 是 WebRTC 官方实现，
直接产出 YUV 帧交给 WebRTC 编码器，没有中间编解码损耗，是三者中最优的路径。

---

## 7. 输入注入（被控端能力）

| 端 | 机制 | 权限要求 |
| --- | --- | --- |
| Windows | `enigo` 调 `SendInput` | 普通用户权限即可 |
| Android | `AccessibilityService.dispatchGesture` | 用户在系统设置里手动开启无障碍 |
| HarmonyOS | ❌ 系统未开放 | 无 |

Android 的手势注入有两个坑，都在 `InjectorService.kt` 里处理了：

1. **`dispatchGesture` 不能并发** —— 用 `AtomicBoolean busy` 串行化，
   在 `GestureResultCallback` 回调里才释放
2. **拖拽必须用 `continueStroke`** —— 每次新建一个 `StrokeDescription` 会导致
   手势被切成多段、系统识别成多次点击。正确做法是保存上一个 stroke，
   用 `prev.continueStroke(...)` 续接，最后一段 `willContinue=false` 收尾

---

## 8. 数据存储

服务器只有一张 SQLite 文件（默认 `./data/remotedesk.db`），四张表：

```sql
users    (id, username UNIQUE, password_hash, created_at)
devices  (id PK, user_id, name, os, last_seen, created_at,
          auto_accept_same_account, mic_enabled, camera_enabled)
sessions (id PK, controller_id, target_id, status, auth_mode,
          created_at, updated_at)
links    (code PK, target_id, expires_at, used, created_at)
```

- 用 `modernc.org/sqlite`（纯 Go），**不需要 CGO**，交叉编译无痛
- `db.SetMaxOpenConns(1)` —— SQLite 写锁竞争下，单连接比连接池更稳
- **不存任何画面、输入、文件内容**：这些全程在 WebRTC 里，服务器看不到

---

## 9. 一次完整连接的时序

```
控制端                     服务器                        被控端
  │                          │                             │
  ├─ POST /api/session/request ─►                          │
  │                          ├─ 校验授权（A/B/C 分支）      │
  │                          ├─ INSERT sessions            │
  │                          ├─ WS: session_req ──────────►│ 弹窗「XX 请求控制」
  │◄─ 200 {status:"pending"}─┤                             │
  │                          │◄──── POST /api/session/accept ┤（用户点同意）
  │                          ├─ UPDATE status='active'     │
  │                          ├─ relay.Issue(30min) → turn   │
  │                          ├─ WS: session_ok {turn} ────►│
  │◄─ 200 {status:"active", turn} ──────────────────────────┤
  │                          ├─ WS: control_start ────────►│ 显示被控横幅
  │                          │                             │
  ├─ WS: offer ─────────────►├────────────────────────────►│
  │◄─────────────── WS: answer ────────────────────────────┤
  │◄─────────────── WS: ice（双向多次）────────────────────►│
  │                          │                             │
  ├══════════ WebRTC P2P 或 TURN 中继（服务器不再参与）═══════┤
  │  视频轨 ◄──────────────────────────────────────────────┤ 屏幕流
  │  control 通道 ─────────────────────────────────────────►│ 输入注入
  │  file 通道 ◄───────────────────────────────────────────►│ 文件传输
  │                          │                             │
  ├─ POST /api/session/cancel ─►                            │
  │                          ├─ WS: control_end ──────────►│
  │◄─ 200 {status:"ended"} ──┤                             │
```

注意 **WebRTC 建立之后，服务器就退出了数据路径**。会话记录只用于事后审计与超时清理。

---

## 10. 可靠性设计

| 场景 | 处理 |
| --- | --- |
| WebSocket 断线 | 客户端指数退避重连（800ms×2ⁿ，上限 15s），重连后首帧重新鉴权 |
| 同 device_id 重复登录 | Hub 踢掉旧连接，保证一个设备只有一条有效信令通道 |
| 心跳丢失 | 服务端读超时 120s 判定离线；客户端 25s 主动 ping |
| TURN 启动失败 | **不阻断服务**，降级为纯 P2P（局域网/Symmetric NAT 同侧仍可用） |
| 长时间无操作 | TURN 凭证 30 分钟过期，后台每 30s 清理过期凭证 |
| 连接码泄露 | 一次性 + 10 分钟 TTL，用后即焚 |
| 服务重启 | SQLite 持久化；在线状态丢失但会话记录保留 |
| 进程退出 | 监听 SIGINT/SIGTERM，5 秒优雅关闭 |

---

## 11. 扩展点

想二次开发时，以下几个位置是刻意留出的：

1. **换中继**：`internal/relay/relay.go` 里的 `Issue/Revoke` 接口没变的话，
   可以把 pion/turn 换成 coturn（配置 TURN REST API 即可，无需改代码）
2. **加录制**：在客户端 `PeerSession`/`RtcClient` 里挂一个 `MediaRecorder`
   或 `VideoFileRenderer`，服务端不用动
3. **加中继鉴权策略**：`internal/api/handlers.go` 的 `turnConfigForSession` 是唯一签发点
4. **换数据库**：`internal/store/store.go` 是唯一的 SQL 出入口，换 Postgres 只改这个文件
5. **加端**：照 `docs/protocol.md` 实现即可，协议里没有平台相关的东西

---

## 12. 已知限制（如实列出）

| 限制 | 影响 | 缓解 |
| --- | --- | --- |
| HarmonyOS 不能作被控端 | 鸿蒙手机不能被远程操作 | 系统限制，无 workaround |
| Windows 采集是 JPEG 帧中转 | 高帧率下 CPU 占用偏高 | 可换 H.264 硬编（接口已留） |
| 单服务器单机 SQLite | 十万级用户会遇到写瓶颈 | 换 Postgres（`store.go` 单点替换） |
| 信令无消息队列 | 服务器重启时在线会话全断 | 客户端自动重连，用户无感 |
| 无 Web 管理后台 | 只能命令行部署与查看 | 可直接读 SQLite，或用 `sqlite3` |
| 无自动更新 | 客户端要手动升级 | 可接 Tauri updater / 应用商店 |
| **语音 / 摄像头只是"权限开关"，没有音视频通话链路** | 设置里的麦克风/摄像头开关会按设备持久化到服务端，作为"允许对方使用语音/摄像头"的声明；当前 WebRTC 会话只承载屏幕视频 + 三条数据通道，**不采集也不传音频/摄像头画面** | 协议已预留：新增两条 track（`audio` / `camera`）并在 `control_start` 前校验被控端 `mic_enabled` / `camera_enabled` 即可，改动集中在 `RtcClient.start()`、`session.js start()` 与服务端 `activateSession` |
| HarmonyOS 工程未在本机编译验证 | 缺少 DevEco Studio / hvigor 工具链，`.hap` 需用户侧构建；ArkTS 代码按 API 12 静态编写，未经过编译器 | 见 `docs/build-harmony.md`，导入 DevEco 后按提示修语法即可 |
| 没有 macOS / Linux 客户端 | 只能被 Windows / Android 控制 | 服务端产物已覆盖 linux/darwin，客户端可复用 Tauri 前端 + 另一套采集注入后端 |
| Windows 客户端未做代码签名 | 首次运行 SmartScreen 会拦一次 | 购买证书后用 `signtool` 签名，或让用户点"仍要运行" |
| 部分厂商 ROM 限制无障碍服务 | Android 被控端在这些机型上无法注入输入 | 引导用户开"自启动"并在电池优化里放行；HarmonyOS 侧系统级不可行 |