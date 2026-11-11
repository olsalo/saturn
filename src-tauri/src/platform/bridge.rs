//! Synchronous C boundary called only from Rust worker threads. Swift owns Apple
//! objects; small JSON events are copied before the native callback returns.
use std::{
    ffi::{c_char, c_void, CStr, CString},
    sync::Mutex,
};
unsafe extern "C" {
    fn saturn_native_run(
        request: *const c_char,
        context: *mut c_void,
        callback: extern "C" fn(*const c_char, *mut c_void),
    ) -> i32;
}
struct Callback<F> {
    handler: F,
    error: Option<String>,
}
extern "C" fn receive<F: FnMut(serde_json::Value) + Send>(
    text: *const c_char,
    context: *mut c_void,
) {
    if text.is_null() || context.is_null() {
        return;
    }
    // SAFETY: Swift holds its reporter lock while calling us. Both pointers are
    // valid until this callback returns; the context outlives saturn_native_run.
    let state = unsafe { &*(context as *const Mutex<Callback<F>>) };
    if let Ok(mut state) = state.lock() {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let text = unsafe { CStr::from_ptr(text) };
            let event: serde_json::Value =
                serde_json::from_slice(text.to_bytes()).map_err(|e| e.to_string())?;
            if event["type"] == "error" {
                state.error = Some(
                    event["message"]
                        .as_str()
                        .unwrap_or("Native capture failed")
                        .to_string(),
                );
            }
            (state.handler)(event);
            Ok::<(), String>(())
        }));
        match result {
            Ok(Err(e)) => state.error = Some(e),
            Err(_) => state.error = Some("Native callback failed".into()),
            _ => {}
        }
    };
}
pub fn execute<F: FnMut(serde_json::Value) + Send>(
    command: &str,
    arguments: &[&str],
    handler: F,
) -> Result<(), String> {
    let request =
        CString::new(serde_json::json!({"command":command,"arguments":arguments}).to_string())
            .map_err(|e| e.to_string())?;
    let context = Mutex::new(Callback {
        handler,
        error: None,
    });
    // SAFETY: Swift closes its reporter before returning, so no callback can use
    // context after this call. Swift copies the request before starting its Task.
    let status = unsafe {
        saturn_native_run(
            request.as_ptr(),
            &context as *const _ as *mut c_void,
            receive::<F>,
        )
    };
    let state = context
        .into_inner()
        .map_err(|_| "Native callback lock failed")?;
    if status != 0 || state.error.is_some() {
        return Err(state
            .error
            .unwrap_or_else(|| "Native capture failed".into()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn swift_errors_cross_the_real_callback_boundary() {
        let mut event = serde_json::Value::Null;
        let error = execute("unknown-bridge-test-command", &[], |value| event = value).unwrap_err();
        assert!(error.contains("Unknown native command"));
        assert_eq!(event["type"], "error");
        assert_eq!(event["domain"], "Saturn");
    }
}
