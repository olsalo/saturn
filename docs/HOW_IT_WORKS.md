# How Saturn works, for Electron developers

Saturn is a local macOS screen recorder. You choose a window or display, record it, adjust its presentation, and export a video. A `.saturn` project keeps the original footage, cursor data, and presentation settings together so you can export again later.

The interface is a React app. Tauri supplies the desktop window and connects that interface to a Rust backend. Swift handles Apple's capture and media APIs. Recording and encoding happen locally; there is no application server involved.

This guide describes the current implementation in this repository, including segmented recording and the web export path. Start here before reading the more detailed [project format](PROJECT_FORMAT.md) and [segmented recording notes](segmented-recording.md).

## Translate your Electron mental model

Think of Tauri as the desktop host around a web interface. The division between interface code and privileged desktop code will feel familiar, but the host is Rust rather than Node.js.

| In an Electron app                                   | In Saturn                                                                          |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Renderer running React                               | React running in the macOS system webview, WKWebView                               |
| Bundled Chromium                                     | The operating system's webview engine                                              |
| Main process written in JavaScript or TypeScript     | Rust application started by Tauri                                                  |
| `BrowserWindow` configuration                        | Window configuration in `src-tauri/tauri.conf.json`, plus runtime window calls     |
| A preload API exposed with `contextBridge`           | The TypeScript API wrapper in `src/lib/tauri.ts`, backed by Tauri commands         |
| `ipcRenderer.invoke` → `ipcMain.handle`              | `invoke()` → a registered Rust `#[tauri::command]` function                        |
| Main-to-renderer notifications                       | Tauri events emitted by Rust and listened to by React                              |
| Node filesystem and process APIs in the main process | Rust filesystem/process APIs and native Swift code                                 |
| A native addon or helper executable                  | An in-process Swift library for capture, plus a Swift helper executable for export |

These are role comparisons, not identical APIs or process models. The webview still has engine-managed processes. Saturn's Swift capture library is linked into the Rust host; it is not running inside the React JavaScript environment.

There is no Node runtime available to application code in the webview. Node is used by the development and build scripts. Desktop filesystem access and process launching live behind the Rust API.

## The runtime layout

```text
React interface (system webview)
  src/app + src/features
       |
       | commands down; snapshot events up
       v
Tauri / Rust application host
  session state, files, validation, job coordination
       |
       +-- C function bridge --> linked Swift library
       |                         permissions, sources, capture, shortcuts
       |
       +-- child process ------> recorder-native export helper
                                 AVFoundation / Core Animation composition
                                      |
                                      +--> bundled FFmpeg / ffprobe
                                           final encoding / media inspection
```

The boundaries carry small structured messages and file paths. Video frames are processed by native code and stored on disk; they do not travel through React or Tauri events.

The same Swift sources are compiled in two forms by [build.rs](../src-tauri/build.rs): a static library linked into Saturn, and the `recorder-native` command-line executable. [platform/mod.rs](../src-tauri/src/platform/mod.rs) selects which form handles an operation. Permission checks, source discovery, and recording use the in-process bridge. Export and operations such as media inspection use the helper.

## Startup and the desktop window

[main.rs](../src-tauri/src/main.rs) calls the application `run()` function in [lib.rs](../src-tauri/src/lib.rs). Tauri's builder then:

1. Creates the application data and session directories.
2. Removes eligible clean staged sessions and discovers work that may need recovery.
3. Loads saved recording defaults and installs shared Rust session state.
4. Registers global shortcuts and restores/tracks the panel position.
5. Registers the commands callable by the frontend and starts the event loop.

The main window is a small, transparent, undecorated, always-on-top panel. Its initial properties are in [tauri.conf.json](../src-tauri/tauri.conf.json). It stays hidden while [window_position.rs](../src-tauri/src/window_position.rs) restores its position and React loads its initial state. After the initial screen and footer are committed, fonts are ready, and layout is calculated, [use-window-ready.ts](../src/app/use-window-ready.ts) sends a one-time `frontend_ready` command to reveal it. Finder document opens also respect this startup gate. The React header provides a drag region in place of a normal title bar.

In development, that window loads Vite at port 1420. In a built app, it loads the bundled frontend from `dist`. The Vite server is a development convenience; an installed app does not need it running.

## How React talks to Rust

The frontend's desktop API is centralized in [src/lib/tauri.ts](../src/lib/tauri.ts). For example, starting a recording sends this command:

```ts
return invoke<void>("start_recording", {
  options: { source, systemAudio, microphone },
});
```

