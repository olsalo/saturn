pub mod archive;
pub mod disk;
pub mod manifest;
use manifest::Manifest;
use std::path::PathBuf;
#[derive(Clone)]
pub struct Project {
    pub path: PathBuf,
    pub work: PathBuf,
    pub manifest: Manifest,
}
impl Project {
    pub fn checkpoint(&self) -> Result<(), String> {
        archive::write_manifest(&self.work, &self.manifest)?;
        let info = serde_json::json!({"destination":self.path,"updatedAt":chrono::Utc::now().to_rfc3339()});
        std::fs::write(
            self.work.join("recovery.json"),
            serde_json::to_vec(&info).unwrap(),
        )
        .map_err(|e| e.to_string())
    }
    pub fn save(&self) -> Result<(), String> {
        self.checkpoint()?;
        archive::save(&self.work, &self.path, &self.manifest)
    }
}

/// Store a background in an opened or newly recorded project workspace.
pub fn write_background(
    work: &std::path::Path,
    filename: &str,
    bytes: &[u8],
) -> Result<(), String> {
    let assets = work.join("assets");
    std::fs::create_dir_all(&assets)
        .map_err(|e| format!("Could not prepare the background folder: {e}"))?;
    std::fs::write(assets.join(filename), bytes)
        .map_err(|e| format!("Could not save the background image: {e}"))
}

#[cfg(test)]
mod tests {
    #[test]
    fn background_can_be_added_to_workspace_without_assets_directory() {
        let work =
            std::env::temp_dir().join(format!("saturn-background-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&work).unwrap();
        super::write_background(&work, "background.jpg", b"image").unwrap();
        assert_eq!(
            std::fs::read(work.join("assets/background.jpg")).unwrap(),
            b"image"
        );
        std::fs::remove_dir_all(work).unwrap();
    }
}
