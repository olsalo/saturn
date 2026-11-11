# Minimal Screen Recorder: Architecture & Project Structure

**Status:** Proposed architecture, ready for a technical spike  
**Date:** 2026-11-07  
**Platforms:** macOS first, Windows later  
**Working name / extension:** `Recorder` / `.recproj` (placeholders)  
**UI:** Tauri 2 + React + TypeScript + Tailwind CSS  
**Backend:** Rust, native OS recording and export APIs

> **Product thesis:** A recording is a file, not an entry in an app database. The app is one floating panel that changes purpose, from capture to export. It should be effortless to record, style, export, move, and reopen a recording.

---

## 1. Product scope

### The core experience

1. **Ready:** A small floating panel shows the selected window, a window picker, and **Record**.
2. **Recording:** The same panel shows elapsed time and **Stop**. The panel does not appear in the saved recording.
3. **Preparing:** Stopping finalizes the source recording, cursor events, and a recoverable project file. Show brief processing feedback only as needed.
4. **Export:** The same panel morphs into a preview, a background selector, and **Export video**. Cursor motion and clicks are stylized automatically.
5. **Exporting:** Real progress replaces the export action; the panel stays responsive. The export creates an MP4 next to the editable project by default.
6. **Done:** Offer **Show in Finder**, **Copy file**, **Export again**, and **New recording**.
7. **Reopen:** Double-click a `.recproj` in Finder to open the same panel directly in **Export** mode, with the chosen background and rendering settings restored.

**No** conventional app dashboard, project list, timeline, cloud backend, sign-in, embedded browser editor, or custom project database in v1.

### Product requirements

- The **editable project is one ordinary, portable file** on both macOS and Windows.
- A project is self-contained. Source video, cursor metadata, selected background image, settings, and thumbnails live **inside** the file.
- Move, rename, back up, AirDrop, or share the project without breaking media references.
- Preserve **original source footage**. All visual treatment is non-destructive.
- Opening a project must not depend on a remembered absolute file path or a global database.
- Exported MP4 is a disposable derivative, not the editable source.
- File ownership and destination are obvious; a **Show in Finder** action is always accessible.
- When recording or exporting fails, salvage everything already captured.
- Defaults must produce a good result without requiring settings changes.

### Explicitly out of scope for v1

Timeline editor, arbitrary trims, manual zoom keyframes, annotations, captions, webcam layout, multitrack audio editing, cloud sharing, team workspaces, collaboration, and Linux. Keep the file schema expandable for these later.

---

## 2. Technical decisions (ADRs)

| ID | Decision | Why | Caveat |
|---|---|---|---|
| ADR-001 | **Tauri 2** application shell | Small native desktop package, React UX, Rust backend | WKWebView on macOS; avoid a browser-only rendering pipeline |
| ADR-002 | **macOS 15+ proposed minimum** | ScreenCaptureKit direct-to-file recording output is available, reducing initial encoding work | Confirm market compatibility before locking this in; macOS 14 requires an alternative writer |
| ADR-003 | **Rust service layer** with platform adapters | Single Tauri boundary now, Windows backend later | Apple APIs may require a narrow Swift/Objective-C bridge |
| ADR-004 | **ZIP64 `.recproj` file**, with media entries stored uncompressed | A real, portable, inspectable single file across platforms | Repacking a large archive for each metadata edit is expensive; use an editable working copy and batch commits |
| ADR-005 | **Non-destructive rendering spec** | Styling does not touch original footage; future timeline/editor can reuse it | Export pipeline must implement the spec faithfully |
| ADR-006 | **Capture cursor metadata separately** | Enables smooth cursor and click effects, changes after recording | Click detection and global input permissions require validation |
| ADR-007 | **Platform-specific capture + render implementations** | Use efficient native APIs without forcing one lowest-common-denominator engine | Separate macOS and Windows implementations, shared project schema |
| ADR-008 | **File system is source of truth** | No opaque app library, no broken database references | Only preferences and crash recovery live in app support folders |

