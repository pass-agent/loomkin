use tauri_plugin_notification::NotificationExt;

/// Send a native desktop notification.
///
/// This command is callable from the Phoenix web app via the Tauri JS bridge:
/// ```js
/// import { invoke } from '@tauri-apps/api/core';
/// await invoke('send_notification', { title: 'Hello', body: 'World' });
/// ```
#[tauri::command]
pub fn send_notification(
    app: tauri::AppHandle,
    title: String,
    body: String,
) -> Result<(), String> {
    app.notification()
        .builder()
        .title(&title)
        .body(&body)
        .show()
        .map_err(|e| format!("Failed to send notification: {}", e))?;

    Ok(())
}
