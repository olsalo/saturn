use super::manifest::{Background, Manifest};
use chrono::{Datelike, TimeZone, Timelike};
use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    io::{self, BufRead, BufReader, Read, Write},
    path::Path,
    time::SystemTime,
};
use zip::{write::SimpleFileOptions, CompressionMethod, ZipArchive, ZipWriter};
type Result<T> = std::result::Result<T, String>;
const ALLOWED: &[&str] = &[
    "manifest.json",
    "media/source.mov",
    "media/source.mp4",
    "media/system.m4a",
    "media/microphone.m4a",
    "cursor/events.jsonl",
    "cursor/assets.json",
    "assets/background.jpg",
    "assets/background.png",
    "preview/thumbnail.jpg",
    "preview/thumbnail.png",
];
fn allowed(name: &str) -> bool {
    if ALLOWED.contains(&name) {
        return true;
    }
    let parts: Vec<_> = name.split('/').collect();
    parts.len() == 4
        && parts[0] == "clips"
        && super::manifest::valid_clip_id(parts[1])
        && [
            "media/source.mov",
            "media/source.mp4",
            "media/system.m4a",
            "media/microphone.m4a",
            "cursor/events.jsonl",
            "cursor/assets.json",
        ]
        .contains(&format!("{}/{}", parts[2], parts[3]).as_str())
}
pub fn thumbnail_path(work: &Path) -> Option<&'static str> {
    ["preview/thumbnail.jpg", "preview/thumbnail.png"]
        .into_iter()
        .find(|path| work.join(path).is_file())
}
fn zip_modified_time(time: SystemTime) -> zip::DateTime {
    let date: chrono::DateTime<chrono::Local> = time.into();
    zip::DateTime::from_date_and_time(
        date.year() as u16,
        date.month() as u8,
        date.day() as u8,
        date.hour() as u8,
        date.minute() as u8,
        date.second() as u8,
    )
    .unwrap_or_default()
}
fn extracted_modified_time(date: Option<zip::DateTime>, created_at: &str) -> Result<SystemTime> {
    // Older Saturn archives used ZIP's 1980 default for every entry. Their true
    // per-file times were lost; use the known recording date for those entries.
    if let Some(date) = date.filter(|date| *date != zip::DateTime::default()) {
        if let Some(time) = chrono::Local
            .with_ymd_and_hms(
                date.year() as i32,
                date.month() as u32,
                date.day() as u32,
                date.hour() as u32,
                date.minute() as u32,
                date.second() as u32,
            )
            .earliest()
        {
            return Ok(time.into());
        }
    }
    chrono::DateTime::parse_from_rfc3339(created_at)
        .map(SystemTime::from)
        .map_err(err)
}
fn cursor_assets(cursor: &super::manifest::Cursor) -> String {
    format!("{}/assets.json", cursor.path.rsplit_once('/').unwrap().0)
}
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
pub fn write_manifest(work: &Path, m: &Manifest) -> Result<()> {
    m.validate()?;
    let temp = work.join("manifest.next");
    fs::write(&temp, serde_json::to_vec_pretty(m).map_err(err)?).map_err(err)?;
    File::open(&temp).map_err(err)?.sync_all().map_err(err)?;
    fs::rename(temp, work.join("manifest.json")).map_err(err)
}
pub fn save(work: &Path, destination: &Path, m: &Manifest) -> Result<()> {
    m.validate()?;
    let parent = destination.parent().ok_or("Invalid save folder")?;
    if !parent.is_dir() {
        return Err("The project folder moved or was removed. Choose Save As.".into());
    }
    let mut entries = m.source_entries();
    for (_, cursor) in m.sources() {
        let path = cursor_assets(cursor);
        if work.join(&path).is_file() {
            validate_cursor_assets(&work.join(&path))?;
            entries.push(path);
        }
    }
    if let Background::EmbeddedImage { path, .. } = &m.appearance.background {
        entries.push(path.clone());
    }
    if let Some(path) = thumbnail_path(work) {
        entries.push(path.into());
    }
    let needed = entries.iter().try_fold(65_536u64, |sum, path| {
        fs::metadata(work.join(path))
            .map(|m| sum.saturating_add(m.len()))
            .map_err(err)
    })?;
    super::disk::ensure_space(parent, needed)?;
    let temp = parent.join(format!(".saturn-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .map_err(err)?;
        let mut zip = ZipWriter::new(file);
        let opts = SimpleFileOptions::default()
            .compression_method(CompressionMethod::Stored)
            .large_file(true)
            .unix_permissions(0o600)
            .last_modified_time(zip_modified_time(SystemTime::now()));
        zip.start_file("manifest.json", opts).map_err(err)?;
        zip.write_all(&serde_json::to_vec_pretty(m).map_err(err)?)
            .map_err(err)?;
        for entry in entries {
            let mut source = File::open(work.join(&entry)).map_err(err)?;
            let modified = source
                .metadata()
                .and_then(|meta| meta.modified())
                .map_err(err)?;
            zip.start_file(entry, opts.last_modified_time(zip_modified_time(modified)))
                .map_err(err)?;
            io::copy(&mut source, &mut zip).map_err(err)?;
        }
        let out = zip.finish().map_err(err)?;
        out.sync_all().map_err(err)?;
        fs::rename(&temp, destination).map_err(err)?;
        File::open(parent).map_err(err)?.sync_all().map_err(err)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}
pub fn open(path: &Path, work: &Path) -> Result<Manifest> {
    let file = File::open(path).map_err(err)?;
    let mut zip = ZipArchive::new(file).map_err(err)?;
    if zip.len() > 6010 {
        return Err("Too many project entries".into());
    }
    let mut names = HashSet::new();
    let mut total = 0u64;
    for i in 0..zip.len() {
        let e = zip.by_index(i).map_err(err)?;
        let name = e.name();
        if !allowed(name)
            || !names.insert(name.to_owned())
            || e.is_dir()
            || e.enclosed_name().is_none()
            || e.unix_mode().is_some_and(|m| m & 0o170000 == 0o120000)
            || e.compression() != CompressionMethod::Stored
        {
            return Err("Unsafe or unsupported project archive entry".into());
        }
        let max = if name.starts_with("media/") || name.contains("/media/") {
            64 * 1024 * 1024 * 1024
        } else if name.ends_with("cursor/assets.json") {
            16 * 1024 * 1024
        } else if name.starts_with("cursor/") || name.contains("/cursor/") {
            512 * 1024 * 1024
        } else if ["preview/thumbnail.png", "preview/thumbnail.jpg"].contains(&name) {
            256 * 1024 * 1024
        } else if name == "manifest.json" {
            2 * 1024 * 1024
        } else {
            32 * 1024 * 1024
        };
        if e.size() > max {
            return Err("Project entry exceeds safety limit".into());
        }
        total = total.checked_add(e.size()).ok_or("Project is too large")?;
    }
    if total > 65 * 1024 * 1024 * 1024 {
        return Err("Project is too large".into());
    }
    let m: Manifest = {
        let mut text = String::new();
        zip.by_name("manifest.json")
            .map_err(err)?
            .read_to_string(&mut text)
            .map_err(err)?;
        serde_json::from_str(&text).map_err(err)?
    };
    m.validate()?;
    for needed in m.source_entries() {
        if !names.contains(&needed) {
            return Err(format!("Missing {needed}"));
        }
    }
    if let Background::EmbeddedImage { path, .. } = &m.appearance.background {
        if !names.contains(path) {
            return Err("Missing embedded background".into());
        }
    }
    if names.contains("media/source.mov") && names.contains("media/source.mp4") {
        return Err("Ambiguous source media".into());
    }
    super::disk::ensure_space(work.parent().ok_or("Invalid workspace")?, total)?;
    fs::create_dir_all(work).map_err(err)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(work, fs::Permissions::from_mode(0o700)).map_err(err)?;
    }
    let result = (|| {
        for i in 0..zip.len() {
            let mut e = zip.by_index(i).map_err(err)?;
            let modified = extracted_modified_time(e.last_modified(), &m.created_at)?;
            let output = work.join(e.name());
            fs::create_dir_all(output.parent().unwrap()).map_err(err)?;
            let mut out = OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(output)
                .map_err(err)?;
            io::copy(&mut e, &mut out).map_err(err)?;
            out.set_times(fs::FileTimes::new().set_modified(modified))
                .map_err(err)?;
            out.sync_all().map_err(err)?;
        }
        for (media, cursor) in m.sources() {
            validate_cursor(&work.join(&cursor.path), media.duration_us)?;
            let assets = cursor_assets(cursor);
            if names.contains(&assets) {
                validate_cursor_assets(&work.join(assets))?;
            }
        }
        Ok(m)
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(work);
    }
    result
}
pub fn validate_cursor_assets(path: &Path) -> Result<()> {
    if fs::metadata(path).map_err(err)?.len() > 16 * 1024 * 1024 {
        return Err("Cursor assets exceed safety limit".into());
    }
    let value: serde_json::Value =
        serde_json::from_slice(&fs::read(path).map_err(err)?).map_err(err)?;
    let assets = value.as_object().ok_or("Invalid cursor assets")?;
    if assets.len() > 256 {
        return Err("Too many cursor assets".into());
    }
    for (id, asset) in assets {
        if id.is_empty()
            || id.len() > 64
            || !id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
        {
            return Err("Invalid cursor asset identifier".into());
        }
        for field in ["width", "height"] {
            if !asset[field]
                .as_f64()
                .is_some_and(|n| n.is_finite() && n > 0. && n <= 512.)
            {
                return Err("Invalid cursor asset dimensions".into());
            }
        }
        for (field, dimension) in [("hotspotX", "width"), ("hotspotY", "height")] {
            if !asset[field].as_f64().is_some_and(|n| {
                n.is_finite() && n >= 0. && n <= asset[dimension].as_f64().unwrap()
            }) {
                return Err("Invalid cursor hotspot".into());
            }
        }
        if !asset["png"]
            .as_str()
            .is_some_and(|data| !data.is_empty() && data.len() <= 1_400_000)
        {
            return Err("Invalid cursor bitmap".into());
        }
    }
    Ok(())
}
pub fn validate_cursor(path: &Path, duration: u64) -> Result<()> {
    let mut reader = BufReader::new(File::open(path).map_err(err)?);
    let mut line = String::new();
    let mut last = 0u64;
    let mut count = 0;
    loop {
        line.clear();
        let len = reader
            .by_ref()
            .take(4097)
            .read_line(&mut line)
            .map_err(err)?;
        if len == 0 {
            break;
        }
        if len > 4096 {
            return Err("Cursor event is too large".into());
        }
        let e: serde_json::Value = serde_json::from_str(&line).map_err(err)?;
        let time = e["tUs"].as_u64().ok_or("Invalid cursor timestamp")?;
        if time < last || time > duration + 1_000_000 {
            return Err("Cursor timestamps are out of range".into());
        }
        last = time;
        if e["type"] != "move" || e["visible"].as_bool().is_none() {
            return Err("Unsupported cursor event".into());
        }
        for k in ["x", "y"] {
            if !e[k]
                .as_f64()
                .is_some_and(|v| v.is_finite() && v.abs() < 1_000_000.)
            {
                return Err("Invalid cursor coordinates".into());
            }
        }
        if let Some(id) = e.get("cursorID") {
            if !id.as_str().is_some_and(|id| {
                !id.is_empty()
                    && id.len() <= 64
                    && id
                        .bytes()
                        .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
            }) {
                return Err("Invalid cursor identifier".into());
            }
        }
        if e.get("click")
            .is_some_and(|value| value.as_bool().is_none())
        {
            return Err("Invalid cursor click".into());
        }
        if let Some(click_us) = e.get("clickUs") {
            if !click_us.as_u64().is_some_and(|click_us| click_us <= time) {
                return Err("Invalid click timestamp".into());
            }
        }
        for field in ["cursorScaleX", "cursorScaleY"] {
            if let Some(value) = e.get(field) {
                if !value
                    .as_f64()
                    .is_some_and(|v| v.is_finite() && v > 0. && v <= 1000.)
                {
                    return Err("Invalid cursor scale".into());
                }
            }
        }
        count += 1;
        if count > 3_000_000 {
            return Err("Too many cursor events".into());
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    fn dir() -> std::path::PathBuf {
        let p = std::env::temp_dir().join(uuid::Uuid::new_v4().to_string());
        fs::create_dir_all(&p).unwrap();
        p
    }
    #[test]
    fn portable_roundtrip() {
        let root = dir();
        let work = root.join("work");
        for d in ["media", "cursor", "assets"] {
            fs::create_dir_all(work.join(d)).unwrap()
        }
        fs::write(work.join("media/source.mov"), b"original footage").unwrap();
        fs::write(
            work.join("cursor/events.jsonl"),
            "{\"tUs\":0,\"type\":\"move\",\"x\":12,\"y\":4,\"visible\":true}\n",
        )
        .unwrap();
        fs::write(work.join("assets/background.png"), b"embedded").unwrap();
        let mut m = Manifest::new(1_000_000, 1920, 1080, true, false);
        m.appearance.background = Background::EmbeddedImage {
            path: "assets/background.png".into(),
            preset: Some("tahoe-light.jpg".into()),
        };
        save(&work, &root.join("first.recproj"), &m).unwrap();
        fs::create_dir(root.join("moved")).unwrap();
        fs::rename(
            root.join("first.recproj"),
            root.join("moved/renamed.recproj"),
        )
        .unwrap();
        let loaded = open(&root.join("moved/renamed.recproj"), &root.join("opened")).unwrap();
        assert_eq!(loaded.project_id, m.project_id);
        assert!(
            matches!(&loaded.appearance.background, Background::EmbeddedImage { preset: Some(id), .. } if id == "tahoe-light.jpg")
        );
        assert_eq!(
            fs::read(root.join("opened/media/source.mov")).unwrap(),
            b"original footage"
        );
        assert!(root.join("opened/assets/background.png").exists());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn separate_audio_roundtrips_and_missing_track_is_rejected() {
        use crate::project::manifest::{AudioTrack, SeparateAudio};
        let root = dir();
        let work = root.join("work");
        fs::create_dir_all(work.join("media")).unwrap();
        fs::create_dir_all(work.join("cursor")).unwrap();
        fs::write(work.join("media/source.mov"), b"video").unwrap();
        fs::write(work.join("media/system.m4a"), b"system").unwrap();
        fs::write(work.join("media/microphone.m4a"), b"microphone").unwrap();
        fs::write(
            work.join("cursor/events.jsonl"),
            b"{\"tUs\":0,\"type\":\"move\",\"x\":0,\"y\":0,\"visible\":true}\n",
        )
        .unwrap();
        let mut manifest = Manifest::new(1_000_000, 1920, 1080, true, true);
        manifest.media.separate_audio = Some(SeparateAudio {
            system: Some(AudioTrack {
                path: "media/system.m4a".into(),
                offset_us: -1000,
            }),
            microphone: Some(AudioTrack {
                path: "media/microphone.m4a".into(),
                offset_us: 4000,
            }),
        });
        manifest.export_settings.include_microphone_audio = false;
        save(&work, &root.join("separate.recproj"), &manifest).unwrap();
        let restored = open(&root.join("separate.recproj"), &root.join("restored")).unwrap();
        assert_eq!(
            restored
                .media
                .separate_audio
                .unwrap()
                .system
                .unwrap()
                .offset_us,
            -1000
        );
        assert!(!restored.export_settings.include_microphone_audio);
        assert_eq!(
            fs::read(root.join("restored/media/microphone.m4a")).unwrap(),
            b"microphone"
        );
        fs::remove_file(work.join("media/microphone.m4a")).unwrap();
        assert!(save(&work, &root.join("missing.recproj"), &manifest).is_err());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn cursor_assets_survive_archive_roundtrip() {
        let root = dir();
        let work = root.join("work");
        fs::create_dir_all(work.join("media")).unwrap();
        fs::create_dir_all(work.join("cursor")).unwrap();
        fs::write(work.join("media/source.mov"), b"original").unwrap();
        fs::write(work.join("cursor/events.jsonl"), "{\"tUs\":0,\"type\":\"move\",\"x\":1,\"y\":2,\"visible\":true,\"cursorID\":\"text\",\"cursorScaleX\":2,\"cursorScaleY\":2}\n").unwrap();
        let assets =
            br#"{"text":{"png":"aGVsbG8=","width":12,"height":24,"hotspotX":6,"hotspotY":12}}"#;
        fs::write(work.join("cursor/assets.json"), assets).unwrap();
        let manifest = Manifest::new(1_000_000, 640, 400, false, false);
        save(&work, &root.join("cursors.recproj"), &manifest).unwrap();
        open(&root.join("cursors.recproj"), &root.join("opened")).unwrap();
        assert_eq!(
            fs::read(root.join("opened/cursor/assets.json")).unwrap(),
            assets
        );
        fs::write(
            work.join("cursor/assets.json"),
            br#"{"text":{"png":"aGVsbG8=","width":12,"height":24,"hotspotX":999,"hotspotY":12}}"#,
        )
        .unwrap();
        assert!(validate_cursor_assets(&work.join("cursor/assets.json")).is_err());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn reject_unsafe_archives() {
        for name in [
            "../escape",
            "/absolute",
            "media/source.mov",
            "manifest.json",
        ] {
            let root = dir();
            let path = root.join("bad.recproj");
            let mut z = ZipWriter::new(File::create(&path).unwrap());
            z.start_file(
                name,
                SimpleFileOptions::default().compression_method(CompressionMethod::Stored),
            )
            .unwrap();
            z.write_all(b"{}").unwrap();
            z.finish().unwrap();
            assert!(open(&path, &root.join("staged")).is_err());
            assert!(!root.join("escape").exists());
            fs::remove_dir_all(root).unwrap();
        }
    }
    #[test]
    fn failed_save_preserves_existing() {
        let root = dir();
        let dest = root.join("existing.recproj");
        fs::write(&dest, b"keep").unwrap();
        assert!(save(&root, &dest, &Manifest::new(1, 1920, 1080, false, false)).is_err());
        assert_eq!(fs::read(dest).unwrap(), b"keep");
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn rejects_future_and_invalid_coordinates() {
        let root = dir();
        let mut m = Manifest::new(1, 1920, 1080, false, false);
        m.format_version = 2;
        assert!(m.validate().is_err());
        let p = root.join("events");
        fs::write(
            &p,
            "{\"tUs\":0,\"type\":\"move\",\"x\":1e200,\"y\":4,\"visible\":true}\n",
        )
        .unwrap();
        assert!(validate_cursor(&p, 1).is_err());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    #[ignore = "Writes and stages a 5 GiB ZIP64 project; run explicitly for archive benchmarking"]
    fn zip64_large_project() {
        let root = dir();
        let work = root.join("work");
        fs::create_dir_all(work.join("media")).unwrap();
        fs::create_dir_all(work.join("cursor")).unwrap();
        let source = File::create(work.join("media/source.mov")).unwrap();
        let gib = std::env::var("SATURN_BENCH_GIB")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(5);
        assert!((1..=20).contains(&gib));
        let bytes = gib * 1024 * 1024 * 1024;
        source.set_len(bytes).unwrap();
        fs::write(work.join("cursor/events.jsonl"), b"").unwrap();
        let manifest = Manifest::new(1_000_000, 1920, 1080, false, false);
        let start = std::time::Instant::now();
        save(&work, &root.join("large.recproj"), &manifest).unwrap();
        let save_elapsed = start.elapsed();
        let start = std::time::Instant::now();
        open(&root.join("large.recproj"), &root.join("reopened")).unwrap();
        let open_elapsed = start.elapsed();
        assert_eq!(
            fs::metadata(root.join("reopened/media/source.mov"))
                .unwrap()
                .len(),
            bytes
        );
        println!("{gib} GiB ZIP64: save {save_elapsed:?}, reopen+CRC {open_elapsed:?}");
        fs::remove_dir_all(root).unwrap();
    }
}

#[cfg(test)]
mod clip_tests {
    use super::*;
    use crate::project::manifest::{Clip, SequenceClip};
    fn clip(id: &str) -> Clip {
        let base = Manifest::new(1_000_000, 640, 400, false, false);
        let mut clip = Clip {
            id: id.into(),
            media: base.media,
            cursor: base.cursor,
        };
        clip.media.path = format!("clips/{id}/media/source.mov");
        clip.cursor.path = format!("clips/{id}/cursor/events.jsonl");
        clip.media.separate_audio = Some(crate::project::manifest::SeparateAudio {
            system: Some(crate::project::manifest::AudioTrack {
                path: format!("clips/{id}/media/system.m4a"),
                offset_us: -50_000,
            }),
            microphone: None,
        });
        clip
    }
    #[test]
    fn clips_roundtrip_in_sequence_order_without_flattening() {
        let root = std::env::temp_dir().join(format!("saturn-clips-{}", uuid::Uuid::new_v4()));
        let work = root.join("work");
        let mut m = Manifest::new(1, 640, 400, false, false);
        m.set_clips(vec![clip("0001"), clip("0002")]).unwrap();
        m.sequence.reverse();
        for clip in &m.clips {
            fs::create_dir_all(work.join(&clip.media.path).parent().unwrap()).unwrap();
            fs::create_dir_all(work.join(&clip.cursor.path).parent().unwrap()).unwrap();
            fs::write(work.join(&clip.media.path), clip.id.as_bytes()).unwrap();
            fs::write(
                work.join(
                    &clip
                        .media
                        .separate_audio
                        .as_ref()
                        .unwrap()
                        .system
                        .as_ref()
                        .unwrap()
                        .path,
                ),
                b"audio",
            )
            .unwrap();
            fs::write(work.join(&clip.cursor.path), b"").unwrap();
        }
        let dest = root.join("clips.saturn");
        save(&work, &dest, &m).unwrap();
        let reopened = open(&dest, &root.join("opened")).unwrap();
        assert_eq!(reopened.media.duration_us, 2_000_000);
        assert_eq!(reopened.sequence[0].clip_id, "0002");
        assert_eq!(
            reopened.clips[1]
                .media
                .separate_audio
                .as_ref()
                .unwrap()
                .system
                .as_ref()
                .unwrap()
                .offset_us,
            -50_000
        );
        assert_eq!(
            fs::read(root.join("opened/clips/0002/media/system.m4a")).unwrap(),
            b"audio"
        );
        assert_eq!(
            fs::read(root.join("opened/clips/0001/media/source.mov")).unwrap(),
            b"0001"
        );
        assert!(!root.join("opened/media/source.mov").exists());
        // A missing later source must reject the entire project.
        fs::remove_file(work.join(&m.clips[1].media.path)).unwrap();
        assert!(save(&work, &dest, &m).is_err());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn rejects_unsafe_clip_paths_and_invalid_sequences() {
        let mut m = Manifest::new(1, 640, 400, false, false);
        m.set_clips(vec![clip("0001"), clip("0002")]).unwrap();
        let mut bad = m.clone();
        bad.clips[1].media.path = "clips/0002/../../secret".into();
        assert!(bad.validate().is_err());
        let mut bad = m.clone();
        bad.sequence[1] = SequenceClip {
            clip_id: "0001".into(),
        };
        assert!(bad.validate().is_err());
        let mut bad = m.clone();
        bad.clips[1].id = "0001".into();
        assert!(bad.validate().is_err());
        let mut bad = m.clone();
        bad.media.duration_us += 1;
        assert!(bad.validate().is_err());
        for path in [
            "clips/../media/source.mov",
            "clips/0001/media/secret",
            "clips/0001/../manifest.json",
            "clips/0000/media/source.mov",
        ] {
            assert!(!allowed(path));
        }
    }
}

#[cfg(test)]
mod thumbnail_tests {
    use super::*;
    #[test]
    fn jpeg_thumbnail_survives_save_and_takes_precedence_over_png() {
        let root = std::env::temp_dir().join(format!("saturn-thumbnail-{}", uuid::Uuid::new_v4()));
        let work = root.join("work");
        for name in ["media", "cursor", "preview"] {
            fs::create_dir_all(work.join(name)).unwrap();
        }
        fs::write(work.join("media/source.mov"), b"source").unwrap();
        fs::write(work.join("cursor/events.jsonl"), b"").unwrap();
        fs::write(work.join("preview/thumbnail.png"), b"previous png").unwrap();
        assert_eq!(thumbnail_path(&work), Some("preview/thumbnail.png"));
        fs::write(work.join("preview/thumbnail.jpg"), b"full resolution jpeg").unwrap();
        assert_eq!(thumbnail_path(&work), Some("preview/thumbnail.jpg"));
        let manifest = Manifest::new(1_000_000, 1920, 1200, false, false);
        let destination = root.join("project.saturn");
        save(&work, &destination, &manifest).unwrap();
        let opened = root.join("opened");
        open(&destination, &opened).unwrap();
        assert_eq!(
            fs::read(opened.join("preview/thumbnail.jpg")).unwrap(),
            b"full resolution jpeg"
        );
        assert!(!opened.join("preview/thumbnail.png").exists());
        fs::remove_dir_all(root).unwrap();
    }
}

#[cfg(test)]
mod timestamp_tests {
    use super::*;
    #[test]
    fn file_dates_survive_save_open_and_resave() {
        let root = std::env::temp_dir().join(format!("saturn-dates-{}", uuid::Uuid::new_v4()));
        let work = root.join("work");
        for name in ["media", "cursor"] {
            fs::create_dir_all(work.join(name)).unwrap();
        }
        fs::write(work.join("media/source.mov"), b"video").unwrap();
        fs::write(work.join("cursor/events.jsonl"), b"").unwrap();
        let modified: SystemTime =
            chrono::DateTime::parse_from_rfc3339("2026-11-10T11:22:24+02:00")
                .unwrap()
                .into();
        File::options()
            .write(true)
            .open(work.join("media/source.mov"))
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(modified))
            .unwrap();
        let manifest = Manifest::new(1_000_000, 640, 400, false, false);
        let path = root.join("first.saturn");
        save(&work, &path, &manifest).unwrap();
        let mut archive = ZipArchive::new(File::open(&path).unwrap()).unwrap();
        assert_eq!(
            archive.by_name("media/source.mov").unwrap().last_modified(),
            Some(zip_modified_time(modified))
        );
        assert_ne!(
            archive.by_name("manifest.json").unwrap().last_modified(),
            Some(zip::DateTime::default())
        );
        drop(archive);
        let opened = root.join("opened");
        let manifest = open(&path, &opened).unwrap();
        let restored = fs::metadata(opened.join("media/source.mov"))
            .unwrap()
            .modified()
            .unwrap();
        assert_eq!(restored, modified);
        let second = root.join("second.saturn");
        save(&opened, &second, &manifest).unwrap();
        let mut archive = ZipArchive::new(File::open(&second).unwrap()).unwrap();
        assert_eq!(
            archive.by_name("media/source.mov").unwrap().last_modified(),
            Some(zip_modified_time(modified))
        );
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn legacy_1980_dates_use_the_recording_date() {
        let created = "2026-11-10T11:22:24+02:00";
        let expected: SystemTime = chrono::DateTime::parse_from_rfc3339(created)
            .unwrap()
            .into();
        assert_eq!(
            extracted_modified_time(Some(zip::DateTime::default()), created).unwrap(),
            expected
        );
        assert_eq!(extracted_modified_time(None, created).unwrap(), expected);
    }
}