**Potential alternative to ADR-004:** macOS Finder document packages are directories displayed as a single item. They avoid the archive rewrite problem, but are not a true single file when moved to other platforms. Keep ZIP64 for the stated portability requirement. Another alternative is a custom container or SQLite BLOB-backed file; reconsider only if large-project save benchmarks justify the complexity.

---

## 3. High-level architecture

```text
┌───────────────────────────────────────────────────────────┐
│                     React + TypeScript                    │
│  FloatingPanel / WindowPicker / ExportPanel / Progress    │
│  UI state machine; no raw video-frame processing          │
└──────────────────────────────┬────────────────────────────┘
                               │ Tauri invoke + typed events
┌──────────────────────────────▼────────────────────────────┐
│                       Tauri / Rust                        │
│  Commands + lifecycle + session controller                │
│  Project file service + recovery + render orchestration   │
└───────────────┬─────────────────────────┬─────────────────┘
                │                         │
┌───────────────▼────────────────┐ ┌──────▼──────────────────┐
│         Capture backend        │ │     Export backend      │
│  macOS: ScreenCaptureKit       │ │  render plan/compositor │
│  Windows: WGC (later)          │ │  native encoder         │
│  synchronized video/audio      │ │  progress + cancellation│
│  separate cursor events        │ │                         │
└───────────────┬────────────────┘ └───────┬─────────────────┘
                │                          │
                └─────────┬────────────────┘
                          ▼
               ┌────────────────────┐
               │   Project service  │
               │ session workdir    │
               │ ZIP64 .recproj     │
               │ atomic commits     │
               └────────────────────┘
```

**Rule:** Never send uncompressed video frames over Tauri IPC. Send only commands, project metadata, progress, source thumbnails, and preview resource locations. Native code owns capture, media, export, and filesystem commits.

### Responsibilities

| Layer | Owns | Does not own |
|---|---|---|
| React | Floating UI, transitions, picker, background choice, progress, keyboard interactions | ScreenCaptureKit, audio, encoding, arbitrary filesystem access |
| Tauri commands | Validation, session lifecycle, cancellation, frontend event delivery | Platform-specific capture details |
| `capture` | Source enumeration, filter selection, synchronized raw media creation | Project format, UI |
| `cursor` | Timestamped position/click samples, screen-to-capture transforms | Burned-in pointer rendering |
| `project` | Manifest validation, archive I/O, working copy, recovery, safe save | Capture hardware |
| `export` | Render plan, compositing, encoding, export destination/progress | UI animations |
| `platform` | Native file-open events, Finder/Explorer reveal, OS permissions | Business logic |

---

## 4. Frontend interaction model

Use **one borderless, compact Tauri window** as the primary UI. Keep one content root and switch panels; avoid destroying and recreating the native window when changing modes. This allows a visual morph between the capture bar and export bar.

```text
idle → selecting → ready → starting → recording → stopping
                                  │                 │
                                  └──────── error ←─┤
                                                    ▼
                                               finalizing
                                                    │
                                                    ▼
                        open project ──────────→ export_ready
                                                    │
                                                    ▼
                                                exporting
                                               ↙    │    ↘
                                            failed  done  cancelled
                                               └────┴──────┘
                                                    │
                                               export_ready
```

- Treat transitions as **explicit states**, not a collection of unrelated booleans.
- Disable **Record** during `starting`, **Stop** during `stopping`, and **Export** while another export is active.
- The Rust backend is authoritative for capture and export state; the UI can optimistically animate, but must not claim export completion until the backend confirms the file exists.
- If a `.recproj` is opened while recording, either queue the open or ask for an explicit stop. Never discard the active session.
- A small menu-bar/tray entry may expose **New recording**, **Open project**, **Settings**, and **Quit**. The floating panel remains the primary experience.
- The panel should be draggable, movable between monitors, keyboard-accessible, and excluded from captures when supported.

### v1 export controls

