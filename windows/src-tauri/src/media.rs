// 语音 / 摄像头的系统侧权限诊断。
//
// WebView2 里的 getUserMedia 能否成功，取决于两层外部状态：
//   1. Windows 隐私设置是否允许「桌面应用」访问摄像头 / 麦克风
//   2. WebView2 运行时是否允许该页面使用媒体设备
//
// 第 2 层由 WebView2 在首次调用 getUserMedia 时弹授权提示（用户点允许即可）。
// 第 1 层是硬开关，被关掉时 WebView2 连设备都枚举不到，只报一个含糊的
// NotReadableError / NotFoundError。所以这里直接读注册表把它诊断出来，
// 并给一个能一键跳到系统设置页的入口——比让用户自己找「设置 → 隐私」快得多。
use serde::Serialize;
use std::process::Command;

/// 读到的隐私开关状态。`None` 表示读不到（系统版本差异 / 注册表项不存在），
/// 此时前端应显示「无法确认」而不是误报「被禁用」。
#[derive(Serialize)]
pub struct MediaPrivacy {
    pub webcam: Option<bool>,
    pub microphone: Option<bool>,
    pub hint: String,
}

const CONSENT_BASE: &str =
    r"HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore";

/// `reg query <key> /v Value` → Some(true/false)；键不存在或格式异常返回 None。
fn read_consent(key: &str) -> Option<bool> {
    let out = Command::new("reg")
        .args(["query", key, "/v", "Value"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    for line in text.lines() {
        if !line.contains("REG_DWORD") && !line.contains("REG_SZ") {
            continue;
        }
        let last = line.split_whitespace().last()?.trim();
        if line.contains("REG_DWORD") {
            let hex = last.trim_start_matches("0x").trim_start_matches("0X");
            if let Ok(n) = u32::from_str_radix(hex, 16) {
                return Some(n != 0);
            }
        } else {
            // REG_SZ：Allow / Deny
            let v = last.to_ascii_lowercase();
            if v == "allow" || v == "deny" {
                return Some(v == "allow");
            }
        }
    }
    None
}

/// 先看「桌面应用」这一档（NonPackaged），它才是决定桌面 exe 的关键；
/// 没有再退回全局 Value。
fn capability_enabled(cap: &str) -> Option<bool> {
    let non_packaged = format!(r"{}\{}\NonPackaged", CONSENT_BASE, cap);
    if let Some(v) = read_consent(&non_packaged) {
        return Some(v);
    }
    read_consent(&format!(r"{}\{}", CONSENT_BASE, cap))
}

#[tauri::command]
pub fn media_privacy_status() -> MediaPrivacy {
    let webcam = capability_enabled("webcam");
    let microphone = capability_enabled("microphone");

    let mut blocked = Vec::new();
    if webcam == Some(false) {
        blocked.push("摄像头");
    }
    if microphone == Some(false) {
        blocked.push("麦克风");
    }
    let hint = if blocked.is_empty() {
        "系统隐私设置未阻止媒体设备".to_string()
    } else {
        format!(
            "Windows 隐私设置已禁止桌面应用使用{}，请点「打开设置」允许后重试",
            blocked.join(" / ")
        )
    };

    MediaPrivacy {
        webcam,
        microphone,
        hint,
    }
}

/// 打开系统隐私设置页。`kind`: `camera` | `microphone`（其余值按摄像头处理）。
#[tauri::command]
pub fn open_privacy_settings(kind: String) -> Result<(), String> {
    let uri = if kind.eq_ignore_ascii_case("microphone") || kind.eq_ignore_ascii_case("mic") {
        "ms-settings:privacy-microphone"
    } else {
        "ms-settings:privacy-webcam"
    };
    #[cfg(target_os = "windows")]
    {
        // 用 cmd start 打开 URI：比 ShellExecuteW 少一堆依赖，行为一致。
        Command::new("cmd")
            .args(["/C", "start", "", uri])
            .spawn()
            .map(|_| ())
            .map_err(|e| format!("无法打开系统设置：{e}"))
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = uri;
        Err("当前平台不支持打开 Windows 隐私设置".to_string())
    }
}
