# Windows 客户端构建与排错

## 1. 前置条件

| 项 | 要求 | 检查命令 |
| --- | --- | --- |
| Windows | 10 1809+ / 11 | `winver` |
| Node.js | 18+（推荐 20 LTS） | `node --version` |
| Rust | stable，`x86_64-pc-windows-msvc` | `rustc --version` |
| MSVC 工具链 | VS 2022 Build Tools + "使用 C++ 的桌面开发" | 见下 |
| WebView2 | Windows 11 自带；Win10 需装 Runtime | 见下 |

### 1.1 安装 Rust

```powershell
# 官方
winget install Rustlang.Rustup
# 国内网络慢可用镜像
$env:RUSTUP_DIST_SERVER = "https://mirrors.tuna.tsinghua.edu.cn/rustup"
rustup default stable-x86_64-pc-windows-msvc
```

### 1.2 安装 MSVC 工具链

```powershell
winget install Microsoft.VisualStudio.2022.BuildTools `
  --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

装完确认存在（版本号可能不同）：

```text
C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\<ver>\bin\Hostx64\x64\link.exe
```

> **注意**：只装 `Microsoft.VisualStudio.2022.BuildTools` 而**不加 VCTools workload** 不够，
> 目录会是空的，`cargo build` 会报 `linker 'link.exe' not found`。

### 1.3 检查 WebView2

```powershell
Test-Path "C:\Program Files (x86)\Microsoft\EdgeWebView\Application"
```

不存在则装：<https://developer.microsoft.com/microsoft-edge/webview2/>

---

## 2. 构建

```powershell
cd remotedesk\windows
npm install
npm run tauri build            # EXE + NSIS 安装包 + MSI
npm run tauri build -- --no-bundle   # 只要裸 EXE，快很多
```

或一键脚本（自动探测环境、失败给中文提示）：

```powershell
powershell -ExecutionPolicy Bypass -File ..\scripts\build-windows.ps1
```

### 2.1 如果命令行里 `cargo` 找不到 MSVC 的头文件/库

Tauri 的构建需要 MSVC 的环境变量（`INCLUDE` / `LIB` / `PATH`）。
在**普通 PowerShell** 里直接 `npm run tauri build` 有时会失败，改用开发者命令提示符：

