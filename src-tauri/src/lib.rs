mod export;
mod platform;
mod project;
mod recording;
use project::{manifest::Appearance, Project};
use serde::Serialize;
use std::{
    fs,
    path::{Path, PathBuf},
    sync::Mutex,
};
use tauri::{Emitter, Manager};

type Result<T> = std::result::Result<T, String>;
#[derive(Default)]
pub struct Session {
    mode: String,
    started_at_ms: Option<i64>,
    project: Option<Project>,
    work: Option<PathBuf>,
    job: Option<String>,
    output: Option<PathBuf>,
    error: Option<String>,
    progress: f64,
    pending: Vec<PathBuf>,
    recoveries: Vec<PathBuf>,
    saving: bool,
    window_defaults: CaptureDefaults,
    display_defaults: CaptureDefaults,
}
#[derive(Clone, Default)]
struct CaptureDefaults {
    aspect_ratio: Option<String>,
    resolution: Option<String>,
    background: Option<(project::manifest::Background, Option<Vec<u8>>)>,
}
impl CaptureDefaults {
    fn window() -> Self {
        Self {
            aspect_ratio: Some("16:10".into()),
            resolution: Some("high".into()),
            background: None,
        }
    }
    fn display() -> Self {
        Self {
            aspect_ratio: Some("original".into()),
            resolution: Some("original".into()),
            background: None,
        }
    }
    fn apply(self, manifest: &mut project::manifest::Manifest, work: &Path) -> Result<()> {
        if let Some(ratio) = self.aspect_ratio {
            manifest.export_settings.aspect_ratio = Some(ratio);
        }
        if let Some(resolution) = self.resolution {
            manifest.export_settings.resolution = Some(resolution);
        }
        if let Some((background, bytes)) = self.background {
            if let project::manifest::Background::EmbeddedImage { path, .. } = &background {
                let bytes = bytes.ok_or("Missing session background image")?;
                let name = path
                    .strip_prefix("assets/")
                    .ok_or("Invalid background reference")?;
                if !["background.jpg", "background.png"].contains(&name) {
                    return Err("Invalid background reference".into());
                }
                project::write_background(work, name, &bytes)?;
            }
            manifest.appearance.background = background;
        }
        manifest.update_export_dimensions();
        Ok(())
    }
}
impl Session {
    fn defaults_mut(&mut self, kind: &str) -> &mut CaptureDefaults {
        if kind == "display" {
            &mut self.display_defaults
        } else {
            &mut self.window_defaults
        }
    }
    fn remember_background(&mut self) -> Result<()> {
        let p = self.project.as_ref().ok_or("No open project")?;
        let kind = p.manifest.media.capture_kind.clone();
        let background = p.manifest.appearance.background.clone();
        let bytes = match &background {
            project::manifest::Background::EmbeddedImage { path, .. } => {
                Some(fs::read(p.work.join(path)).map_err(|e| e.to_string())?)
            }
            _ => None,
        };
        self.defaults_mut(&kind).background = Some((background, bytes));
        Ok(())
    }
}
pub struct Shared {
    inner: Mutex<Session>,
    root: PathBuf,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ProjectView {
    path: String,
    display_name: String,
    duration_us: u64,
    capture_kind: String,
    width: u32,
    height: u32,
    thumbnail_path: Option<String>,
    background_path: Option<String>,
    background_revision: Option<u64>,
    appearance: Appearance,
    export_width: u32,
    export_height: u32,
    aspect_ratio: String,
    resolution: String,
    export_fps: u32,
    separate_audio: bool,
    has_system_audio: bool,
    has_microphone_audio: bool,
    include_system_audio: bool,
    include_microphone_audio: bool,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    mode: String,
    started_at_ms: Option<i64>,
    project: Option<ProjectView>,
    error: Option<String>,
    progress: f64,
    output_path: Option<String>,
    output_is_website: bool,
    job_id: Option<String>,
    pending_count: usize,
    recoveries: Vec<String>,
    saving: bool,
}
fn snapshot(s: &Session) -> Snapshot {
    Snapshot {
        started_at_ms: s.started_at_ms,
        mode: if s.mode.is_empty() {
            "idle".into()
        } else {
            s.mode.clone()
        },
        project: s.project.as_ref().map(|p| ProjectView {
            path: p.path.to_string_lossy().into(),
            display_name: p
                .path
                .file_stem()
                .unwrap_or_default()
                .to_string_lossy()
                .into(),
            duration_us: p.manifest.media.duration_us,
            capture_kind: p.manifest.media.capture_kind.clone(),
            width: p.manifest.media.width,
            height: p.manifest.media.height,
            thumbnail_path: p.work.join("preview/thumbnail.jpg").is_file().then(|| {
                p.work
                    .join("preview/thumbnail.jpg")
                    .to_string_lossy()
                    .into()
            }),
            background_path: if let project::manifest::Background::EmbeddedImage { path, .. } =
                &p.manifest.appearance.background
            {
                Some(p.work.join(path).to_string_lossy().into())
            } else {
                None
            },
            background_revision: if let project::manifest::Background::EmbeddedImage {
                path, ..
            } = &p.manifest.appearance.background
            {
                fs::metadata(p.work.join(path))
                    .ok()
                    .and_then(|m| m.modified().ok())
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_millis() as u64)
            } else {
                None
            },
            appearance: p.manifest.appearance.clone(),
            export_width: p.manifest.export_settings.width,
            export_height: p.manifest.export_settings.height,
            aspect_ratio: if matches!(
                p.manifest.appearance.background,
                project::manifest::Background::None
            ) {
                "original".into()
            } else {
                p.manifest
                    .export_settings
                    .aspect_ratio
                    .clone()
                    .unwrap_or_else(|| "16:10".into())
            },
            resolution: p
                .manifest
                .export_settings
                .resolution
                .clone()
                .unwrap_or_else(|| "high".into()),
            separate_audio: p.manifest.media.separate_audio.is_some(),
            has_system_audio: p
                .manifest
                .media
                .separate_audio
                .as_ref()
                .is_some_and(|a| a.system.is_some()),
            has_microphone_audio: p
                .manifest
                .media
                .separate_audio
                .as_ref()
                .is_some_and(|a| a.microphone.is_some()),
            include_system_audio: p.manifest.export_settings.include_system_audio,
            include_microphone_audio: p.manifest.export_settings.include_microphone_audio,
            export_fps: p.manifest.export_settings.frame_rate.min(
                (p.manifest.media.frame_rate.numerator as f64
                    / p.manifest.media.frame_rate.denominator.max(1) as f64)
                    .round()
                    .max(1.0) as u32,
            ),
        }),
        error: s.error.clone(),
        progress: s.progress,
        output_path: s.output.as_ref().map(|p| p.to_string_lossy().into()),
        output_is_website: s.output.as_ref().is_some_and(|p| p.is_dir()),
        job_id: s.job.clone(),
        pending_count: s.pending.len(),
        recoveries: s
            .recoveries
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into())
            .collect(),
        saving: s.saving,
    }
}
fn notify(app: &tauri::AppHandle, s: &Session) {
    let _ = app.emit("recorder://snapshot", snapshot(s));
}
fn lock(state: &Shared) -> Result<std::sync::MutexGuard<'_, Session>> {
    state
        .inner
        .try_lock()
        .map_err(|_| "Another operation is still finishing".into())
}
fn ensure_editable(s: &Session) -> Result<()> {
    if [
        "starting",
        "recording",
        "stopping",
        "finalizing",
        "exporting",
    ]
    .contains(&s.mode.as_str())
    {
        Err("Finish the current recording or export first".into())
    } else {
        Ok(())
    }
}
fn workspace(state: &Shared) -> Result<PathBuf> {
    let work = state
        .root
        .join("sessions")
        .join(uuid::Uuid::new_v4().to_string());
    fs::create_dir_all(&work).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&work, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?;
    }
    for d in ["media", "cursor", "assets", "preview"] {
        fs::create_dir_all(work.join(d)).map_err(|e| e.to_string())?;
    }
    Ok(work)
}
fn check_folder_access(folder: &Path) -> std::io::Result<()> {
    // A successful metadata check does not imply macOS will permit file creation.
    let probe = folder.join(format!(".saturn-access-{}", uuid::Uuid::new_v4()));
    let file = fs::OpenOptions::new().write(true).create_new(true).open(&probe)?;
    drop(file);
    fs::remove_file(probe)
}
fn choose_recordings_folder(state: &Shared) -> Result<PathBuf> {
    let folder = rfd::FileDialog::new()
        .set_title("Choose a folder to allow Saturn to save recordings")
        .pick_folder()
        .ok_or("No folder selected. Choose a folder to allow Saturn to save recordings.")?;
    check_folder_access(&folder).map_err(|e| format!(
        "Saturn cannot write to the selected folder: {e}. Choose a different folder or allow access in System Settings."
    ))?;
    let pref = state.root.join("preferences.json");
    fs::write(
        pref,
        serde_json::to_vec(&serde_json::json!({"recordingsFolder":folder})).unwrap(),
    )
    .map_err(|e| e.to_string())?;
    Ok(folder)
}
fn recordings_folder(state: &Shared) -> Result<PathBuf> {
    let pref = state.root.join("preferences.json");
    if let Ok(data) = fs::read(&pref) {
        if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&data) {
            if let Some(p) = v["recordingsFolder"].as_str() {
                let folder = PathBuf::from(p);
                if check_folder_access(&folder).is_ok() {
                    return Ok(folder);
                }
            }
        }
    }
    choose_recordings_folder(state)
}
fn permission_error(error: &std::io::Error) -> bool {
    error.kind() == std::io::ErrorKind::PermissionDenied || error.raw_os_error() == Some(libc::EPERM)
}
const FILE_ACCESS_REQUIRED: &str = "SATURN_FILE_ACCESS_REQUIRED";
fn recovery_permission_failure(error: &str) -> bool {
    error.contains("os error 1)") || error.contains("os error 13)") || error.contains(FILE_ACCESS_REQUIRED)
}
fn save_recording_with_folder_retry(project: &mut Project, _state: &Shared) -> Result<()> {
    let parent = project.path.parent().ok_or("Invalid save folder")?;
    if let Err(error) = check_folder_access(parent) {
        return if permission_error(&error) {
            Err(FILE_ACCESS_REQUIRED.into())
        } else {
            Err(format!("Cannot access the recordings folder: {error}"))
        };
    }
    project.save().map_err(|error| {
        if recovery_permission_failure(&error) { FILE_ACCESS_REQUIRED.into() } else { error }
    })
}
fn unique_path(parent: &Path, name: &str, ext: &str) -> PathBuf {
    let mut path = parent.join(format!("{name}.{ext}"));
    let mut n = 2;
    while path.exists() {
        path = parent.join(format!("{name} {n}.{ext}"));
        n += 1;
    }
    path
}
fn scoped(app: &tauri::AppHandle, project: &Project) {
    for relative in [
        "preview/thumbnail.jpg",
        "assets/background.jpg",
        "assets/background.png",
    ] {
        let p = project.work.join(relative);
        if p.is_file() {
            let _ = app.asset_protocol_scope().allow_file(p);
        }
    }
}
fn retire(old: Option<Project>) {
    if let Some(p) = old {
        if !p.work.join("dirty").exists() {
            let _ = fs::remove_dir_all(p.work);
        }
    }
}
fn open_path(app: &tauri::AppHandle, s: &mut Session, state: &Shared, path: PathBuf) -> Result<()> {
    ensure_editable(s)?;
    if !matches!(
        path.extension().and_then(|s| s.to_str()),
        Some("saturn" | "recproj")
    ) {
        return Err("Choose a .saturn project (or a legacy .recproj project)".into());
    }
    let path = fs::canonicalize(path).map_err(|e| e.to_string())?;
    let work = state
        .root
        .join("sessions")
        .join(uuid::Uuid::new_v4().to_string());
    let mut manifest = project::archive::open(&path, &work)?;
    manifest.use_export_layout();
    let p = Project {
        path,
        work,
        manifest,
    };
    p.checkpoint()?;
    scoped(app, &p);
    retire(s.project.replace(p));
    s.mode = "export_ready".into();
    s.output = None;
    s.error = None;
    s.progress = 0.;
    notify(app, s);
    Ok(())
}
async fn blocking<T: Send + 'static>(f: impl FnOnce() -> Result<T> + Send + 'static) -> Result<T> {
    tauri::async_runtime::spawn_blocking(f)
        .await
        .map_err(|e| e.to_string())?
}
#[tauri::command]
fn get_snapshot(state: tauri::State<Shared>) -> Result<Snapshot> {
    Ok(snapshot(&*lock(&state)?))
}
#[tauri::command]
async fn list_capture_sources() -> Result<serde_json::Value> {
    blocking(|| platform::call("sources", &[])).await
}
#[tauri::command]
async fn check_capture_permissions() -> Result<serde_json::Value> {
    blocking(|| platform::call("permissions", &[])).await
}
#[tauri::command]
async fn request_capture_permission() -> Result<serde_json::Value> {
    blocking(|| platform::call("request-permission", &[])).await
}
#[tauri::command]
async fn open_screen_recording_settings() -> Result<()> {
    blocking(|| platform::call("open-screen-settings", &[]).map(|_| ())).await
}
#[tauri::command]
async fn open_file_access_settings() -> Result<()> {
    blocking(|| platform::call("open-file-settings", &[]).map(|_| ())).await
}
#[tauri::command]
async fn request_microphone_permission() -> Result<serde_json::Value> {
    blocking(|| platform::call("request-microphone-permission", &[])).await
}
#[tauri::command]
async fn open_microphone_settings() -> Result<()> {
    blocking(|| platform::call("open-microphone-settings", &[]).map(|_| ())).await
}
fn has_recoverable_data(work: &Path) -> bool {
    work.join("manifest.json").is_file()
        || fs::metadata(work.join("media/source.mov")).is_ok_and(|m| m.is_file() && m.len() > 0)
        || fs::metadata(work.join("media/source.mp4")).is_ok_and(|m| m.is_file() && m.len() > 0)
}
fn is_recovery_candidate(work: &Path) -> bool {
    has_recoverable_data(work)
        && (work.join("dirty").exists()
            || (!work.join("manifest.json").exists() && work.join("media/source.mov").exists()))
}
fn mark_recovery_complete(work: &Path) -> Result<()> {
    match fs::remove_file(work.join("dirty")) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("The project was saved, but Saturn could not mark recovery complete: {error}")),
    }
}
#[tauri::command]
async fn start_recording(
    app: tauri::AppHandle,
    options: recording::RecordingOptions,
) -> Result<()> {
    blocking(move || recording::start(&app, options)).await
}
#[tauri::command]
fn stop_recording(app: tauri::AppHandle) -> Result<()> {
    let state = app.state::<Shared>();
    let mut s = lock(&state)?;
    if s.mode != "recording" {
        return Err("No active recording".into());
    }
    let work = s.work.as_ref().ok_or("No active workspace")?;
    fs::write(work.join("stop"), b"").map_err(|e| e.to_string())?;
    s.mode = "stopping".into();
    notify(&app, &s);
    Ok(())
}
#[tauri::command]
async fn open_project(app: tauri::AppHandle, pending: Option<bool>) -> Result<()> {
    blocking(move || {
        let state = app.state::<Shared>();
        let mut s = lock(&state)?;
        ensure_editable(&s)?;
        let path = if pending.unwrap_or(false) {
            if s.pending.is_empty() {
                return Ok(());
            }
            s.pending[0].clone()
        } else {
            match rfd::FileDialog::new()
                .add_filter("Saturn project", &["saturn", "recproj"])
                .pick_file()
            {
                Some(p) => p,
                None => return Ok(()),
            }
        };
        open_path(&app, &mut s, &state, path)?;
        if pending.unwrap_or(false) {
            s.pending.remove(0);
            notify(&app, &s)
        }
        Ok(())
    })
    .await
}
#[tauri::command]
async fn update_project_appearance(app: tauri::AppHandle, appearance: Appearance) -> Result<()> {
    blocking(move || {
        appearance.validate()?;
        let state = app.state::<Shared>();
        let mut s = lock(&state)?;
        ensure_editable(&s)?;
        let p = s.project.as_mut().ok_or("No open project")?;
        if let project::manifest::Background::EmbeddedImage { path, .. } = &appearance.background {
            if !p.work.join(path).is_file() {
                return Err("Choose a background image first".into());
            }
        }
        p.manifest.appearance = appearance;
        p.manifest.update_export_dimensions();
        save_current(&app, &mut s)?;
        s.remember_background()
    })
    .await
}
fn save_current(app: &tauri::AppHandle, s: &mut Session) -> Result<()> {
    s.saving = true;
    notify(app, s);
    let p = s.project.as_ref().ok_or("No open project")?;
    fs::write(p.work.join("dirty"), b"").map_err(|e| e.to_string())?;
    let result = if p.path.is_file() {
        p.save()
    } else {
        p.checkpoint().and_then(|_| {
            Err("The project moved or was removed. Use Save As to keep your changes.".into())
        })
    };
    s.saving = false;
    match result {
        Ok(()) => {
            let _ = fs::remove_file(p.work.join("dirty"));
            s.error = None;
        }
        Err(ref e) => s.error = Some(e.clone()),
    };
    notify(app, s);
    result
}
#[tauri::command]
async fn update_aspect_ratio(app: tauri::AppHandle, ratio: String) -> Result<()> {
    blocking(move || {
        if !["16:10", "16:9", "1:1", "9:16", "original"].contains(&ratio.as_str()) {
            return Err("Unsupported aspect ratio".into());
        }
        let state = app.state::<Shared>();
        let mut s = lock(&state)?;
        ensure_editable(&s)?;
        let p = s.project.as_mut().ok_or("No open project")?;
        if p.manifest.media.capture_kind == "display"
            || matches!(
                p.manifest.appearance.background,
                project::manifest::Background::None
            )
        {
            return Err("The canvas matches the recording when there is no background".into());
        }
        let kind = p.manifest.media.capture_kind.clone();
        p.manifest.export_settings.aspect_ratio = Some(ratio.clone());
        p.manifest.update_export_dimensions();
        save_current(&app, &mut s)?;
        s.defaults_mut(&kind).aspect_ratio = Some(ratio);
        Ok(())
    })
    .await
}
#[tauri::command]
async fn update_resolution(app: tauri::AppHandle, resolution: String) -> Result<()> {
    blocking(move || {
        if !["original", "high", "medium", "small"].contains(&resolution.as_str()) {
            return Err("Unsupported resolution".into());
        }
        let state = app.state::<Shared>();
        let mut s = lock(&state)?;
        ensure_editable(&s)?;
        let p = s.project.as_mut().ok_or("No open project")?;
        let kind = p.manifest.media.capture_kind.clone();
        p.manifest.export_settings.resolution = Some(resolution.clone());
        p.manifest.update_export_dimensions();
        save_current(&app, &mut s)?;
        s.defaults_mut(&kind).resolution = Some(resolution);
        Ok(())
    })
    .await
}
#[tauri::command]
async fn update_export_audio(app: tauri::AppHandle, system: bool, microphone: bool) -> Result<()> {
    blocking(move || {
        let state = app.state::<Shared>();
        let mut s = lock(&state)?;
        ensure_editable(&s)?;
        let p = s.project.as_mut().ok_or("No open project")?;
        if p.manifest.media.separate_audio.is_none() {
            return Err("This recording does not have separate audio tracks".into());
        }
        p.manifest.export_settings.include_system_audio = system;
        p.manifest.export_settings.include_microphone_audio = microphone;
        save_current(&app, &mut s)?;
        Ok(())
    })
    .await
}
#[tauri::command]
async fn save_project(app: tauri::AppHandle) -> Result<()> {
    blocking(move || {
        let state = app.state::<Shared>();
        let mut s = lock(&state)?;
        ensure_editable(&s)?;
        save_current(&app, &mut s)
    })
    .await
}
#[tauri::command]
async fn save_project_as(app: tauri::AppHandle) -> Result<()> {
    blocking(move || {
        let state = app.state::<Shared>();
        let mut s = lock(&state)?;
        ensure_editable(&s)?;
        let p = s.project.as_ref().ok_or("No open project")?;
        let Some(path) = rfd::FileDialog::new()
            .add_filter("Saturn project", &["saturn"])
            .set_file_name(
                p.path
                    .with_extension("saturn")
                    .file_name()
                    .unwrap()
                    .to_string_lossy(),
            )
            .save_file()
        else {
            return Ok(());
        };
        let path = path.with_extension("saturn");
        p.manifest.validate()?;
        project::archive::save(&p.work, &path, &p.manifest)?;
        s.project.as_mut().unwrap().path = path;
        s.project.as_ref().unwrap().checkpoint()?;
        let _ = fs::remove_file(s.project.as_ref().unwrap().work.join("dirty"));
        s.error = None;
        notify(&app, &s);
        Ok(())
    })
    .await
}
#[tauri::command]
async fn choose_builtin_background(app: tauri::AppHandle, preset: String) -> Result<()> {
    blocking(move || {
        let catalog: serde_json::Value =
            serde_json::from_str(include_str!("../../src/lib/wallpapers.json"))
                .map_err(|e| e.to_string())?;
        if !catalog.as_array().is_some_and(|items| {
            items
                .iter()
                .any(|item| item["id"].as_str() == Some(&preset))
        }) {
            return Err("Unknown background preset".into());
        }
        let asset = app
            .asset_resolver()
            .get(format!("wallpapers/{preset}"))
            .ok_or("Bundled background image is unavailable")?;
        if !asset.bytes().starts_with(&[255, 216, 255]) || asset.bytes().len() > 32 * 1024 * 1024 {
            return Err("Bundled background is not a supported JPEG image".into());
        }
        let state = app.state::<Shared>();
        let mut s = lock(&state)?;
        ensure_editable(&s)?;
        let p = s.project.as_mut().ok_or("No open project")?;
        let path = "assets/background.jpg";
        project::write_background(&p.work, "background.jpg", asset.bytes())?;
        p.manifest.appearance.background = project::manifest::Background::EmbeddedImage {
            path: path.into(),
            preset: Some(preset),
        };
        p.manifest.update_export_dimensions();
        scoped(&app, p);
        save_current(&app, &mut s)?;
        s.remember_background()
    })
    .await
}
#[tauri::command]
async fn choose_background(app: tauri::AppHandle) -> Result<()> {
    blocking(move || {
        let state = app.state::<Shared>();
        let mut s = lock(&state)?;
        ensure_editable(&s)?;
        let Some(path) = rfd::FileDialog::new()
            .add_filter("Background image", &["jpg", "jpeg", "png"])
            .pick_file()
        else {
            return Ok(());
        };
        let meta = fs::metadata(&path).map_err(|e| e.to_string())?;
        if !meta.is_file() || meta.len() > 32 * 1024 * 1024 {
            return Err("Choose a JPEG or PNG smaller than 32 MB".into());
        }
        let bytes = fs::read(path).map_err(|e| e.to_string())?;
        let ext = if bytes.starts_with(&[137, 80, 78, 71, 13, 10, 26, 10]) {
            "png"
        } else if bytes.starts_with(&[255, 216, 255]) {
            "jpg"
        } else {
            return Err("Invalid JPEG or PNG image".into());
        };
        let p = s.project.as_mut().ok_or("No project open")?;
        let relative = format!("assets/background.{ext}");
        project::write_background(&p.work, &format!("background.{ext}"), &bytes)?;
        p.manifest.appearance.background = project::manifest::Background::EmbeddedImage {
            path: relative,
            preset: None,
        };
        p.manifest.update_export_dimensions();
        scoped(&app, p);
        save_current(&app, &mut s)?;
        s.remember_background()
    })
    .await
}
#[tauri::command]
async fn start_export(
    app: tauri::AppHandle,
    choose_destination: Option<bool>,
    export_format: Option<String>,
) -> Result<()> {
    blocking(move || {
        export::start(
            &app,
            choose_destination.unwrap_or(false),
            export_format.as_deref().unwrap_or("web"),
        )
    })
    .await
}
#[tauri::command]
fn cancel_export(app: tauri::AppHandle, job_id: String) -> Result<()> {
    let state = app.state::<Shared>();
    let s = lock(&state)?;
    if s.mode != "exporting" || s.job.as_deref() != Some(&job_id) {
        return Err("Export job is no longer active".into());
    }
    fs::write(
        s.project
            .as_ref()
            .ok_or("No project")?
            .work
            .join("cancel-export"),
        b"",
    )
    .map_err(|e| e.to_string())
}
#[tauri::command]
async fn file_action(app: tauri::AppHandle, action: String, exported: bool) -> Result<()> {
    blocking(move || {
        let state = app.state::<Shared>();
        let s = lock(&state)?;
        let path = if exported {
            s.output.as_ref()
        } else {
            s.project.as_ref().map(|p| &p.path)
        }
        .ok_or("No file available yet")?;
        if !path.is_file() && !(exported && path.is_dir()) {
            return Err("The file moved or was removed. Use Save As to save another copy.".into());
        }
        if !["reveal", "copy-file", "copy-path"].contains(&action.as_str()) {
            return Err("Unsupported file action".into());
        }
        platform::call(&action, &[&path.to_string_lossy()])?;
        Ok(())
    })
    .await
}
#[tauri::command]
fn edit_project(app: tauri::AppHandle) -> Result<()> {
    let state = app.state::<Shared>();
    let mut s = lock(&state)?;
    ensure_editable(&s)?;
    if s.project.is_none() {
        return Err("No project open".into());
    }
    s.mode = "export_ready".into();
    notify(&app, &s);
    Ok(())
}
#[tauri::command]
fn new_recording(app: tauri::AppHandle) -> Result<()> {
    let state = app.state::<Shared>();
    let mut s = lock(&state)?;
    ensure_editable(&s)?;
    if let Some(p) = &s.project {
        if p.work.join("dirty").exists() {
            return Err("Save the project or use Save As before starting another recording".into());
        }
    }
    retire(s.project.take());
    s.mode = "idle".into();
    s.output = None;
    s.error = None;
    notify(&app, &s);
    Ok(())
}
#[tauri::command]
async fn recover_recording(app: tauri::AppHandle, id: String, choose_folder: bool) -> Result<()> {
    blocking(move || {
        let state = app.state::<Shared>();
        let mut s = lock(&state)?;
        ensure_editable(&s)?;
        let work = s
            .recoveries
            .iter()
            .find(|p| p.file_name().unwrap().to_string_lossy() == id)
            .cloned()
            .ok_or("Recovery no longer available")?;
        let outcome = (|| -> Result<()> {
            let selected_folder = if choose_folder { Some(choose_recordings_folder(&state)?) } else { None };
            let info = fs::read(work.join("recovery.json"))
                .ok()
                .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok());
            let mut manifest = if work.join("manifest.json").is_file() {
                let m: project::manifest::Manifest = serde_json::from_slice(
                    &fs::read(work.join("manifest.json")).map_err(|e| e.to_string())?,
                )
                .map_err(|e| e.to_string())?;
                m.validate()?;
                m
            } else {
                let v = platform::call(
                    "inspect",
                    &[&work.join("media/source.mov").to_string_lossy()],
                )?;
                project::manifest::Manifest::new(
                    v["durationUs"]
                        .as_u64()
                        .ok_or("Invalid recovered duration")?,
                    v["width"].as_u64().unwrap_or(0) as u32,
                    v["height"].as_u64().unwrap_or(0) as u32,
                    false,
                    false,
                )
            };
            if !work.join("manifest.json").is_file() {
                let request = fs::read(work.join("capture-request.json"))
                    .ok()
                    .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok());
                if request
                    .as_ref()
                    .is_some_and(|v| v["source"]["kind"] == "display")
                {
                    manifest.set_display_capture();
                }
            }
            manifest.use_export_layout();
            let original_path = info
                .and_then(|v| v["destination"].as_str().map(PathBuf::from))
                .filter(|p| p.parent().is_some_and(Path::is_dir));
            let path = if let Some(folder) = selected_folder.as_deref() {
                unique_path(folder, "Recovered recording", "saturn")
            } else {
                match original_path {
                    Some(path) if !path.exists() => path,
                    Some(path) => unique_path(path.parent().unwrap(), "Recovered recording", "saturn"),
                    None => return Err(FILE_ACCESS_REQUIRED.into()),
                }
            };
            let mut p = Project {
                work: work.clone(),
                path,
                manifest,
            };
            save_recording_with_folder_retry(&mut p, &state)?;
            mark_recovery_complete(&work)?;
            scoped(&app, &p);
            retire(s.project.replace(p));
            s.mode = "export_ready".into();
            s.error = None;
            Ok(())
        })().map_err(|error| if recovery_permission_failure(&error) { FILE_ACCESS_REQUIRED.into() } else { error });
        if outcome.is_ok() {
            s.recoveries.retain(|p| p != &work);
            let _ = fs::remove_file(work.join("recovery-failed"));
            if s.error.as_deref().is_some_and(|error| error.starts_with("Saturn couldn’t finish the recording")) {
                s.error = None;
            }
        }
        notify(&app, &s);
        outcome
    })
    .await
}
#[tauri::command]
fn discard_recovery(app: tauri::AppHandle, id: String) -> Result<()> {
    let state = app.state::<Shared>();
    let mut s = lock(&state)?;
    ensure_editable(&s)?;
    let work = s
        .recoveries
        .iter()
        .find(|p| {
            p.file_name()
                .is_some_and(|name| name.to_string_lossy() == id)
        })
        .cloned()
        .ok_or("Recovery no longer available")?;
    fs::remove_dir_all(&work).map_err(|e| e.to_string())?;
    s.recoveries.retain(|p| p != &work);
    if s.error.as_deref().is_some_and(|error| error.starts_with("Saturn couldn’t finish the recording")) {
        s.error = None;
    }
    notify(&app, &s);
    Ok(())
}
#[tauri::command]
fn clear_error(app: tauri::AppHandle) -> Result<()> {
    let state = app.state::<Shared>();
    let mut s = lock(&state)?;
    s.error = None;
    notify(&app, &s);
    Ok(())
}

pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            let root = app.path().app_data_dir()?;
            fs::create_dir_all(root.join("sessions"))?;
            for entry in fs::read_dir(root.join("sessions"))?.flatten() {
                let p = entry.path();
                if entry.file_type()?.is_dir()
                    && uuid::Uuid::parse_str(&entry.file_name().to_string_lossy()).is_ok()
                    && p.join("manifest.json").is_file()
                    && !p.join("dirty").exists()
                {
                    let _ = fs::remove_dir_all(p);
                }
            }
            let recoveries = fs::read_dir(root.join("sessions"))?
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| is_recovery_candidate(p))
                .collect();
            app.manage(Shared {
                inner: Mutex::new(Session {
                    mode: "idle".into(),
                    window_defaults: CaptureDefaults::window(),
                    display_defaults: CaptureDefaults::display(),
                    recoveries,
                    ..Default::default()
                }),
                root,
            });
            #[cfg(target_os = "macos")]
            if let Err(error) = platform::shortcut::register(app.handle()) {
                app.state::<Shared>().inner.lock().unwrap().error = Some(error);
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_snapshot,
            list_capture_sources,
            check_capture_permissions,
            request_capture_permission,
            open_screen_recording_settings,
            request_microphone_permission,
            open_file_access_settings,
            open_microphone_settings,
            start_recording,
            stop_recording,
            open_project,
            update_project_appearance,
            update_aspect_ratio,
            update_resolution,
            update_export_audio,
            save_project,
            save_project_as,
            choose_background,
            choose_builtin_background,
            start_export,
            cancel_export,
            file_action,
            new_recording,
            edit_project,
            recover_recording,
            discard_recovery,
            clear_error
        ])
        .build(tauri::generate_context!())
        .expect("Could not launch Saturn")
        .run(|app, event| match event {
            #[cfg(target_os = "macos")]
            tauri::RunEvent::Exit => platform::shortcut::unregister(),
            #[cfg(target_os = "macos")]
            tauri::RunEvent::Opened { urls } => {
                let handle = app.clone();
                std::thread::spawn(move || {
                    let state = handle.state::<Shared>();
                    let mut s = state.inner.lock().unwrap();
                    for url in urls {
                        if let Ok(path) = url.to_file_path() {
                            if ensure_editable(&s).is_ok()
                                && !s
                                    .project
                                    .as_ref()
                                    .is_some_and(|p| p.work.join("dirty").exists())
                            {
                                if let Err(e) = open_path(&handle, &mut s, &state, path) {
                                    s.error = Some(e);
                                }
                            } else {
                                s.pending.push(path);
                            }
                        }
                    }
                    notify(&handle, &s);
                    if let Some(window) = handle.get_webview_window("main") {
                        let _ = window.show();
                        let _ = window.set_focus();
                    }
                });
            }
            tauri::RunEvent::WindowEvent {
                event: tauri::WindowEvent::CloseRequested { api, .. },
                ..
            } => {
                let state = app.state::<Shared>();
                if let Ok(mut s) = state.inner.lock() {
                    if ensure_editable(&s).is_err()
                        || s.project
                            .as_ref()
                            .is_some_and(|p| p.work.join("dirty").exists())
                    {
                        api.prevent_close();
                        s.error = Some(
                            "Finish the active operation and save changes before closing Saturn."
                                .into(),
                        );
                        notify(app, &s);
                    }
                };
            }
            _ => {}
        });
}

