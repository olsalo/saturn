use std::path::Path;
/// Keep a small reserve so a failed media operation does not consume the last disk blocks.
pub fn ensure_space(path: &Path, bytes: u64) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::{ffi::CString, os::unix::ffi::OsStrExt};
        let path = CString::new(path.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
        let mut info = std::mem::MaybeUninit::<libc::statvfs>::uninit();
        // SAFETY: the path is NUL-terminated; statvfs initializes info on success.
        if unsafe { libc::statvfs(path.as_ptr(), info.as_mut_ptr()) } != 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        let info = unsafe { info.assume_init() };
        let available = u128::from(info.f_bavail) * u128::from(info.f_frsize);
        if available < u128::from(bytes) + 64 * 1024 * 1024 {
            return Err(format!("Not enough free disk space. Free at least {} MB or choose another destination. Existing files and recovery data were kept.", (bytes / 1_048_576) + 64));
        }
    }
    #[cfg(not(unix))]
    let _ = (path, bytes);
    Ok(())
}
