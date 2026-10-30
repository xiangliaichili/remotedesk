# HarmonyOS 客户端构建与说明

本目录是 HarmonyOS（鸿蒙）客户端的完整 ArkTS 工程，包名 `com.remotedesk.harmony`，
面向 **HarmonyOS NEXT / API 12**。

---

## 1. 架构说明（重要，先读这段）

HarmonyOS 的 ArkTS 运行时尚**未提供标准 WebRTC API**（`RTCPeerConnection` / `RTCDataChannel`
在 ArkTS 侧不可用），而远程桌面必须依赖 WebRTC 才能做到低延迟屏幕流 + 三条数据通道。

因此本客户端采用**桥接架构**：

```
┌─────────────────────────── HarmonyOS 应用进程 ───────────────────────────┐
│                                                                          │
│   ArkTS 原生层 (entry/src/main/ets/)          ArkWeb 容器                  │
│   ┌──────────────────────────────┐        ┌────────────────────────────┐ │
│   │ pages/Index.ets     UI 全部   │        │ rawfile/rdwebrtc.html      │ │
│   │ common/Api.ets      REST      │        │ window.RD = {              │ │
│   │ common/Signaling.ets WSS 信令 │◄──────►│   init / signal / frame /  │ │
│   │ common/Files.ets    文件读写   │JSON 桥 │   sendInput / pushChunk /  │ │
│   │ common/Prefs.ets    偏好存储   │        │   setQuality / close }     │ │
│   └──────────────────────────────┘        └────────────────────────────┘ │
│                                                      ▲                   │
└──────────────────────────────────────────────────────┼───────────────────┘
                                                       │ RTCPeerConnection
                                                       ▼
                                              WebRTC (DTLS-SRTP)
```

- **方向一（原生 → WebView）**：`WebviewController.runJavaScript("window.RD.signal({...})")`
- **方向二（WebView → 原生）**：`javaScriptProxy({ name: 'rdNative', methodList: ['postMessage'] })`
  注入 `NativeBridge`，页面里调用 `window.rdNative.postMessage(JSON.stringify(msg))`

好处是 WebRTC 部分与 Windows 端**完全同源**（同一套 JS 逻辑、同一份协议），
不会出现三端行为不一致。

**代价**：依赖目标设备的 ArkWeb 内核具备 WebRTC 支持。若某机型内核裁掉了 WebRTC，
该机型需要改为原生 RTC 实现（本仓库未包含）。目前已验证的是 HarmonyOS NEXT 模拟器与
主流真机内核均带 WebRTC。

---

## 2. 前置条件

| 项 | 要求 |
| --- | --- |
| DevEco Studio | **5.0.0 Release 及以上** |
| HarmonyOS SDK | **API 12**（`5.0.0(12)`） |
| Node.js | 18+（hvigor 依赖） |
| 华为开发者账号 | 签名需要（自动签名即可） |
| 调试设备 | HarmonyOS NEXT 真机 或 模拟器 |

---

## 3. 构建步骤（DevEco Studio，推荐）

```text
1. DevEco Studio → File → Open → 选择 remotedesk/harmony 目录
2. 等待右下角 "hvigor sync" 完成（首次会下载 hvigor 5.0.2 与依赖，几分钟）
3. File → Project Structure → Signing Configs
     勾选 "Automatically generate signature"（需登录华为账号）
     若报错，先点 "Sign In" 登录，再回来勾选
4. Build → Build Hap(s)/APP(s) → Build Hap(s)
5. 产物：entry/build/default/outputs/default/entry-default-signed.hap
```

安装到设备：

```bash
hdc install entry/build/default/outputs/default/entry-default-signed.hap
# 或 DevEco 里直接点 Run ▶
```

---

## 4. 构建步骤（命令行 hvigor）

```bash
cd remotedesk/harmony

# hvigorw 由 DevEco 提供；若没有，用 DevEco 安装目录下的
# <DevEco>/tools/hvigor/bin/hvigorw
export DEVECO_SDK_HOME=/path/to/HarmonyOS/SDK

npm install                 # 安装 hvigor 依赖
node ./hvigorw --mode module -p product=default assembleHap
```

