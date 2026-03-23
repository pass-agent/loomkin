use tauri::AppHandle;
use tauri_plugin_updater::UpdaterExt;

/// Check for updates on application startup.
/// Runs asynchronously and does not block the main thread.
pub async fn check_for_updates_on_startup(app: AppHandle) {
    let updater = match app.updater() {
        Ok(u) => u,
        Err(e) => {
            log::debug!("Updater not available: {}", e);
            return;
        }
    };
    match updater.check().await {
        Ok(Some(update)) => {
            log::info!(
                "Update available: {} -> {}",
                update.current_version,
                update.version
            );
        }
        Ok(None) => {
            log::info!("Application is up to date");
        }
        Err(e) => {
            // Not an error in development when no update endpoints are configured
            log::debug!("Update check skipped or failed: {}", e);
        }
    }
}

/// Manually check for updates.
///
/// Returns a JSON object with update info if available, or null if up to date.
/// Callable from JS via:
/// ```js
/// import { invoke } from '@tauri-apps/api/core';
/// const update = await invoke('check_for_updates');
/// ```
#[tauri::command]
pub async fn check_for_updates(app: tauri::AppHandle) -> Result<Option<UpdateInfo>, String> {
    let updater = app.updater().map_err(|e| format!("Updater not available: {}", e))?;
    match updater.check().await {
        Ok(Some(update)) => Ok(Some(UpdateInfo {
            current_version: update.current_version.to_string(),
            available_version: update.version.to_string(),
        })),
        Ok(None) => Ok(None),
        Err(e) => Err(format!("Failed to check for updates: {}", e)),
    }
}

/// Serializable update information returned to the frontend.
#[derive(serde::Serialize)]
pub struct UpdateInfo {
    pub current_version: String,
    pub available_version: String,
}
