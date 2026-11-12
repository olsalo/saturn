import { invoke, convertFileSrc, isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import type {
  Appearance,
  CaptureSource,
  Snapshot,
  ScreenPermissionStatus,
} from "./contracts";
export const native = isTauri();
function call<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  if (!native)
    return Promise.reject(
      new Error(
        "Open the desktop app with npm run desktop to record or open a project.",
      ),
    );
  return invoke<T>(command, args);
}
export const api = {
  snapshot: () => call<Snapshot>("get_snapshot"),
  sources: () =>
    call<{
      sources: CaptureSource[];
      permissionRequired: boolean;
      needsRestart?: boolean;
    }>("list_capture_sources"),
  permissions: () =>
    call<
      ScreenPermissionStatus & {
        microphone: boolean;
        microphoneCanRequest: boolean;
      }
    >("check_capture_permissions"),
  requestPermission: () =>
    call<ScreenPermissionStatus>("request_capture_permission"),
  openScreenSettings: () => call<void>("open_screen_recording_settings"),
  requestMicrophonePermission: () =>
    call<{ microphone: boolean; microphoneCanRequest: boolean }>(
      "request_microphone_permission",
    ),
  openMicrophoneSettings: () => call<void>("open_microphone_settings"),
  openFileAccessSettings: () => call<void>("open_file_access_settings"),
  start: (source: CaptureSource, systemAudio: boolean, microphone: boolean) =>
    call<void>("start_recording", {
      options: { source, systemAudio, microphone },
    }),
  stop: () => call<void>("stop_recording"),
  open: (pending = false) => call<void>("open_project", { pending }),
  appearance: (appearance: Appearance) =>
    call<void>("update_project_appearance", { appearance }),
  aspectRatio: (ratio: string) => call<void>("update_aspect_ratio", { ratio }),
  resolution: (resolution: string) =>
    call<void>("update_resolution", { resolution }),
  exportAudio: (system: boolean, microphone: boolean) =>
    call<void>("update_export_audio", { system, microphone }),
  background: () => call<void>("choose_background"),
  builtinBackground: (preset: string) =>
    call<void>("choose_builtin_background", { preset }),
  save: () => call<void>("save_project"),
  saveAs: () => call<void>("save_project_as"),
  export: (
    chooseDestination = false,
    exportFormat: "web" | "hevc" | "h264" = "web",
  ) => call<void>("start_export", { chooseDestination, exportFormat }),
  cancel: (jobId: string) => call<void>("cancel_export", { jobId }),
  file: (action: "reveal" | "copy-file" | "copy-path", exported = false) =>
    call<void>("file_action", { action, exported }),
  edit: () => call<void>("edit_project"),
  newRecording: () => call<void>("new_recording"),
  recover: (id: string, chooseFolder = false) =>
    call<void>("recover_recording", { id, chooseFolder }),
  discardRecovery: (id: string) => call<void>("discard_recovery", { id }),
  clearError: () => call<void>("clear_error"),
  subscribeFocus: (callback: () => void) =>
    getCurrentWindow().onFocusChanged(({ payload }) => {
      if (payload) callback();
    }),
  subscribe: (callback: (snapshot: Snapshot) => void) =>
    listen<Snapshot>("recorder://snapshot", (e) => callback(e.payload)),
  subscribeRecordingShortcut: (callback: () => void) =>
    listen("recorder://toggle-recording", callback),
};
export function asset(path: string | null | undefined) {
  return path ? convertFileSrc(path) : undefined;
}
