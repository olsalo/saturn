# Saturn

A compact, document-based macOS screen recorder, implemented from [the architecture](minimal_recorder_architecture_2026-11-07.md). Record a window, choose a background, and export an MP4. Your original footage and rendering settings travel together in one `.saturn` file. Existing `.recproj` files still open; Save As creates a `.saturn` file.

For a guided explanation of the React, Rust, and Swift layers, see [How Saturn works, for Electron developers](docs/HOW_IT_WORKS.md).

## Run

Requires macOS 15+, Node.js 22.12+ (24 recommended), Rust, and Apple command-line tools with the macOS 15+ SDK. No online service is used for recording or encoding. The first build downloads and SHA-256-verifies FFmpeg 8.0.1, libaom 3.15.1, libvpx 1.16.0 and Opus 1.6.1 source, builds LGPL FFmpeg/ffprobe with these permissive codec libraries, and bundles them for offline exports. CMake and pkgconf build tools are prepared locally under the ignored target directory; they are not included in the app. Complete codec source archives, licenses, patent notices and build instructions are included under `public/legal`. Encoder setup requires network access on the first build; subsequent builds reuse verified local binaries.

```sh
npm ci
npm run desktop
```

`npm run desktop:build` builds and opens **Saturn Local** (`com.saturn.recorder.local`), using `src-tauri/tauri.local.conf.json`. `npm run desktop` then opens that same local build without rebuilding. The local app has its own macOS privacy permissions and application data, and does not replace `/Applications/Saturn.app` or register itself as the default editor for project files. `npm run package` retains the production **Saturn** identity (`com.saturn.recorder`).

The launcher remembers the local app's designated signing requirement. When a rebuild changes it, the launcher resets only **Saturn Local's** stale Screen Recording decision before opening the new build. Approve the local app once when macOS asks; subsequent `npm run desktop` launches preserve that decision. The launcher never closes a running Saturn instance or changes permission while one is running. Certificate-signed rebuilds whose designated requirement stays unchanged retain consent without a reset.

Finder document icons are declared in `src-tauri/Info.plist`: both `.saturn` and legacy `.recproj` files use the bundled Saturn logo (`icon.icns`). Keep the extension declarations there aligned with `bundle.fileAssociations` in `src-tauri/tauri.conf.json`. After changing this metadata, quit Saturn and run `npm run desktop:build` to rebuild and open the registered app bundle.

If an existing build is stuck at the permission explanation, quit Saturn and run:

```sh
npm run desktop:repair
```

This resets only Saturn Local's Screen Recording decision and launches the existing local app without rebuilding. It does not change microphone, Accessibility, other apps' permissions, or grant access automatically. No manual Terminal reset command is needed. The launcher's identity record is stored beside the debug build in the ignored target directory. A failed reset is not marked successful and is retried on the next launch.

For UI/Rust hot reload, use `npm run desktop:dev` (the raw dev process remains separate from Saturn Local). A raw dev process launched from an editor terminal can inherit that editor's macOS privacy identity; use the normal app launch to test recording permissions. Rebuilding an ad-hoc-signed app can require renewed consent; a stable Apple Development signing identity is needed to retain consent reliably across code changes.

Choose **Choose a window**, then allow **Screen Recording** when prompted. If access is denied, Saturn provides **Open System Settings** and an explicit refresh action. Enable Saturn under Privacy & Security → Screen & System Audio Recording; quit and reopen Saturn if macOS requires it. Passive status checks never request permission. Once authorized, Saturn shows a searchable list of visible windows, with application names and window titles. Refresh the list after opening another window.

Choose a window, choose a Recordings folder on first capture, then press **Control + Option + Command + R (⌃⌥⌘R)** or click **Start recording**. R stands for recording: the same shortcut starts and stops, even while another app is in front. Saturn hides its panel while recording. Press **Control + Option + Command + P (⌃⌥⌘P)** to pause or continue globally, or use the directly clickable **Pause / Continue** and **Stop** buttons in the macOS status bar. Pausing restores the panel with the window picker disabled; continuing hides it before capture resumes. Each stretch is saved as a separate source clip in the same project. Press the recording shortcut again or click **Stop** to finish. The shortcut uses the selected window and current audio settings, ignores held-key repeats and capture transitions, and requires no Accessibility or Input Monitoring permission. If another app has reserved the combination, Saturn shows an error and the recording buttons remain available. Saturn uses a display filter cropped to the selected window’s bounds. It avoids the system window-sharing picker and its target-window controls. The normal macOS menu-bar privacy indicator remains. Keep the selected window uncovered: overlapping windows and menus inside its bounds are captured. The crop trims the outermost border pixel and aligns to physical pixels. Cursor images match the recorded system cursor and render at 2× native size, with shape changes stored for new recordings. Movement and resizing are followed on the same display; minimizing, closing or moving outside the display stops capture and finalizes usable footage.

Exports use a **2560×1600 (16:10)** canvas with **38% padding** (7.6% per canvas edge). Open **Wallpaper collection** in the export panel to choose a bundled background image. Choosing one embeds the original image in the project; gradient and custom-image options remain available. Add JPEG or PNG images to a category under `public/wallpapers`, then run `npm run wallpapers:thumbs` on macOS to generate thumbnails and refresh the wallpaper catalog. The **H.264 MP4** option uses **FFmpeg / VideoToolbox**, **High profile**, **8-bit color**, and a **30 fps ceiling**. Quality determines file size; the old under-1-MB target and fixed bitrate budget have been removed to preserve text and moving UI detail. All audio tracks are retained as AAC stereo with a 128 kbit/s target; FFmpeg uses constrained variable bitrate so silence stays small. Web Optimized/Fast Start remains enabled. The temporary ProRes compositor master renders directly at the output size, avoiding a second scaling step and reducing compositor work; it is deleted after export or cancellation. Original recordings remain unchanged. Export checks reserve temporary master space before starting.

