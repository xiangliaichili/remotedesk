mod capture;
mod files;
mod input;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(input::InputState::new())
        .invoke_handler(tauri::generate_handler![
            files::device_info,
            files::pick_file,
            files::read_file_chunk,
            files::file_begin,
            files::file_write_chunk,
            files::file_finish,
            capture::start_capture,
            capture::stop_capture,
            input::inject_input,
        ])
        .run(tauri::generate_context!())
        .expect("remotedesk 启动失败");
}
