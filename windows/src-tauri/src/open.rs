// 用系统默认浏览器打开外部链接（微信扫码授权页等）。
//
// 为什么不装 tauri-plugin-opener：这一条命令用系统自带能力就够，
// 少一个依赖 = 少一次 MSVC 链接失败的机会。
use std::process::Command;

/// 只允许 http/https，避免被当成任意命令执行的入口。
#[tauri::command]
pub fn open_url(url: String) -> Result<(), String> {
    let trimmed = url.trim();
    if !(trimmed.starts_with("https://") || trimmed.starts_with("http://")) {
        return Err("只支持 http/https 链接".to_string());
    }

    #[cfg(target_os = "windows")]
    {
        Command::new("cmd")
            .args(["/C", "start", "", trimmed])
            .spawn()
            .map(|_| ())
            .map_err(|e| format!("打开浏览器失败：{e}"))
    }
    #[cfg(target_os = "macos")]
    {
        Command::new("open")
            .arg(trimmed)
            .spawn()
            .map(|_| ())
            .map_err(|e| format!("打开浏览器失败：{e}"))
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        Command::new("xdg-open")
            .arg(trimmed)
            .spawn()
            .map(|_| ())
            .map_err(|e| format!("打开浏览器失败：{e}"))
    }
}
