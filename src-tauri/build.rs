fn main() {
    println!("cargo:rerun-if-changed=native/RecorderNative.swift");
    println!("cargo:rerun-if-changed=native/ExportCompositor.swift");
    println!("cargo:rerun-if-changed=native/RecordingShortcut.swift");
    println!("cargo:rerun-if-changed=native/CaptureGeometry.swift");
    println!("cargo:rerun-if-changed=native/CursorTimeline.swift");
    println!("cargo:rerun-if-changed=native/CursorAppearance.swift");
    println!("cargo:rerun-if-changed=native/VideoTiming.swift");
    println!("cargo:rerun-if-changed=native/ExportEncoder.swift");
    println!("cargo:rerun-if-changed=native/FFmpegEncoder.swift");
    println!("cargo:rerun-if-changed=native/CapturePermission.swift");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        let out = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap());
        let target = std::env::var("TARGET").unwrap();
        let swift_target = format!("{}-apple-macosx15.0", target.split('-').next().unwrap());
        let status = std::process::Command::new("swiftc")
            .args([
                "-module-cache-path",
                out.join("swift-cache").to_str().unwrap(),
                "-swift-version",
                "5",
                "-O",
                "-parse-as-library",
                "-D",
                "SATURN_BRIDGE",
                "-emit-library",
                "-static",
                "-module-name",
                "SaturnNative",
                "-target",
                &swift_target,
                "native/RecorderNative.swift",
                "native/ExportCompositor.swift",
                "native/RecordingShortcut.swift",
                "native/VideoTiming.swift",
                "native/ExportEncoder.swift",
                "native/FFmpegEncoder.swift",
                "native/CaptureGeometry.swift",
                "native/CursorTimeline.swift",
                "native/CursorAppearance.swift",
                "native/CapturePermission.swift",
                "-o",
                out.join("libSaturnNative.a").to_str().unwrap(),
            ])
            .status()
            .expect("Swift command-line tools are required");
        assert!(
            status.success(),
            "In-process native capture bridge failed to compile"
        );
        swift_rs::SwiftLinker::new("15.0").link();
        println!("cargo:rustc-link-search=native={}", out.display());
        println!("cargo:rustc-link-lib=static=SaturnNative");
        for framework in [
            "AppKit",
            "Carbon",
            "ScreenCaptureKit",
            "AVFoundation",
            "CoreMedia",
            "CoreGraphics",
            "QuartzCore",
            "ImageIO",
            "CryptoKit",
        ] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
        let target = std::env::var("TARGET").unwrap();
        std::fs::create_dir_all("binaries").unwrap();
        let binary = std::path::PathBuf::from(format!("binaries/recorder-native-{target}"));
        let modified = std::fs::metadata(&binary).and_then(|m| m.modified()).ok();
        let stale = [
            "native/RecorderNative.swift",
            "native/ExportCompositor.swift",
            "native/RecordingShortcut.swift",
            "native/VideoTiming.swift",
            "native/ExportEncoder.swift",
            "native/FFmpegEncoder.swift",
            "native/CaptureGeometry.swift",
            "native/CursorTimeline.swift",
            "native/CursorAppearance.swift",
            "native/CapturePermission.swift",
            "build.rs",
        ]
        .iter()
        .any(|path| {
            let source_modified = std::fs::metadata(path).and_then(|m| m.modified()).ok();
            match (source_modified, modified) {
                (Some(source), Some(output)) => source > output,
                _ => true,
            }
        });
        if stale {
            let pending = binary.with_extension("next");
            let status = std::process::Command::new("swiftc")
                .args([
                    "-module-cache-path",
                    &format!("{}/swift-cache", std::env::var("OUT_DIR").unwrap()),
                    "-swift-version",
                    "5",
                    "-O",
                    "-parse-as-library",
                    "-target",
                    &format!("{}-apple-macosx15.0", target.split('-').next().unwrap()),
                    "native/RecorderNative.swift",
                    "native/ExportCompositor.swift",
                    "native/RecordingShortcut.swift",
                    "native/VideoTiming.swift",
                    "native/ExportEncoder.swift",
                    "native/FFmpegEncoder.swift",
                    "native/CaptureGeometry.swift",
                    "native/CursorTimeline.swift",
                    "native/CursorAppearance.swift",
                    "native/CapturePermission.swift",
                    "-o",
                    pending.to_str().unwrap(),
                ])
                .status()
                .expect("Swift command-line tools are required");
            assert!(status.success(), "Native recorder helper failed to compile");
            std::fs::rename(pending, binary).expect("Could not install the native recorder helper");
        }
    }
    tauri_build::build()
}
