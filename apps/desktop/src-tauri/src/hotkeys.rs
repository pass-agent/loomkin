use tauri::{App, Manager};
use tauri_plugin_global_shortcut::GlobalShortcutExt;

/// Register global hotkeys for the application.
///
/// - Cmd+Shift+L (macOS) / Ctrl+Shift+L (Windows/Linux): Toggle Loomkin window
/// - Cmd+Shift+N (macOS) / Ctrl+Shift+N (Windows/Linux): Open new session
pub fn register_hotkeys(app: &App) -> Result<(), Box<dyn std::error::Error>> {
    let handle = app.handle().clone();

    // Toggle window visibility: CmdOrCtrl+Shift+L
    app.global_shortcut().on_shortcut("CmdOrCtrl+Shift+L", {
        let handle = handle.clone();
        move |_app, _shortcut, _event| {
            if let Some(window) = handle.get_webview_window("main") {
                if window.is_visible().unwrap_or(false) {
                    let _ = window.hide();
                } else {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
        }
    })?;

    // Open new session: CmdOrCtrl+Shift+N
    app.global_shortcut().on_shortcut("CmdOrCtrl+Shift+N", {
        let handle = handle.clone();
        move |_app, _shortcut, _event| {
            if let Some(window) = handle.get_webview_window("main") {
                let _ = window.show();
                let _ = window.set_focus();
                let _ = window.eval("window.location.href = '/sessions/new'");
            }
        }
    })?;

    Ok(())
}