- Background: **none**, a few built-in gradients/colors, or **choose image**.
- Fixed tasteful defaults for padding, corner radius, shadow, and cursor motion.
- One primary button: **Export MP4**.
- Optional overflow menu: show project, save as, output location, new recording, and preferences.
- Preview is a lightweight still or lower-resolution proxy; exact full-quality rendering happens off the UI thread.

### Windows and overlays

- Make sure an always-on-top bar is **not inadvertently included** in full-display captures.
- Keep capture/selection overlays separate from source content. Prefer excluding the app process from display capture where possible, then test the exact filter/window behavior.
- macOS screen recording indicators are controlled by the operating system; **do not try to suppress system privacy UI**.

---

## 5. Capture pipeline (macOS first)

### Proposed implementation

**macOS:** `screencapturekit-rs` over ScreenCaptureKit, with a narrow Swift/native bridge only when a needed API is unavailable or unreliable. Prefer macOS 15+ for direct-to-file recording output. Capture system audio through ScreenCaptureKit when enabled; microphone support must be permission-gated and tested independently.

```text
Window Picker
    ↓ selected display/window ID
ScreenCaptureKit SCContentFilter
    ↓ synchronized video and audio samples
Recording output / writer ───────────────────→ workdir/media/source.mov|mp4
    │
    └──── timestamp reference ─────→ Cursor sampler
                                         ↓
                              workdir/cursor/events.jsonl
```

### Watermark-free window capture: a gating experiment

Do **not** claim the filter is watermark-free until it has been tested. Run a short spike comparing:

1. `SCContentFilter` for a **single desktop-independent window** (baseline).
2. **Display + including selected window** (potential isolated-window path).
3. **Full display + crop to target window** (Recordly-style fallback).

Check (a) saved-video watermark, (b) occluding/overlapping windows, (c) moving/resizing the target, (d) multiple monitors and display scaling, (e) minimized windows, (f) focus changes, (g) system and app UI overlays, and (h) audio synchronization.

**Fallback trade-off:** Display + crop can capture other content that overlaps the target window. This is a privacy and correctness issue, not just a visual issue. If isolation is impossible, disclose the behavior and avoid promising true isolated-window recording.

### Pointer capture

- Set `showsCursor = false` for capture when supported, then render the pointer during export.
- Sample global pointer position and (if permitted) click events, and associate samples with the **same monotonic timebase** as the recorded media.
- Store positions in **capture-content coordinates**; also store enough transform metadata to reconstruct mapping when the target window moves, changes size, or the display scale changes.
- Interpolate between valid samples. Handle pointer leaving the capture bounds, display changes, and dropped frames gracefully.
- Start with motion smoothing; click rings are conditional on reliable input-event capture and required permissions.
- Validate macOS Input Monitoring / Accessibility implications before making click effects mandatory. Do not automatically request broad permissions if simple cursor movement can work without them.

**Important:** Captured video timestamps are authoritative. Do not assume wall-clock timestamps are perfectly aligned with media sample presentation timestamps (PTS).

---

## 6. Portable project format (`.recproj`)

### On-disk form

One ZIP64 archive with `STORE`/no compression for video and already-compressed images. The extension is owned by this app. All references inside the archive are **relative**.

```text
Product Demo.recproj  (ZIP64 container)
├── manifest.json
├── media/
│   └── source.mov               # or source.mp4, specified in manifest
├── cursor/
│   └── events.jsonl
├── assets/
│   └── background.jpg           # included only if custom image chosen
└── preview/
    └── thumbnail.jpg
```

**Schema example, illustrative rather than final:**

