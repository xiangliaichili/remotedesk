// 屏幕采集：xcap 抓帧 -> JPEG -> base64 -> 事件推给前端
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use base64::Engine as _;
use tauri::{AppHandle, Emitter};

static RUNNING: AtomicBool = AtomicBool::new(false);

/// 被控屏幕几何（用于把 0..1 归一化坐标还原为绝对坐标）
#[derive(Clone, Copy, Default, Debug)]
pub struct Geom {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

static GEOM: OnceLock<Mutex<Geom>> = OnceLock::new();

fn geom_cell() -> &'static Mutex<Geom> {
    GEOM.get_or_init(|| Mutex::new(Geom::default()))
}

pub fn geometry() -> Geom {
    *geom_cell().lock().unwrap()
}

#[tauri::command]
pub fn start_capture(app: AppHandle, monitor: u32, fps: u32) -> Result<(), String> {
    if RUNNING.swap(true, Ordering::SeqCst) {
        return Ok(());
    }
    let fps = fps.clamp(1, 30) as u64;

    std::thread::spawn(move || {
        let monitors = match xcap::Monitor::all() {
            Ok(m) => m,
            Err(e) => {
                let _ = app.emit("capture-error", format!("无法枚举显示器: {e}"));
                RUNNING.store(false, Ordering::SeqCst);
                return;
            }
        };
        if monitors.is_empty() {
            let _ = app.emit("capture-error", "未找到可采集的显示器");
            RUNNING.store(false, Ordering::SeqCst);
            return;
        }
        let idx = (monitor as usize).min(monitors.len() - 1);
        let mon = &monitors[idx];
        let frame_dt = Duration::from_millis(1000 / fps);

        while RUNNING.load(Ordering::SeqCst) {
            let t0 = Instant::now();
            match mon.capture_image() {
                Ok(img) => {
                    let (w, h) = (img.width(), img.height());
                    if w == 0 || h == 0 {
                        std::thread::sleep(Duration::from_millis(100));
                        continue;
                    }
                    if let Some(b64) = encode_jpeg(img.into_raw(), w, h) {
                        *geom_cell().lock().unwrap() = Geom {
                            x: 0,
                            y: 0,
                            w: w as i32,
                            h: h as i32,
                        };
                        let _ = app.emit(
                            "screen-frame",
                            serde_json::json!({
                                "jpeg_b64": b64,
                                "width": w,
                                "height": h,
                            }),
                        );
                    }
                }
                Err(_) => {
                    // 例如锁屏 / UAC 桌面切换，稍后重试
                    std::thread::sleep(Duration::from_millis(250));
                }
            }
            let elapsed = t0.elapsed();
            if elapsed < frame_dt {
                std::thread::sleep(frame_dt - elapsed);
            }
        }
    });

    Ok(())
}

#[tauri::command]
pub fn stop_capture() {
    RUNNING.store(false, Ordering::SeqCst);
}

fn encode_jpeg(raw: Vec<u8>, w: u32, h: u32) -> Option<String> {
    use image::ExtendedColorType;
    let rgba = image::RgbaImage::from_raw(w, h, raw)?;
    let rgb = image::DynamicImage::ImageRgba8(rgba).to_rgb8();
    let mut buf: Vec<u8> = Vec::new();
    let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 70);
    enc.encode(rgb.as_raw(), rgb.width(), rgb.height(), ExtendedColorType::Rgb8)
        .ok()?;
    Some(base64::engine::general_purpose::STANDARD.encode(&buf))
}
