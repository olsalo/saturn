//! Register on the main thread; Carbon owns the key until app exit.
use std::sync::OnceLock;
use tauri::Emitter;

static APP: OnceLock<tauri::AppHandle> = OnceLock::new();

unsafe extern "C" {
    fn saturn_register_recording_shortcut(callback: extern "C" fn(), pause: extern "C" fn())
        -> i32;
    fn saturn_unregister_recording_shortcut();
}

extern "C" fn toggle() {
    if let Some(app) = APP.get() {
        let _ = app.emit("recorder://toggle-recording", ());
    }
}

extern "C" fn toggle_pause() {
    if let Some(app) = APP.get() {
        let _ = app.emit("recorder://toggle-pause", ());
    }
}

pub fn register(app: &tauri::AppHandle) -> Result<(), String> {
    let _ = APP.set(app.clone());
    // SAFETY: Tauri calls setup on the main thread. This static callback and
    // its AppHandle remain valid until process exit.
    let status = unsafe { saturn_register_recording_shortcut(toggle, toggle_pause) };
    if status == 0 {
        Ok(())
    } else {
        Err(format!(
            "Could not enable ⌃⌥⌘R and ⌃⌥⌘P (macOS error {status}). Another app may already use one. Use the recording buttons or status-bar controls instead."
        ))
    }
}

pub fn unregister() {
    // SAFETY: RunEvent::Exit runs on the main thread, after setup.
    unsafe { saturn_unregister_recording_shortcut() }
}