```json
{
  "formatVersion": 1,
  "projectId": "f6c5118e-09ef-46cf-b397-92ffdac5a917",
  "createdAt": "2026-11-07T12:00:00Z",
  "media": {
    "path": "media/source.mov",
    "durationUs": 42123000,
    "width": 1920,
    "height": 1080,
    "frameRate": { "numerator": 30, "denominator": 1 },
    "hasSystemAudio": true,
    "hasMicrophoneAudio": false
  },
  "cursor": {
    "path": "cursor/events.jsonl",
    "timeUnit": "microseconds",
    "coordinateSpace": "capturedVideoPixels"
  },
  "appearance": {
    "background": {
      "type": "embeddedImage",
      "path": "assets/background.jpg"
    },
    "paddingPx": 64,
    "cornerRadiusPx": 16,
    "shadow": true,
    "cursorSmoothing": true,
    "clickAnimation": true
  },
  "export": {
    "container": "mp4",
    "codec": "h264",
    "width": 1920,
    "height": 1080,
    "frameRate": 30
  }
}
```

**Pointer metadata example:**

```jsonl
{"tUs":0,"type":"move","x":123.5,"y":241.3,"visible":true}
{"tUs":16000,"type":"move","x":127.1,"y":245.4,"visible":true}
{"tUs":33000,"type":"click","button":"left","phase":"down","x":127.1,"y":245.4}
```

Consider a binary cursor event format only after profiling. JSONL is debuggable and sufficient for v1. Validate coordinate conventions, timestamps, project versions, and numeric bounds before accepting files.

### Open / save lifecycle

```text
Record → private recoverable workdir (partial media + cursor events)
Stop   → finalize media; write initial .recproj to chosen Recordings folder
Open   → validate archive; stage required media/assets in a cache workdir
Edit   → change appearance in memory; checkpoint changes in recovery workdir
Save   → build replacement .recproj; fsync; atomic replace on same volume
Export → render to output.tmp; finalize and atomically rename to .mp4
```

- **Never edit the source media in place.** The source remains the same across repeated exports.
- **Do not rebuild a gigabyte archive on every slider tick.** Debounce UI changes and commit only after an intentional change group, on panel close, or when needed to guarantee a portable saved project. Show a discreet **Saving…** state until commit completes.
- Preserve crash-recoverable workdir edits until the portable archive is updated successfully.
- On a normal macOS filesystem, prefer a temporary file **in the same destination directory** for the final atomic rename. Handle cross-volume Save As separately.
- Opening an archive might require staging/extracting the source media to a cache path for native video decoders; that copy has a disk/time cost. Benchmark it on 1 GB, 5 GB, and 20 GB projects.
- During a recording, the workdir is not the user's final project. On crash/relaunch, offer **Recover recording** rather than silently deleting it.
- Reject ZIP path traversal, absolute paths, symlinks, archive bombs, unexpected file types, bad checksums, duplicate ambiguous entries, and unsupported future schema versions.
- Never trust internal paths from an opened project as arbitrary paths on the user's machine.

### File location and UX rules

- On first recording, ask for a **default Recordings folder** (or a simple initial Save destination); remember the choice as an app preference.
- After Stop, create `Recording YYYY-MM-DD HH-MM.recproj` automatically, with collision-safe names.
- Default MP4 export path: **next to the project** with the same base name.
- **Show in Finder**, **Copy project path**, **Save As…**, and **Open…** are always available through an overflow menu.
- Move or rename a finished project at will. On reopen, use its **current path**. Do not store canonical absolute file paths inside the project archive.
- Auto-detect if a project moved or was deleted while open and handle Save As appropriately.
- The application support directory may hold preferences, telemetry-free logs, and recoverable session workdirs, **not** a permanent media library.

### File association

Register `.recproj` as a custom type in Tauri's `bundle.fileAssociations`, including an `exportedType` identifier for macOS. Handle both **cold-start** and **already-running** file-open events. On macOS, Tauri delivers `RunEvent::Opened`; bridge this into managed Rust state + a frontend event. For Windows later, handle command-line file arguments and the single-instance path forwarding behavior. Validate against the installed Tauri version rather than assuming identical event delivery on both platforms.

**No app database required.** `projectId` is an internal stable identifier for temporary work and debugging, not a lookup key needed to open the document.

---

## 7. Export pipeline

### Render contract

