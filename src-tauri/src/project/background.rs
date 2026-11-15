use super::{manifest::Background, write_background, Manifest};
use serde::Deserialize;
use std::path::Path;

#[derive(Deserialize)]
struct Wallpaper {
    id: String,
    path: String,
    #[serde(default, rename = "duplicateOf")]
    duplicate_of: Option<String>,
}

fn catalog() -> Result<Vec<Wallpaper>, String> {
    serde_json::from_str(include_str!("../../../src/lib/wallpapers.json"))
        .map_err(|e| e.to_string())
}

pub struct BundledBackground {
    pub background: Background,
    pub bytes: Vec<u8>,
    filename: &'static str,
}

impl BundledBackground {
    fn from_bytes(preset: String, bytes: Vec<u8>) -> Result<Self, String> {
        let filename = if bytes.starts_with(&[255, 216, 255]) {
            "background.jpg"
        } else if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
            "background.png"
        } else {
            return Err("Bundled background is not a supported image".into());
        };
        if bytes.len() > 32 * 1024 * 1024 {
            return Err("Bundled background is too large".into());
        }
        Ok(Self {
            background: Background::EmbeddedImage {
                path: format!("assets/{filename}"),
                preset: Some(preset),
            },
            bytes,
            filename,
        })
    }

    pub fn apply(self, manifest: &mut Manifest, work: &Path) -> Result<(), String> {
        write_background(work, self.filename, &self.bytes)?;
        manifest.appearance.background = self.background;
        manifest.update_export_dimensions();
        Ok(())
    }
}

fn load(app: &tauri::AppHandle, wallpaper: Wallpaper) -> Result<BundledBackground, String> {
    let asset = app
        .asset_resolver()
        .get(format!("wallpapers/{}", wallpaper.path))
        .ok_or("Bundled background image is unavailable")?;
    BundledBackground::from_bytes(wallpaper.id, asset.bytes().to_vec())
}

pub fn builtin(app: &tauri::AppHandle, preset: &str) -> Result<BundledBackground, String> {
    let wallpaper = catalog()?
        .into_iter()
        .find(|wallpaper| wallpaper.id == preset)
        .ok_or("Unknown background preset")?;
    load(app, wallpaper)
}

pub fn random(app: &tauri::AppHandle) -> Result<BundledBackground, String> {
    let mut wallpapers = catalog()?;
    wallpapers.retain(|wallpaper| wallpaper.duplicate_of.is_none());
    if wallpapers.is_empty() {
        return Err("No bundled backgrounds are available".into());
    }
    let index = (uuid::Uuid::new_v4().as_u128() % wallpapers.len() as u128) as usize;
    load(app, wallpapers.swap_remove(index))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn default_pool_contains_only_embeddable_bundled_wallpapers() {
        let wallpapers = catalog().unwrap();
        assert!(!wallpapers.is_empty());
        let public = Path::new(env!("CARGO_MANIFEST_DIR")).join("../public/wallpapers");
        for wallpaper in wallpapers {
            let bytes = fs::read(public.join(&wallpaper.path)).unwrap();
            let background = BundledBackground::from_bytes(wallpaper.id.clone(), bytes).unwrap();
            assert!(matches!(background.background, Background::EmbeddedImage {
                preset: Some(ref id), ..
            } if id == &wallpaper.id));
        }
    }

    #[test]
    fn embeds_the_original_image_and_replaces_a_previous_background() {
        let wallpaper = catalog().unwrap().remove(0);
        let bytes = fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../public/wallpapers")
                .join(&wallpaper.path),
        )
        .unwrap();
        let background =
            BundledBackground::from_bytes(wallpaper.id.clone(), bytes.clone()).unwrap();
        let work = std::env::temp_dir().join(format!("saturn-wallpaper-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&work).unwrap();
        let mut manifest = Manifest::new(1_000_000, 1920, 1080, false, false);
        manifest.appearance.background = Background::None;
        background.apply(&mut manifest, &work).unwrap();
        let Background::EmbeddedImage { path, preset } = &manifest.appearance.background else {
            panic!("Expected a bundled wallpaper");
        };
        assert_eq!(preset.as_deref(), Some(wallpaper.id.as_str()));
        assert_eq!(fs::read(work.join(path)).unwrap(), bytes);
        manifest.validate().unwrap();
        fs::remove_dir_all(work).unwrap();
    }
}
