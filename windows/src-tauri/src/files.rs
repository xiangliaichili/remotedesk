// 本机信息与文件收发
use std::fs::{self, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use base64::Engine as _;
use serde::Serialize;

#[derive(Serialize)]
pub struct DeviceInfo {
    pub name: String,
    pub os: String,
}

#[tauri::command]
pub fn device_info() -> DeviceInfo {
    let name = std::env::var("COMPUTERNAME")
        .ok()
        .or_else(|| std::env::var("HOSTNAME").ok())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Windows 电脑".to_string());
    DeviceInfo {
        name,
        os: "windows".to_string(),
    }
}

#[derive(Serialize)]
pub struct FileMeta {
    pub path: String,
    pub name: String,
    pub size: u64,
}

#[tauri::command]
pub fn pick_file() -> Option<FileMeta> {
    let p = rfd::FileDialog::new()
        .set_title("选择要发送的文件")
        .pick_file()?;
    let meta = fs::metadata(&p).ok()?;
    let name = p
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "file".to_string());
    Some(FileMeta {
        path: p.to_string_lossy().to_string(),
        name,
        size: meta.len(),
    })
}

#[tauri::command]
pub fn read_file_chunk(path: String, offset: u64, len: u64) -> Result<String, String> {
    let mut f = fs::File::open(&path).map_err(|e| e.to_string())?;
    f.seek(SeekFrom::Start(offset)).map_err(|e| e.to_string())?;
    let mut buf = vec![0u8; len.min(8 * 1024 * 1024) as usize];
    let mut read = 0usize;
    while read < buf.len() {
        match f.read(&mut buf[read..]) {
            Ok(0) => break,
            Ok(n) => read += n,
            Err(e) => return Err(e.to_string()),
        }
    }
    buf.truncate(read);
    Ok(base64::engine::general_purpose::STANDARD.encode(&buf))
}

fn recv_dir() -> PathBuf {
    let base = dirs::download_dir()
        .or_else(dirs::home_dir)
        .unwrap_or_else(|| PathBuf::from("."));
    let d = base.join("remotedesk-received");
    let _ = fs::create_dir_all(&d);
    d
}

fn sanitize(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| if "/\\:*?\"<>|".contains(c) { '_' } else { c })
        .collect();
    if cleaned.trim().is_empty() {
        "received.bin".to_string()
    } else {
        cleaned
    }
}

/// 接收文件前创建空文件，返回最终落盘路径
#[tauri::command]
pub fn file_begin(name: String) -> Result<serde_json::Value, String> {
    let dir = recv_dir();
    let safe = sanitize(&name);
    let stem = Path::new(&safe)
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "received".to_string());
    let ext = Path::new(&safe)
        .extension()
        .map(|s| s.to_string_lossy().to_string());

    let mut path = dir.join(&safe);
    let mut i = 1;
    while path.exists() {
        let fname = match &ext {
            Some(e) => format!("{stem} ({i}).{e}"),
            None => format!("{stem} ({i})"),
        };
        path = dir.join(fname);
        i += 1;
        if i > 9999 {
            break;
        }
    }
    fs::File::create(&path).map_err(|e| e.to_string())?;
    Ok(serde_json::json!({ "path": path.to_string_lossy().to_string() }))
}

#[tauri::command]
pub fn file_write_chunk(path: String, offset: u64, data: String) -> Result<(), String> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data.as_bytes())
        .map_err(|e| e.to_string())?;
    let mut f = OpenOptions::new()
        .write(true)
        .open(&path)
        .map_err(|e| e.to_string())?;
    f.seek(SeekFrom::Start(offset)).map_err(|e| e.to_string())?;
    f.write_all(&bytes).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn file_finish(path: String) -> Result<serde_json::Value, String> {
    let size = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    Ok(serde_json::json!({ "path": path, "size": size }))
}