The previous display-picker capture was user-verified. The replacement window-list/global-permission flow and absence of window-sharing controls need interactive verification in the rebuilt app. Backgrounds and MP4 export remain available for existing projects.

`npm run dev` provides a browser UI preview. It intentionally does not simulate successful recordings or exports. The desktop panel stays above other windows and is excluded from capture where supported.

The **Web export** switch is on by default. This renders the compositor once, then saves a new `<project>-web` folder containing `video-av1.webm` (libaom AV1, CRF 32, CPU-used 6, screen-content tuning), `video-vp9.webm` (libvpx VP9, CRF 32, CPU-used 4), `poster.jpg`, `embed.html`, and `README.txt`. Both WebM files keep all selected audio tracks as variable-bitrate Opus at a 128 kbit/s stereo target and move seek metadata ahead of the media clusters. The JPEG thumbnail uses the first frame, with its long edge capped at 1280 pixels, and the embed uses it as the video poster. The embed declares the actual AV1 profile/level, lists AV1 first and VP9 second, and lets the browser select the supported source. Upload the files together and copy the `<video>` element into your page. Both encoders run in software and can be substantially slower than hardware MP4 export. A partial or cancelled pair is cleaned up; the destination folder is published only when both videos and the embed are ready. Existing export folders are never replaced.

Turn off **Web export** to export H.264 MP4 for compatibility with other apps. H.264 uses VideoToolbox High profile, 8-bit color, quality 65 on Apple Silicon (8 Mbit/s hardware encoding on Intel), AAC and MP4 Fast Start. The Project menu offers destination selection for Web and MP4 exports. The desktop API accepts only `web` and `h264`; the standalone native helper defaults to H.264 when its encoder is omitted.

The FFmpeg tools are built without GPL/nonfree components. Adding AV1/VP9 does not clear H.264 patent licensing for commercial use. This is still a macOS implementation; Windows/Linux capture and compositing are not implemented by the codec additions.

## Build and verify

```sh
npm run check
cargo test --manifest-path src-tauri/Cargo.toml
npm run test:shortcut
bash scripts/verify-native.sh
bash scripts/verify-compact.sh
npm run test:web
npm run tauri -- build --debug --bundles app
# Release app and DMG (configure signing/notarization for distribution):
npm run package
```

The shortcut test requires a macOS desktop session and checks real hotkey registration, reservation conflicts, held-key suppression, unrelated events, and cleanup without recording the screen. The native smoke test generates a synthetic two-second source with audio, exports it through the actual compositor, checks H.264/2560×1600/source fps/audio and MP4 fast-start ordering, and checks cancellation. The compact-export test repeats a fixture to 30 seconds, checks dimensions, duration and retained audio, and compares every decoded frame for introduced black patches and compression loss. Pass a compositor master path to `bash scripts/verify-compact.sh` to test real footage. These tests never record your screen. Rust tests exercise portable archive round trips, moved projects, rejected archives, cursor validation, and preservation of an existing file on failed save. Frontend tests enforce the backend completion contract.

Build artifacts are in `src-tauri/target/{debug,release}/bundle/`; the local app is `src-tauri/target/debug/bundle/macos/Saturn Local.app`. The in-process Swift capture bridge and bundled export helper are compiled automatically; do not run `swift build` or install Swift packages. For universal builds, both Rust targets and matching Apple SDK/toolchains are required; only the current host architecture is checked by default.

## Status and release gates

This is an initial functional macOS implementation with local ad-hoc signing, not a Developer ID signed/notarized release. Native compositing/export is verified with synthetic media. Complete the [interactive validation matrix](docs/VALIDATION.md) before shipping. In particular, watermark-free isolation, cursor timing through window movement/scaling, actual permission flows, file associations in an installed signed bundle, interrupted MOV recovery, and real-media decoding/performance require real-device validation (archive-only 1/5/20 GiB benchmarks have passed). New recordings include a subtle cursor click bounce based on mouse-down counters, without requesting Accessibility or Input Monitoring. Existing recordings without click metadata cannot acquire click effects retrospectively. Windows capture/export is not implemented.

The shared UI components live in `src/components/ui`. Native and portable format decisions are in [DECISIONS](docs/DECISIONS.md) and [PROJECT_FORMAT](docs/PROJECT_FORMAT.md).

### Component showcase

Run `npm run showcase` to start the standalone development gallery and open it in your browser at `http://127.0.0.1:1421/showcase.html`. The theme switch is temporary and resets on reload. The examples use mock data and do not connect to the recorder.

The gallery entry point and its Tailwind theme live in `src/showcase/`, with the separate HTML entry in `showcase.html`. To reuse it in another Vite/React project, copy those files and `src/components/ui_new`, along with `src/components/icons.tsx`, `drawer-dropdown-state.tsx`, `dialog-popup-styles.ts`, `sheet-popup-styles.ts`, and `src/lib/{utils,hooks,use-hydrated}.ts`. Configure the `@` and `~` aliases as in `vite.config.ts` and `tsconfig.json`, and install the component dependencies listed in `package.json` (including Tailwind, Base UI, Pixelarticons, React Day Picker, and react-i18next). The showcase stylesheet defines its own theme tokens, so it does not depend on the recorder's global stylesheet.