Tauri routes the name to the Rust function registered in `generate_handler!` in [lib.rs](../src-tauri/src/lib.rs). Rust deserializes `options` into `RecordingOptions`, validates it, and starts the operation. `serde` is the Rust serialization library used here; its `camelCase` naming settings let fields such as Rust's `system_audio` match JavaScript's `systemAudio`.

The `void` result matters: this call acknowledges starting the operation. It does not wait for the entire recording to finish. Recording and export run on worker threads and report their eventual state through events.

Rust emits a `recorder://snapshot` event containing the UI-facing state: mode, project summary, progress, error, output path, job ID, and recovery information. [use-app-events.ts](../src/app/use-app-events.ts) subscribes to it and feeds snapshots into the React reducer. It subscribes before fetching the initial snapshot and guards against an older fetch overwriting a newer event.

The [reducer](../src/app/recorder-machine.ts) also checks basic completion rules. For example, a `done` snapshot must contain both a project and an output path. Resolving an IPC promise alone cannot make the interface claim that an export succeeded.

[contracts.ts](../src/lib/contracts.ts) defines the TypeScript view of these messages. This is a manually maintained contract with Rust, not generated bindings: when changing message fields, update both sides.

## Who owns state?

Rust owns the active session and project. `Shared` wraps the `Session` in a `Mutex`, which makes concurrent access from commands and worker threads safe. Commands check whether an operation is allowed before changing files or state. Blocking work is moved off the asynchronous command executor with `spawn_blocking` or explicit worker threads.

React keeps interface-only state, such as the selected capture source, open popovers, and countdown interactions. Some boolean preferences use webview `localStorage` through [preferences.ts](../src/lib/preferences.ts): capture audio/microphone/countdown options and the web export switch. Rust separately persists recording defaults, including independent window and display presentation defaults, in the application data directory. The project manifest stores the settings belonging to the document itself.

The usual successful path is:

```text
idle → starting → recording → stopping → finalizing → export_ready
                    |
                    +→ pausing → paused → resuming → recording

export_ready → exporting → done
```

Errors can return the app to an editable state with a message and, where possible, recoverable footage. The TypeScript `Mode` union also contains interface-oriented values; the sequence above shows the main backend workflow.

## Trace a recording from click to project

1. **Choose a source.** The [capture panel](../src/features/capture/capture-panel.tsx) asks Rust for available sources. Swift uses ScreenCaptureKit to discover displays and eligible windows. Permission status checks and explicit permission requests are separate operations.
2. **Start.** React sends the source ID and audio choices. [recording/mod.rs](../src-tauri/src/recording/mod.rs) validates the request, obtains the recording destination, checks disk space, and creates a session workspace with a recovery record and `capture-request.json`.
3. **Enter native capture.** A Rust worker calls `platform::stream("record", ...)`. This operation goes through [bridge.rs](../src-tauri/src/platform/bridge.rs) into the linked Swift library. The bridge passes a JSON request through a C-compatible function and receives JSON callback events. Rust copies and parses callback data before the callback returns.
4. **Write media.** [RecorderNative.swift](../src-tauri/native/RecorderNative.swift) configures a ScreenCaptureKit stream and writes the source video, optional separate audio files, and cursor observations. Native `started`, pause, and completion events become Rust session updates and frontend snapshots.
5. **Stop and finalize.** The stop command writes a `stop` signal file in the workspace. Swift observes it and finalizes capture. Rust builds and validates the manifest, applies the saved defaults, and saves the portable `.saturn` archive.
6. **Show the editor.** Only after finalization and saving succeed does Rust publish `export_ready` with the loaded project. The React app then displays the export panel.

For window recording, Saturn currently captures a display cropped to the selected window's bounds. It follows supported movement/resizing on that display. Overlapping windows and menus within those bounds can appear in the result, so keep the target uncovered. This behavior comes from the native capture configuration, not a web `getDisplayMedia()` call.

Source video is written with `AVAssetWriter` at 30 fps. ScreenCaptureKit can stop delivering new pictures while a screen is idle, so the native sampler repeats the latest picture until Stop or Pause. The final frame has an explicit duration, and system/microphone audio stays in separate files; audio cannot extend the source movie into an interval without video.

The system cursor is excluded from the video stream. Saturn records cursor positions, visibility, shapes, and click observations separately so the exporter can draw and animate the cursor later. New recordings also keep system and microphone audio separate, allowing export choices without rewriting the original capture.

### Pause creates clips

Pause finalizes the current clip; Continue begins another one. New recordings therefore store media under paths such as `clips/0001/media/source.mov` and `clips/0002/media/source.mov`, with corresponding audio and cursor data. Even a recording without a pause uses the clip structure.

Swift maintains a `clips.json` journal, and Rust checkpoints completed clips. Export joins the clips in order without the paused wall-clock gaps. If starting a later clip fails, previously completed clips can still be retained. See [segmented-recording.md](segmented-recording.md) for details.