The frontend changes a small **render specification**. The exporter receives only the project/workspace, destination, and final validated render plan.

```text
source video ───┐
                │
background ─────┼──→ compositing/render pipeline ─→ encoder ─→ output.tmp
                │                                           │
cursor events ──┘                                      validated MP4
                                                            │
                                                      atomic rename
```

**Rendering order:** background → captured window video with rounded-mask/padding/shadow → interpolated cursor → click animation. Audio is preserved/mixed from the source according to the project settings. Video rendering and audio must retain A/V sync, including variable-frame-rate sources.

**v1 output:** MP4/H.264, SDR, fixed output FPS preset (e.g. 30), with sensible quality and resolution defaults. Do not promise 4K60 until performance is measured.

### Implementation recommendation

- Define a Rust `Exporter` interface and immutable `RenderPlan` early.
- On macOS, evaluate a **Metal/Core Image + AVFoundation/VideoToolbox** path for frame compositing and hardware encoding. A small Swift helper is acceptable if the Rust bindings are incomplete or less maintainable.
- For a quick MVP spike, a bundled **FFmpeg** renderer is a reasonable alternative; explicitly evaluate binary size, hardware encoding, code-signing/notarization, build distribution, and LGPL/GPL licensing of the chosen build.
- On Windows later, implement the same `RenderPlan` using Media Foundation / Direct3D, or select a genuinely cross-platform compositor if performance benchmarks justify it.
- Keep export work off the UI thread. Report **actual encoded progress** (processed frames or media duration), not simulated progress.
- Support cancellation; remove or retain partial output safely. Never replace a prior successful export with an incomplete file.

**Preview:** Render one still or a low-resolution, short-lived preview from the same `RenderPlan`. A CSS approximation is acceptable for UI responsiveness, but must not promise pixel-perfect parity with export.

---

## 8. Tauri contract (TypeScript sketch)

This is an API design sketch, **not a drop-in compiled implementation**. Keep the binding typed and small.

```ts
export type CaptureSource =
  | { kind: 'display'; id: string; label: string }
  | { kind: 'window'; id: string; label: string; application: string }

export type RecordingOptions = {
  source: CaptureSource
  fps: 30 | 60
  systemAudio: boolean
  microphone: boolean
}

export type RecorderMode =
  | 'idle'
  | 'selecting'
  | 'ready'
  | 'starting'
  | 'recording'
  | 'stopping'
  | 'finalizing'
  | 'export_ready'
  | 'exporting'
  | 'done'
  | 'error'

export type ExportOptions = {
  projectPath: string
  destinationPath: string
}

export type ExportProgress = {
  jobId: string
  fraction: number
  stage: 'preparing' | 'rendering' | 'finalizing'
}

export type ProjectSummary = {
  path: string
  displayName: string
  durationUs: number
  thumbnailUrl?: string
}
```

Suggested Tauri commands:

```text
list_capture_sources()
check_capture_permissions()
start_recording(options)
stop_recording() -> ProjectSummary
cancel_recording()
open_project(path) -> ProjectSummary
update_project_appearance(patch)
save_project()
save_project_as(path)
start_export(options) -> jobId
cancel_export(jobId)
reveal_in_file_manager(path)
get_startup_opened_documents()
```

Suggested events:

```text
recorder://state-changed
recorder://elapsed
project://save-state
export://progress
export://completed
export://failed
app://open-project
```

**Security:** Validate paths on the Rust side. Give the frontend narrow project/export commands rather than broad unrestricted filesystem and shell permissions. Be especially careful about passing untrusted ZIP content to native media decoders.

---

## 9. Proposed repository and project structure

Start as **one Tauri repository**. Do not introduce a Cargo workspace, shared npm packages, services, or a monorepo until a second consumer actually exists.

