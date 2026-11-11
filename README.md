# Saturn

A compact, document-based macOS screen recorder, implemented from [the architecture](minimal_recorder_architecture_2026-11-07.md). Record a window, choose a background, and export an MP4. Your original footage and rendering settings travel together in one `.saturn` file. Existing `.recproj` files still open; Save As creates a `.saturn` file.

## Run

Requires macOS 15+, Node.js 22.12+ (24 recommended), Rust, and Apple command-line tools with the macOS 15+ SDK. No online service is used for recording or encoding. The first build downloads and SHA-256-verifies FFmpeg 8.0.1 source, builds a minimal LGPL CLI using Apple command-line tools, and bundles it for offline exports. Its complete source archive, license and build instructions are included under `public/legal/ffmpeg`. The official HandBrakeCLI 1.11.2 is also downloaded, verified and bundled for the existing optional backends. Encoder setup requires network access on the first build; subsequent builds reuse verified local binaries.

```sh
npm ci
npm run desktop
```

`npm run desktop` opens the existing signed `Saturn.app` through macOS LaunchServices, building it only if it does not exist. Use `npm run desktop:build` after changing code, with Saturn closed. The launcher remembers the app's designated signing requirement. When that requirement changes, it automatically resets only Saturn's stale Screen Recording decision before opening the new build. Ordinary launches and certificate-signed builds whose designated requirement stays the same preserve consent. macOS still requires you to approve a newly identified build once; reopen Saturn if prompted. The launcher never closes an active app or resets permissions while Saturn is running.

Finder document icons are declared in `src-tauri/Info.plist`: both `.saturn` and legacy `.recproj` files use the bundled Saturn logo (`icon.icns`). Keep the extension declarations there aligned with `bundle.fileAssociations` in `src-tauri/tauri.conf.json`. After changing this metadata, quit Saturn and run `npm run desktop:build` to rebuild and open the registered app bundle.

If an existing build is stuck at the permission explanation, quit Saturn and run:

```sh
npm run desktop:repair
```

This performs the scoped Screen Recording reset and launches the existing app without rebuilding. It does not change microphone, Accessibility, other apps' permissions, or grant access automatically. No manual Terminal reset command is needed. The launcher's identity record is stored beside the debug build in the ignored target directory. A failed reset is retried on the next launch rather than marked successful.

For UI/Rust hot reload, use `npm run desktop:dev`. A raw dev process launched from an editor terminal can inherit that editor's macOS privacy identity; use the normal app launch to test recording permissions. Rebuilding an ad-hoc-signed app can require renewed consent; a stable Apple Development signing identity is needed to retain consent reliably across code changes.

Choose **Choose a window**, then allow **Screen Recording** when prompted. If access is denied, Saturn provides **Open System Settings** and an explicit refresh action. Enable Saturn under Privacy & Security → Screen & System Audio Recording; quit and reopen Saturn if macOS requires it. Passive status checks never request permission. Once authorized, Saturn shows a searchable list of visible windows, with application names and window titles. Refresh the list after opening another window.

