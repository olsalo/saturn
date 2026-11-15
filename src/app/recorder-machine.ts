import { initialSnapshot, type Snapshot } from "@/lib/contracts";
export type Action =
  | { type: "backend"; snapshot: Snapshot }
  | { type: "error"; message: string }
  | { type: "clear-error" };
export function recorderReducer(state: Snapshot, action: Action): Snapshot {
  switch (action.type) {
    case "backend": {
      const next = action.snapshot;
      if (next.mode === "done" && (!next.outputPath || !next.project))
        return {
          ...state,
          error: "The export did not return a completed file.",
        };
      if (["export_ready", "exporting"].includes(next.mode) && !next.project)
        return { ...state, error: "The project could not be loaded." };
      return { ...next, progress: Math.min(1, Math.max(0, next.progress)) };
    }
    case "error":
      return { ...state, error: action.message };
    case "clear-error":
      return { ...state, error: null };
  }
}
export { initialSnapshot };
export function isBusy(mode: Snapshot["mode"]) {
  return [
    "starting",
    "recording",
    "pausing",
    "paused",
    "resuming",
    "stopping",
    "finalizing",
    "exporting",
  ].includes(mode);
}