```powershell
cmd /c "`"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat`" -arch=amd64 && npm run tauri build"
```

或先开 "x64 Native Tools Command Prompt for VS 2022"，再 `cd` 到 `windows` 目录构建。

### 2.2 产物

| 文件 | 说明 |
| --- | --- |
| `src-tauri\target\release\remotedesk.exe` | 免安装单文件，双击即用 |
| `src-tauri\target\release\bundle\nsis\RemoteDesk_0.1.0_x64-setup.exe` | NSIS 安装包（当前用户级安装，免管理员） |
| `src-tauri\target\release\bundle\msi\RemoteDesk_0.1.0_x64_en-US.msi` | MSI 安装包 |

首次运行体积约 10~15 MB（WebView2 用系统共享运行时，不重复打包）。

---

## 3. 工作原理

```
┌────────────────────── Tauri 应用 ──────────────────────┐
│                                                        │
│  前端 (WebView2)                Rust 后端               │
│  ┌────────────────────┐        ┌─────────────────────┐ │
│  │ main.js    UI/编排  │        │ capture.rs  xcap    │ │
│  │ session.js WebRTC  │◄──────►│ input.rs    enigo   │ │
│  │ api.js     REST    │ invoke │ files.rs    rfd/fs  │ │
│  │ signaling.js  WSS  │ 事件   │ lib.rs      command │ │
│  └────────────────────┘        └─────────────────────┘ │
└────────────────────────────────────────────────────────┘
```

- **作被控端**：`start_capture` 启动后台线程，`xcap` 抓屏 → JPEG（质量 70）→ base64
  → `app.emit("screen-frame")` → 前端画到 canvas → `canvas.captureStream(15)` 变成视频轨
- **作控制端**：收到的输入事件 → `invoke("inject_input")` → `enigo` 注入鼠标/键盘
- **文件**：`pick_file` 用 `rfd` 选文件，`read_file_chunk` / `file_write_chunk` 分块读写，
  接收目录 `%USERPROFILE%\Downloads\remotedesk-received`

> **为什么不直接用 `getDisplayMedia`？**
> WebView2 对 `getDisplayMedia` 的支持不稳定（需要额外的 picker 权限配置），
> 所以走 Rust 抓屏 + canvas 这条路，行为可预测。代价是多一次 JPEG 编解码，
> 在局域网/宽带下 1080p@15fps 完全够用。若要更高帧率，可把 JPEG 编码换成
> H.264 硬编 + `MediaStreamTrackGenerator`（需改 `capture.rs` 与 `session.js`）。

---

## 4. 常见问题

**Q: `failed to run custom build command for libappindicator` / 各种 `*-sys` crate 编译失败**
A: 先把 Rust 与 cargo 更新到最新：`rustup update stable`。Tauri 2 的依赖树更新很快，
旧 stable 可能装不上某个 crate。

**Q: `error: linker 'link.exe' not found`**
A: 没装 MSVC 工具链，或没在 VS 开发者环境里构建。见 1.2 与 2.1。

**Q: `error: linking with link.exe failed: exit code: 1181` / 找不到 `kernel32.lib`**
A: Windows SDK 缺失或版本不匹配。在 VS Installer 里勾选
"Windows 11 SDK (10.0.22621.0 或更新)"。

**Q: `xcap` / `enigo` 报方法不存在**
A: 这两个 crate 迭代快，`Cargo.toml` 里锁的是 `xcap = "0.0.14"` / `enigo = "0.2"`。
若按报错需要升级，改 `capture.rs` / `input.rs` 的调用即可，整体结构不用动：

- `xcap`：`Monitor::all()` → `monitor.capture_image()` → `RgbaImage`
- `enigo`：`Enigo::new(&Settings::default())`，`move_mouse` / `button` / `key` / `text` / `scroll`

**Q: 界面一片空白 / 白屏**
A: WebView2 运行时缺失，或 `frontendDist: "../dist"` 没先构建。
`npm run tauri build` 会自动先跑 `npm run build`（vite）；手动 `cargo build` 不会。

**Q: 被控端画面是黑的（但连接正常）**
A: 检查是不是 RDP 会话里运行（会话锁屏/最小化时抓屏会全黑），
或在多显示器上抓了不存在的索引。`start_capture` 的 `monitor` 参数默认 0（主屏）。

**Q: 杀毒软件报毒**
A: Tauri 应用未签名时，部分杀软对"能模拟键鼠 + 抓屏"的程序敏感。
正式分发建议购买代码签名证书，在 `tauri.conf.json` 的
`bundle.windows.certificateThumbprint` 里配置。

---

## 5. 开发调试

```powershell
cd remotedesk\windows
npm run tauri dev
```

- 前端热更新（vite 1420 端口）
- 打开 WebView2 DevTools：`Ctrl+Shift+I`（debug 构建自动启用）
- Rust 侧日志：`RUST_LOG=debug npm run tauri dev`

---

## 6. 验证清单（首次构建后建议走一遍）

- [ ] 双击 `remotedesk.exe` 能打开登录页
- [ ] 填服务器地址 → 注册 → 进入「我的设备」
- [ ] 同账号第二台设备（另一台电脑/Android）登录后，设备列表出现且在线绿点
- [ ] 点设备发起控制 → 被控端弹出「请求控制」→ 同意 → 看到对方屏幕
- [ ] 控制端鼠标移动 / 点击 / 滚轮 / 键盘输入有效
- [ ] 控制端「发送文件」→ 被控端 `下载\remotedesk-received` 出现文件
- [ ] 被控端横幅「取消控制」→ 两端都断开且提示
- [ ] 设置里打开「同账号免同意」→ 再次连接无需弹窗，但被控端仍有提示横幅