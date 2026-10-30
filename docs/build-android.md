# Android 客户端构建与排错

## 1. 前置条件

| 项 | 要求 |
| --- | --- |
| JDK | **17**（AGP 8.7 要求；21 也可，但 17 最稳） |
| Android SDK | Platform **34** + Build-Tools **34.0.0** |
| Gradle | 8.9（用 Android Studio 时自动带） |
| 设备 | Android 7.0 (API 24) 及以上 |

### 1.1 检查 JDK

```powershell
java -version            # 需要 17.x
echo $env:JAVA_HOME
```

常见可用路径：`D:\Java\jdk-17`、`C:\Program Files\Microsoft\jdk-17.*`、
`C:\Program Files\Android\Android Studio\jbr`。

### 1.2 检查 Android SDK

```powershell
echo $env:ANDROID_HOME        # 一般是 C:\Users\<你>\AppData\Local\Android\Sdk
Test-Path "$env:ANDROID_HOME\platforms\android-34"
Test-Path "$env:ANDROID_HOME\build-tools\34.0.0"
```

缺的话在 Android Studio 的 **SDK Manager** 里勾选后安装。

---

## 2. 构建

### 方式一：Android Studio（推荐，最省事）

```text
1. Android Studio → Open → 选择 remotedesk/android
2. 等待 Gradle Sync 完成（首次会下载 AGP / Kotlin / WebRTC SDK，约 200 MB）
3. Build → Build Bundle(s)/APK(s) → Build APK(s)
4. 产物：app/build/outputs/apk/debug/app-debug.apk
```

### 方式二：命令行 Gradle

```powershell
cd remotedesk\android

# 如果没有 gradlew（本仓库未附带 wrapper 二进制）：
#   让 Android Studio 执行一次 File → Sync 会自动生成；
#   或本机装 Gradle 8.9 后执行 `gradle wrapper`
$env:JAVA_HOME = "D:\Java\jdk-17"
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"

.\gradlew.bat assembleDebug      # 或 assembleRelease
```

### 方式三：一键脚本

```powershell
powershell -ExecutionPolicy Bypass -File ..\scripts\build-android.ps1
powershell -ExecutionPolicy Bypass -File ..\scripts\build-android.ps1 -Release
```

脚本会自动探测 `JAVA_HOME` / `ANDROID_HOME`，自动写 `local.properties`，
自动找 gradlew 或 `.tools\gradle-8.9`，最后打印 APK 路径。

### 产物

| 文件 | 说明 |
| --- | --- |
| `android\app\build\outputs\apk\debug\app-debug.apk` | 调试包，debug 签名，可直接装 |
| `android\app\build\outputs\apk\release\app-release.apk` | release 包（当前配置为 debug 签名，见第 5 节） |

安装：`adb install -r app-debug.apk`

---

## 3. 真机上的三件事（缺一不可）

Android 上要能被远程控制，必须同时满足：

1. **无障碍服务** —— 注入点击/滑动的唯一无 root 途径
   `系统设置 → 无障碍 → 已下载的服务 → 远程桌面 → 开启`
   （应用内「设置 → 开启无障碍服务」按钮会直接跳转）
2. **MediaProjection 授权** —— 被控时系统弹「开始录制或投放屏幕」，点**立即开始**
3. **电池优化 / 后台存活** —— 应用已用**前台服务 + 常驻通知**保活；
   部分国产 ROM（MIUI / EMUI / ColorOS）仍需在"电池 → 应用启动管理"里设为"允许后台活动"

控制端（去控别人）不需要这些，装好登录就能用。

---

## 4. 架构与关键文件

```
android/app/src/main/java/com/remotedesk/app/
├─ App.kt               Application，初始化 PeerConnectionFactory
├─ Prefs.kt             SharedPreferences：server / token / deviceId / deviceName
├─ Api.kt               REST（OkHttp）
├─ Signaling.kt         WebSocket 信令（OkHttp WebSocket）
├─ RtcClient.kt         WebRTC：三通道、SDP/ICE、屏幕采集、文件收发
├─ SessionHub.kt        全局单例会话协调器（Activity ↔ Service 之间）
├─ RemoteService.kt     被控端前台服务（mediaProjection 类型）
├─ InjectorService.kt   无障碍服务，把输入事件变成手势/文本注入
└─ MainActivity.kt      全部 UI（三屏幕 + 弹窗 + 触摸映射）
```

