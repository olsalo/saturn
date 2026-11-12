use crate::*;
use tauri::Manager;
pub fn start(app: &tauri::AppHandle, choose: bool, format: &str) -> Result<()> {
    let encoder = match format {
        "web" => "web",
        "hevc" => "ffmpeg",
        "h264" => "h264",
        _ => return Err("Unsupported export format".into()),
    };
    let website = match format {
        "web" => true,
        "hevc" | "h264" => false,
        _ => return Err("Unsupported export format".into()),
    };
    let state = app.state::<Shared>();
    let mut s = lock(&state)?;
    ensure_editable(&s)?;
    let project = s.project.as_ref().ok_or("No project to export")?.clone();
    project.manifest.validate()?;
    // Never replace a moved project or a previous export implicitly.
    if !project.path.is_file() {
        return Err("Project moved or was removed. Use Save As before exporting.".into());
    }
    let stem = project.path.file_stem().unwrap().to_string_lossy();
    let default = if website {
        unique_website_path(project.path.parent().unwrap(), &stem)
    } else {
        unique_path(project.path.parent().unwrap(), &stem, "mp4")
    };
    let destination = if choose && website {
        let Some(parent) = rfd::FileDialog::new()
            .set_title("Choose a folder for the website videos")
            .set_directory(project.path.parent().unwrap())
            .pick_folder()
        else {
            return Ok(());
        };
        unique_website_path(&parent, &stem)
    } else if choose {
        let Some(p) = rfd::FileDialog::new()
            .add_filter("MP4 video", &["mp4"])
            .set_directory(project.path.parent().unwrap())
            .set_file_name(default.file_name().unwrap().to_string_lossy())
            .save_file()
        else {
            return Ok(());
        };
        p.with_extension("mp4")
    } else {
        default
    };
    let source_bytes = fs::metadata(project.work.join(&project.manifest.media.path))
        .map_err(|e| e.to_string())?
        .len();
    let media = &project.manifest.media;
    let fps = (media.frame_rate.numerator / media.frame_rate.denominator).clamp(1, 60) as u64;
    // ProRes is a high-fidelity temporary master, so reserve by rendered pixels
    // and duration rather than by the much smaller compressed source file.
    let frames = media.duration_us.saturating_mul(fps) / 1_000_000 + 1;
    let master_bytes = frames
        .saturating_mul(project.manifest.export_settings.width as u64)
        .saturating_mul(project.manifest.export_settings.height as u64)
        .saturating_mul(3)
        / 5;
    project::disk::ensure_space(&project.work, master_bytes.max(256 * 1024 * 1024))?;
    project::disk::ensure_space(
        destination.parent().ok_or("Invalid export destination")?,
        source_bytes
            .saturating_mul(if website { 4 } else { 2 })
            .max(256 * 1024 * 1024),
    )?;
    if destination == project.path {
        return Err("Export must be separate from the project".into());
    }
    if project.work.join("dirty").exists() {
        save_current(app, &mut s)?;
    }
    let id = uuid::Uuid::new_v4().to_string();
    let temp = destination.parent().unwrap().join(if website {
        format!(".saturn-{id}")
    } else {
        format!(".saturn-{id}.mp4")
    });
    let request = project.work.join("export-request.json");
    let cancel = project.work.join("cancel-export");
    let _ = fs::remove_file(&cancel);
    fs::write(
        &request,
        serde_json::to_vec(
            &serde_json::json!({"workspace":project.work,"output":temp,"encoder":encoder}),
        )
        .unwrap(),
    )
    .map_err(|e| e.to_string())?;
    s.mode = "exporting".into();
    s.progress = 0.;
    s.error = None;
    s.job = Some(id);
    notify(app, &s);
    let handle = app.clone();
    std::thread::spawn(move || {
        let mut finished = false;
        let outcome = platform::stream("export", &request, |event| {
            if event["type"] == "finished" {
                finished = true;
            }
            if event["type"] == "progress" {
                let state = handle.state::<Shared>();
                if let Ok(mut s) = state.inner.lock() {
                    s.progress = event["fraction"].as_f64().unwrap_or(0.).clamp(0., 0.999);
                    notify(&handle, &s)
                };
            }
        })
        .and_then(|_| {
            if cancel.exists() {
                return Err("Export cancelled".into());
            }
            if !finished {
                return Err("Encoder did not finish the export".into());
            }
            validate_export_files(&temp, website)?;
            if website && destination.exists() {
                return Err(
                    "Website export destination already exists; existing files were kept.".into(),
                );
            }
            fs::rename(&temp, &destination).map_err(|e| e.to_string())?;
            Ok(())
        });
        if website {
            let _ = fs::remove_dir_all(&temp);
        } else {
            let _ = fs::remove_file(&temp);
        }
        let state = handle.state::<Shared>();
        let mut s = state.inner.lock().unwrap();
        s.job = None;
        match outcome {
            Ok(()) => {
                s.output = Some(destination);
                s.mode = "done".into();
                s.progress = 1.;
                s.error = None
            }
            Err(e) => {
                s.mode = "export_ready".into();
                s.error = if cancel.exists() { None } else { Some(e) }
            }
        }
        let _ = fs::remove_file(cancel);
        notify(&handle, &s);
    });
    Ok(())
}

fn unique_website_path(parent: &Path, name: &str) -> PathBuf {
    let mut path = parent.join(format!("{name}-web"));
    let mut number = 2;
    while path.exists() {
        path = parent.join(format!("{name}-web {number}"));
        number += 1;
    }
    path
}

fn validate_export_files(path: &Path, website: bool) -> Result<()> {
    let files = if website {
        [
            "video-av1.webm",
            "video-vp9.webm",
            "poster.jpg",
            "embed.html",
            "README.txt",
        ]
        .into_iter()
        .map(|name| path.join(name))
        .collect::<Vec<_>>()
    } else {
        vec![path.to_path_buf()]
    };
    for file in files {
        if !file.is_file() || fs::metadata(&file).map_err(|e| e.to_string())?.len() == 0 {
            return Err("Encoder did not produce all export files".into());
        }
        fs::File::open(&file)
            .map_err(|e| e.to_string())?
            .sync_all()
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn website_exports_require_all_bundle_files() {
        let root = std::env::temp_dir().join(format!("saturn-web-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        for name in ["video-av1.webm", "video-vp9.webm", "embed.html"] {
            fs::write(root.join(name), b"fixture").unwrap();
        }
        assert!(validate_export_files(&root, true).is_err());
        fs::write(root.join("README.txt"), b"fixture").unwrap();
        assert!(validate_export_files(&root, true).is_err());
        fs::write(root.join("poster.jpg"), b"fixture").unwrap();
        assert!(validate_export_files(&root, true).is_ok());
        fs::write(root.join("video-vp9.webm"), b"").unwrap();
        assert!(validate_export_files(&root, true).is_err());
        let first = unique_website_path(&root, "recording");
        fs::create_dir(&first).unwrap();
        assert_eq!(
            unique_website_path(&root, "recording"),
            root.join("recording-web 2")
        );
        fs::remove_dir_all(root).unwrap();
    }
}
