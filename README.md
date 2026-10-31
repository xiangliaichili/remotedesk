# RemoteDesk · 跨平台远程桌面（手机 ↔ 电脑 全互控）

一套可自建的远程桌面系统：**Go 中转服务器 + WebRTC 加密直连/中继**，
客户端覆盖 **Windows（Tauri）/ Android（Kotlin）/ HarmonyOS（ArkTS）**。
支持 **电脑控电脑、手机控电脑、电脑控手机、手机控手机**。

> 本文档是仓库唯一的说明文件，把「上手 / 使用 / 构建 / 部署 / 协议 / 架构 / 排错 / 变更」全部收录。
> 只想马上跑起来：跳到 [2. 快速开始](#2-快速开始)。想改代码：先看 [10. 架构设计](#10-架构设计)
> 与 [9. 协议规范](#9-协议规范)。

**当前版本**：v1.02（应用版本 1.3.0）· 变更见 [13. 版本记录](#13-版本记录)

| 端 | 作控制端 | 作被控端 | 文件收发 | 语音 / 摄像头 | 登录方式 |
| --- | --- | --- | --- | --- | --- |
| Windows 10/11 | ✅ | ✅ | ✅ | ✅ 采集 + 播放 | 密码 / 手机验证码 / 微信扫码 |
| Android 7.0+ | ✅ | ✅ | ✅ | ✅ 采集 + 播放 | 密码 / 手机验证码 / 微信 |
| HarmonyOS NEXT (API 12) | ✅ | ❌ 系统限制 | ✅ | ◐ 仅接收（播放 + 画中画） | 密码 / 手机验证码 / 微信 |

**按角色找入口**

| 我想… | 看这里 |
| --- | --- |
| 先跑起来看看效果 | [2.1 本机试用](#21-只想在本机试一下不买服务器) → [2.4 第一次连接](#24-第一次连接) |
| 部署到公网给别人连 | [8. 服务器部署](#8-服务器部署) |
| 打包三端客户端 | [7. 客户端构建](#7-客户端构建) |
| 语音/摄像头没声音、看不到画面 | [6.2 三层权限](#62-语音与摄像头三层权限) → [11. 排错手册](#11-排错手册) |
| 改协议、加功能、换成 Postgres | [9. 协议规范](#9-协议规范) → [10. 架构设计](#10-架构设计) |
| 查某个具体报错 | [11. 排错手册](#11-排错手册) |
| 看这一版改了什么 | [13. 版本记录](#13-版本记录) |

---

## 目录

<!-- TOC -->
- [1. 30 秒速览](#1-30-秒速览)
- [2. 快速开始](#2-快速开始)
  - [2.1 只想在本机试一下（不买服务器）](#21-只想在本机试一下不买服务器)
  - [2.2 部署到公网服务器（给外网的人连）](#22-部署到公网服务器给外网的人连)
  - [2.3 构建客户端](#23-构建客户端)
  - [2.4 第一次连接](#24-第一次连接)
- [3. 仓库结构](#3-仓库结构)
- [4. 功能与平台能力](#4-功能与平台能力)
  - [4.1 功能清单](#41-功能清单)
  - [4.2 平台能力矩阵](#42-平台能力矩阵)
- [5. 连接方式](#5-连接方式)
  - [5.1 同账号连接（免同意可选）](#51-同账号连接免同意可选)
  - [5.2 账号密码连接](#52-账号密码连接)
  - [5.3 统一连接码](#53-统一连接码)
- [6. 使用说明](#6-使用说明)
  - [6.1 设置项](#61-设置项)
  - [6.2 语音与摄像头三层权限](#62-语音与摄像头三层权限)
  - [6.3 被控端提示（协议强制）](#63-被控端提示协议强制)
  - [6.4 Windows 端的小便利](#64-windows-端的小便利)
  - [6.5 登录方式（v1.03）](#65-登录方式v103)
- [7. 客户端构建](#7-客户端构建)
  - [7.1 先体检，再构建](#71-先体检再构建)
  - [7.2 Windows（Tauri v2）](#72-windowstauri-v2)
  - [7.3 Android（Kotlin）](#73-androidkotlin)
  - [7.4 HarmonyOS（ArkTS + ArkWeb）](#74-harmonyosarkts-arkweb)
  - [7.5 HarmonyOS 的边界与限制](#75-harmonyos-的边界与限制)
  - [7.6 打包发布（dist）](#76-打包发布dist)
- [8. 服务器部署](#8-服务器部署)
  - [8.1 一键脚本（推荐）](#81-一键脚本推荐)
  - [8.2 Docker](#82-docker)
  - [8.3 环境变量](#83-环境变量)
  - [8.4 上线检查](#84-上线检查)
  - [8.5 配置登录方式（短信 / 微信）](#85-配置登录方式短信-微信)
  - [8.6 部署完成后怎么用（一张清单）](#86-部署完成后怎么用一张清单)
- [9. 协议规范](#9-协议规范)
  - [9.1 基础](#91-基础)
  - [9.2 账号与设备](#92-账号与设备)
  - [9.3 信令 WebSocket](#93-信令-websocket)
  - [9.4 建立控制会话](#94-建立控制会话)
  - [9.5 WebRTC 与数据通道](#95-webrtc-与数据通道)
  - [9.6 远程输入事件（`control` 通道，JSON 文本）](#96-远程输入事件control-通道json-文本)
  - [9.7 文件传输（`meta` 控制帧 + `file` 二进制块）](#97-文件传输meta-控制帧-file-二进制块)
  - [9.8 控制提示与权限](#98-控制提示与权限)
  - [9.9 错误码](#99-错误码)
- [10. 架构设计](#10-架构设计)
  - [10.1 总体拓扑](#101-总体拓扑)
  - [10.2 为什么选 WebRTC](#102-为什么选-webrtc)
  - [10.3 三种连接方式的授权模型](#103-三种连接方式的授权模型)
  - [10.4 "免同意"与"控制提示"是两件事](#104-免同意与控制提示是两件事)
  - [10.5 三条数据通道为什么必须分开](#105-三条数据通道为什么必须分开)
  - [10.6 被控端的采集路径](#106-被控端的采集路径)
  - [10.7 输入注入（被控端能力）](#107-输入注入被控端能力)
  - [10.8 数据存储](#108-数据存储)
  - [10.9 一次完整连接的时序](#109-一次完整连接的时序)
  - [10.10 可靠性设计](#1010-可靠性设计)
  - [10.11 扩展点](#1011-扩展点)
  - [10.12 语音 / 摄像头链路设计](#1012-语音-摄像头链路设计)
  - [10.13 已知限制（如实列出）](#1013-已知限制如实列出)
- [11. 排错手册](#11-排错手册)
  - [11.1 通用](#111-通用)
  - [11.2 Windows](#112-windows)
  - [11.3 Android](#113-android)
  - [11.4 HarmonyOS](#114-harmonyos)
- [12. 安全说明](#12-安全说明)
- [13. 版本记录](#13-版本记录)
  - [13.1 v1.03（应用版本 1.3.0）· 2026-10-31](#131-v103应用版本-130-2026-10-31)
  - [13.2 v1.02（应用版本 1.2.0）· 2026-10-31](#132-v102应用版本-120-2026-10-31)
  - [13.3 v1.01 · 2026-10-30](#133-v101-2026-10-30)
- [14. 开发与测试](#14-开发与测试)
- [15. License](#15-license)
<!-- /TOC -->

---

## 1. 30 秒速览

| 你关心的问题 | 答案 |
| --- | --- |
| 要不要公网服务器 | 局域网自用不必：`scripts\quickstart.ps1` 在本机起服务；跨网才需要一台 VPS |
| 需不需要域名 | 不需要：`install.sh --ip-only <IP>` 直接按 `http://IP:8080` 跑 |
| 画面/文件经过服务器吗 | 不经过。WebRTC 端到端 DTLS-SRTP 加密，服务器只转发信令与（必要时）TURN 中继 |
| 数据存在哪 | 服务器只有 `users / devices / sessions / links` 四张 SQLite 表，不存画面、输入、文件内容 |
| 语音/摄像头默认开吗 | **默认全关**。三层都放行才会真正采集（见 [6.2](#62-语音与摄像头三层权限)） |
| 最少几步能连上 | 两台设备填同一服务器、登同一账号 → 点「连接」→ 对方点同意 |
| 为什么 HarmonyOS 不能被控 | 系统未向第三方开放跨应用触摸注入，无 root 无解（见 [7.5](#75-harmonyos-的边界与限制)） |

---

## 2. 快速开始

三条路，按目的选一条。

### 2.1 只想在本机试一下（不买服务器）

**前置**：Windows + [Go](https://go.dev/dl/)（装完开个新终端，`go version` 有输出即可）。

```powershell
# 仓库根目录
powershell -ExecutionPolicy Bypass -File scripts\quickstart.ps1
```

一条命令完成：生成 `server\.env`（随机 JWT、自动探测内网 IP）→ 编译 → 后台启动 →
`/healthz` 健康检查 → **打印客户端该填的服务器地址**。

```
客户端「服务器地址」填：
   本机使用      http://127.0.0.1:8443
   同一 WiFi 的设备  http://192.168.1.23:8443
```

```powershell
scripts\quickstart.ps1 -Port 9443    # 换端口
scripts\quickstart.ps1 -Force        # 重建 .env + 强制重编译
scripts\quickstart.ps1 -Stop         # 停止
```

> 手机要和电脑在**同一 WiFi**；连不上先看 Windows 防火墙是否放行 8443（TCP）与 3478（TCP+UDP）。

### 2.2 部署到公网服务器（给外网的人连）

```bash
scp -r server root@你的IP:/tmp/remotedesk-server
ssh root@你的IP && cd /tmp/remotedesk-server && chmod +x deploy/install.sh

./deploy/install.sh desk.example.com 1.2.3.4    # ① 域名 + 公网IP：Caddy 自动 HTTPS（推荐）
./deploy/install.sh --ip-only 1.2.3.4           # ② 只有 IP：http://IP:8080
./deploy/install.sh --local                     # ③ 本机/内网验证
```

脚本自动编译、写配置、装 systemd、（域名模式）申请证书、配防火墙，最后**跑健康检查并打印客户端地址**。
细节见 [8. 服务器部署](#8-服务器部署)。

### 2.3 构建客户端

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1                # 先体检，缺什么直接说
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -Target all    # 再按需构建
```

| 端 | 产物 |
| --- | --- |
| Windows | `windows\src-tauri\target\release\remotedesk.exe` |
| Android | `android\app\build\outputs\apk\debug\app-debug.apk` |
| HarmonyOS | `dist\harmony\*.hap`（需 DevEco Studio） |

细节见 [7. 客户端构建](#7-客户端构建)。

> 只是想先看看界面？`dist/` 里已经有**三端统一到 1.3.0** 的现成产物
> （Windows EXE / Android APK / 4 平台服务端），按 `dist/README.md` 直接跑即可，
> 不用自己装工具链。

### 2.4 第一次连接

1. 两台设备填**同一服务器地址**，注册/登录**同一账号**（不同账号也能连：账号密码 或 连接码）
2. 「我的设备」里看到对方 → 点「连接」
3. 被控端弹「请求控制」→ 点「同意」
4. 被控端立刻出现「正在被 X 控制」提示条，随时可点「取消控制」

---

## 3. 仓库结构

```
remotedesk/
├─ server/                 Go 中转服务器（REST + WebSocket 信令 + TURN + SQLite）
│  ├─ main.go
│  ├─ internal/{api,auth,config,link,relay,signaling,sms,store,wechat}/
│  ├─ deploy/{install.sh,Caddyfile,remotedesk.service}
│  ├─ Dockerfile · docker-compose.yml · .env.example · Makefile
│  └─ go.mod
├─ windows/                Windows 客户端（Tauri v2：前端 WebRTC + Rust 采集/注入）
│  ├─ src/{api,media,signaling,session,main}.js · index.html · style.css
│  └─ src-tauri/src/{lib,capture,input,files,media}.rs · tauri.conf.json · icons/
├─ android/                Android 客户端（Kotlin，原生 WebRTC）
│  └─ app/src/main/java/com/remotedesk/app/
│     {MainActivity,RtcClient,SessionHub,RemoteService,InjectorService,
│      Api,Signaling,Prefs,Permissions,App}.kt
├─ harmony/                HarmonyOS 客户端（ArkTS + ArkWeb 内 WebRTC 桥接）
│  └─ entry/src/main/ets/{pages/Index.ets, common/*.ets}
│     entry/src/main/resources/rawfile/rdwebrtc.html
├─ scripts/                构建、体检与测试
│  ├─ quickstart.ps1       本机一键起服务器
│  ├─ setup.ps1            环境体检 + 一键构建
│  ├─ package-dist.ps1     整理 dist 发布包（命名 + VERSION + 校验和）
│  ├─ build-server.sh      交叉编译 5 平台服务器
│  ├─ build-windows.ps1    打包 EXE / MSI
│  ├─ build-android.ps1    打包 APK
│  ├─ build-harmony.ps1    打包 HAP（调用 DevEco 的 hvigor）
│  ├─ e2e-test.mjs         服务器端到端测试（含媒体权限位下发）
│  ├─ media-policy.test.mjs 媒体协商纯逻辑单测（24 项断言）
│  └─ smoke.ps1            本地起服务器 + 跑 e2e
├─ dist/                   本地构建产物（已 gitignore）
│  ├─ README.md            发布包说明（怎么跑、版本、校验）
│  ├─ VERSION              产物版本 vs 源码版本
│  ├─ SHA256SUMS.txt       相对路径校验和
│  └─ windows/ · android/ · server/
├─ README.md               本文件（唯一说明文档）
└─ .gitignore
```

> 仓库只收录**源码与构建脚本**。编译产物（`dist/`、`windows/src-tauri/target/`、
> `android/app/build/`、`harmony/**/build/`、`node_modules/`）与 `local.properties`
> 等本机配置由 `.gitignore` 排除。

---

## 4. 功能与平台能力

### 4.1 功能清单

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 电脑控电脑 | ✅ | 屏幕采集 + 键鼠注入 + 文件双向传输 |
| 手机控电脑 | ✅ | 触摸映射为鼠标/手势，软键盘输入 |
| 电脑控手机 | ✅ | Android 无障碍服务注入点击/滑动/文本 |
| 手机控手机 | ✅ | Android ↔ Android；HarmonyOS 可作控制端 |
| 文件传输 | ✅ | 双向、48KB 分块、断点续写、重名自动改名 |
| 账号体系 | ✅ | 注册 / 登录 / 同账号多设备 |
| 手机验证码登录 | ✅ | 11 位手机号 + 6 位短信码，首次自动建号；60 秒限流、5 次错误作废 |
| 微信扫码登录 | ✅ | 开放平台网站应用 OAuth2；扫码完自动登录，state 一次性 |
| 账号密码连接 | ✅ | 需要对方同意（弹窗） |
| 统一连接码 | ✅ | 8 位一次性码，10 分钟有效 |
| 同账号免同意 | ✅ | 设置项开关，**但仍会弹出"正在被控制"提示** |
| 任一端随时取消 | ✅ | 被控端横幅按钮 / 通知栏按钮 / 控制端工具栏 |
| 语音通话 | ✅ | 被控端麦克风 → 控制端扬声器；三层权限 + 状态回执 |
| 摄像头 | ✅ | 被控端摄像头 → 控制端画中画；可随时单方面关闭 |
| 权限自检 | ✅ | Windows 读系统隐私开关并给「打开设置」直达按钮；其余端运行时申请 |
| 一键部署 | ✅ | `install.sh` 三种模式 / `docker compose up -d` |
| 本机一键跑起来 | ✅ | `scripts\quickstart.ps1` |
| 环境体检 / 一键构建 | ✅ | `scripts\setup.ps1`，缺工具只跳过对应端 |
| 传输加密 | ✅ | WebRTC DTLS-SRTP；信令 WSS/TLS（纯 IP 模式为 WS） |

### 4.2 平台能力矩阵

| 端 | 作控制端 | 作被控端 | 文件收发 | 语音 / 摄像头 | 备注 |
| --- | --- | --- | --- | --- | --- |
| Windows | ✅ | ✅ | ✅ | ✅ 采集 + 播放 | 采集用 xcap，注入用 enigo，音视频走 WebView2 getUserMedia |
| Android | ✅ | ✅ | ✅ | ✅ 采集 + 播放 | 被控需无障碍 + MediaProjection + 麦克风/摄像头运行时权限 |
| HarmonyOS | ✅ | ⚠️ 未实现 | ✅ | ◐ 仅接收 | 系统未开放第三方无障碍注入 API |

> HarmonyOS 收到 `session_req` / `control_start` 时会明确提示"本机暂不支持被控"并自动拒绝，
> 不会让对端误以为已连上。

---

## 5. 连接方式

三种方式最终建立同一条 WebRTC 会话，区别只在**授权环节**。

| 方式 | 控制端提供 | 谁批准 | 结果 |
| --- | --- | --- | --- |
| **A 同账号** | 自己的 JWT + 目标 device_id | 被控端 `auto_accept_same_account` 设置 | 开→直接连；关→被控端弹窗 |
| **B 账号密码** | **对方的**用户名 + 密码 | 被控端人工点同意 | 始终弹窗 |
| **C 统一连接码** | 8 位随机码 | 被控端生成码这个动作本身 | 直接连 |

### 5.1 同账号连接（免同意可选）

- 控制端在「我的设备」里点另一台设备
- 被控端设置里打开「同账号免同意」→ 直接连上；否则弹窗「XX 请求控制本机」
- **无论哪种，被控端都会出现"正在被 XX 控制"横幅 + 取消按钮**

### 5.2 账号密码连接

- 控制端输入**对方**的账号密码 → 拉取对方设备列表 → 选设备
- 适合临时帮别人处理问题，事后可让对方改密码

> 安全语义：校验的是**目标账号的密码**，不是"我的密码"。A 想控制 B 的电脑，必须知道 B 的账号密码。

### 5.3 统一连接码

- 被控端点「生成连接码」→ 8 位码（如 `X89SU3L7`），10 分钟有效、**只能用一次**
- 控制端输入该码 → 直接连上（无需同意，仍需对方在场配合）
- 适合"我把码念给你"的临时场景

---

## 6. 使用说明

### 6.1 设置项

| 设置 | 作用 |
| --- | --- |
| 同账号免同意 | 打开后同账号其他设备可直接控制本机（仍会弹提示横幅） |
| 允许远程开启麦克风 | 关闭后本机不提供麦克风；控制端按钮置灰并提示原因 |
| 允许远程开启摄像头 | 同上，作用于摄像头 |
| 无障碍服务（Android） | 开启后本机才能被远程注入操作 |

以上均**按设备**存储（`devices` 表），同账号不同设备互不影响。

### 6.2 语音与摄像头三层权限

远程开麦/开摄像头是最敏感的能力，只靠一个开关会出两类事故：设置开着但没系统权限
（控制端一直转圈）、设置关着但代码仍采集（指示灯亮起）。所以拆成三层，每层都能给出**可读结论**。

| 层 | 在哪 | 不通过时 |
| --- | --- | --- |
| ① 政策开关 | 被控端「设置」两个开关，存服务端 `devices` 表，随会话下发 `media{mic,camera}` | 控制端按钮提示「对方未开放」 |
| ② 系统权限 | Android `RECORD_AUDIO`/`CAMERA`、Windows 隐私设置 + WebView2 站点权限、HarmonyOS `MICROPHONE`/`CAMERA` | 弹窗给「去设置 / 打开隐私设置」 |
| ③ 会话内请求 | 控制端点「语音/摄像头」→ `media_req` → 被控端按需打开 → `media_state` 回执 | 状态文字写明原因 |

**操作顺序**

1. 被控端：设置里打开两个开关（政策）
2. 被控端首次被控：同意系统的麦克风 / 摄像头授权弹窗
3. 连上后控制端：点工具栏「语音」「摄像头」
4. 被控端：提示条上可随时「关麦克风 / 关摄像头」，控制端立即同步

**失败原因（三端一致，协议见 9.5.3）**

| `reason` | 含义 | 用户该做什么 |
| --- | --- | --- |
| `policy_off` | 被控端设置里关了 | 让对方打开后重连 |
| `permission_denied` | 系统权限被拒 | 点「去设置 / 打开隐私设置」 |
| `no_device` | 没有可用设备 | 插设备 / 查驱动 |
| `busy` | 被其他程序占用 | 关掉会议软件再试 |
| `unsupported` | 该端不支持 | HarmonyOS 不作被控，本来也用不到 |

**各端差异**

| 端 | 采集实现 | 注意 |
| --- | --- | --- |
| Windows | WebView2 `getUserMedia`（设备由系统提供） | 需系统隐私允许「桌面应用」；首页有自检卡片 + 直达设置 |
| Android | `AudioSource` + `Camera2Enumerator`；`JavaAudioDeviceModule` 播远端音频 | 前台服务类型按权限自动裁剪，失败降级为只共享屏幕 |
| HarmonyOS | 仅控制端：播放远端音频 + 画中画 | 需 `onPermissionRequest` 放行 |

### 6.3 被控端提示（协议强制）

被控端进入 active **必须**显示「正在被 X 控制」提示，并提供取消入口。这不是 UI 建议，
是 [9.8](#98-控制提示与权限) 的硬要求。即使用户开了「免同意」，提示依然出现。

### 6.4 Windows 端的小便利

- **本机语音 / 摄像头自检卡片**：政策开关 / 系统隐私 / 设备数量六行状态，红点行直接给设置按钮
- **最近连接**：点一下直接重连（离线时置灰）
- **设备列表**直接标注对方开放了哪些能力（`开放 语音/摄像头`）
- 被控时横幅可一键关麦/关摄像头；控制端可单独静音对方声音（纯本地）

### 6.5 登录方式（v1.03）

登录页有三个标签：**账号密码 / 手机验证码 / 微信登录**。服务端没配的那一项会自动隐藏
（客户端启动时问 `/api/auth/methods`），所以不用怕点了报错。

| 方式 | 需要什么 | 首次登录 | 备注 |
| --- | --- | --- | --- |
| 账号密码 | 用户名 ≥3 位、密码 ≥6 位 | 先「注册」 | 原有方式，完全兼容 |
| 手机验证码 | 服务端配好短信通道（阿里云 / mock） | **自动建号**，用户名 = 手机号 | 60 秒只能发一条；验证码 5 分钟有效、错 5 次作废 |
| 微信扫码 | 服务端配好开放平台 AppID/Secret | **自动建号**，用户名形如 `wx_a1b2c` | 浏览器里扫码，客户端轮询，扫完自动登录 |

**操作步骤**

1. **手机验证码**：切到「手机验证码」→ 填 11 位手机号 → 点「获取验证码」→ 填 6 位码 →
   点「登录 / 注册」。本地 mock 模式下验证码会自动填入输入框。
2. **微信**：切到「微信登录」→ 点「打开微信扫码登录」→ 浏览器弹出二维码 → 微信扫码确认 →
   客户端 2 秒轮询一次，拿到 token 后自动进主页（二维码 10 分钟有效）。
3. **账号密码**：和以前一样，登 / 注册两个按钮。

**账号关系（当前实现）**

- 手机号账号与微信账号是**两套独立账号**，各自有独立的设备列表；暂未做"同一人绑定合并"。
  想统一管理，建议团队内固定用一种登录方式。
- 手机号/微信账号没有密码（服务端存的是不可用占位哈希），因此不能用「账号密码」登录；
  反之密码账号也没有手机号/微信绑定。
- 三种方式登录后拿到的 JWT 完全等价，后续连接、被控、文件、媒体都不区分来源。

---

## 7. 客户端构建

### 7.1 先体检，再构建

```powershell
scripts\setup.ps1                  # 只体检：node/npm/cargo/go/java/gradle/adb 一目了然
scripts\setup.ps1 -Target windows  # 体检 + 构建指定端
scripts\setup.ps1 -Target all      # 多端：缺工具只跳过该端，不影响其它端
scripts\setup.ps1 -SkipInstall     # 跳过 npm install
```

| 工具 | 用途 | 获取 |
| --- | --- | --- |
| node 18+ / npm | Windows 前端 + 测试脚本 | https://nodejs.org |
| cargo (rustup) | Windows 外壳 | https://rustup.rs |
| Visual Studio Build Tools | MSVC 链接器（勾"使用 C++ 的桌面开发"） | VS Installer |
| Go 1.22+ | 服务器 | https://go.dev/dl/ |
| JDK 17 | Android | https://adoptium.net |
| Gradle 8.9 | Android 构建（AGP 8.7 要求 8.9+） | https://gradle.org/releases |
| DevEco Studio 5.0+ | HarmonyOS | 华为开发者官网 |

> 体检脚本会自动找 `.tools\` 下的便携版（`go`、`cargo`、`gradle-home`），也会去
> `C:\Program Files\Microsoft\jdk-*` 之类常见位置找 JDK；找到就回填 `JAVA_HOME` /
> `ANDROID_HOME` / `CARGO_HOME` 给后续构建脚本，不用手工设环境变量。

### 7.2 Windows（Tauri v2）

**前置**：Windows 10 1809+ / 11、Node 18+、Rust stable（`x86_64-pc-windows-msvc`）、
VS 2022 Build Tools（C++ 桌面开发）、WebView2 Runtime（Win11 自带）。

```powershell
winget install Rustlang.Rustup
winget install Microsoft.VisualStudio.2022.BuildTools `
  --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
Test-Path "C:\Program Files (x86)\Microsoft\EdgeWebView\Application"   # WebView2
```

> 只装 BuildTools 而**不加 VCTools workload** 不够：目录会是空的，`cargo build` 报
> `linker 'link.exe' not found`。

**构建**

```powershell
cd windows
npm install
npm run tauri build                 # EXE + NSIS + MSI
npm run tauri build -- --no-bundle  # 只要裸 EXE，快很多
# 或一键：
powershell -ExecutionPolicy Bypass -File ..\scripts\build-windows.ps1
```

**产物**

| 文件 | 说明 |
| --- | --- |
| `src-tauri\target\release\remotedesk.exe` | 免安装单文件，双击即用 |
| `...\bundle\nsis\RemoteDesk_1.3.0_x64-setup.exe` | NSIS 安装包（当前用户级，免管理员） |
| `...\bundle\msi\RemoteDesk_1.3.0_x64_en-US.msi` | MSI 安装包 |

体积约 10~15 MB（WebView2 用系统共享运行时，不重复打包）。

**工作原理**

```
┌────────────────────── Tauri 应用 ──────────────────────┐
│  前端 (WebView2)                Rust 后端               │
│  ┌────────────────────┐        ┌─────────────────────┐ │
│  │ main.js    UI/编排  │        │ capture.rs  xcap    │ │
│  │ session.js WebRTC  │◄──────►│ input.rs    enigo   │ │
│  │ media.js   媒体协商 │ invoke │ files.rs    rfd/fs  │ │
│  │ api.js     REST    │ 事件   │ media.rs    隐私诊断 │ │
│  └────────────────────┘        └─────────────────────┘ │
└────────────────────────────────────────────────────────┘
```

- **作被控端**：`start_capture` → `xcap` 抓屏 → JPEG(q70) → base64 → `screen-frame` 事件 →
  canvas → `captureStream(15)` 变成视频轨
- **作控制端**：输入事件 → `inject_input` → `enigo` 注入
- **文件**：`rfd` 选文件，分块读写到 `下载\remotedesk-received`
- **语音/摄像头**：WebView2 `getUserMedia`，Rust 侧只做权限诊断

> 为什么不用 `getDisplayMedia`？WebView2 对它的支持不稳定（需额外 picker 权限配置），
> Rust 抓屏行为可预测，代价是多一次 JPEG 编解码。要高帧率可换 H.264 硬编 +
> `MediaStreamTrackGenerator`（接口已留）。

**Windows 语音/摄像头排查**

| 层 | 检查 | 不通过的报错 |
| --- | --- | --- |
| 系统隐私 | 首页自检卡片，或 `设置 → 隐私和安全性 → 摄像头/麦克风 → 让桌面应用访问…` | `NotReadableError` / 设备数为 0 |
| WebView2 站点权限 | 首次点「语音」弹的授权提示 | `NotAllowedError` |

等价命令（`0x1` 允许，`0x0` 禁止）：

```text
reg query "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam\NonPackaged" /v Value
reg query "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged" /v Value
```

新增 Rust 命令：`media_privacy_status`（返回 `{webcam, microphone, hint}`，`null` 表示读不到）、
`open_privacy_settings(kind)`（打开 `ms-settings:privacy-webcam` / `-microphone`）。
企业组策略统一封禁时应用无法绕过，需管理员放开。

**开发调试**

```powershell
cd windows
npm run tauri dev        # 前端热更新（vite 1420）
```

- WebView2 DevTools：`Ctrl+Shift+I`（debug 构建自动启用）
- Rust 日志：`RUST_LOG=debug npm run tauri dev`

### 7.3 Android（Kotlin）

**前置**：JDK 17、Android SDK Platform 34 + Build-Tools 34.0.0、Android 7.0 (API 24)+。

Gradle 不必单独安装：把 `gradle-8.9-bin.zip` 解压到 `<仓库>\.tools\gradle-home\gradle-8.9`，
`setup.ps1` 与 `build-android.ps1` 都会自动发现它（也支持系统 PATH 里的 `gradle`）。

```powershell
echo $env:JAVA_HOME
Test-Path "$env:ANDROID_HOME\platforms\android-34"
```

**构建**

```text
① Android Studio → Open → android → 等 Gradle Sync → Build APK(s)
② 命令行：cd android; .\gradlew.bat assembleDebug
③ 一键：  powershell -File ..\scripts\build-android.ps1 [-Release]
```

产物：`android\app\build\outputs\apk\debug\app-debug.apk`（安装 `adb install -r`）

**真机上的三件事（缺一不可）**

1. **无障碍服务**：`设置 → 无障碍 → 已下载的服务 → 远程桌面 → 开启`（应用内有直达按钮）
2. **MediaProjection**：被控时系统弹「开始录制或投放屏幕」→ 点**立即开始**
3. **后台存活**：已用前台服务 + 常驻通知保活；MIUI / EMUI / ColorOS 还需在
   "电池 → 应用启动管理"里允许后台活动

控制端（去控别人）不需要这三样。

**文件分布**

```
android/app/src/main/java/com/remotedesk/app/
├─ App.kt               Application：初始化 PeerConnectionFactory + JavaAudioDeviceModule
├─ Prefs.kt             SharedPreferences：server / token / deviceId / deviceName
├─ Permissions.kt       麦克风/摄像头运行时权限
├─ Api.kt               REST（OkHttp）
├─ Signaling.kt         WebSocket 信令
├─ RtcClient.kt         WebRTC：三通道、SDP/ICE、屏幕/摄像头/麦克风、文件收发
├─ SessionHub.kt        全局单例会话协调器（Activity ↔ Service）
├─ RemoteService.kt     被控端前台服务（mediaProjection|microphone|camera）
├─ InjectorService.kt   无障碍服务：输入事件 → 手势/文本
└─ MainActivity.kt      全部 UI（三屏幕 + 弹窗 + 触摸映射）
```

**签名**：release 默认用 debug 签名，方便直接 `assembleRelease` 出可安装包。
正式分发改 `app/build.gradle.kts` 的 `signingConfigs`（建议用环境变量注入密钥），
`proguard-rules.pro` 已 `keep org.webrtc.**`。

```kotlin
android {
    signingConfigs {
        create("release") {
            storeFile = file(System.getenv("RD_KEYSTORE") ?: "release.keystore")
            storePassword = System.getenv("RD_STORE_PASSWORD") ?: ""
            keyAlias = System.getenv("RD_KEY_ALIAS") ?: "remotedesk"
            keyPassword = System.getenv("RD_KEY_PASSWORD") ?: ""
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
        }
    }
}
```

```bash
keytool -genkeypair -v -keystore release.keystore -alias remotedesk \
  -keyalg RSA -keysize 2048 -validity 10000
```

**Android 语音/摄像头**

1. Manifest 已声明 `RECORD_AUDIO`、`CAMERA`、`MODIFY_AUDIO_SETTINGS`、
   `FOREGROUND_SERVICE_MICROPHONE/CAMERA`
2. 被控端收到 `control_start` 后、拉起 MediaProjection **之前**先申请缺失权限（`Permissions.kt`）
3. `RemoteService` 按「政策位 ∩ 已授权」算前台服务类型；Android 14 声明了类型却没授权会抛
   `SecurityException`，此时自动降级为「只共享屏幕」
4. `App.kt` 必须装 `JavaAudioDeviceModule`，否则 `createAudioSource()` 返回 `null`，远端也不出声

### 7.4 HarmonyOS（ArkTS + ArkWeb）

**前置**：DevEco Studio 5.0.0+、HarmonyOS SDK API 12、Node 18+、华为开发者账号（签名）。

```text
DevEco Studio → Open → harmony → 等 hvigor sync
  → Project Structure → Signing Configs → 勾选 Automatically generate signature
  → Build → Build Hap(s)
产物：entry/build/default/outputs/default/entry-default-signed.hap
```

命令行：`.\scripts\build-harmony.ps1`（自动定位 hvigorw / node / ohpm / SDK），
或 `hdc install entry-default-signed.hap` 装到设备。

**桥接架构**：ArkTS 没有标准 WebRTC API，因此 **ArkTS 负责 UI / 信令 / 文件，
ArkWeb 内的 `rdwebrtc.html` 负责 `RTCPeerConnection`**，通过 `javaScriptProxy` 双向通信，
协议与另两端完全一致。

```
ArkTS 原生层 (Index.ets / Api.ets / Signaling.ets / Files.ets)
        │  runJavaScript("window.RD.signal(...)")  ↓
        │  rdNative.postMessage(JSON)              ↑
ArkWeb 容器 (rawfile/rdwebrtc.html) ── RTCPeerConnection ── WebRTC
```

**工程结构**

```
harmony/
├─ AppScope/app.json5                       bundleName / versionCode / icon / label
├─ build-profile.json5                      signingConfigs / SDK 版本
├─ hvigor/hvigor-config.json5               hvigor 5.0.2 + ohos plugin
└─ entry/src/main/
   ├─ module.json5                          权限、Ability、页面入口
   ├─ ets/
   │  ├─ entryability/EntryAbility.ets      沉浸式深色窗口 + 加载 Index
   │  ├─ pages/Index.ets                    全部 UI 与交互
   │  └─ common/{Types,Prefs,Api,Signaling,Files,Permissions}.ets
   └─ resources/rawfile/rdwebrtc.html        WebRTC 桥接页面（核心）
```

**权限**：`module.json5` 声明 INTERNET / GET_NETWORK_INFO / KEEP_BACKGROUND_RUNNING /
MICROPHONE / CAMERA；麦克风与摄像头由 `Permissions.ets` 运行时申请，
ArkWeb 的媒体访问由 `onPermissionRequest` 按设置开关 `grant` / `deny`。
设置页底部显示「系统权限：麦克风已授权 · 摄像头未授权」，便于判断。

### 7.5 HarmonyOS 的边界与限制

- **只能作控制端**：系统未向第三方应用开放"跨应用注入触摸事件"能力（无 Android
  AccessibilityService 等价物），也没给第三方完整屏幕采集能力。收到 `session_req` /
  `control_start` 会明确提示并自动拒绝。
- **依赖 ArkWeb 内核的 WebRTC**：若某机型内核裁掉了 WebRTC，该机型需改原生 RTC（仓库未含）。
  目前已验证 HarmonyOS NEXT 模拟器与主流真机内核均带 WebRTC。
- **文件接收目录**为沙箱 `filesDir/received`，用 `hdc file recv` 取出，或在文件管理里访问。

### 7.6 打包发布（dist）

三端构建完，用一条命令把产物收进 `dist/`（自动按版本命名、写 `VERSION`、重算 `SHA256SUMS.txt`）：

```powershell
scripts\setup.ps1 -Target all                                        # 先构建
powershell -ExecutionPolicy Bypass -File scripts\package-dist.ps1     # 再打包
```

产物布局：

```
dist/
├─ README.md               发布包说明（怎么跑、版本、校验）
├─ VERSION                 产物版本 / 源码版本 / 打包时间
├─ SHA256SUMS.txt          相对路径校验和（cd dist 后 sha256sum -c 即可）
├─ windows/remotedesk-<版本>-windows-x64.exe
├─ android/remotedesk-<版本>-debug.apk
└─ server/remotedesk-server-{linux-amd64,linux-arm64,darwin-arm64,windows-amd64.exe}
   server/.env.example
```

打包脚本会做**产物新鲜度检查**：exe/apk 早于源码改动时，会列出具体哪些文件更新过，
提醒先重新构建（`-Force` 可跳过）。宁可提示过期，也不把旧二进制标成新版本。

校验：

```bash
cd dist && sha256sum -c SHA256SUMS.txt
```

---

## 8. 服务器部署

### 8.1 一键脚本（推荐）

**前置**：Linux（Ubuntu 20.04+ / Debian 11+ / CentOS Stream 9）、
域名 A 记录指向该 IP（或用 `--ip-only` 免域名）、放行 **80/443** 与 **3478 TCP+UDP**。

```bash
scp -r remotedesk/server root@你的IP:/tmp/remotedesk-server
ssh root@你的IP
cd /tmp/remotedesk-server && chmod +x deploy/install.sh

./deploy/install.sh desk.example.com 1.2.3.4   # ① 域名 + 公网IP（生产，自动 HTTPS）
./deploy/install.sh --ip-only 1.2.3.4          # ② 只有 IP（http://IP:8080）
./deploy/install.sh --local                    # ③ 本机/内网（自动探测内网 IP）
```

脚本会：建 `remotedesk` 系统用户 → 编译（无 Go 自动装 1.23.4）→ 写 `/opt/remotedesk/.env`
（随机 JWT）→ 装 systemd →（① 模式）装 Caddy 自动签证书 → 配防火墙 →
**健康检查并打印客户端地址**。

> `--ip-only` / `--local` 走明文 HTTP：客户端是原生程序，不依赖浏览器安全上下文；
> 媒体仍是 DTLS-SRTP 端到端加密，只是信令没走 TLS。正式对外仍建议上域名。

### 8.2 Docker

```bash
cd server
cp .env.example .env      # 填 RD_DOMAIN / RD_PUBLIC / RD_TURN_RELAY_IP / RD_JWT_SECRET
docker compose up -d --build
```

两个容器都 `network_mode: host`，因为 TURN 的 UDP 端口必须绑到公网网卡，桥接网络下中继连不通。

### 8.3 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `RD_LISTEN` | `:8443` | HTTP 监听（前面挂 Caddy 时保持本机语义即可） |
| `RD_PUBLIC` | 空 | 对外地址，用于拼接 TURN URL |
| `RD_TURN_LISTEN` | `:3478` | TURN 监听 |
| `RD_TURN_RELAY_IP` | 空 | **公网 IP，VPS 必须填**，否则中继不回包 |
| `RD_DB` | `./data/remotedesk.db` | SQLite 路径 |
| `RD_JWT_SECRET` | 空 | JWT 密钥，**生产必填** |
| `RD_TLS` / `RD_CERT` / `RD_KEY` | 关 | 由 Go 自己终结 TLS（默认交给 Caddy） |
| `RD_HEARTBEAT` | `60` | 心跳超时（秒） |
| `RD_LINK_TTL` | `10` | 连接码有效期（分钟） |
| `RD_SMS_PROVIDER` | `mock` | `mock`（打日志）/ `aliyun` / `off`（关闭短信登录） |
| `RD_SMS_SIGN` | 空 | 短信签名，如「远程桌面」（阿里云控制台申请） |
| `RD_SMS_TEMPLATE` | 空 | 模板 CODE，模板正文需含 `${code}` 变量 |
| `RD_SMS_DEV` | `false` | 开发模式：日志打印验证码 + 接口回 `dev_code`（**生产必须关**） |
| `RD_ALIYUN_KEY_ID` | 空 | 阿里云 AccessKeyId（建议 RAM 子账号只授 `dysms:SendSms`） |
| `RD_ALIYUN_KEY_SECRET` | 空 | 阿里云 AccessKeySecret |
| `RD_WECHAT_APP_ID` | 空 | 微信开放平台「网站应用」AppID（填了才开微信登录） |
| `RD_WECHAT_APP_SECRET` | 空 | 微信开放平台 AppSecret |
| `RD_WECHAT_REDIRECT` | 空 | 回调基址，如 `https://rd.example.com`；空则用 `RD_PUBLIC` |
| `RD_AUTH_DEV` | `false` | 开放 `/api/auth/wechat/dev` 模拟扫码（**生产必须关**） |

### 8.4 上线检查

- [ ] `<地址>/healthz` 返回 `ok`
- [ ] `<地址>/version` 返回版本号
- [ ] 防火墙放行 80/443（或 8080）与 3478 TCP+UDP
- [ ] `RD_TURN_RELAY_IP` 是公网 IP（不是内网）
- [ ] `RD_JWT_SECRET` 不是默认值
- [ ] 已设置 `data/remotedesk.db` 的备份

### 8.5 配置登录方式（短信 / 微信）

默认开箱即用：**账号密码 + 短信 mock（验证码打在服务器日志里）**，微信默认关闭。
要上生产按下面配。

#### 8.5.1 短信（阿里云）

1. 阿里云控制台 → 短信服务 → 开通 → 申请**签名**（如「远程桌面」）与**模板**
   （模板正文需含 `${code}`，例如「您的验证码是 ${code}，5 分钟内有效」）
2. RAM 里建一个子账号，只授 `AliyunDysmsFullAccess`（或更细的 `dysms:SendSms`），拿 AccessKey
3. 写进 `/opt/remotedesk/.env`：

```bash
RD_SMS_PROVIDER=aliyun
RD_SMS_SIGN=远程桌面
RD_SMS_TEMPLATE=SMS_123456789
RD_ALIYUN_KEY_ID=LTAI...
RD_ALIYUN_KEY_SECRET=...
RD_SMS_DEV=0
```

4. `systemctl restart remotedesk`，验证：

```bash
curl -s -X POST https://rd.example.com/api/auth/sms/send \
  -H 'Content-Type: application/json' -d '{"phone":"13800138000"}'
# 期望：{"status":"ok","ttl":300,"resend_after":60}   手机应收到短信
```

失败会返回 `502` 并带阿里云错误码（如签名未审核、模板变量不匹配、余额不足），
日志里也有原文：`journalctl -u remotedesk -n 50 --no-pager`。

#### 8.5.2 微信扫码（开放平台网站应用）

1. 注册/登录 [微信开放平台](https://open.weixin.qq.com) → 管理中心 → 创建**网站应用**
   （需要企业主体 + 已备案域名，审核 1~7 天）
2. 记下 `AppID` / `AppSecret`，在应用详情里把**授权回调域**填成你的域名
   （只填域名，如 `rd.example.com`，不要带 `https://` 和路径）
3. 写进 `.env`：

```bash
RD_WECHAT_APP_ID=wx1234567890abcdef
RD_WECHAT_APP_SECRET=...
RD_WECHAT_REDIRECT=https://rd.example.com
RD_AUTH_DEV=0
```

4. 重启后验证「能不能发起」：

```bash
curl -s -X POST https://rd.example.com/api/auth/wechat/url \
  -H 'Content-Type: application/json' -d '{"device_name":"test","os":"windows"}'
# 期望：{"state":"...","url":"https://open.weixin.qq.com/connect/qrconnect?...","expires_in":600}
```

浏览器打开返回的 `url`，扫码后应跳到 `/api/auth/wechat/callback` 并显示「授权成功」，
客户端轮询随即拿到 token。

> 回调地址由服务端拼：`<RD_WECHAT_REDIRECT>/api/auth/wechat/callback`。
> 微信侧只校验**域名**，所以换端口/换路径都不用改开放平台配置。

#### 8.5.3 本地/内网联调（不申请任何账号）

```bash
RD_SMS_PROVIDER=mock RD_SMS_DEV=1 RD_AUTH_DEV=1
RD_WECHAT_APP_ID=wxtest RD_WECHAT_APP_SECRET=test
```

- 短信：接口直接返回 `dev_code`，客户端会自动填入；服务器日志也有
- 微信：登录页会多出「模拟扫码（开发模式）」按钮，点一下等价于"用户已扫码"
- **生产务必把 `RD_SMS_DEV` / `RD_AUTH_DEV` 设为 0**，否则任何人都能伪造登录

### 8.6 部署完成后怎么用（一张清单）

1. `curl https://你的地址/healthz` → `ok`
2. `curl https://你的地址/api/auth/methods` → 看到 `password/sms/wechat` 的启用状态
3. 打开客户端 → 填**同一个服务器地址** → 选一种登录方式进主页
4. 第二台设备（手机/另一台电脑）用**同一账号**登录 → 「我的设备」里出现彼此
5. 点「连接」→ 对方同意 → 看到屏幕、可以操作、可以传文件
6. 需要语音/摄像头：被控端先在设置里打开两项 → 控制端点工具栏「语音 / 摄像头」

---

## 9. 协议规范

所有客户端与服务端严格遵循本协议。改协议先改这一章。

### 9.1 基础

- 服务端地址：`https://<domain>`（客户端可配置）
- REST 基址：`https://<domain>/api`
- 信令 WebSocket：`wss://<domain>/ws`
- 所有 REST 请求/响应均为 JSON，UTF-8
- 鉴权：`Authorization: Bearer <JWT>`

### 9.2 账号与设备

**注册** `POST /api/register`

```json
{ "username": "alice", "password": "secret123", "device_name": "Alice-PC", "os": "windows", "device_id": "<可空>" }
```

响应 `200`：`{ "token": "<JWT>", "user_id": 1, "device_id": "<uuid>", "username": "alice" }`
错误：`409` 用户名已存在；`400` 参数不合法（用户名≥3、密码≥6）。

**登录** `POST /api/login`，请求体同注册（`device_id` 为空则服务端生成新设备）。
同一账号可多设备登录，**每台设备有独立 device_id**（客户端应本地持久化，重复登录复用）。

**设备列表** `GET /api/devices`（需鉴权）

```json
{ "devices": [ { "id": "...", "name": "Alice-PC", "os": "windows", "online": true,
                 "mic_enabled": false, "camera_enabled": false } ] }
```

`mic_enabled` / `camera_enabled` 是设备媒体权限位（见 9.8），控制端可据此在连接前提示
「对方未开放麦克风/摄像头」。

**设置** `GET /api/settings`
→ `{ "auto_accept_same_account": false, "mic_enabled": false, "camera_enabled": false }`

`PUT /api/settings`，字段均可选：

```json
{ "auto_accept_same_account": true, "mic_enabled": false, "camera_enabled": false }
```

#### 9.2.1 登录方式自述

`GET /api/auth/methods`（公开）

```json
{ "password": true,
  "sms":    { "enabled": true, "dev": false, "through": "aliyun" },
  "wechat": { "enabled": true, "dev": false } }
```

客户端据此隐藏未配置的入口（`sms.enabled=false` 就不显示手机登录页）。

#### 9.2.2 手机验证码

**发送** `POST /api/auth/sms/send`

```json
{ "phone": "13800138000" }
```

- `200`：`{ "status":"ok", "ttl":300, "resend_after":60 }`；
  dev 模式额外有 `"dev_code":"123456"`
- `400` 手机号格式不正确（必须 `^1[3-9]\d{9}$`）
- `429` 60 秒内重复发送，带 `Retry-After` 头
- `502` 短信通道发送失败（响应里带服务商错误）
- `503` 服务端关闭了短信登录

**登录/注册** `POST /api/auth/sms/login`

```json
{ "phone": "13800138000", "code": "123456",
  "device_name": "我的手机", "os": "android", "device_id": "<可空>" }
```

成功后响应与 `/api/login` 完全一致（`token / user_id / device_id / username`）。
首次登录自动建号，用户名即手机号。

失败：`400` 未获取/已过期/已使用；`401` 验证码错误（提示剩余次数）；`429` 错误次数超限。

> 安全约束：验证码 6 位、5 分钟有效、**一次使用即作废**、同一手机号最多错 5 次
> （超限需重新获取）；比较用常量时间，防时序侧信道。

#### 9.2.3 微信扫码登录

**① 取授权地址** `POST /api/auth/wechat/url`

```json
{ "device_name": "我的电脑", "os": "windows", "device_id": "<可空>", "redirect_base": "<可选>" }
```

响应：

```json
{ "state": "8f1c...", "url": "https://open.weixin.qq.com/connect/qrconnect?appid=...&redirect_uri=...&state=8f1c...#wechat_redirect",
  "expires_in": 600, "scope": "snsapi_login" }
```

**② 用户在微信里扫码授权** → 微信跳 `GET /api/auth/wechat/callback?code=&state=`，
服务端换取 `openid/unionid`、建号或复用账号、把结果写入 `state`，并返回一个 HTML 提示页。

**③ 客户端轮询** `POST /api/auth/wechat/poll`

```json
{ "state": "8f1c..." }
```

| 响应 `status` | 含义 | 客户端动作 |
| --- | --- | --- |
| `pending` | 还没扫码/没确认 | 继续轮询（建议 2s） |
| `ok` | 成功，附带 `token / user_id / device_id / username` | 直接进主页 |
| `error` | 授权失败，带 `message` | 提示并停止 |
| `expired` | state 超过 10 分钟 | 提示重新发起 |
| `consumed` | 这份 state 已经换过 token | 不再复用（防重放） |

`state` 一次性：`ok` 之后服务端标记 `consumed`，同一 state 再轮询不会再发 token。
鉴权：三个接口都是**公开**的（还没有 token），因此 `state` 由服务端随机生成并限时，不能由客户端指定。

**本地模拟扫码（仅 `RD_AUTH_DEV=1`）** `POST /api/auth/wechat/dev`

```json
{ "state": "8f1c...", "openid": "test-openid", "unionid": "test-unionid" }
```

作用是跳过微信那一步直接置 `ok`，供 e2e 与联调使用；生产环境该接口返回 `403`。

### 9.3 信令 WebSocket

连接 `wss://<domain>/ws`，首帧必须鉴权：

```json
{ "type": "auth", "data": "<JWT>" }
```

成功返回 `{ "type": "auth_ok", "data": { "device_id": "..." } }`

| type | 方向 | 字段 | 说明 |
|---|---|---|---|
| `auth` | C→S | `data`: JWT | 鉴权 |
| `auth_ok` | S→C | `data.device_id` | 鉴权成功 |
| `heartbeat` | C→S | — | 心跳（建议 25s） |
| `offer` | 双向 | `to`,`session_id`,`sdp` | SDP offer |
| `answer` | 双向 | `to`,`session_id`,`sdp` | SDP answer |
| `ice` | 双向 | `to`,`session_id`,`candidate` | ICE candidate |
| `cancel` | 双向 | `to`,`session_id` | 取消控制 |
| `list_devices` | C→S | — | 请求设备列表 |
| `devices` | S→C | `data`: DeviceInfo[] | 设备列表 |
| `session_req` | S→C(被控端) | `session_id`,`from`,`data.{controller_name,auth_mode,media}` | 请求控制，被控端弹窗 |
| `session_ok` | S→C(控制端) | `session_id`,`data.{turn,media}` | 已同意（**仅"需同意"路径推送**） |
| `session_deny` | S→C(控制端) | `session_id` | 被控端拒绝 |
| `control_start` | S→C(被控端) | `session_id`,`from`,`data.{controller_name,turn,media}` | 控制已开始（**必须提示**） |
| `control_end` | 双向 | `session_id` | 控制结束 |
| `error` | S→C | `data.message` | 错误 |

服务器转发 `offer/answer/ice/cancel` 时自动填入 `from`（发送方 device_id）。

### 9.4 建立控制会话

**A. 同账号**：`GET /api/devices` → `POST /api/session/request`

```json
{ "target_device_id": "<被控设备>", "auth": { "mode": "same_account" } }
```

- `auto_accept_same_account=true` → 立即 `active`，被控端收到 `control_start`
- 否则 `pending`，被控端收到 `session_req` 弹窗

**B. 账号密码**：先 `POST /api/session/lookup {username,password}` 拿设备列表，再

```json
{ "target_device_id": "<被控设备>", "auth": { "mode": "account", "username": "...", "password": "..." } }
```

**C. 统一连接码**：被控端 `POST /api/link/create` → `{code, expires_at, ttl_minutes}`；控制端

```json
{ "auth": { "mode": "link", "link_code": "ABCD2345" } }
```

码即授权，立即 `active`。

**会话响应**

- 立即激活（A-auto / C）：
  `{ "session_id": "...", "status": "active", "turn": { "urls": [...], "username": "...", "credential": "..." }, "media": { "mic": false, "camera": false } }`
- 待同意（A-manual / B）：`{ "session_id": "...", "status": "pending", "media": {...} }`（**不含 turn**）

`media` 是**会话建立时刻**的政策快照：`mic` / `camera` 为 true 表示被控端允许控制端接收。
它只是"政策允许"，控制端创建轨道前仍须按 9.5.3 协商；真正的结论由被控端 `media_state` 给出。

> 立即激活时，**控制端从 HTTP 响应取 `turn`**，服务端不额外推 `session_ok`；
> 被控端仍收到 `control_start`（同样带 `turn`），两端 `turn` 内容一致。

**同意/拒绝** `POST /api/session/accept {session_id, accept}`

- 同意：置 active，响应 `{status:"active", turn, media}`，向控制端推 `session_ok`，
  向被控端推 `control_start`
- 拒绝：响应 `{status:"denied"}`，向控制端推 `session_deny`，被控端**不会**收到 `control_start`

**取消** `POST /api/session/cancel {session_id}` → 对端收到 `control_end`。
也可直接发信令 `cancel`。任一端都可调用，服务端不做角色限制。

### 9.5 WebRTC 与数据通道

#### 9.5.1 ICE 配置

用会话下发的 `turn.urls` 作为 `iceServers`（含 `stun:` 与 `turn:`，服务端 3478 端口）；
`turn.username` / `credential` 为临时凭证（30 分钟有效）。

#### 9.5.2 协商流程

1. 控制端创建 `RTCPeerConnection`，创建 `control`/`meta`/`file` 三条 DataChannel，发 `offer`
2. 被控端 `setRemoteDescription` → 添加屏幕视频轨 → 创建 answer → 信令 `answer`
3. 双方通过信令 `ice` 交换 candidate
4. 连接 `connected` 后可开始控制/传输
5. **重协商（v1.02）**：会话中途被控端追加麦克风/摄像头轨道时，由**被控端**再发一次 `offer`，
   控制端按同样流程回 `answer`。控制端**不主动重协商**，避免双方同时 offer（glare）；
   被控端在 `currentRemoteDescription` 就绪前不得发起。

**编码格式（三端统一，务必遵守）**

- `offer`/`answer` 的 `sdp` 字段是 **纯 SDP 文本**（`pc.localDescription.sdp`），
  **不要**再包一层 `JSON.stringify({type,sdp})`
- `ice` 的 `candidate` 字段是 **JSON 字符串**：
  `"{\"candidate\":\"...\",\"sdpMid\":\"0\",\"sdpMLineIndex\":0}"`

#### 9.5.3 语音 / 摄像头协商（`meta` 通道）

WebRTC 会话默认只承载**屏幕视频 + 三条数据通道**。语音与摄像头是按需追加的两条独立轨道：

| 轨道 | 采集方 | 添加到 PeerConnection 的时机 |
|---|---|---|
| 屏幕 | 被控端 | 会话开始即添加 |
| 麦克风 | 被控端 | 收到 `media_req{mic:true}` 且政策位允许 |
| 摄像头 | 被控端 | 收到 `media_req{camera:true}` 且政策位允许 |

控制端**只接收**，不需要自己有麦克风/摄像头设备。

> 轨道类型如何区分？屏幕与摄像头都是 `video`，仅凭 `track.kind` 无法分辨。
> 被控端每添加一路媒体轨，就在 `meta` 通道补一条通告：
> `{"t":"media_track","kind":"camera","id":"<track.id>"}`
> `track.id` 随 SDP 的 msid 传到对端，控制端据此建 `trackId → kind` 映射；
> 收不到通告时按 stream id（`rd-camera`）与 `track.id` 前缀兜底，其余 video 一律当屏幕。

**消息格式**（`meta` 通道，纯 JSON）

控制端 → 被控端：

```json
{"t":"media_req","mic":true,"camera":false}
```

被控端 → 控制端（**每次状态变化都发**：首次打开、关闭、失败）：

```json
{"t":"media_state","mic":true,"camera":false,"mic_on":true,"cam_on":false,"reason":""}
```

| 字段 | 含义 |
|---|---|
| `mic` / `camera` | 被控端**政策**是否允许（对应设置位） |
| `mic_on` / `cam_on` | 被控端**实际**是否有活动轨道 |
| `reason` | 不可用原因，空串表示正常 |

`reason` 取值（三端一致，可直接展示）：`policy_off` / `permission_denied` /
`no_device` / `busy` / `unsupported`。

**时序**

```
控制端                                     被控端
  │── media_req{mic:true} ───────────────►│ 1. 校验政策位
  │                                        │ 2. 申请/检查系统权限
  │                                        │ 3. getUserMedia / AudioSource+CameraCapturer
  │◄─ media_state{mic:true,mic_on:true} ───┤ 4a. 成功，addTrack
  │◄─ media_state{mic:true,mic_on:false,reason:"busy"} ─┤ 4b. 失败，附原因
```

- 被控端**也允许**在没有 `media_req` 时主动发 `media_state`（用户在被控横幅上直接关麦）。
  控制端必须把它视为最终状态并刷新 UI。
- 政策位为 false 时收到 `media_req` 必须回 `media_state{reason:"policy_off"}`，
  不得静默忽略（否则控制端会一直转圈）。

**轨道生命周期**

- **关闭**用 `replaceTrack(null)` / `setEnabled(false)`，**不要** `removeTrack` —— 保留 m-line，
  重新打开时立刻恢复，无需重新协商。
- 会话结束时被控端必须停止所有本地采集，麦克风/摄像头指示灯要熄灭。
- 音频只在控制端播放，默认不静音；控制端可"静音对方声音"（纯本地行为，不发消息）。

#### 9.5.4 数据通道

| label | 方向 | 承载内容 |
|---|---|---|
| `control` | 控制端→被控端 | **仅**输入事件 JSON（9.6） |
| `meta` | 双向 | **仅** JSON：文件控制帧、画面尺寸、媒体协商 |
| `file` | 双向 | **仅**二进制块（不带任何 JSON） |

> 三条通道职责严格分离。原因：Android 的 `DataChannel.Buffer` 只有 `binary` 标志，
> 无法区分「小体积 JSON」与「小体积二进制块」（例如传一个 300 字节的 .json 文件会被误判）。
> 混在一条通道还会互相阻塞：传大文件时鼠标事件排在 48KB 块后面，操作延迟肉眼可见。

#### 9.5.5 画面尺寸同步

被控端在 `meta` open 时、采集启动/分辨率变化时发送：

```json
{"t":"screen","w":1920,"h":1080}
```

控制端据此把 0..1 归一化坐标还原成像素（配合视频显示区域做 letterbox 反算）；
未收到时可按 `videoWidth/videoHeight` 兜底。

### 9.6 远程输入事件（`control` 通道，JSON 文本）

坐标统一 **0..1 归一化**（相对被控屏幕），与分辨率无关。

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

`button`：0=左键，1=中键，2=右键。

### 9.7 文件传输（`meta` 控制帧 + `file` 二进制块）

同一时刻一个通道传输一个文件。

1. 发送端 `meta`：`{"t":"file_offer","id":"<uuid>","name":"报告.pdf","size":123456,"dir":""}`
2. 接收端 `meta` 回 `{"t":"file_accept","id":"<uuid>"}` 或 `file_reject`
3. 发送端在 `file` 通道连续发块（每块 ≤ 64KB，保序）
4. `meta`：`{"t":"file_done","id":"<uuid>"}`
5. 接收端校验后 `meta` 回 `{"t":"file_ack","id":"<uuid>","ok":true}`

实现约定：

- 发送端每块建议 48KB；`bufferedAmount` 超阈值（1~2MB）时暂停等 `bufferedamountlow`
- 接收端按块顺序 **seek + write**，天然支持断点与乱序补偿
- 接收目录：Windows `下载\remotedesk-received`；Android 应用外部私有目录
  `remotedesk-received`；HarmonyOS `filesDir/received`。重名自动追加 ` (n)`
- 可选进度：`meta` 上 `{"t":"file_progress","id":"...","received":102400}`

### 9.8 控制提示与权限

- 被控端在会话进入 active 时**必须**弹出「正在被 X 控制」提示窗，提供「取消控制」按钮
- 「取消控制」调用 `POST /api/session/cancel` 并关闭本地连接
- 麦克风/摄像头**默认关闭**；被控端在设置里开启后才允许，权限位按设备持久化
- 权限位随会话下发（9.4 `media`），运行期用 `media_req` / `media_state` 协商（9.5.3）
- 控制端**不得绕过**政策位：即使设置里关闭，也不得先 `getUserMedia` 再静默丢弃
- 被控端可随时一键关闭麦克风/摄像头（横幅按钮），此时必须**立刻停止采集**并发 `media_state`
- 被控端可随时在提示窗或托盘退出控制

### 9.9 错误码

| HTTP | 含义 |
|---|---|
| 400 | 参数错误 |
| 401 | 未鉴权/凭证错误 |
| 403 | 无权操作该会话 |
| 404 | 目标不存在/链接失效 |
| 409 | 用户名已存在 / 目标离线 / 会话已处理 |
| 500 | 服务端错误 |

---

## 10. 架构设计

本章说明系统为什么这样设计、关键取舍在哪、出问题该看哪一层。

### 10.1 总体拓扑

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
        └──────────── WebRTC（P2P 直连 / TURN 中继，DTLS-SRTP 加密）──────┘
```

**关键点：媒体流与文件内容永远不经过服务器。** 服务器只做三件事：

1. **账号与设备目录** —— 谁在线、属于哪个账号、有哪些权限位
2. **信令交换** —— 帮两端交换 SDP 与 ICE candidate，然后退场
3. **TURN 中继** —— 仅在 NAT 打洞失败（对称 NAT、双 4G）时兜底转发加密字节流

因此服务器是**低带宽**的：1000 个在线会话的服务器，真正需要中继的可能只有几十个。

### 10.2 为什么选 WebRTC

| 方案 | 优点 | 缺点 | 结论 |
| --- | --- | --- | --- |
| **WebRTC** | 三端都有成熟实现；自带丢包重传/拥塞控制/NAT 穿透/DTLS 加密；TURN 生态成熟 | 信令要自己写；三端 API 差异大 | ✅ 采用 |
| 自研 TCP 流 + H.264 | 完全可控 | NAT 穿透要自建、弱网体验差、要自己实现拥塞控制 | ❌ |
| VNC/RFB | 成熟、简单 | 只适合局域网；公网要自己套 TLS 和穿透 | ❌ |
| 服务器中转（像免费版远控） | 实现简单 | 带宽成本爆炸，1080p 一小时几十 GB | ❌ |

WebRTC 的**数据通道**顺带解决了文件传输（不需要另开端口，也不需要额外鉴权——
通道本身就活在同一条已加密的 P2P 连接里）。

### 10.3 三种连接方式的授权模型

三种方式的差别**只在"谁批准了这次连接"**，批准之后走完全同一条链路。

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

### 10.4 "免同意"与"控制提示"是两件事

| | 免同意（`auto_accept_same_account`） | 控制提示（协议强制） |
| --- | --- | --- |
| 是什么 | 被控端**不弹确认框**直接连上 | 连上之后**必须显示**"正在被 X 控制"横幅 |
| 在哪实现 | 服务端 `handleSessionRequest` 的 `autoAccept` 分支 | 客户端 UI + `control_start` 消息 |
| 能不能关 | 用户可以开/关 | **不能关**，协议强制项 |
| 目的 | 省掉每次点"同意" | 让用户随时知道自己在被看着，并能一键断开 |

所以即使用户开了"免同意"，被控端依然会收到 `control_start` 并显示横幅与取消按钮。

### 10.5 三条数据通道为什么必须分开

WebRTC 的 DataChannel 默认 `ordered: true`，不同类型数据混在一条通道会互相阻塞：

```
错误做法：一条通道混发
  [输入事件 20B][文件块 48KB][输入事件 20B][文件块 48KB]...
  → 传大文件时，鼠标事件排在 48KB 块后面，操作延迟肉眼可见

正确做法：三条独立通道
  control: [鼠标][鼠标][键盘]...        ← 永远不排队
  meta:    [file_offer][screen]...      ← 小 JSON，不排队
  file:    [48KB][48KB][48KB]...        ← 慢慢传，独占
```

另一个原因是**接收端无法可靠区分 JSON 与二进制**（见 9.5.4）。

### 10.6 被控端的采集路径

| 端 | 采集方式 | 编码 | 送进 WebRTC 的方式 |
| --- | --- | --- | --- |
| Windows | Rust `xcap` 抓屏 | JPEG q70 | Tauri 事件 → canvas → `captureStream(15)` |
| Android | `MediaProjection` + `ScreenCapturerAndroid` | WebRTC 自带 | 直接 `VideoSource` → `VideoTrack` |
| HarmonyOS | ArkWeb 内 `canvas`（由原生喂帧） | JPEG | `captureStream` |

**Windows 为什么绕一圈？** WebView2 的 `getDisplayMedia` 需要额外 picker 权限配置且跨版本行为
不一致。Rust 抓屏行为可预测，代价是多一次 JPEG 编解码（1080p 单帧约 8~15ms）。

**Android 为什么用原生？** `ScreenCapturerAndroid` 是 WebRTC 官方实现，直接产出 YUV 帧交给编码器，
无中间编解码损耗，是三者中最优。

### 10.7 输入注入（被控端能力）

| 端 | 机制 | 权限要求 |
| --- | --- | --- |
| Windows | `enigo` 调 `SendInput` | 普通用户权限 |
| Android | `AccessibilityService.dispatchGesture` | 用户手动开启无障碍 |
| HarmonyOS | ❌ 系统未开放 | 无 |

Android 手势注入有两个坑，都在 `InjectorService.kt` 处理了：

1. **`dispatchGesture` 不能并发** —— 用 `AtomicBoolean busy` 串行化，在 `GestureResultCallback`
   回调里才释放
2. **拖拽必须用 `continueStroke`** —— 每次新建 `StrokeDescription` 会把手势切成多段、被识别成
   多次点击；正确做法是 `prev.continueStroke(...)` 续接，最后一段 `willContinue=false` 收尾

### 10.8 数据存储

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
- **不存任何画面、输入、文件内容**

### 10.9 一次完整连接的时序

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
  │  media_state ◄─────────────────────────────────────────┤ 语音/摄像头
  │                          │                             │
  ├─ POST /api/session/cancel ─►                            │
  │                          ├─ WS: control_end ──────────►│
  │◄─ 200 {status:"ended"} ──┤                             │
```

注意 **WebRTC 建立之后，服务器就退出了数据路径**。会话记录只用于事后审计与超时清理。

### 10.10 可靠性设计

| 场景 | 处理 |
| --- | --- |
| WebSocket 断线 | 客户端指数退避重连（800ms×2ⁿ，上限 15s），重连后首帧重新鉴权 |
| 同 device_id 重复登录 | Hub 踢掉旧连接，保证一个设备只有一条有效信令通道 |
| 心跳丢失 | 服务端读超时 120s 判定离线；客户端 25s 主动 ping |
| TURN 启动失败 | **不阻断服务**，降级为纯 P2P |
| 长时间无操作 | TURN 凭证 30 分钟过期，后台每 30s 清理过期凭证 |
| 连接码泄露 | 一次性 + 10 分钟 TTL，用后即焚 |
| 服务重启 | SQLite 持久化；在线状态丢失但会话记录保留 |
| 进程退出 | 监听 SIGINT/SIGTERM，5 秒优雅关闭 |

### 10.11 扩展点

1. **换中继**：`internal/relay/relay.go` 的 `Issue/Revoke` 接口不变即可换 coturn
2. **加录制**：客户端 `PeerSession`/`RtcClient` 挂 `MediaRecorder` 或 `VideoFileRenderer`，服务端不动
3. **加中继鉴权策略**：`internal/api/handlers.go` 的 `turnConfigForSession` 是唯一签发点
4. **换数据库**：`internal/store/store.go` 是唯一 SQL 出入口，换 Postgres 只改这个文件
5. **加端**：照第 9 章实现即可，协议里没有平台相关的东西

### 10.12 语音 / 摄像头链路设计

**为什么是三层权限而不是一个开关**：见 [6.2](#62-语音与摄像头三层权限)。

**为什么轨道要重协商，而不是一开始全开**

1. **隐私**：用户没点「语音」时就在采集，指示灯亮着
2. **浪费**：大多数会话只共享屏幕

所以设计成「按需 addTrack」→ 触发一次**被控端发起的**重协商。为避免双方同时 offer（glare），
约定只有被控端主动重协商，控制端永远只应答。

**关闭为什么用 `replaceTrack(null)` 而不是 `removeTrack`**：`removeTrack` 会把 m-line 变
`a=inactive` 并**再触发一次重协商**；`replaceTrack(null)` 只是不再发 RTP，m-line 保持，
重新打开时立即恢复。只有真要释放设备（Android 上必须 dispose 才能熄灭指示灯）时才
removeTrack + 重协商。

**三端各自的坑**

| 端 | 坑 | 处理 |
| --- | --- | --- |
| Android | 没有 `JavaAudioDeviceModule` 时 `createAudioSource()` 返回 null，远端也不出声 | `App.kt` 装 ADM（硬件 AEC/NS） |
| Android 14 | 前台服务必须声明 `microphone`/`camera` 且权限已授予，否则 `startForeground` 抛异常 | 按「政策位 ∩ 已授权」算类型掩码，失败降级只共享屏幕 |
| Windows | 隐私设置关掉时 WebView2 只报含糊的 `NotReadableError` | Rust 读注册表 `ConsentStore\{webcam,microphone}\NonPackaged` 诊断 + `ms-settings:` 深链 |
| 全部 | 两路 video（屏幕 + 摄像头）无法用 `kind` 区分 | 被控端发 `media_track{kind,id}`，控制端建 `trackId→kind` 映射，并用 stream id `rd-camera` 兜底 |
| 全部 | `<video muted>` 会吞掉远端声音 | 控制端单独建 `<audio>` 承接音频轨 |

### 10.13 已知限制（如实列出）

| 限制 | 影响 | 缓解 |
| --- | --- | --- |
| HarmonyOS 不能作被控端 | 鸿蒙手机不能被远程操作 | 系统限制，无 workaround |
| Windows 采集是 JPEG 帧中转 | 高帧率下 CPU 占用偏高 | 可换 H.264 硬编（接口已留） |
| 仅一路麦克风 + 一路摄像头 | 不能选设备、不能多摄像头切换 | `getUserMedia` 的 `deviceId` 加选择器即可，协议不变 |
| 单服务器单机 SQLite | 十万级用户会遇到写瓶颈 | 换 Postgres（`store.go` 单点替换） |
| 信令无消息队列 | 服务器重启时在线会话全断 | 客户端自动重连，用户无感 |
| 无 Web 管理后台 | 只能命令行部署与查看 | 可直接读 SQLite |
| 无自动更新 | 客户端要手动升级 | 可接 Tauri updater / 应用商店 |
| HarmonyOS 工程未在本机编译验证 | `.hap` 需用户侧构建；ArkTS 按 API 12 静态编写 | 导入 DevEco 后按提示修语法 |
| 没有 macOS / Linux 客户端 | 只能被 Windows / Android 控制 | 服务端产物已覆盖 linux/darwin，可复用 Tauri 前端 |
| Windows 客户端未做代码签名 | 首次运行 SmartScreen 会拦一次 | 买证书 `signtool` 签名 |
| 部分厂商 ROM 限制无障碍服务 | 这些机型无法注入输入 | 引导开"自启动"并放行电池优化 |

---

## 11. 排错手册

### 11.1 通用

**连上了但画面全黑 / 一直转圈？**
多半是 TURN 没配好。检查 `RD_TURN_RELAY_IP` 是否填了**公网 IP**、云厂商安全组是否放行
3478 TCP+UDP、`RD_PUBLIC` 是否正确。P2P 能通时不需要 TURN，对称 NAT / 4G 下必须靠它。

**登录提示网络错误？**
地址要带协议：`http://192.168.1.23:8443` 或 `https://desk.example.com`，不要只填 IP。

**能不能不用域名？**
可以，`install.sh --ip-only <IP>` 走 `http://IP:8080`；本地用 `--local`。

**跑 `.ps1` 报"未对文件进行数字签名 / 无法加载脚本"？**

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\smoke.ps1   # 单次绕过
Unblock-File .\scripts\*.ps1                                   # 解除下载锁定
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass     # 仅当前窗口
```

脚本带 UTF-8 BOM，Windows PowerShell 5.1 与 PowerShell 7 都能正确读中文提示。

**数据存在哪？**
服务器只有 `users / devices / sessions / links` 四张表（v1.03 增加了 `sms_codes` 与 `auth_states`），
**不存画面、输入或文件内容**。

**手机验证码收不到？**
① `curl /api/auth/methods` 看 `sms.enabled` 是否为 true；② 看服务器日志里有没有
`sms/mock` 或阿里云返回的错误码（签名未审核 / 模板变量不匹配 / 余额不足）；
③ 同一手机号 60 秒内只能发一次，接口会返回 `429` + `Retry-After`。

**微信登录入口没出现？**
服务端没配 `RD_WECHAT_APP_ID` / `RD_WECHAT_APP_SECRET` 时，`/api/auth/methods` 返回
`wechat.enabled=false`，客户端会自动隐藏该标签页。

**微信扫码成功但客户端一直转圈？**
① 微信开放平台的**授权回调域**必须与 `RD_WECHAT_REDIRECT` 的域名一致（只填域名）；
② 确认服务端能访问 `api.weixin.qq.com`（国内服务器正常，海外可能超时）；
③ 二维码 10 分钟过期，超时重新点一次即可。

**点了「语音 / 摄像头」没反应？**
看控制端工具栏右侧状态文字，它直接写原因（对照 [6.2 的 reason 表](#62-语音与摄像头三层权限)）。

### 11.2 Windows

| 现象 | 原因 / 处理 |
| --- | --- |
| `failed to run custom build command for ...-sys` | `rustup update stable`，Tauri 依赖树更新快 |
| `error: linker 'link.exe' not found` | 没装 MSVC 工具链，或不在 VS 开发者环境 |
| `linking failed: 找不到 kernel32.lib` | 缺 Windows SDK，VS Installer 勾 "Windows 11 SDK" |
| `xcap` / `enigo` 方法不存在 | 版本迭代快，按报错微调 `capture.rs` / `input.rs` 调用，结构不用动 |
| 界面白屏 | WebView2 运行时缺失，或没先 `npm run build`（`tauri build` 会自动跑） |
| 被控端画面黑但连接正常 | RDP 会话锁屏/最小化时抓屏全黑；或多显示器抓了不存在的索引 |
| 杀软报毒 | 未签名 + 能模拟键鼠，正式分发建议买证书配置 `certificateThumbprint` |
| 语音/摄像头拿不到 | 先看首页自检卡片：政策、系统隐私、设备数三项 |
| 启动即崩：`failed to create webview: WebView2 error: WindowsError(0x800700AA)` | 同一用户数据目录被占用（另一个实例还开着 / 杀软锁定 / 受限账户目录不可写）。关掉已有实例；或设 `WEBVIEW2_USER_DATA_FOLDER` 指向可写目录再启动 |
| `LNK1104: 无法打开文件 ...\Temp\lnk{...}.tmp` | 临时目录不可写，把 `TMP`/`TEMP` 指向项目内目录后重跑 cargo |

MSVC 头文件/库找不到时，用
`cmd /c ""...\VsDevCmd.bat" -arch=amd64 && npm run tauri build"`，
或直接开 "x64 Native Tools Command Prompt for VS 2022"。

### 11.3 Android

| 现象 | 原因 / 处理 |
| --- | --- |
| `project path contains non-ASCII characters` | `gradle.properties` 已加 `android.overridePathCheck=true`；介意就挪到纯英文路径 |
| `Could not resolve io.github.webrtc-sdk:android` | 已配阿里云镜像 + `mavenCentral()`；公司网络用 `~/.gradle/init.gradle` |
| 首次构建卡 Download | 要下 ~200MB 依赖，镜像已放最前 |
| 装上闪退 | `adb logcat \| findstr remotedesk`；多为 native so 与 ABI 不匹配 |
| 被控端有画面但点不动 | 无障碍服务没开（应用内提示可直达设置） |
| 华为/小米后台一会儿就断 | 系统杀进程，需给"自启动/后台活动"，EMUI 还要关自动管理 |
| 语音没声音 | ① 设置开关 ② 系统权限 ③ 是否被其它应用独占 |
| 摄像头黑屏 | Android 14 前台服务类型是否含 `camera`（本版自动追加）；相机是否被占用 |
| 关麦后指示灯还亮 | 本版已 `dispose()` 音频源/采集器，若仍亮说明其它应用占用 |

### 11.4 HarmonyOS

| 现象 | 原因 / 处理 |
| --- | --- |
| hvigor sync 失败 | 确认 DevEco 5.0+ 与 SDK API 12 已装，网络能到华为仓库 |
| 构建报签名错误 | Project Structure → Signing Configs → 登录华为账号后勾自动签名 |
| 页面白屏 / 无 WebRTC | 目标机型 ArkWeb 内核可能裁掉了 WebRTC，需改原生 RTC（仓库未含） |
| 听不到对方声音 | 设置里「允许传输语音」是否开、系统权限是否授予、`onPermissionRequest` 是否放行 |

---

## 12. 安全说明

- 信令与控制通道：WebRTC **DTLS-SRTP 加密**，服务器无法解密媒体流
- 信令 WebSocket：WSS（TLS 1.2+，Caddy 自动续期证书）；纯 IP 模式为 WS（内网/测试）
- 账号密码：bcrypt 哈希存储，登录态用 HS256 JWT（默认 24h）
- TURN 凭证：**每会话单独签发，30 分钟过期**，随会话结束失效
- 连接码：一次性、10 分钟过期、去除 `0/O/1/I` 等易混字符
- 权限最小化：麦克风/摄像头默认关闭，需被控端设置显式开启；控制端**无法绕过**政策位
- 媒体放设备：会话结束 / 关闭某一路时立即 `stop()` 采集，系统指示灯熄灭
- TURN 凭证签发集中在 `turnConfigForSession`，便于加策略

---

## 13. 版本记录

### 13.1 v1.03（应用版本 1.3.0）· 2026-10-31

主题：**三种登录方式**（密码 / 手机验证码 / 微信扫码），并把部署后的配置与使用写清楚。

**新增：手机验证码登录**

- 接口：`/api/auth/sms/send`、`/api/auth/sms/login`
- 6 位验证码、5 分钟有效、一次性；同一手机号 60 秒限流、错 5 次作废（常量时间比较）
- 首次登录自动建号（用户名 = 手机号），后续复用同一 `user_id`
- 短信通道抽象成 `internal/sms`：`mock`（日志）/ `aliyun`（RPC 签名，无 SDK 依赖）/ `off`
- `dev_code`：`RD_SMS_DEV=1` 时把验证码回给客户端，客户端自动填入

**新增：微信扫码登录**

- 接口：`/api/auth/wechat/url`、`/callback`、`/poll`、`/dev`（仅 `RD_AUTH_DEV=1`）
- 开放平台「网站应用」OAuth2（`snsapi_login`），服务端换 `openid/unionid`，
  按 unionid 兜底匹配已有账号，没有就自动建号（用户名 `wx_xxxxx`）
- `state` 一次性 + 10 分钟 TTL；`ok` 之后标 `consumed`，同一 state 不再发 token
- 客户端打开系统浏览器授权 + 2 秒轮询，扫完自动进主页；dev 模式可一键模拟扫码
- Windows 新增 Rust 命令 `open_url`（只放行 http/https），不引入新依赖

**新增：登录方式自述**

- `GET /api/auth/methods` 告诉客户端哪些方式可用（含 dev 标记），未配置的入口自动隐藏
- 三端登录页统一改成三个标签：账号密码 / 手机验证码 / 微信登录

**客户端（本次一并重编）**

- Windows：`npx tauri build --no-bundle` 通过，EXE 为 1.3.0；新增 Rust 命令 `open_url`（仅 http/https）
- Android：`gradle assembleDebug` 通过，APK 为 1.3.0（versionCode 3）；登录页三标签 +
  运行时申请麦克风/摄像头；修掉两处编译错误（`${what}` 模板、`MediaStream.getId()`）
- HarmonyOS：界面与协议同步到 1.3.0，需 DevEco Studio 编译
- `dist/` 更新为**三端统一 1.3.0**：4 平台服务端 + Windows EXE + Android APK，
  `VERSION` 与 `SHA256SUMS.txt`（9 个文件）重新生成并校验通过

**数据库**

- `users` 新增 `phone` / `wechat_openid` / `wechat_unionid`（老库自动 `ALTER TABLE` 补列，
  唯一索引用 NULL 语义，未绑定用户不冲突）
- 新增 `sms_codes`（验证码）与 `auth_states`（扫码登录状态）两张表，启动时清理过期记录

**验证状态**

| 项 | 命令 | 结果 |
| --- | --- | --- |
| 服务器编译 | `go build ./...` | 通过 |
| 服务器静态检查 | `go vet ./...` | 零警告 |
| 服务器单测 | `go test ./...` | `auth` / `link` / `sms` / `wechat` 全部通过 |
| 端到端 | `node scripts/e2e-test.mjs` | **全部用例通过**（含新增 17 项登录断言 + 11 项媒体断言） |
| Windows 前端 | `npx vite build` | 通过（11 modules，bundle 64.8 kB） |
| Windows 客户端 | `npx tauri build --no-bundle` | `Finished release profile`，产出 `remotedesk.exe`（6.1 MB） |
| Windows 启动 | 直接运行 `remotedesk.exe` | 进程正常常驻（43 MB），无崩溃 |
| Android 客户端 | `gradle assembleDebug` | `BUILD SUCCESSFUL`，`versionName=1.3.0`，`app-debug.apk` 47.3 MB |
| 发布包实测 | 直接启动 `dist/server/remotedesk-server-*.exe` 跑 e2e | `/version` → `1.3.0`，**全部用例通过** |
| 发布包校验 | `cd dist && sha256sum -c SHA256SUMS.txt` | 9 个文件全部 OK |
| 静态检查 | XML / JSON / 括号配平 | 通过 |

**未验证**：HarmonyOS 端未编译——需要 DevEco Studio 的 hvigor 工具链，本机没有；
源码与三端保持同一套协议与界面，装好 DevEco 后跑 `scripts\build-harmony.ps1` 即可。

> 踩到的两个真实编译错误（已修，供参考）：Kotlin 里 `"$what正被..."` 会把中文当成标识符的一部分，
> 必须写 `${what}`；`org.webrtc.MediaStream` 的 id 取值是 `getId()` 而不是 `id()`。

### 13.2 v1.02（应用版本 1.2.0）· 2026-10-31

主题：**把「语音 / 摄像头」从开关变成真的能用**，同时把部署与上手压到「一条命令」。

**新增：语音与摄像头完整链路**

- 协议：会话响应 / `session_req` / `session_ok` / `control_start` 增加 `media{mic,camera}`；
  设备列表增加两个权限位；`meta` 通道新增 `media_req` / `media_state` / `media_track`；
  reason 统一为 `policy_off` / `permission_denied` / `no_device` / `busy` / `unsupported`；
  新增"被控端发起重协商"约定
- 服务端：`signaling.MediaPolicy`、`activateSession(sess, media)`、`api.mediaPolicy()`；
  e2e 增加 11 项断言
- Windows：`src/media.js`（纯逻辑 + 24 项单测）、`session.js` 按需开麦/开摄像头与重协商、
  工具栏三按钮 + 画中画 + 权限弹窗、`media.rs` 隐私诊断与 `ms-settings:` 深链、
  首页自检卡片与最近连接
- Android：`JavaAudioDeviceModule`、`Permissions.kt`、`AudioSource` + `Camera2Enumerator`、
  前台服务类型按权限裁剪、媒体按钮与被控横幅开关、失败弹窗
- HarmonyOS：`Permissions.ets`、`onPermissionRequest` 授权、独立 `<audio>` + 画中画、
  媒体按钮与状态文字

**新增：部署与使用更省事**

- `scripts/quickstart.ps1`：本机一条命令起服务器（生成 `.env`、随机 JWT、探测内网 IP、
  健康检查、打印客户端地址、`-Stop`）
- `scripts/setup.ps1`：环境体检 + 一键构建，缺工具只跳过对应端
- `install.sh` 三种模式：域名 / `--ip-only` / `--local`，安装后自动健康检查
- Windows 客户端：最近连接一键重连、设备列表标注对方媒体能力、登录页本地测试提示
- 文档合并为单一 `README.md`（本文件）
- `dist/` 发布包整理：`README.md`（使用说明）、`VERSION`（产物版本 vs 源码版本）、
  相对路径 `SHA256SUMS.txt`（9 个文件全部校验通过）、`server/.env.example`
- 新增 `scripts/package-dist.ps1`：一条命令归位 / 命名 / 写版本 / 重算校验和，
  并带「产物早于源码」的新鲜度检查

**兼容性**

- 新字段全部可选：旧客户端连新服务器、新客户端连旧服务器都不会崩
- 数据表结构未变（`mic_enabled` / `camera_enabled` 早已存在），无需迁移

**验证状态**

| 项 | 命令 | 结果 |
| --- | --- | --- |
| 媒体逻辑单测 | `node scripts/media-policy.test.mjs` | 24 项全部通过 |
| Windows 前端构建 | `npx vite build`（windows/） | 11 modules，bundle 57.9 kB（模块解析无误） |
| Windows 前端语法 | `node --check windows/src/*.js` | 通过 |
| HarmonyOS 页面脚本 | 抽取 `<script>` → `node --check` | 通过 |
| Android XML | `xml.etree` 解析 | 通过 |
| Kotlin / ArkTS / Go 结构 | 括号配平 | 通过 |
| 部署脚本 | `bash -n install.sh` | 通过 |
| PowerShell 脚本 | `Parser::ParseFile` | 通过 |

**未能在本机验证**：本机没有 Go / Rust / JDK，`go vet`、`go test`、`e2e-test.mjs`、三端编译未重跑。
合入前请在具备工具链的环境执行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\smoke.ps1        # 服务器编译 + e2e
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -Target all
```

**已知问题**：只支持一路麦克风 + 一路摄像头；Windows 媒体仍受系统隐私策略约束；
HarmonyOS 仅作控制端，其媒体开关只影响 ArkWeb 授权策略。

### 13.3 v1.01 · 2026-10-30

- 三端远程桌面打通：屏幕采集、输入注入、文件双向传输
- 三种连接方式（同账号 / 账号密码 / 统一连接码）
- 语音·摄像头仅有权限开关（**未实现音视频链路**）
- 服务器一键部署（systemd + Caddy / Docker），e2e 覆盖 10 组断言

---

## 14. 开发与测试

```bash
# 服务器本地跑起来
cd server
go mod tidy
go run .                     # 默认 :8443，数据在 ./data

# 端到端测试（需先起服务器）
node scripts/e2e-test.mjs http://127.0.0.1:8443

# 媒体逻辑单测
node scripts/media-policy.test.mjs

# 一键：编译服务器 + 起临时实例 + 跑 e2e
powershell -ExecutionPolicy Bypass -File scripts\smoke.ps1
```

e2e 覆盖：注册 / 多设备 / 密码错误 401 / 目标离线 409 / 双端 JWT 鉴权 / 账号密码
pending→弹窗→同意→active / 拒绝→denied / SDP 与 ICE 中继转发 / 任一端 cancel /
连接码一次性 / 同账号免同意开关 / 免同意也仍推控制提示 / 越权与参数校验 /
媒体权限位下发与随设置变化 / **手机验证码（格式校验、限流、错码、一次性、幂等建号）/
微信扫码（授权地址、pending→ok、state 一次性、重复登录复用账号）**。

---

## 15. License

MIT