### 输入注入的原理（`InjectorService.kt`）

- **点击**：`dispatchGesture` 一个 `TAP_MS=60ms` 的短划线
- **拖拽**：用 `StrokeDescription.continueStroke()` 链式手势逐段延长，
  每段 `SEG_MS=20ms`，位移超过 `DRAG_THRESHOLD=10px` 才算拖动
- **滑动/滚轮**：`mouse_wheel` 的 `dy` 转成一次固定距离的上下滑
- **右键** → `GLOBAL_ACTION_BACK`（手机上"右键"语义最接近返回）
- **按键** → Escape/Back = 返回，Home = 桌面，AppSwitch = 最近任务，
  Backspace/Delete = 删掉焦点输入框最后一个字符，Enter = 追加换行
- **文本** → 焦点节点 `ACTION_SET_TEXT` 整串回写（兼容中文/emoji）

坐标从控制端来的是 **0..1 归一化**，投影到 `displayMetrics` 的实际像素。

---

## 5. 签名（出正式包时改这里）

当前 `app/build.gradle.kts` 里 release 用的是 **debug 签名**，目的是让你
无需准备 keystore 就能直接 `assembleRelease` 出可安装包（方便内部测试）。

正式分发请改成自己的 keystore：

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
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}
```

生成 keystore：

```bash
keytool -genkeypair -v -keystore release.keystore -alias remotedesk \
  -keyalg RSA -keysize 2048 -validity 10000
```

> `proguard-rules.pro` 已经 `keep org.webrtc.**`，开混淆不会把 RTC 类删掉。

---

## 6. 常见问题

**Q: `Your project path contains non-ASCII characters`**
A: 工程放在中文目录（如 `D:\文档\...`）时 AGP 会警告。本仓库的
`android/gradle.properties` 已加 `android.overridePathCheck=true`，可以正常构建。
若仍想彻底避免，把工程移到纯英文路径。

**Q: `Could not resolve io.github.webrtc-sdk:android:125.6422.07`**
A: 这是第三方 WebRTC 预编译包（官方 `org.webrtc:google-webrtc` 已停更）。
`settings.gradle.kts` 已配置阿里云镜像 + `mavenCentral()`。
若公司网络限制，可在 `~/.gradle/init.gradle` 里加自己的私服。

**Q: 构建很慢 / 卡在 Download**
A: 首次要下 ~200MB 依赖。`settings.gradle.kts` 里已把
`maven.aliyun.com/repository/{google,public,gradle-plugin}` 放最前。

**Q: APK 装上了但打开闪退**
A: 用 `adb logcat | findstr remotedesk` 看堆栈。最常见原因是
WebRTC 的 native so 与 ABI 不匹配（已打包 arm64-v8a / armeabi-v7a / x86 / x86_64 四套）。

**Q: 被控端能看到画面，但点了没反应**
A: 无障碍服务没开。应用内会提示"无障碍未开启"，点提示可直接跳设置。

**Q: 华为/小米上后台一会儿就断**
A: 系统杀进程。除前台服务外，还要在系统设置里给"自启动/后台活动"权限；
EMUI 还需在"应用启动管理"里关掉自动管理。

---

## 7. 验证清单

- [ ] 装好 APK，填服务器地址能注册/登录
- [ ] 「我的设备」能看到同账号的其他设备（在线时绿点）
- [ ] 作为控制端：点设备 → 看到对方屏幕 → 触摸操作有效
- [ ] 作为控制端：顶部「键盘」按钮能发文字
- [ ] 作为控制端：「发送文件」→ 对方收到
- [ ] 作为被控端：开启无障碍 + 同意投屏 → 弹出"正在被控制"横幅与常驻通知
- [ ] 作为被控端：点横幅「取消控制」或通知里的「取消控制」→ 双方断开
- [ ] 设置里打开「同账号免同意」后，同账号设备直连，但仍有提示横幅