### Global shortcuts

Swift registers ⌃⌥⌘R for start/stop and ⌃⌥⌘P for pause/continue using macOS hotkey APIs. [platform/shortcut.rs](../src-tauri/src/platform/shortcut.rs) forwards their callbacks as Tauri events. The capture panel handles those events using the current source, preferences, countdown, and transition guards. The Swift status-bar controls also communicate with recording through workspace signals.

## Projects, working files, and recovery

There are two distinct locations to understand:

| Location                              | Purpose                                                                                 |
| ------------------------------------- | --------------------------------------------------------------------------------------- |
| User's `.saturn` file                 | Portable saved document containing original media and settings                          |
| App data `sessions/<UUID>/` directory | Expanded working files, capture/export requests, control signals, and recovery metadata |

A `.saturn` document is a ZIP64 archive with uncompressed entries. Its `manifest.json` references relative paths to media, cursor data, an optional embedded background, and a preview thumbnail. Legacy `.recproj` files and older single-source layouts remain readable. You can move a saved project without needing the original workspace or wallpaper file.

[project/archive.rs](../src-tauri/src/project/archive.rs) validates entries and their paths before accepting an archive. Saving streams a new archive into a temporary file beside the destination, syncs it, and renames it into place. This avoids replacing the existing project with a partially written archive.

The workspace's `dirty` marker indicates unsaved work. Startup discovers recovery candidates; explicit recovery can rebuild a project from a manifest, clip journal, or usable captured media. Recovery is best effort: an interrupted MOV whose container never finalized may be unreadable. Keeping recovery files does not guarantee that every interrupted recording can be restored.

Finder opens arrive through Tauri's application events. [open_requests.rs](../src-tauri/src/project/open_requests.rs) coordinates startup/open requests; the application queues documents when the current operation or unsaved work prevents opening them immediately.

## Appearance settings and the preview

The [export panel](../src/features/export/export-panel.tsx) changes the project through commands for appearance, aspect ratio, resolution, backgrounds, and audio inclusion. Rust validates the change, updates the manifest, saves the document, and publishes snapshots.

Each new window recording starts with a randomly selected bundled wallpaper, embedded at its original quality in the project. The random pool contains only catalog images; none, custom images, gradients, and solid colors are excluded. Screen recordings keep their existing background defaults, and reopening a project preserves its saved background.

The panel keeps pending selected values while asynchronous saves run, then reconciles them with the backend result. This is important for settings work: controls and labels must stay visually stable during saves and permission checks. Preserve clear disabled styling for genuinely unavailable options, such as an aspect-ratio control locked by the capture/background choice. See the repository's [AGENTS.md](../AGENTS.md).

[RecordingPreview](../src/features/export/recording-preview.tsx) is a thumbnail-based appearance preview using browser layout and styling. It is not live playback or the final encoder. The frontend's [export-layout.ts](../src/lib/export-layout.ts) and the native compositor must agree on geometry when padding, fitting, or canvas rules change.

Local images are exposed through Tauri's asset protocol: Rust explicitly allows preview/background files, and the frontend converts their paths with `convertFileSrc`. Passing a filesystem path to an image element by itself does not grant webview access to that file.

## Trace an export

1. React sends `start_export` with a format and destination preference.
2. [export/mod.rs](../src-tauri/src/export/mod.rs) checks the project, reserves disk space, saves pending changes, creates a job ID, and writes `export-request.json`.
3. Rust starts the `recorder-native` helper process. Its stdout carries newline-separated JSON progress/completion messages; Rust drains stderr separately so diagnostic output cannot block it.
4. [ExportCompositor.swift](../src-tauri/native/ExportCompositor.swift) reads the manifest and uses AVFoundation/Core Animation to compose footage, background, padding, corners, shadows, cursor animation, and enabled audio. Segmented recordings are assembled in clip order.
5. The native export pipeline produces a temporary ProRes master and uses bundled FFmpeg for the selected delivery encoding. Web export shares the composed master between its AV1 and VP9 encodes. Temporary masters are cleaned up after the operation.
6. Rust requires a native completion event and nonempty expected output files, syncs the files, and publishes the temporary output to the destination by renaming it. It then emits `done` with an output path. Progress is held below 100% until this succeeds.

The current main-panel choices are:

| Choice                  | Result                                                                                    |
| ----------------------- | ----------------------------------------------------------------------------------------- |
| Web export on (default) | A folder containing AV1 and VP9 WebM videos, `poster.jpg`, `embed.html`, and `README.txt` |
| Web export off          | H.264 MP4                                                                                 |

