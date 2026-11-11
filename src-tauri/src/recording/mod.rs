use crate::*;
use serde::Deserialize;
use tauri::Manager;
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingOptions {
    source: serde_json::Value,
    system_audio: bool,
    microphone: bool,
}
pub fn start(app: &tauri::AppHandle, options: RecordingOptions) -> Result<()> {
    let state = app.state::<Shared>();
    let mut s = lock(&state)?;
    ensure_editable(&s)?;
    if s.project
        .as_ref()
        .is_some_and(|p| p.work.join("dirty").exists())
    {
        return Err("Save the current project before recording".into());
    }
    let kind = options.source["kind"]
        .as_str()
        .ok_or("Select a capture source")?;
    let id = options.source["id"]
        .as_str()
        .ok_or("Select a capture source")?;
    if !["window", "display"].contains(&kind)
        || id.parse::<u32>().ok().filter(|id| *id > 0).is_none()
    {
        return Err("Choose a window or screen before recording".into());
    }
    let defaults = if kind == "display" {
        s.display_defaults.clone()
    } else {
        s.window_defaults.clone()
    };
    let folder = recordings_folder(&state)?;
    let work = workspace(&state)?;
    project::disk::ensure_space(&work, 256 * 1024 * 1024)?;
    project::disk::ensure_space(&folder, 256 * 1024 * 1024)?;
    let path = unique_path(
        &folder,
        &format!(
            "Recording {}",
            chrono::Local::now().format("%Y-%m-%d %H.%M")
        ),
        "saturn",
    );
    fs::write(work.join("dirty"), b"").map_err(|e| e.to_string())?;
    fs::write(
        work.join("recovery.json"),
        serde_json::to_vec(&serde_json::json!({"destination":path})).unwrap(),
    )
    .map_err(|e| e.to_string())?;
    let request = work.join("capture-request.json");
    let mut value = serde_json::to_value(&options).unwrap();
    value["workspace"] = serde_json::json!(work);
    value["filterMode"] = serde_json::json!("crop");
    fs::write(&request, serde_json::to_vec(&value).unwrap()).map_err(|e| e.to_string())?;
    s.mode = "starting".into();
    s.error = None;
    s.work = Some(work.clone());
    s.output = None;
    notify(app, &s);
    let handle = app.clone();
    std::thread::spawn(move || {
        let mut result = None;
        let mut warning: Option<String> = None;
        let native = platform::stream("record", &request, |event| {
            if event["type"] == "started" {
                let state = handle.state::<Shared>();
                if let Ok(mut s) = state.inner.lock() {
                    s.mode = "recording".into();
                    s.started_at_ms = Some(chrono::Utc::now().timestamp_millis());
                    notify(&handle, &s);
                };
            }
            if event["type"] == "finished" {
                warning = event["warning"].as_str().map(String::from);
                result = Some(event);
                let state = handle.state::<Shared>();
                if let Ok(mut s) = state.inner.lock() {
                    s.mode = "finalizing".into();
                    notify(&handle, &s);
                };
            }
        });
        let outcome = native.and_then(|_| {
            let v = result.ok_or("Native recorder returned no recording")?;
            let mut m = project::manifest::Manifest::new(
                v["durationUs"].as_u64().ok_or("Missing duration")?,
                v["width"].as_u64().unwrap_or(0) as u32,
                v["height"].as_u64().unwrap_or(0) as u32,
                options.system_audio,
                options.microphone,
            );
            if options.source["kind"] == "display" {
                m.set_display_capture();
            }
            if let Some(audio) = v.get("separateAudio") {
                m.media.separate_audio =
                    Some(serde_json::from_value(audio.clone()).map_err(|e| e.to_string())?);
            }
            defaults.apply(&mut m, &work)?;
            let p = Project {
                work: work.clone(),
                path,
                manifest: m,
            };
            p.save()?;
            let _ = fs::remove_file(work.join("dirty"));
            Ok(p)
        });
        let state = handle.state::<Shared>();
        let mut s = state.inner.lock().unwrap();
        s.work = None;
        match outcome {
            Ok(p) => {
                scoped(&handle, &p);
                retire(s.project.replace(p));
                s.mode = "export_ready".into();
                s.error = warning
            }
            Err(e) => {
                s.mode = if s.project.is_some() {
                    "export_ready"
                } else {
                    "idle"
                }
                .into();
                if has_recoverable_data(&work) {
                    s.error = Some(recovery_error_message(&e));
                    if !s.recoveries.contains(&work) {
                        s.recoveries.push(work);
                    }
                } else {
                    s.error = Some(e);
                    let _ = fs::remove_dir_all(&work);
                }
            }
        }
        notify(&handle, &s);
    });
    Ok(())
}

fn recovery_error_message(error: &str) -> String {
    if error.contains("Operation not permitted (os error 1)") {
        "Saturn couldn’t finish the recording because macOS denied access. Your captured files were kept for recovery.".into()
    } else {
        format!("Saturn couldn’t finish the recording. Your captured files were kept for recovery. Details: {error}")
    }
}

#[cfg(test)]
mod tests {
    use super::recovery_error_message;

    #[test]
    fn recovery_errors_explain_permission_denial_and_preserve_other_details() {
        let permission = recovery_error_message("Operation not permitted (os error 1)");
        assert!(permission.contains("macOS denied access"));
        assert!(permission.contains("kept for recovery"));
        assert!(recovery_error_message("disk full").contains("disk full"));
    }
}
