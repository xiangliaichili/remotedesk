// 远程输入注入：把控制端发来的 0..1 归一化事件还原为本机鼠标/键盘操作
use std::sync::Mutex;

use enigo::{Button, Coordinate, Direction, Enigo, Key, Keyboard, Mouse, Settings};
use serde_json::Value;

pub struct InputState {
    enigo: Mutex<Enigo>,
}

impl InputState {
    pub fn new() -> Self {
        let enigo = Enigo::new(&Settings::default()).expect("初始化输入模拟失败");
        Self {
            enigo: Mutex::new(enigo),
        }
    }
}

fn er<E: std::fmt::Debug>(e: E) -> String {
    format!("{e:?}")
}

fn coord(v: &Value, key: &str) -> f64 {
    v.get(key).and_then(|x| x.as_f64()).unwrap_or(0.0).clamp(0.0, 1.0)
}

fn abs_xy(v: &Value) -> (i32, i32) {
    let g = crate::capture::geometry();
    let (w, h) = if g.w > 0 && g.h > 0 {
        (g.w, g.h)
    } else {
        (1920, 1080)
    };
    let x = g.x + (coord(v, "x") * w as f64) as i32;
    let y = g.y + (coord(v, "y") * h as f64) as i32;
    (x, y)
}

fn button_of(v: &Value) -> Button {
    match v.get("button").and_then(|b| b.as_i64()).unwrap_or(0) {
        1 => Button::Middle,
        2 => Button::Right,
        _ => Button::Left,
    }
}

fn direction_of(v: &Value) -> Direction {
    match v.get("action").and_then(|a| a.as_str()).unwrap_or("down") {
        "up" => Direction::Release,
        _ => Direction::Press,
    }
}

fn map_key(code: &str, key: &str) -> Option<Key> {
    let k = match code {
        "ControlLeft" | "ControlRight" => Key::Control,
        "ShiftLeft" | "ShiftRight" => Key::Shift,
        "AltLeft" | "AltRight" => Key::Alt,
        "MetaLeft" | "MetaRight" => Key::Meta,
        "Enter" | "NumpadEnter" => Key::Return,
        "Backspace" => Key::Backspace,
        "Tab" => Key::Tab,
        "Escape" => Key::Escape,
        "Delete" => Key::Delete,
        "Insert" => Key::Insert,
        "ArrowUp" => Key::UpArrow,
        "ArrowDown" => Key::DownArrow,
        "ArrowLeft" => Key::LeftArrow,
        "ArrowRight" => Key::RightArrow,
        "Home" => Key::Home,
        "End" => Key::End,
        "PageUp" => Key::PageUp,
        "PageDown" => Key::PageDown,
        "Space" => Key::Space,
        "CapsLock" => Key::CapsLock,
        "F1" => Key::F1,
        "F2" => Key::F2,
        "F3" => Key::F3,
        "F4" => Key::F4,
        "F5" => Key::F5,
        "F6" => Key::F6,
        "F7" => Key::F7,
        "F8" => Key::F8,
        "F9" => Key::F9,
        "F10" => Key::F10,
        "F11" => Key::F11,
        "F12" => Key::F12,
        _ => {
            // 普通字符：用 key 的实际字符（能正确处理 Shift 后的字符）
            let mut it = key.chars();
            match (it.next(), it.next()) {
                (Some(c), None) => Key::Unicode(c),
                _ => return None,
            }
        }
    };
    Some(k)
}

#[tauri::command]
pub fn inject_input(state: tauri::State<'_, InputState>, event: Value) -> Result<(), String> {
    let mut e = state.enigo.lock().map_err(|_| "输入锁失败".to_string())?;
    let t = event.get("t").and_then(|v| v.as_str()).unwrap_or("");

    match t {
        "mouse_move" => {
            let (x, y) = abs_xy(&event);
            e.move_mouse(x, y, Coordinate::Abs).map_err(er)?;
        }
        "mouse_down" => {
            let (x, y) = abs_xy(&event);
            e.move_mouse(x, y, Coordinate::Abs).map_err(er)?;
            e.button(button_of(&event), Direction::Press).map_err(er)?;
        }
        "mouse_up" => {
            let (x, y) = abs_xy(&event);
            e.move_mouse(x, y, Coordinate::Abs).map_err(er)?;
            e.button(button_of(&event), Direction::Release).map_err(er)?;
        }
        "mouse_wheel" => {
            let dy = event.get("dy").and_then(|v| v.as_f64()).unwrap_or(0.0);
            // 浏览器 1 格约 100px，换算成滚轮格数
            let steps = (-dy / 100.0).round() as i32;
            if steps != 0 {
                e.scroll(steps, enigo::Axis::Vertical).map_err(er)?;
            }
        }
        "key" => {
            let code = event.get("code").and_then(|v| v.as_str()).unwrap_or("");
            let key = event.get("key").and_then(|v| v.as_str()).unwrap_or("");
            if let Some(k) = map_key(code, key) {
                e.key(k, direction_of(&event)).map_err(er)?;
            }
        }
        "text" => {
            let text = event.get("text").and_then(|v| v.as_str()).unwrap_or("");
            if !text.is_empty() {
                e.text(text).map_err(er)?;
            }
        }
        // 触控事件在 Windows 上映射为鼠标
        "touch" => {
            let action = event.get("action").and_then(|v| v.as_str()).unwrap_or("down");
            let (x, y) = abs_xy(&event);
            e.move_mouse(x, y, Coordinate::Abs).map_err(er)?;
            match action {
                "down" => {
                    e.button(Button::Left, Direction::Press).map_err(er)?;
                }
                "up" => {
                    e.button(Button::Left, Direction::Release).map_err(er)?;
                }
                _ => {}
            }
        }
        _ => {}
    }
    Ok(())
}
