use crate::*;
use tauri::Manager;
pub fn start(app: &tauri::AppHandle, choose: bool) -> Result<()> {
    let state = app.state::<Shared>();
    let mut s = lock(&state)?;
    ensure_editable(&s)?;
    let project = s.project.as_ref().ok_or("No project to export")?.clone();
    project.manifest.validate()?;
    // Never replace a moved project or a previous export implicitly.
    if !project.path.is_file() {
        return Err("Project moved or was removed. Use Save As before exporting.".into());
    }
    let default = unique_path(
        project.path.parent().unwrap(),
        &project.path.file_stem().unwrap().to_string_lossy(),
        "mp4",
    );
    let destination = if choose {
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
        source_bytes.saturating_mul(2).max(256 * 1024 * 1024),
    )?;
    if destination == project.path {
        return Err("Export must be separate from the project".into());
    }
    if project.work.join("dirty").exists() {
        save_current(app, &mut s)?;
    }
    let id = uuid::Uuid::new_v4().to_string();
    let temp = destination
        .parent()
        .unwrap()
        .join(format!(".saturn-{id}.mp4"));
    let request = project.work.join("export-request.json");
    let cancel = project.work.join("cancel-export");
    let _ = fs::remove_file(&cancel);
    fs::write(
        &request,
        serde_json::to_vec(&serde_json::json!({"workspace":project.work,"output":temp})).unwrap(),
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
            if !finished
                || !temp.is_file()
                || fs::metadata(&temp).map_err(|e| e.to_string())?.len() == 0
            {
                return Err("Encoder did not produce a valid MP4".into());
            }
            fs::File::open(&temp)
                .map_err(|e| e.to_string())?
                .sync_all()
                .map_err(|e| e.to_string())?;
            fs::rename(&temp, &destination).map_err(|e| e.to_string())?;
            Ok(())
        });
        let _ = fs::remove_file(&temp);
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