```text
minimal-recorder/
├── README.md
├── docs/
│   ├── ARCHITECTURE.md            # this document
│   ├── PROJECT_FORMAT.md          # versioned .recproj format once stable
│   └── DECISIONS.md               # ADR updates and trade-offs
├── package.json
├── pnpm-lock.yaml
├── index.html
├── vite.config.ts
├── tsconfig.json
├── src/
│   ├── main.tsx
│   ├── app/
│   │   ├── App.tsx                 # one floating-panel application root
│   │   ├── recorder-machine.ts    # explicit UI state transitions
│   │   └── use-app-events.ts      # backend → frontend event adapter
│   ├── features/
│   │   ├── capture/
│   │   │   ├── CapturePanel.tsx
│   │   │   ├── SourcePicker.tsx
│   │   │   └── RecordingControls.tsx
│   │   ├── export/
│   │   │   ├── ExportPanel.tsx
│   │   │   ├── BackgroundPicker.tsx
│   │   │   ├── RecordingPreview.tsx
│   │   │   └── ExportProgress.tsx
│   │   └── project/
│   │       ├── ProjectMenu.tsx
│   │       └── use-project.ts
│   ├── lib/
│   │   ├── tauri.ts                # typed invoke wrappers
│   │   ├── contracts.ts            # TypeScript API and project types
│   │   └── format.ts
│   ├── components/
│   │   ├── Button.tsx
│   │   └── FloatingPanel.tsx
│   └── styles/
│       └── globals.css
├── src-tauri/
│   ├── Cargo.toml
│   ├── Cargo.lock
│   ├── build.rs
│   ├── tauri.conf.json
│   ├── capabilities/
│   │   └── default.json
│   ├── icons/
│   ├── macos/
│   │   └── Info.plist             # merged if required for usage strings
│   └── src/
│       ├── main.rs
│       ├── lib.rs                  # Tauri setup and plugins
│       ├── commands/
│       │   ├── mod.rs
│       │   ├── recording.rs
│       │   ├── projects.rs
│       │   └── export.rs
│       ├── app/
│       │   ├── mod.rs
│       │   ├── state.rs            # active session and job handles
│       │   └── events.rs           # typed frontend notifications
│       ├── recording/
│       │   ├── mod.rs
│       │   ├── engine.rs           # backend trait and session coordinator
│       │   ├── macos.rs            # ScreenCaptureKit implementation
│       │   └── windows.rs          # cfg-gated future implementation
│       ├── cursor/
│       │   ├── mod.rs
│       │   ├── events.rs           # timestamps and transforms
│       │   └── macos.rs            # pointer sampling implementation
│       ├── project/
│       │   ├── mod.rs
│       │   ├── manifest.rs         # schema/validation/migrations
│       │   ├── archive.rs          # ZIP64 file reader/writer
│       │   ├── workspace.rs        # staging, caching, cleanup
│       │   └── recovery.rs         # crash-safe session recovery
│       ├── export/
│       │   ├── mod.rs
│       │   ├── plan.rs             # platform-neutral scene description
│       │   ├── service.rs          # export lifecycle and cancellation
│       │   ├── macos.rs            # native compositor/encoder
│       │   └── windows.rs          # future backend
│       └── platform/
│           ├── mod.rs
│           ├── documents.rs        # Finder document-open handling
│           ├── permissions.rs
│           └── reveal.rs           # Finder/Explorer reveal
├── tests/
│   ├── fixtures/
│   │   ├── tiny-valid.recproj
│   │   └── invalid-projects/
│   └── e2e/
│       └── reopen-project.spec.ts
└── scripts/
    └── verify-package.sh
```

### Module boundaries

- `commands/*` are thin adapters; they should not contain capture logic.
- `recording/engine.rs` defines the abstract operations `list_sources`, `start`, `stop`, and `cancel`. The macOS adapter owns ScreenCaptureKit types. The Windows adapter gets the same contract later.
- `project/*` is platform-neutral wherever possible. It owns the single-file format, not the UI or capture engine.
- `export/plan.rs` describes **what to render**, while platform `export/*.rs` modules decide **how**.
- `cursor/events.rs` defines a versioned event format shared by capture and export.
- React uses `src/lib/tauri.ts` only. Avoid scattering stringly typed `invoke(...)` calls across components.
- Platform-specific files use conditional compilation; avoid introducing a large plugin system in v1.

