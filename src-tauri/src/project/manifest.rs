use serde::{Deserialize, Serialize};
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Media {
    pub path: String,
    #[serde(default = "default_capture_kind")]
    pub capture_kind: String,
    pub duration_us: u64,
    pub width: u32,
    pub height: u32,
    pub frame_rate: FrameRate,
    pub has_system_audio: bool,
    pub has_microphone_audio: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub separate_audio: Option<SeparateAudio>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioTrack {
    pub path: String,
    pub offset_us: i64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeparateAudio {
    pub system: Option<AudioTrack>,
    pub microphone: Option<AudioTrack>,
}
fn default_capture_kind() -> String {
    "window".into()
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FrameRate {
    pub numerator: u32,
    pub denominator: u32,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Cursor {
    pub path: String,
    pub time_unit: String,
    pub coordinate_space: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Background {
    None,
    Gradient {
        preset: String,
    },
    Solid {
        color: String,
    },
    EmbeddedImage {
        path: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        preset: Option<String>,
    },
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Appearance {
    pub background: Background,
    pub padding_px: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub padding_percent: Option<f64>,
    pub corner_radius_px: u32,
    pub shadow: bool,
    pub cursor_smoothing: bool,
    pub click_animation: bool,
}
impl Default for Appearance {
    fn default() -> Self {
        Self {
            background: Background::Solid {
                color: "white".into(),
            },
            padding_px: 64,
            padding_percent: Some(38.0),
            corner_radius_px: 21,
            shadow: true,
            cursor_smoothing: true,
            click_animation: true,
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportSettings {
    pub container: String,
    pub codec: String,
    pub width: u32,
    pub height: u32,
    pub frame_rate: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub aspect_ratio: Option<String>,
    #[serde(default = "default_enabled")]
    pub include_system_audio: bool,
    #[serde(default = "default_enabled")]
    pub include_microphone_audio: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolution: Option<String>,
}
fn default_enabled() -> bool {
    true
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Clip {
    pub id: String,
    pub media: Media,
    pub cursor: Cursor,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SequenceClip {
    pub clip_id: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub format_version: u32,
    pub project_id: String,
    pub created_at: String,
    pub media: Media,
    pub cursor: Cursor,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub clips: Vec<Clip>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sequence: Vec<SequenceClip>,
    pub appearance: Appearance,
    #[serde(rename = "export")]
    pub export_settings: ExportSettings,
}
impl Manifest {
    pub fn new(duration: u64, width: u32, height: u32, system: bool, mic: bool) -> Self {
        let mut manifest = Self {
            format_version: 1,
            project_id: uuid::Uuid::new_v4().to_string(),
            created_at: chrono::Utc::now().to_rfc3339(),
            media: Media {
                path: "media/source.mov".into(),
                capture_kind: default_capture_kind(),
                duration_us: duration,
                width,
                height,
                frame_rate: FrameRate {
                    numerator: 30,
                    denominator: 1,
                },
                has_system_audio: system,
                has_microphone_audio: mic,
                separate_audio: None,
            },
            cursor: Cursor {
                path: "cursor/events.jsonl".into(),
                time_unit: "microseconds".into(),
                coordinate_space: "capturedVideoPixels".into(),
            },
            clips: vec![],
            sequence: vec![],
            appearance: Appearance::default(),
            export_settings: ExportSettings {
                container: "mp4".into(),
                codec: "h264".into(),
                width: 2560,
                height: 1600,
                frame_rate: 30,
                aspect_ratio: Some("16:10".into()),
                resolution: Some("high".into()),
                include_system_audio: true,
                include_microphone_audio: true,
            },
        };
        manifest.update_export_dimensions();
        manifest
    }
    pub fn set_clips(&mut self, clips: Vec<Clip>) -> Result<(), String> {
        let first = clips.first().ok_or("No completed clips")?;
        self.media = first.media.clone();
        self.cursor = first.cursor.clone();
        self.media.duration_us = clips.iter().map(|c| c.media.duration_us).sum();
        self.sequence = clips
            .iter()
            .map(|c| SequenceClip {
                clip_id: c.id.clone(),
            })
            .collect();
        self.clips = clips;
        self.format_version = 2;
        self.validate()
    }
    pub fn sources(&self) -> Vec<(&Media, &Cursor)> {
        if self.clips.is_empty() {
            vec![(&self.media, &self.cursor)]
        } else {
            self.clips.iter().map(|c| (&c.media, &c.cursor)).collect()
        }
    }
    pub fn source_entries(&self) -> Vec<String> {
        let mut entries = vec![];
        for (media, cursor) in self.sources() {
            entries.extend([media.path.clone(), cursor.path.clone()]);
            if let Some(audio) = &media.separate_audio {
                entries.extend(
                    [&audio.system, &audio.microphone]
                        .into_iter()
                        .flatten()
                        .map(|a| a.path.clone()),
                );
            }
        }
        entries
    }
    pub fn set_display_capture(&mut self) {
        self.media.capture_kind = "display".into();
        self.appearance.background = Background::None;
        self.export_settings.aspect_ratio = Some("original".into());
        self.export_settings.resolution = Some("original".into());
        self.update_export_dimensions();
    }
    /// The app's current export defaults also apply when reopening older captures.
    pub fn use_export_layout(&mut self) {
        if self.media.capture_kind == "display" {
            self.export_settings.aspect_ratio = Some("original".into());
        } else if self.export_settings.aspect_ratio.is_none() {
            self.export_settings.aspect_ratio = Some("16:10".into());
        }
        self.update_export_dimensions();
    }
    pub fn update_export_dimensions(&mut self) {
        let original_ratio = self.media.capture_kind == "display"
            || matches!(self.appearance.background, Background::None)
            || self.export_settings.aspect_ratio.as_deref() == Some("original");
        let ratio = if original_ratio {
            self.media.width as f64 / self.media.height as f64
        } else {
            match self.export_settings.aspect_ratio.as_deref() {
                Some("16:9") => 16.0 / 9.0,
                Some("1:1") => 1.0,
                Some("9:16") => 9.0 / 16.0,
                _ => 16.0 / 10.0,
            }
        };
        // Fit the canvas to the recording bounds before applying the preset.
        // Swapping bounds for portrait shapes keeps the source's long and short
        // sides as the limits without enlarging the captured content.
        let long = self.media.width.max(self.media.height) as f64;
        let short = self.media.width.min(self.media.height) as f64;
        let (bound_w, bound_h) = if ratio >= 1.0 {
            (long, short)
        } else {
            (short, long)
        };
        let base_height = (bound_w / ratio).min(bound_h).min(4096.0 / ratio.max(1.0));
        let quality_scale = match self.export_settings.resolution.as_deref() {
            Some("original") => 1.0,
            Some("standard") | Some("medium") => 0.75,
            Some("small") => 0.6,
            _ => 0.9,
        };
        let height = base_height * quality_scale;
        let width = height * ratio;
        self.export_settings.width = ((width / 2.0).floor() as u32 * 2).max(2);
        self.export_settings.height = ((height / 2.0).floor() as u32 * 2).max(2);
    }
    pub fn validate(&self) -> Result<(), String> {
        if ![1, 2].contains(&self.format_version) {
            return Err("Unsupported project version. Update Saturn to open this project.".into());
        }
        if uuid::Uuid::parse_str(&self.project_id).is_err()
            || chrono::DateTime::parse_from_rfc3339(&self.created_at).is_err()
        {
            return Err("Invalid project identity".into());
        }
        if !self.clips.is_empty() {
            if self.format_version != 2
                || self.clips.len() > 1000
                || self.sequence.len() != self.clips.len()
            {
                return Err("Invalid clip sequence".into());
            }
            let mut ids = std::collections::HashSet::new();
            for clip in &self.clips {
                if !valid_clip_id(&clip.id) || !ids.insert(&clip.id) {
                    return Err("Invalid or duplicate clip ID".into());
                }
                let prefix = format!("clips/{}/", clip.id);
                let mut single = self.clone();
                single.format_version = 1;
                single.clips.clear();
                single.sequence.clear();
                single.media = clip.media.clone();
                single.cursor = clip.cursor.clone();
                single.media.path = clip
                    .media
                    .path
                    .strip_prefix(&prefix)
                    .ok_or("Invalid clip media path")?
                    .into();
                single.cursor.path = clip
                    .cursor
                    .path
                    .strip_prefix(&prefix)
                    .ok_or("Invalid clip cursor path")?
                    .into();
                if let Some(audio) = &mut single.media.separate_audio {
                    for track in [&mut audio.system, &mut audio.microphone]
                        .into_iter()
                        .flatten()
                    {
                        track.path = track
                            .path
                            .strip_prefix(&prefix)
                            .ok_or("Invalid clip audio path")?
                            .into();
                    }
                }
                single.validate()?;
            }
            let mut used = std::collections::HashSet::new();
            let mut duration = 0u64;
            for entry in &self.sequence {
                let clip = self
                    .clips
                    .iter()
                    .find(|c| c.id == entry.clip_id)
                    .ok_or("Missing sequence clip")?;
                if !used.insert(&entry.clip_id) {
                    return Err("Duplicate sequence clip".into());
                }
                duration = duration
                    .checked_add(clip.media.duration_us)
                    .ok_or("Invalid sequence duration")?;
            }
            if duration != self.media.duration_us || duration > 86_400_000_000 {
                return Err("Invalid sequence duration".into());
            }
            // Validate the summary's settings through the first source's normal validation.
            let mut single = self.clone();
            single.clips.clear();
            single.sequence.clear();
            single.format_version = 1;
            single.media.path = "media/source.mov".into();
            single.media.separate_audio = None;
            single.cursor.path = "cursor/events.jsonl".into();
            return single.validate();
        }
        if !self.sequence.is_empty() || self.format_version != 1 {
            return Err("Missing project clips".into());
        }
        if !["media/source.mov", "media/source.mp4"].contains(&self.media.path.as_str())
            || self.cursor.path != "cursor/events.jsonl"
            || self.cursor.time_unit != "microseconds"
            || self.cursor.coordinate_space != "capturedVideoPixels"
        {
            return Err("Invalid media or cursor reference".into());
        }
        if !["window", "display"].contains(&self.media.capture_kind.as_str()) {
            return Err("Invalid capture source".into());
        }
        if self.media.duration_us == 0
            || self.media.duration_us > 86_400_000_000
            || !(2..=16384).contains(&self.media.width)
            || !(2..=16384).contains(&self.media.height)
            || self.media.frame_rate.denominator == 0
            || self.media.frame_rate.numerator == 0
            || self.media.frame_rate.numerator as f64 / self.media.frame_rate.denominator as f64
                > 240.
        {
            return Err("Invalid media dimensions, duration or frame rate".into());
        }
        if let Some(audio) = &self.media.separate_audio {
            for (track, expected) in [
                (&audio.system, "media/system.m4a"),
                (&audio.microphone, "media/microphone.m4a"),
            ] {
                if let Some(track) = track {
                    if track.path != expected
                        || track.offset_us.unsigned_abs()
                            > self.media.duration_us.saturating_add(10_000_000)
                    {
                        return Err("Invalid separate audio track".into());
                    }
                }
            }
        }
        self.appearance.validate()?;
        let e = &self.export_settings;
        if e.container != "mp4"
            || !["h264", "hevc"].contains(&e.codec.as_str())
            || ![30, 60].contains(&e.frame_rate)
            || !(2..=4096).contains(&e.width)
            || !(2..=4096).contains(&e.height)
            || e.width % 2 != 0
            || e.height % 2 != 0
            || e.aspect_ratio
                .as_deref()
                .is_some_and(|r| !["16:10", "16:9", "1:1", "9:16", "original"].contains(&r))
            || e.resolution
                .as_deref()
                .is_some_and(|r| !["original", "high", "standard", "medium", "small"].contains(&r))
        {
            return Err("Unsupported export settings".into());
        }
        Ok(())
    }
}
impl Appearance {
    pub fn validate(&self) -> Result<(), String> {
        if self.padding_px > 256
            || self.corner_radius_px > 128
            || self
                .padding_percent
                .is_some_and(|p| !p.is_finite() || !(0.0..=100.0).contains(&p))
        {
            return Err("Unsupported appearance settings".into());
        }
        match &self.background {
            Background::Solid { color } if !["white", "black"].contains(&color.as_str()) => {
                Err("Unknown background color".into())
            }
            Background::Gradient { preset }
                if !["dawn", "dusk", "mint", "ink"].contains(&preset.as_str()) =>
            {
                Err("Unknown background preset".into())
            }
            Background::EmbeddedImage { path, .. }
                if !["assets/background.jpg", "assets/background.png"].contains(&path.as_str()) =>
            {
                Err("Invalid background reference".into())
            }
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn solid_backgrounds_round_trip_and_validate() {
        for color in ["white", "black"] {
            let mut appearance = Appearance::default();
            appearance.background = Background::Solid {
                color: color.into(),
            };
            let json = serde_json::to_string(&appearance).unwrap();
            let restored: Appearance = serde_json::from_str(&json).unwrap();
            assert!(restored.validate().is_ok());
            assert!(
                matches!(restored.background, Background::Solid { color: ref actual } if actual == color)
            );
        }
        let mut appearance = Appearance::default();
        appearance.background = Background::Solid {
            color: "red".into(),
        };
        assert!(appearance.validate().is_err());
    }
    #[test]
    fn display_capture_roundtrips_and_old_projects_default_to_window() {
        let mut m = Manifest::new(1_000_000, 1920, 1080, false, false);
        m.set_display_capture();
        let encoded = serde_json::to_value(&m).unwrap();
        let restored: Manifest = serde_json::from_value(encoded.clone()).unwrap();
        assert_eq!(restored.media.capture_kind, "display");
        assert!(matches!(restored.appearance.background, Background::None));
        let mut old = encoded;
        old["media"].as_object_mut().unwrap().remove("captureKind");
        let restored: Manifest = serde_json::from_value(old).unwrap();
        assert_eq!(restored.media.capture_kind, "window");
    }
    #[test]
    fn presets_follow_source_without_upscaling() {
        let mut m = Manifest::new(1_000_000, 1920, 1080, false, false);
        assert_eq!(m.export_settings.aspect_ratio.as_deref(), Some("16:10"));
        assert_eq!(m.export_settings.resolution.as_deref(), Some("high"));
        assert_eq!(
            (m.export_settings.width, m.export_settings.height),
            (1554, 972)
        );
        for (ratio, preset, expected) in [
            ("16:9", "original", (1920, 1080)),
            ("16:9", "high", (1728, 972)),
            ("16:9", "medium", (1440, 810)),
            ("16:9", "standard", (1440, 810)),
            ("16:9", "small", (1152, 648)),
            ("original", "original", (1920, 1080)),
            ("16:10", "original", (1728, 1080)),
            ("9:16", "original", (1080, 1920)),
        ] {
            m.export_settings.aspect_ratio = Some(ratio.into());
            m.export_settings.resolution = Some(preset.into());
            m.update_export_dimensions();
            assert_eq!(
                (m.export_settings.width, m.export_settings.height),
                expected
            );
            m.validate().unwrap();
        }
        m.set_display_capture();
        assert_eq!(m.export_settings.resolution.as_deref(), Some("original"));
        assert_eq!(
            (m.export_settings.width, m.export_settings.height),
            (1920, 1080)
        );
        m.export_settings.aspect_ratio = Some("9:16".into());
        m.export_settings.resolution = Some("medium".into());
        m.update_export_dimensions();
        assert_eq!(
            (m.export_settings.width, m.export_settings.height),
            (1440, 810)
        );
    }
    #[test]
    fn no_background_uses_window_shape_and_restores_selected_canvas() {
        let mut m = Manifest::new(1_000_000, 1920, 1080, false, false);
        m.export_settings.aspect_ratio = Some("1:1".into());
        m.export_settings.resolution = Some("original".into());
        m.update_export_dimensions();
        assert_eq!(
            (m.export_settings.width, m.export_settings.height),
            (1080, 1080)
        );
        m.appearance.background = Background::None;
        m.update_export_dimensions();
        assert_eq!(
            (m.export_settings.width, m.export_settings.height),
            (1920, 1080)
        );
        assert_eq!(m.export_settings.aspect_ratio.as_deref(), Some("1:1"));
        m.appearance.background = Background::Gradient {
            preset: "dawn".into(),
        };
        m.update_export_dimensions();
        assert_eq!(
            (m.export_settings.width, m.export_settings.height),
            (1080, 1080)
        );
    }
    #[test]
    fn source_limits_are_respected() {
        for (w, h) in [(1200, 800), (3840, 2160), (16384, 8192)] {
            let mut m = Manifest::new(1_000_000, w, h, false, false);
            for ratio in ["original", "16:10", "16:9", "1:1", "9:16"] {
                m.export_settings.aspect_ratio = Some(ratio.into());
                for preset in ["original", "high", "medium", "small"] {
                    m.export_settings.resolution = Some(preset.into());
                    m.update_export_dimensions();
                    let (cw, ch) = (m.export_settings.width, m.export_settings.height);
                    assert!(cw <= 4096 && ch <= 4096);
                    assert!(f64::min(cw as f64 / w as f64, ch as f64 / h as f64) <= 1.0);
                    m.validate().unwrap();
                }
            }
        }
    }
}

pub fn valid_clip_id(id: &str) -> bool {
    id.len() == 4 && id.bytes().all(|c| c.is_ascii_digit()) && id != "0000"
}
