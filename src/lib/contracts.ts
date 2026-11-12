export type ScreenPermissionStatus = {
  screen: boolean;
  canRequest: boolean;
  needsRestart: boolean;
};
export type CaptureSource = {
  kind: "window" | "display";
  id: string;
  label: string;
  application: string;
  primary?: boolean;
};
export type Mode =
  | "idle"
  | "selecting"
  | "ready"
  | "starting"
  | "recording"
  | "stopping"
  | "finalizing"
  | "export_ready"
  | "exporting"
  | "done";
export type Background =
  | { type: "none" }
  | { type: "gradient"; preset: "dawn" | "dusk" | "mint" | "ink" }
  | { type: "embeddedImage"; path: string; preset?: string };
export type Appearance = {
  background: Background;
  paddingPx: number;
  paddingPercent?: number;
  cornerRadiusPx: number;
  shadow: boolean;
  cursorSmoothing: boolean;
  clickAnimation: boolean;
};
export type Project = {
  path: string;
  displayName: string;
  durationUs: number;
  captureKind: "window" | "display";
  width: number;
  height: number;
  thumbnailPath: string | null;
  backgroundPath: string | null;
  backgroundRevision: number | null;
  appearance: Appearance;
  exportWidth: number;
  exportHeight: number;
  aspectRatio: string;
  resolution: string;
  exportFps: number;
  separateAudio: boolean;
  hasSystemAudio: boolean;
  hasMicrophoneAudio: boolean;
  includeSystemAudio: boolean;
  includeMicrophoneAudio: boolean;
};
export type Snapshot = {
  mode: Mode;
  project: Project | null;
  error: string | null;
  progress: number;
  outputPath: string | null;
  outputIsWebsite?: boolean;
  jobId: string | null;
  pendingCount: number;
  recoveries: string[];
  saving: boolean;
  startedAtMs?: number | null;
};
export const initialSnapshot: Snapshot = {
  mode: "idle",
  project: null,
  error: null,
  progress: 0,
  outputPath: null,
  jobId: null,
  pendingCount: 0,
  recoveries: [],
  saving: false,
};
