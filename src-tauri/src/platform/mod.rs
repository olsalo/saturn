#[cfg(target_os = "macos")]
mod bridge;
#[cfg(target_os = "macos")]
pub mod shortcut;
use std::{
    io::{BufRead, BufReader},
    path::PathBuf,
    process::{Command, Stdio},
};
pub fn helper() -> Result<PathBuf, String> {
    if !cfg!(target_os = "macos") {
        return Err(
            "Native recording is currently supported on macOS 15+. Windows support is planned."
                .into(),
        );
    }
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let bundled = exe.parent().unwrap().join("recorder-native");
    if bundled.is_file() {
        return Ok(bundled);
    }
    let target = if cfg!(target_arch = "aarch64") {
        "aarch64-apple-darwin"
    } else {
        "x86_64-apple-darwin"
    };
    Ok(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(format!("binaries/recorder-native-{target}")),
    )
}
pub fn call(command: &str, args: &[&str]) -> Result<serde_json::Value, String> {
    #[cfg(target_os = "macos")]
    if [
        "sources",
        "permissions",
        "request-permission",
        "open-screen-settings",
        "request-microphone-permission",
        "open-microphone-settings",
    ]
    .contains(&command)
    {
        let mut value = serde_json::Value::Null;
        bridge::execute(command, args, |event| {
            value = event;
        })?;
        return Ok(value);
    }
    let out = Command::new(helper()?)
        .arg(command)
        .args(args)
        .output()
        .map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&out.stdout);
    let value: serde_json::Value =
        serde_json::from_str(text.lines().last().unwrap_or("{}")).map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(value["message"]
            .as_str()
            .unwrap_or("Native operation failed")
            .into());
    }
    Ok(value)
}
pub fn stream(
    command: &str,
    request: &std::path::Path,
    mut on_event: impl FnMut(serde_json::Value) + Send,
) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    if command == "record" {
        return bridge::execute(command, &[&request.to_string_lossy()], on_event);
    }
    let mut child = Command::new(helper()?)
        .arg(command)
        .arg(request)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    // Drain diagnostics concurrently so native framework logs cannot block the media process.
    let stderr = child.stderr.take().unwrap();
    let diagnostics = std::thread::spawn(move || {
        let mut tail = String::new();
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            tail = line;
        }
        tail
    });
    let mut error = None;
    for line in BufReader::new(child.stdout.take().unwrap()).lines() {
        let line = line.map_err(|e| e.to_string())?;
        if let Ok(event) = serde_json::from_str::<serde_json::Value>(&line) {
            if event["type"] == "error" {
                error = Some(
                    event["message"]
                        .as_str()
                        .unwrap_or("Native error")
                        .to_string(),
                )
            }
            on_event(event)
        }
    }
    let status = child.wait().map_err(|e| e.to_string())?;
    let tail = diagnostics.join().unwrap_or_default();
    if !status.success() {
        return Err(error.unwrap_or_else(|| format!("Native process stopped. {tail}")));
    }
    Ok(())
}
