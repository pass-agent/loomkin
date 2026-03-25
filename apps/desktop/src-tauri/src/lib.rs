mod hotkeys;
mod notifications;
mod tray;
mod updater;

use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_log::Builder::new().build())
        .setup(|app| {
            // Set up the system tray
            tray::setup_tray(app)?;

            // Register global hotkeys
            hotkeys::register_hotkeys(app)?;

            // Check for updates on startup (non-blocking)
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                updater::check_for_updates_on_startup(handle).await;
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            notifications::send_notification,
            updater::check_for_updates,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Loomkin desktop app");
}
