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
    let mut defaults = if kind == "display" {
        s.display_defaults.clone()
    } else {
        s.window_defaults.clone()
    };
    if kind == "window" {
        let background = project::background::random(app)?;
        defaults.background = Some((background.background, Some(background.bytes)));
    }
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
    s.started_at_ms = None;
    s.recorded_duration_ms = 0;
    s.error = None;
    s.work = Some(work.clone());
    s.output = None;
    notify(app, &s);
    let handle = app.clone();
    std::thread::spawn(move || {
        let mut result = None;
        let mut warning: Option<String> = None;
        let native = platform::stream("record", &request, |event| {
            if event["type"] == "continueRequested" {
                let _ = handle.emit("recorder://toggle-pause", ());
            }
            if let Some(mode) = match event["type"].as_str() {
                Some("started") => Some("recording"),
                Some("pausing") => Some("pausing"),
                Some("paused") => Some("paused"),
                Some("resuming") => Some("resuming"),
                _ => None,
            } {
                let state = handle.state::<Shared>();
                if let Ok(mut s) = state.inner.lock() {
                    let now = chrono::Utc::now().timestamp_millis();
                    if mode == "recording" {
                        s.recorded_duration_ms = event["recordedDurationMs"].as_i64().unwrap_or(0);
                        s.started_at_ms = Some(now);
                    } else if mode == "pausing" {
                        if let Some(start) = s.started_at_ms.take() {
                            s.recorded_duration_ms += (now - start).max(0);
                        }
                    } else if mode == "paused" {
                        s.started_at_ms = None;
                        s.recorded_duration_ms = event["recordedDurationMs"].as_i64().unwrap_or(0);
                    }
                    if s.mode != "stopping" {
                        s.mode = mode.into();
                    }
                    notify(&handle, &s);
                };
            }
            if event["type"] == "clipFinished" {
                // The native journal is also retained if this checkpoint fails.
                if let Ok(mut m) = manifest_from_clips(&event) {
                    if options.source["kind"] == "display" {
                        m.set_display_capture();
                    }
                    let _ = project::archive::write_manifest(&work, &m);
                }
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
            let mut m = manifest_from_clips(&v)?;
            if options.source["kind"] == "display" {
                m.set_display_capture();
            }
            defaults.apply(&mut m, &work)?;
            let mut p = Project {
                work: work.clone(),
                path,
                manifest: m,
            };
            let save_state = handle.state::<Shared>();
            save_recording_with_folder_retry(&mut p, &save_state)?;
            let _ = fs::remove_file(work.join("dirty"));
            let _ = fs::remove_file(work.join("clips.json"));
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
    if recovery_permission_failure(error) {
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

pub fn manifest_from_clips(value: &serde_json::Value) -> Result<project::manifest::Manifest> {
    let clips: Vec<project::manifest::Clip> =
        serde_json::from_value(value["clips"].clone()).map_err(|e| e.to_string())?;
    let first = clips.first().ok_or("No completed recording clips")?;
    let media = &first.media;
    let mut m = project::manifest::Manifest::new(
        media.duration_us,
        media.width,
        media.height,
        media.has_system_audio,
        media.has_microphone_audio,
    );
    m.set_clips(clips)?;
    Ok(m)
}