Choose a window, choose a Recordings folder on first capture, then press **Control + Option + Command + R (⌃⌥⌘R)** or click **Start recording**. R stands for recording: the same shortcut starts and stops, even while another app is in front. Saturn hides its panel; press the shortcut again or click **Stop** in the macOS menu bar to finish and restore the panel. The shortcut uses the selected window and current audio settings, ignores held-key repeats and capture transitions, and requires no Accessibility or Input Monitoring permission. If another app has reserved the combination, Saturn shows an error and the recording buttons remain available. Following [Recordly v1.4.0](https://github.com/webadderallorg/Recordly/blob/v1.4.0/electron/native/ScreenCaptureKitRecorder.swift), Saturn uses a display filter cropped to the selected window’s bounds. It avoids the system window-sharing picker and its target-window controls. The normal macOS menu-bar privacy indicator remains. Keep the selected window uncovered: overlapping windows and menus inside its bounds are captured. The crop trims the outermost border pixel and aligns to physical pixels. Cursor images match the recorded system cursor and render at 1.75× native size, with shape changes stored for new recordings. Movement and resizing are followed on the same display; minimizing, closing or moving outside the display stops capture and finalizes usable footage.

Exports use a **2560×1600 (16:10)** canvas with **38% Recordly-style padding** (7.6% per canvas edge). Open **Wallpaper collection** in the export panel to search 38 bundled background images copied from Recordly v1.4.0. Choosing one embeds the original image in the project; gradient and custom-image options remain available. Source and license details are in [asset credits](docs/ASSET_CREDITS.md). The final MP4 defaults to **FFmpeg / VideoToolbox HEVC Main 10**, **quality 57**, quality-oriented hardware encoding and a **30 fps ceiling**. FFmpeg and HandBrake quality numbers are backend-specific; matching values do not guarantee identical files. The optional software HandBrake/x265 encoder retains **RF 18 constant quality** and the `faster` preset. Quality determines file size; the old under-1-MB target and fixed bitrate budget have been removed to preserve text and moving UI detail. All audio tracks are retained as AAC stereo with a 128 kbit/s target; FFmpeg uses constrained variable bitrate so silence stays small. Edge-aware adaptive quantization with 8-pixel groups protects faint outlines. On Apple Silicon, x265 SIMD stays disabled (`asm=0`) to prevent reproduced black-block flashes. Web Optimized/Fast Start remains enabled. The temporary ProRes compositor master renders directly at the output size, avoiding a second scaling step and reducing compositor work; it is deleted after export or cancellation. Original recordings remain unchanged. Export checks reserve temporary master space before starting.

The previous display-picker capture was user-verified. The replacement window-list/global-permission flow and absence of window-sharing controls need interactive verification in the rebuilt app. Backgrounds and MP4 export remain available for existing projects.

`npm run dev` provides a browser UI preview. It intentionally does not simulate successful recordings or exports. The desktop panel stays above other windows and is excluded from capture where supported.

Encoder selection is currently code-only: `ExportEncoder.defaultEncoder` in `src-tauri/native/HandBrakeEncoder.swift` defaults to `.ffmpeg`. Native export requests can set `"encoder": "ffmpeg"`, `"encoder": "videotoolbox"` (the retained HandBrake hardware path), or `"encoder": "handbrake"` (the retained x265 path). FFmpeg uses `hevc_videotoolbox`, Main 10, quality 57, a 301-frame maximum keyframe interval (about ten seconds at 30 fps), frame reordering, 128 kbit/s constrained-variable AAC stereo for every audio track, and MP4 Fast Start. The longer keyframe interval matches HandBrake at the normal export rate; FFmpeg's default twelve-frame interval was substantially larger on static UI footage. It performs a short hardware encode before compositing and fails explicitly if unavailable; there is no automatic switch to HandBrake. Both HandBrake configurations retain their previous options. This remains a macOS implementation; adding FFmpeg does not implement Windows or Linux capture/compositing. The FFmpeg CLI is built without GPL/nonfree components or external libraries; retaining HandBrake still retains its separate GPL distribution obligations.

## Build and verify

```sh
npm run check
cargo test --manifest-path src-tauri/Cargo.toml
npm run test:shortcut
bash scripts/verify-native.sh
bash scripts/verify-compact.sh
npm run tauri -- build --debug --bundles app
# Release app and DMG (configure signing/notarization for distribution):
npm run package
```

The shortcut test requires a macOS desktop session and checks real hotkey registration, reservation conflicts, held-key suppression, unrelated events, and cleanup without recording the screen. The native smoke test generates a synthetic two-second source with audio, exports it through the actual compositor, checks HEVC Main 10/2560×1600/source fps/audio and MP4 fast-start ordering, and checks cancellation. The compact-export test repeats a fixture to 30 seconds, checks dimensions, duration and retained audio, and compares every decoded frame for introduced black patches and compression loss. Pass a compositor master path to `bash scripts/verify-compact.sh` to test real footage. These tests never record your screen. Rust tests exercise portable archive round trips, moved projects, rejected archives, cursor validation, and preservation of an existing file on failed save. Frontend tests enforce the backend completion contract.

Build artifacts are in `src-tauri/target/{debug,release}/bundle/`. The in-process Swift capture bridge and bundled export helper are compiled automatically; do not run `swift build` or install Swift packages. For universal builds, both Rust targets and matching Apple SDK/toolchains are required; only the current host architecture is checked by default.

## Status and release gates

This is an initial functional macOS implementation with local ad-hoc signing, not a Developer ID signed/notarized release. Native compositing/export is verified with synthetic media. Complete the [interactive validation matrix](docs/VALIDATION.md) before shipping. In particular, watermark-free isolation, cursor timing through window movement/scaling, actual permission flows, file associations in an installed signed bundle, interrupted MOV recovery, and real-media decoding/performance require real-device validation (archive-only 1/5/20 GiB benchmarks have passed). New recordings include a subtle cursor click bounce based on mouse-down counters, without requesting Accessibility or Input Monitoring. Existing recordings without click metadata cannot acquire click effects retrospectively. Windows capture/export is not implemented.

Coss UI's five manually copied components live in `src/components/ui`; see [attribution](docs/UI_COMPONENTS.md). Native and portable format decisions are in [DECISIONS](docs/DECISIONS.md) and [PROJECT_FORMAT](docs/PROJECT_FORMAT.md).

### Component showcase

Run `npm run showcase` to start the standalone development gallery and open it in your browser at `http://127.0.0.1:1421/showcase.html`. The theme switch is temporary and resets on reload. The examples use mock data and do not connect to the recorder.

The gallery entry point and its Tailwind theme live in `src/showcase/`, with the separate HTML entry in `showcase.html`. To reuse it in another Vite/React project, copy those files and `src/components/ui_new`, along with `src/components/icons.tsx`, `drawer-dropdown-state.tsx`, `dialog-popup-styles.ts`, `sheet-popup-styles.ts`, and `src/lib/{utils,hooks,use-hydrated}.ts`. Configure the `@`, `~`, and `@coss/ui` aliases as in `vite.config.ts` and `tsconfig.json`, and install the component dependencies listed in `package.json` (including Tailwind, Base UI, Pixelarticons, React Day Picker, and react-i18next). The showcase stylesheet defines its own theme tokens, so it does not depend on the recorder's global stylesheet.