Cancellation uses the active job ID and a `cancel-export` signal file. Failed or cancelled exports remove partial staged output and return to `export_ready`. A web folder is published only after all expected files are ready.

Changing the CSS preview does not change the rendered video. Video appearance changes must also be implemented in the native compositor and, when needed, the manifest and contracts.

## Permissions and desktop access

There are two permission systems with different jobs. Tauri's [capabilities file](../src-tauri/capabilities/default.json) controls the core desktop APIs exposed to the `main` webview, such as dragging and resizing the panel. App-defined commands are registered separately in Rust; their handlers must validate incoming arguments and enforce valid operations.

macOS privacy permissions govern screen recording, microphone use, and access to protected folders. A Tauri capability cannot grant those permissions. [CapturePermission.swift](../src-tauri/native/CapturePermission.swift) implements screen permission handling, while other native paths handle microphone requests and links to System Settings.

The app's content security policy and initially empty asset scope are configured in `tauri.conf.json`. Image access is granted selectively at runtime. Keep those restrictions and backend validation in mind when adding desktop features.

## Run it and find the right code

The project requires macOS 15+, Node 22.12+ (24 recommended), Rust, and Apple command-line tools with the macOS 15+ SDK.

```sh
npm ci
npm run desktop:dev
```

`desktop:dev` runs Tauri with the Vite frontend for iteration. For testing macOS recording permission identity, use the app bundle launcher:

```sh
npm run desktop:build
```

Close Saturn before rebuilding. `npm run desktop` opens the existing built app and builds only when it is missing, so use `desktop:build` to pick up code changes. The launcher in [scripts/desktop.mjs](../scripts/desktop.mjs) builds **Saturn Local** using [tauri.local.conf.json](../src-tauri/tauri.local.conf.json), with the separate `com.saturn.recorder.local` bundle ID. It leaves the installed production app and its privacy permissions untouched. If a rebuild changes the local signing requirement, the launcher resets only the local app’s stale Screen Recording decision; after approval, subsequent launches of the same build preserve consent. A raw development process launched from an editor terminal can inherit the editor's privacy identity, which makes it a poor substitute for testing the actual app bundle.

`npm run dev` opens the frontend development server alone. It is useful for layout work, but the desktop API wrapper rejects native operations in a regular browser. It does not simulate a successful recording or export.

Builds prepare the bundled FFmpeg tools through `setup:encoder`, build the frontend, compile Rust and both Swift forms, and package the desktop app. Initial encoder setup needs network access; recording and exports then run offline. See the [README](../README.md) for full setup, signing caveats, and release validation requirements. Capture and export currently target macOS; choosing Tauri does not provide Windows/Linux implementations of the Swift media layer.

| If you want to change…                         | Start here                                                                                                                                                                                           |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Capture controls and permission UI             | [capture-panel.tsx](../src/features/capture/capture-panel.tsx), [source-picker.tsx](../src/features/capture/source-picker.tsx)                                                                       |
| Export controls and appearance preview         | [export-panel.tsx](../src/features/export/export-panel.tsx), [recording-preview.tsx](../src/features/export/recording-preview.tsx)                                                                   |
| A frontend/backend message                     | [tauri.ts](../src/lib/tauri.ts), [contracts.ts](../src/lib/contracts.ts), [lib.rs](../src-tauri/src/lib.rs)                                                                                          |
| Recording lifecycle                            | [recording/mod.rs](../src-tauri/src/recording/mod.rs), [RecorderNative.swift](../src-tauri/native/RecorderNative.swift)                                                                              |
| Project fields or archive compatibility        | [manifest.rs](../src-tauri/src/project/manifest.rs), [archive.rs](../src-tauri/src/project/archive.rs)                                                                                               |
| Rendered video or encoding                     | [ExportCompositor.swift](../src-tauri/native/ExportCompositor.swift), [FFmpegEncoder.swift](../src-tauri/native/FFmpegEncoder.swift), [ExportEncoder.swift](../src-tauri/native/ExportEncoder.swift) |
| Packaging, native compilation, or app identity | [tauri.conf.json](../src-tauri/tauri.conf.json), [build.rs](../src-tauri/build.rs), [desktop.mjs](../scripts/desktop.mjs)                                                                            |

For a new command, add the TypeScript wrapper, implement the Rust handler, register it in `generate_handler!`, and publish a snapshot if it changes session state. Only add a Swift operation when the feature needs native functionality beyond what Rust already provides.

Use `npm run check` for frontend build/tests and launcher checks, and `npm run test:rust` for Rust tests. Native verification scripts cover shortcuts, composition, and export with fixtures; see the README for their commands. Changes to capture, permissions, or settings appearance also need interactive verification in the desktop app.