### Useful dependencies to evaluate, not blindly install

| Area | Candidate | Validate |
|---|---|---|
| Shell | `tauri` 2 | File association and tray behavior for installed builds |
| UI | React, TypeScript, Tailwind | Compact window sizing and animation in WKWebView |
| Capture | `screencapturekit` Rust crate | API coverage, thread safety, source filter behavior, direct-to-file support |
| Serialization | `serde`, `serde_json` | Schema compatibility and migration |
| Project container | ZIP64-capable Rust ZIP library | Store mode, streaming I/O, archive validation, large file performance |
| Async/jobs | Tokio or another Tauri-compatible runtime | Cancellation and deterministic cleanup |
| UUIDs | `uuid` | Workdir identifiers only, not file lookup |
| Export | Native framework bridge or bundled FFmpeg | macOS hardware encoding, Windows viability, licensing |
| Dialog | Tauri dialog plugin | Recordings folder, Save As and image selection |
| OS integration | Tauri opener / single instance / global shortcut plugins | macOS cold start and future Windows behavior |

Keep dependencies minimal. For example, don't add a heavy global state manager in React until native session events and local state clearly need one.

---

## 10. Windows migration plan

From day one, keep these cross-platform:

- `manifest.json` schema, `cursor` event format, color/coordinate conventions, and render plan
- Tauri commands and frontend events
- Project archive and recovery logic
- UI state machine and styling controls
- MP4 output contract and export progress semantics

Platform-specific adapters:

| Concern | macOS first | Windows later |
|---|---|---|
| Capture | ScreenCaptureKit | Windows Graphics Capture |
| System audio | ScreenCaptureKit audio | Windows audio loopback/capture path to be evaluated |
| Cursor events | macOS pointer APIs | Windows Raw Input / appropriate OS event APIs |
| Encoding | AVFoundation/VideoToolbox or sidecar | Media Foundation or equivalent |
| Project open | Launch Services, Tauri `Opened` | File association + startup argv/single-instance forwarding |
| Reveal | Finder | Explorer |

**Important:** Windows capture is a new platform adapter, not a rewrite of the project format or UI.

---

## 11. Reliability, permissions, and testing

### Permissions and security

- Add proper macOS usage strings for screen capture and microphone where applicable, and test the complete first-run permission flow in a **signed** app.
- Handle denied or revoked permissions with an actionable UI, rather than repeatedly retrying capture.
- Verify that background macOS input tracking requires only permissions that are justified by the corresponding feature.
- Do not suppress macOS privacy indicators or misrepresent what is being recorded.
- Sign and notarize the app; any bundled helpers or FFmpeg sidecar must also be handled as part of distribution.
- Avoid remote assets or network calls in the critical recording/export path. v1 should work offline.

### Test matrix

| Test | Pass condition |
|---|---|
| First launch | User can understand and grant necessary permissions |
| Select window | Selected window identifiable; labels and thumbnails sensible |
| Watermark spike | Saved output behavior verified for all three capture filters |
| Move/resize window | Video and cursor stay aligned or predictable limitations are shown |
| 1 / 5 / 20 GB project | Reopen, preview, change background, save and export without corruption |
| Interrupted recording | Recovery available after forced quit / power loss where technically possible |
| Low disk | Warn before failure; don't replace existing valid project/export |
| Export cancellation | No broken final output or stuck exporting state |
| Double-click project | Opens **directly to export mode**, whether app is cold or running |
| Rename/move project | Still reopens; embedded image resolves correctly |
| Share project | A second Mac can open it with no original-path dependency |
| No mouse permission | Record still works; cursor feature degrades gracefully |
| Multiple displays | Correct source, scale, and cursor transforms |
| Screen lock or target closes | Predictable stop/error handling with data recovery |