#[cfg(test)]
mod session_defaults_tests {
    use super::*;
    #[test]
    fn recovery_identifies_file_permission_errors() {
        assert!(recovery_permission_failure("Operation not permitted (os error 1)"));
        assert!(recovery_permission_failure("Permission denied (os error 13)"));
        assert!(recovery_permission_failure(FILE_ACCESS_REQUIRED));
        assert!(!recovery_permission_failure("No recoverable video track"));
    }
    #[test]
    fn folder_access_checks_actual_file_creation() {
        let folder = std::env::temp_dir().join(format!("saturn-access-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&folder).unwrap();
        check_folder_access(&folder).unwrap();
        assert_eq!(fs::read_dir(&folder).unwrap().count(), 0);
        assert!(check_folder_access(&folder.join("missing")).is_err());
        assert!(permission_error(&std::io::Error::from_raw_os_error(libc::EPERM)));
        assert!(permission_error(&std::io::Error::from_raw_os_error(libc::EACCES)));
        assert!(!permission_error(&std::io::Error::from_raw_os_error(libc::ENOENT)));
        fs::remove_dir(folder).unwrap();
    }
    #[test]
    fn recovery_requires_recording_or_project_data() {
        let work = std::env::temp_dir().join(format!("saturn-recovery-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(work.join("media")).unwrap();
        fs::write(work.join("dirty"), b"").unwrap();
        fs::write(work.join("recovery.json"), b"{}").unwrap();
        assert!(!has_recoverable_data(&work));
        fs::write(work.join("media/source.mov"), b"").unwrap();
        assert!(!has_recoverable_data(&work));
        fs::write(work.join("media/source.mov"), b"partial footage").unwrap();
        assert!(has_recoverable_data(&work));
        fs::remove_file(work.join("media/source.mov")).unwrap();
        fs::write(work.join("manifest.json"), b"{}").unwrap();
        assert!(has_recoverable_data(&work));
        fs::remove_dir_all(work).unwrap();
    }
    #[test]
    fn completed_recovery_is_not_offered_after_restart() {
        let work = std::env::temp_dir().join(format!("saturn-recovered-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(work.join("media")).unwrap();
        fs::write(work.join("manifest.json"), b"fixture").unwrap();
        fs::write(work.join("dirty"), b"").unwrap();
        assert!(is_recovery_candidate(&work));
        mark_recovery_complete(&work).unwrap();
        assert!(!is_recovery_candidate(&work));
        mark_recovery_complete(&work).unwrap();
        // A later unsaved change must still be offered for recovery.
        fs::write(work.join("dirty"), b"").unwrap();
        assert!(is_recovery_candidate(&work));
        fs::remove_dir_all(work).unwrap();
    }
    #[test]
    fn failure_to_clear_recovery_marker_is_not_success() {
        let work = std::env::temp_dir().join(format!("saturn-marker-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(work.join("dirty")).unwrap();
        assert!(mark_recovery_complete(&work).is_err());
        fs::remove_dir_all(work).unwrap();
    }
    #[test]
    fn defaults_are_independent_and_background_is_copied() {
        let work = std::env::temp_dir().join(format!("saturn-defaults-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&work).unwrap();
        let mut window = project::manifest::Manifest::new(1_000_000, 1920, 1080, false, false);
        let mut screen = window.clone();
        screen.set_display_capture();
        let mut window_settings = CaptureDefaults::window();
        window_settings.aspect_ratio = Some("1:1".into());
        window_settings.background = Some((
            project::manifest::Background::EmbeddedImage {
                path: "assets/background.png".into(),
                preset: None,
            },
            Some(vec![1, 2, 3]),
        ));
        window_settings.apply(&mut window, &work).unwrap();
        CaptureDefaults::display()
            .apply(&mut screen, &work)
            .unwrap();
        assert_eq!(window.export_settings.aspect_ratio.as_deref(), Some("1:1"));
        assert_eq!(window.export_settings.resolution.as_deref(), Some("high"));
        assert_eq!(
            fs::read(work.join("assets/background.png")).unwrap(),
            vec![1, 2, 3]
        );
        assert_eq!(
            screen.export_settings.resolution.as_deref(),
            Some("original")
        );
        assert!(matches!(
            screen.appearance.background,
            project::manifest::Background::None
        ));
        fs::remove_dir_all(work).unwrap();
    }
}
