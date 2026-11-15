use std::path::PathBuf;

/// macOS can deliver document-open events before Tauri runs app setup.
/// Keep those paths outside managed session state until RunEvent::Ready.
#[derive(Default)]
pub struct OpenRequests {
    ready: bool,
    startup: Vec<PathBuf>,
}

impl OpenRequests {
    pub fn opened(&mut self, paths: impl IntoIterator<Item = PathBuf>) -> Vec<PathBuf> {
        if self.ready {
            paths.into_iter().collect()
        } else {
            self.startup.extend(paths);
            Vec::new()
        }
    }

    pub fn ready(&mut self) -> Vec<PathBuf> {
        self.ready = true;
        std::mem::take(&mut self.startup)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cold_launch_keeps_documents_until_session_setup_finishes() {
        let mut requests = OpenRequests::default();
        let first = PathBuf::from("/recordings/First project.saturn");
        let second = PathBuf::from("/recordings/Second.recproj");
        assert!(requests.opened([first.clone()]).is_empty());
        assert!(requests.opened([second.clone()]).is_empty());
        assert_eq!(requests.ready(), vec![first, second]);
        assert!(
            requests.ready().is_empty(),
            "Never reopen startup projects twice"
        );
    }

    #[test]
    fn running_app_opens_documents_immediately() {
        let mut requests = OpenRequests::default();
        assert!(requests.ready().is_empty());
        let path = PathBuf::from("/recordings/Existing.saturn");
        assert_eq!(requests.opened([path.clone()]), vec![path]);
        assert!(requests.ready().is_empty());
    }
}