### Definition of done for v1

A tester can select a window, record 20 seconds, stop, pick a background image, export a stylized MP4 with a smooth cursor, move the `.recproj` to another folder or Mac, double-click it, change the background, and export again. The original footage remains intact and no hidden application project library is required.

---

## 12. Build sequence

**Spike 0: prove the risky parts before UI polish (must pass)**

- Capture 5–10 seconds using the three ScreenCaptureKit filter options and inspect saved outputs for watermark/occlusion.
- Capture synchronized cursor positions (and investigate clicks/permissions).
- Produce one MP4 export with background, corner mask, and a moving cursor overlay.
- Package a short recording as `.recproj`; reopen it from a **different** directory.
- Test a 5 GB ZIP64 archive save/reopen path to understand latency and disk requirements.

**Milestone 1: functional recorder**

- Basic floating panel, window picker, Record / Stop.
- Permission flow, reliable recording, saving user-visible `.recproj`.
- Finder file association, cold-start and running-app project opening.

**Milestone 2: compelling export**

- Background image/gradient picker, fast preview, smooth cursor rendering.
- Native export progress, cancellation, MP4 writing, reveal file.
- Project metadata commits and Save As.

**Milestone 3: durable v1 release**

- Crash recovery, disk/full handling, project-version validation, CI smoke tests.
- Real-world source filter matrix and privacy warning where needed.
- Signed/notarized builds, docs, installer, file associations.

**Later:** Trimming, manual zooms, timeline, presets, richer click effects, Windows backend.

---

## 13. Open questions to resolve in the spike

1. **Minimum macOS version:** Recommend 15+ initially, but decide after actual target-user compatibility data.
2. **Watermark-free isolation:** Does a display filter including only the target window avoid the artifact? Which overlap behavior does it actually provide?
3. **Export implementation:** Is an all-Rust-native path maintainable, or is a small Swift bridge / FFmpeg helper more efficient?
4. **Archive save cost:** Is ZIP64 repacking acceptable at 5–20 GB? If not, consider a custom append-friendly container or alternate internal format while keeping a **single exported document file**.
5. **Cursor permissions:** Can high-quality movement be captured without broad input permissions? Are clicks optional or essential?
6. **Preview fidelity:** Is a fast static/short proxy sufficient in the floating panel?
7. **Audio policy:** Is system audio on by default? Is the microphone a v1 toggle or post-v1 feature?

---

## 14. Reference documentation

These links are background sources for the proposed architecture; exact APIs and crate versions must be checked at implementation time.

- Tauri 2 project structure: https://v2.tauri.app/start/project-structure/
- Tauri 2 file association schema: https://v2.tauri.app/reference/config/
- Tauri file-open event patterns: https://v2.tauri.app/learn/mobile-file-associations/
- Tauri dialog plugin: https://v2.tauri.app/plugin/dialog/
- Tauri window customization: https://v2.tauri.app/learn/window-customization/
- Tauri bundled sidecars: https://v2.tauri.app/develop/sidecar/
- screencapturekit-rs repository / examples: https://github.com/doom-fish/screencapturekit-rs
- Apple ScreenCaptureKit capture guide: https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
- Apple SCStreamConfiguration (source rect, cursor, audio): https://developer.apple.com/documentation/ScreenCaptureKit/SCStreamConfiguration
- Apple document packages (alternative considered): https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/DocumentPackages/DocumentPackages.html

---

## 15. Summary

**Build a tiny document-based application with three long-lived responsibilities:**

1. **Capture:** A native recording session produces untouched video/audio and timestamped pointer events.
2. **Project:** A portable, self-contained `.recproj` file contains the source and non-destructive render settings; saving/reopening never depends on a project database.
3. **Export:** A renderer turns that project into a styled MP4 while the same floating panel shows progress.

The most important early validation is **watermark-free window isolation plus performance of the single-file project format**. The UI should stay intentionally simple while the native pipeline remains replaceable as macOS APIs and later Windows support evolve.
