# RemoteDesk · 跨平台远程桌面（手机 ↔ 电脑 ↔ 手机 全互控）

一套可自建的远程桌面系统：**Go 中转服务器 + WebRTC 加密直连/中继**，客户端覆盖
**Windows（Tauri）/ Android（Kotlin）/ HarmonyOS（ArkTS）**。

支持 **电脑控电脑、手机控电脑、电脑控手机、手机控手机**（HarmonyOS 端目前仅作为控制端，
原因见 [平台能力矩阵](#平台能力矩阵)）。

---

## 目录

- [功能清单](#功能清单)
- [仓库结构](#仓库结构)
- [快速开始](#快速开始)
  - [1. 部署服务器](#1-部署服务器一键脚本)
  - [2. 构建 Windows 客户端](#2-构建-windows-客户端exe)
  - [3. 构建 Android 客户端](#3-构建-android-客户端apk)
  - [4. 构建 HarmonyOS 客户端](#4-构建-harmonyos-客户端hap)
- [连接方式](#连接方式)
- [设置项](#设置项)
- [平台能力矩阵](#平台能力矩阵)
- [常见问题](#常见问题)
- [安全说明](#安全说明)

---

## 功能清单

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 电脑控电脑 | ✅ | 屏幕采集 + 键鼠注入 + 文件双向传输 |
| 手机控电脑 | ✅ | 触摸映射为鼠标/手势，软键盘输入 |
| 电脑控手机 | ✅ | Android 无障碍服务注入点击/滑动/文本 |
| 手机控手机 | ✅ | Android ↔ Android；HarmonyOS 可作为控制端 |
| 文件传输 | ✅ | 双向、48KB 分块、断点续写、重名自动改名 |
| 账号体系 | ✅ | 注册 / 登录 / 同账号多设备 |
| 账号密码连接 | ✅ | 需要对方同意（弹窗） |
| 统一连接码 | ✅ | 8 位一次性码，10 分钟有效 |
| 同账号免同意 | ✅ | 设置项开关，**但仍会弹出"正在被控制"提示** |
| 任一端随时取消 | ✅ | 被控端横幅按钮 / 通知栏按钮 / 控制端工具栏 |
| 语音·摄像头开关 | ⚠️ | 权限位按设备持久化，三端 UI 可开关；**当前版本尚未实现音视频通话链路**（详见 [已知限制](docs/architecture.md#12-已知限制如实列出)） |
| 一键部署服务器 | ✅ | `install.sh`（systemd+Caddy）或 `docker compose up -d` |
| 传输加密 | ✅ | WebRTC DTLS-SRTP；信令走 WSS/TLS |

---

## 仓库结构

```
remotedesk/
├─ server/                 Go 中转服务器（REST + WebSocket 信令 + TURN + SQLite）
│  ├─ main.go
│  ├─ internal/{api,auth,config,link,relay,signaling,store}/
│  ├─ deploy/{install.sh,Caddyfile,remotedesk.service}
│  ├─ Dockerfile · docker-compose.yml · .env.example · Makefile
│  └─ go.mod
├─ windows/                Windows 客户端（Tauri v2：前端 WebRTC + Rust 采集/注入）
│  ├─ src/{api,signaling,session,main}.js · index.html · style.css
│  └─ src-tauri/{src/{lib,capture,input,files}.rs, tauri.conf.json, icons/}
├─ android/                Android 客户端（Kotlin，原生 WebRTC）
│  └─ app/src/main/java/com/remotedesk/app/{MainActivity,RtcClient,SessionHub,
│      RemoteService,InjectorService,Api,Signaling,Prefs,App}.kt
├─ harmony/                HarmonyOS 客户端（ArkTS + ArkWeb 内 WebRTC 桥接）
│  └─ entry/src/main/ets/{pages/Index.ets, common/*.ets}
│     entry/src/main/resources/rawfile/rdwebrtc.html
├─ docs/                   设计与构建文档
│  ├─ architecture.md      架构设计（含"已知限制"）
│  ├─ protocol.md          协议规范（三端共同遵循，改协议先改这份）
│  └─ build-{windows,android,harmony}.md  各端构建与排错
├─ scripts/                构建与测试脚本
│  ├─ build-server.sh      交叉编译 5 平台服务器
│  ├─ build-windows.ps1    打包 EXE / MSI
│  ├─ build-android.ps1    打包 APK
│  ├─ build-harmony.ps1    打包 HAP（调用 DevEco 的 hvigor）
│  ├─ e2e-test.mjs         服务器端到端集成测试（40 项断言）
│  └─ smoke.ps1            本地起服务器 + 跑 e2e
└─ README.md
```

> 仓库只收录**源码与构建脚本**。编译产物（`dist/`、`windows/src-tauri/target/`、
> `android/app/build/`、`harmony/**/build/`、`node_modules/`）与 `local.properties`
> 等本机配置均由 `.gitignore` 排除，不进入版本库。

---

## 构建产物

源码编译后可得到三端客户端与服务器二进制，产物不进入版本库，需要时自行构建：

| 平台 | 构建命令 | 产物 |
| --- | --- | --- |
| 服务器 | `scripts/build-server.sh` | `dist/server/remotedesk-server-<os>-<arch>` |
| Windows | `scripts/build-windows.ps1` | `windows/src-tauri/target/release/remotedesk.exe`（另有 `bundle/` 下的 NSIS/MSI） |
| Android | `scripts/build-android.ps1` | `android/app/build/outputs/apk/debug/app-debug.apk` |
| HarmonyOS | `scripts/build-harmony.ps1` | `dist/harmony/remotedesk-0.1.0-harmony-<tag>.hap` |

HarmonyOS 的 `.hap` 需要 DevEco Studio（或 hvigor 命令行）构建，见
[docs/build-harmony.md](docs/build-harmony.md)；仓库内已包含可直接导入的完整工程。

### 实测验证记录

| 验证项 | 命令 | 结果 |
| --- | --- | --- |
| 服务器静态检查 | `go vet ./...` | 零警告 |
| 服务器单元测试 | `go test ./...` | `auth`、`link` 包全部通过 |
| 服务器全链路 | `node scripts/e2e-test.mjs http://127.0.0.1:18443` | **10 组 / 40 项断言全部通过** |
| 服务器健康检查 | `GET /healthz`、`GET /version` | `ok`、`{"version":"0.1.0"}` |
| Windows 客户端前端 | `node --check src/*.js` | 语法全部通过 |
| Windows 客户端编译 | `npm run tauri build --no-bundle` | `Finished release profile`，产出 `remotedesk.exe` |
| Windows 客户端启动 | 直接运行 `remotedesk.exe` | 窗口正常创建（标题 `remotedesk`，41 MB 内存，stderr 无报错） |
| Android 客户端编译 | `gradle assembleDebug` | `BUILD SUCCESSFUL`，产出 `app-debug.apk` |
| HarmonyOS 工程静态检查 | 括号/结构配平 + JSON5 解析 | 7 个 `.ets` 与 6 个 `.json5` 全部配平（编译器验证需 DevEco Studio） |

e2e 覆盖：注册 / 多设备 / 密码错误 401 / 目标离线 409 / 双端 JWT 鉴权 / 账号密码
pending→弹窗→同意→active / 拒绝→denied / SDP 与 ICE 中继转发 / 任一端 cancel /
连接码一次性 / 同账号免同意开关 / **免同意也仍推控制提示** / 越权与参数校验。

---

## 快速开始

### 1. 部署服务器（一键脚本）

**前置**：一台有公网 IP 的 Linux（Ubuntu 20.04+ / Debian 11+ / CentOS Stream 9），
一个域名 A 记录指向该 IP，放行 **80 / 443 / 3478（TCP+UDP）**。

```bash
# 上传整个 server 目录到服务器
scp -r remotedesk/server root@你的IP:/tmp/remotedesk-server

ssh root@你的IP
cd /tmp/remotedesk-server
chmod +x deploy/install.sh
./deploy/install.sh desk.example.com 1.2.3.4     # 域名  公网IP
```

脚本会：创建 `remotedesk` 系统用户 → 编译（无 Go 时自动装 Go 1.23.4）→ 写
`/opt/remotedesk/.env`（含随机 JWT 密钥）→ 装 systemd 服务 → 装 Caddy 自动申请
HTTPS 证书 → 配置防火墙。

完成后访问 `https://desk.example.com/healthz` 应返回 `ok`。

**Docker 方式（备选）**

```bash
cd server
cp .env.example .env      # 填 RD_DOMAIN / RD_TURN_RELAY_IP / RD_JWT_SECRET
docker compose up -d --build
```

> 两个容器都用 `network_mode: host`，因为 TURN 的 UDP 端口必须绑到公网网卡，
> 桥接网络下中继会连不通。

**服务器环境变量**

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `RD_LISTEN` | `:8443` | HTTP 监听（前面挂 Caddy 时保持 127.0.0.1 语义即可） |
| `RD_PUBLIC` | 空 | 对外地址，用于拼接 TURN URL |
| `RD_TURN_LISTEN` | `:3478` | TURN 监听 |
| `RD_TURN_RELAY_IP` | 空 | **公网 IP，VPS 必须填**，否则中继不回包 |
| `RD_DB` | `./data/remotedesk.db` | SQLite 路径 |
| `RD_JWT_SECRET` | 空 | JWT 密钥，**生产必填** |
| `RD_TLS` / `RD_CERT` / `RD_KEY` | 关 | 由 Go 自己终结 TLS（默认交给 Caddy） |
| `RD_HEARTBEAT` | `60` | 心跳超时（秒） |
| `RD_LINK_TTL` | `10` | 连接码有效期（分钟） |

---

### 2. 构建 Windows 客户端（EXE）

**前置**：Windows 10/11、[Rust](https://rustup.rs)（MSVC 工具链）、Node.js 18+、
Visual Studio Build Tools（C++ 桌面开发）。

```powershell
cd windows
npm install
npm run tauri build          # 产出 EXE + NSIS 安装包 + MSI
```

或用脚本一键（会自动装依赖、可选跳过打包）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1
```

产物：

- `windows\src-tauri\target\release\remotedesk.exe`（免安装单文件）
- `windows\src-tauri\target\release\bundle\nsis\RemoteDesk_0.1.0_x64-setup.exe`
- `windows\src-tauri\target\release\bundle\msi\RemoteDesk_0.1.0_x64_en-US.msi`

开发调试：`npm run tauri dev`。

**工作原理**：Rust 侧用 `xcap` 抓屏 → JPEG 编码 → 以 `screen-frame` 事件推给前端
canvas → `canvas.captureStream()` 变成 WebRTC 视频轨；控制端收到的输入事件通过
`enigo` 注入系统（鼠标/键盘/滚轮）。文件用 `rfd` 选文件、分块读写落地到
`下载\remotedesk-received`。

---

### 3. 构建 Android 客户端（APK）

**前置**：Android Studio（含 SDK Platform 34 + Build-Tools 34）、JDK 17。

```powershell
cd android
# 用 Android Studio 直接打开本目录，或命令行：
.\gradlew.bat assembleDebug

# 或用脚本：
powershell -ExecutionPolicy Bypass -File ..\scripts\build-android.ps1
```

产物：`android\app\build\outputs\apk\debug\app-debug.apk`

> 首次打开 Android Studio 会提示"Gradle 同步"，接受即可。若仓库里没有
> `gradlew`，用 Android Studio 的 `File → Sync` 或本机 `gradle wrapper` 生成一次。

**真机使用步骤**

1. 安装 APK，填入服务器地址（如 `https://desk.example.com`），注册/登录
2. **要被控**：设置里打开「无障碍服务」→ 找到 RemoteDesk → 开启
   （这是 Android 上无 root 注入点击的唯一官方途径）
3. 被控时系统会弹「开始录制或投放」，必须同意（MediaProjection 授权）
4. 控制端在主界面点设备列表里的设备即可发起

---

### 4. 构建 HarmonyOS 客户端（HAP）

**前置**：DevEco Studio 5.0+（含 HarmonyOS SDK API 12）、已登录华为开发者账号。

```text
DevEco Studio → Open → 选择 remotedesk/harmony 目录
  → 等待 hvigor 同步完成
  → Build → Build Hap(s)/APP(s) → Build Hap(s)
```

产物：`harmony\entry\build\default\outputs\default\entry-default-signed.hap`
（脚本会自动收集到 `dist\harmony\remotedesk-0.1.0-harmony-debug.hap`）

**命令行构建（不想开 IDE）**：

```powershell
.\scripts\build-harmony.ps1                 # debug HAP
.\scripts\build-harmony.ps1 -Release        # release HAP（需先配签名）
.\scripts\build-harmony.ps1 -DevEcoHome "D:\Program Files\Huawei\DevEco Studio"
```

脚本会自动定位 DevEco 的 `hvigorw.bat`、`node.exe`、`ohpm` 与 SDK，执行
`ohpm install` + `hvigor assembleHap`，并把产出的 `.hap` 复制到 `dist\harmony\`。

真机安装：DevEco 里 `Run` 到已连接的 HarmonyOS 设备；或
`hdc install entry-default-signed.hap`。

**架构说明**：HarmonyOS 的 ArkTS 尚未提供标准 WebRTC API，因此采用
**ArkTS 负责信令/文件/UI，ArkWeb 内部的 `rdwebrtc.html` 负责 `RTCPeerConnection`** 的
桥接方案（`javaScriptProxy` 双向通信，协议与另两端完全一致）。
若目标机型的 ArkWeb 内核不支持 WebRTC，需改为原生 RTC 实现（本仓库未包含）。

---

## 连接方式

三种方式最终都建立同一条 WebRTC 会话，区别只在**授权环节**。

### A. 同账号连接（免同意可选）

- 控制端在「我的设备」里点另一台设备
- 若被控端设置里打开的「同账号免同意」→ 直接连上
- 否则被控端弹窗「XX 请求控制本机」→ 同意 / 拒绝
- **无论哪种，被控端都会出现"正在被 XX 控制"横幅 + 取消按钮**

### B. 账号密码连接

- 控制端输入**对方**的账号密码 → 拉取对方设备列表 → 选设备
- 被控端必须手动同意
- 适合临时帮别人处理问题，事后可让对方改密码

### C. 统一连接码

- 被控端点「生成连接码」→ 得到 8 位码（如 `X89SU3L7`），10 分钟有效、**只能用一次**
- 控制端输入该码 → 直接连上（无需同意，仍需对方在场配合）
- 适合"我把码念给你"的临时场景

---

## 设置项

| 设置 | 作用 |
| --- | --- |
| 同账号免同意 | 打开后同账号的其他设备可直接控制本机（仍会弹提示横幅） |
| 允许麦克风 | 关闭后本机不向对端提供麦克风轨道 |
| 允许摄像头 | 关闭后本机不向对端提供摄像头轨道 |
| 无障碍服务（Android） | 开启后本机才能被远程注入操作 |

以上均为**按设备**存储（`devices` 表），同账号不同设备互不影响。

---

## 平台能力矩阵

| 端 | 作控制端 | 作被控端 | 文件收发 | 备注 |
| --- | --- | --- | --- | --- |
| Windows | ✅ | ✅ | ✅ | 屏幕采集用 xcap，输入注入用 enigo |
| Android | ✅ | ✅ | ✅ | 被控需无障碍服务 + MediaProjection 授权 |
| HarmonyOS | ✅ | ⚠️ 未实现 | ✅ | 系统未开放第三方无障碍注入 API，无法无 root 被控 |

> HarmonyOS 端在收到 `session_req` / `control_start` 时会明确提示
> "本机暂不支持被控"，并自动拒绝，不会让对端误以为已连上。

---

## 常见问题

**Q：连上了但画面全黑 / 一直转圈？**
A：多半是 TURN 没配好。检查 `RD_TURN_RELAY_IP` 是否填了**公网 IP**、云厂商安全组
是否放行 3478 TCP+UDP、以及 `RD_PUBLIC` 是否是对外的 `https://域名`。
P2P 能通时不需要 TURN，对称 NAT / 4G 网络下必须靠它。

**Q：Android 被控端点了没反应？**
A：确认三件事：① 设置里无障碍服务已开启；② MediaProjection 授权弹窗点了"立即开始"；
③ 应用在后台没被系统杀（已用前台服务 + 常驻通知保活，部分厂商 ROM 仍需在
"电池优化"里放行）。

**Q：Windows 端编译报 xcap / enigo 的 API 不存在？**
A：这两个 crate 迭代较快。按报错微调 `windows/src-tauri/src/capture.rs` 与
`input.rs` 的调用即可，整体结构不用动。

**Q：能不用域名吗？**
A：可以，但 WebRTC 要求安全上下文。用自签证书 + `RD_TLS=1` 也能跑，只是客户端要
跳过证书校验；更省事的办法是买个便宜域名让 Caddy 自动签 Let's Encrypt。

**Q：跑 `scripts\*.ps1` 报"未对文件进行数字签名 / 无法加载脚本"？**
A：这是 Windows 默认执行策略（Restricted）。三种解法任选：
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\smoke.ps1   # 单次绕过
Unblock-File .\scripts\*.ps1                                   # 解除下载锁定
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass     # 仅当前窗口
```
脚本已带 UTF-8 BOM，Windows PowerShell 5.1 与 PowerShell 7 都能正确读取中文提示。

**Q：数据存在哪？**
A：服务器只存 `users / devices / sessions / links` 四张表（SQLite，单文件），
**不存储任何画面、输入或文件内容**——这些全程走 WebRTC 端到端加密。

---

## 安全说明

- 信令与控制通道：WebRTC **DTLS-SRTP 加密**，服务器无法解密媒体流
- 信令 WebSocket：WSS（TLS 1.2+，Caddy 自动续期证书）
- 账号密码：bcrypt 哈希存储，登录态用 HS256 JWT（默认 24h）
- TURN 凭证：**每会话单独签发，30 分钟过期**，随会话结束失效
- 连接码：一次性、10 分钟过期、去除了 `0/O/1/I` 等易混字符
- 权限最小化：麦克风/摄像头默认关闭，需在设置里显式开启

**自建部署建议**

1. `RD_JWT_SECRET` 用脚本生成的随机值，不要用默认
2. 不要把 8443 直接暴露到公网，只让 Caddy 反代
3. 定期备份 `/opt/remotedesk/data/remotedesk.db`
4. 若面向公网开放注册，建议在 Caddy 上加速率限制或加一层邀请码

---

## 开发与测试

```bash
# 服务器：本地跑起来
cd server
go mod tidy
go run .                     # 默认 :8443，数据在 ./data

# 端到端测试（40 项断言：注册/多设备/三种连接/信令转发/取消/权限）
cd remotedesk
node scripts/e2e-test.mjs http://127.0.0.1:8443
```

`scripts/e2e-test.mjs` 覆盖了协议里所有关键路径，改服务端后先跑它。

---

## 协议

三端共用一套协议，详见 [`docs/protocol.md`](docs/protocol.md)。要点：

- REST `/api/*` 走 Bearer JWT；信令 `/ws` 首帧 `{"type":"auth","data":"<JWT>"}`
- 三条 DataChannel：`control`（输入事件）/ `meta`（元信息与文件控制）/ `file`（纯二进制块）
- SDP 传纯文本，ICE 传 JSON 字符串，坐标一律归一化到 `0..1`
- 被控端进入 active **必须**弹控制提示：这是协议强制项，不是 UI 建议

---

## License

MIT