命令行构建同样需要 `signingConfigs`：可在 `build-profile.json5` 里填入
`storeFile / storePassword / keyAlias / keyPassword`（推荐用环境变量注入，别提交到仓库）。

---

## 5. 工程结构

```
harmony/
├─ AppScope/
│  ├─ app.json5                     bundleName / versionCode / icon / label
│  └─ resources/base/{element,media}/
├─ build-profile.json5              产物配置、signingConfigs、SDK 版本
├─ hvigorfile.ts                    app 级构建脚本
├─ oh-package.json5                 依赖声明（modelVersion 5.0.0）
├─ hvigor/hvigor-config.json5       hvigor 5.0.2 + ohos plugin 5.0.2
└─ entry/
   ├─ build-profile.json5           apiType: stageMode
   ├─ hvigorfile.ts                 hap 级构建脚本
   ├─ oh-package.json5
   └─ src/main/
      ├─ module.json5               权限、Ability、页面入口
      ├─ ets/
      │  ├─ entryability/EntryAbility.ets   沉浸式深色窗口 + 加载 Index
      │  ├─ pages/Index.ets                 全部 UI 与交互逻辑
      │  └─ common/
      │     ├─ Types.ets            协议类型定义
      │     ├─ Prefs.ets            服务器地址/token/设备ID 持久化
      │     ├─ Api.ets              REST（@ohos.net.http）
      │     ├─ Signaling.ets        WebSocket 信令（@ohos.net.webSocket）
      │     └─ Files.ets            文件选择、分块读、分块写
      └─ resources/
         ├─ base/element/{string,color}.json
         ├─ base/media/app_icon.png
         ├─ base/profile/main_pages.json
         └─ rawfile/rdwebrtc.html    ← WebRTC 桥接页面（核心）
```

---

## 6. 权限说明

`entry/src/main/module.json5` 声明：

| 权限 | 用途 |
| --- | --- |
| `ohos.permission.INTERNET` | REST + WebSocket |
| `ohos.permission.GET_NETWORK_INFO` | 断线重连判断 |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | 会话期间保持连接 |
| `ohos.permission.MICROPHONE` | 语音（默认关闭，设置里开启后才申请） |
| `ohos.permission.CAMERA` | 摄像头（默认关闭） |

麦克风/摄像头是**运行时权限**，首次真正使用才会弹系统授权框；用户在设置里关掉后，
本地不会创建对应轨道。

---

## 7. 已知限制

1. **只能作为控制端，不能作为被控端。**
   HarmonyOS 未向第三方应用开放"跨应用注入触摸事件"的能力（无 Android 的
   AccessibilityService 等价物），也没有开放的屏幕采集给第三方做完整远控。
   应用收到 `session_req` / `control_start` 时会明确提示"本机暂不支持被控"并自动拒绝，
   **不会让对端误以为已连上**。

2. **WebRTC 依赖 ArkWeb 内核。** 见第 1 节。

3. **文件接收目录**为应用沙箱 `filesDir/received`，可用 `hdc file recv` 取出，
   或在文件管理里通过"应用文件"访问。

---

## 8. 与另两端的差异

| 能力 | Windows | Android | HarmonyOS |
| --- | --- | --- | --- |
| 登录 / 注册 / 多设备 | ✅ | ✅ | ✅ |
| 发起同账号控制 | ✅ | ✅ | ✅ |
| 发起账号密码控制 | ✅ | ✅ | ✅ |
| 使用统一连接码 | ✅ | ✅ | ✅ |
| 作为被控端 | ✅ | ✅ | ❌ |
| 发送 / 接收文件 | ✅ | ✅ | ✅ |
| 触摸操作对端 | ✅ | ✅ | ✅ |
| 软键盘输入 | ✅ | ✅ | ✅ |

协议层面三端完全一致，见 [`protocol.md`](protocol.md)。