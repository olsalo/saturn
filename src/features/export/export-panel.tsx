import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import Icon from "@/components/ui/icons/icons";
import { Switch } from "@/components/ui/switch";
import { Button } from "@/components/ui/button";
import {
  Progress,
  ProgressTrack,
  ProgressIndicator,
  ProgressLabel,
  ProgressValue,
} from "@/components/ui/progress";
import {
  Select,
  SelectTrigger,
  SelectValue,
  SelectPopup,
  SelectItem,
} from "@/components/ui/select";
import { api } from "@/lib/tauri";
import { time, fileName } from "@/lib/format";
import type { Snapshot } from "@/lib/contracts";
import { BackgroundPicker } from "./background-picker";
import { RecordingPreview } from "./recording-preview";
export function ExportPanel({
  state,
  actionFooter,
  working,
  run,
}: {
  state: Snapshot;
  actionFooter: HTMLElement | null;
  working: boolean;
  run: (f: () => Promise<unknown>) => Promise<boolean>;
}) {
  const p = state.project!;
  const [pendingAspect, setPendingAspect] = useState<string | null>(null);
  const [pendingResolution, setPendingResolution] = useState<string | null>(
    null,
  );
  useEffect(() => {
    if (pendingAspect === p.aspectRatio) setPendingAspect(null);
  }, [pendingAspect, p.aspectRatio]);
  useEffect(() => {
    if (
      pendingResolution ===
      (p.resolution === "standard" ? "medium" : p.resolution)
    )
      setPendingResolution(null);
  }, [pendingResolution, p.resolution]);
  const [pendingAudio, setPendingAudio] = useState<{
    system: boolean;
    microphone: boolean;
  } | null>(null);
  useEffect(() => {
    if (
      pendingAudio &&
      p.includeSystemAudio === pendingAudio.system &&
      p.includeMicrophoneAudio === pendingAudio.microphone
    )
      setPendingAudio(null);
  }, [pendingAudio, p.includeSystemAudio, p.includeMicrophoneAudio]);
  const selectedAudio = pendingAudio ?? {
    system: p.includeSystemAudio,
    microphone: p.includeMicrophoneAudio,
  };
  const updateAudio = (system: boolean, microphone: boolean) => {
    setPendingAudio({ system, microphone });
    void run(() => api.exportAudio(system, microphone)).then((success) => {
      if (!success) setPendingAudio(null);
    });
  };
  const selectedAspect = pendingAspect ?? p.aspectRatio;
  const selectedResolution =
    pendingResolution ??
    (p.resolution === "standard" ? "medium" : (p.resolution ?? "high"));
  const exporting = state.mode === "exporting",
    done = state.mode === "done";
  const disabled = working || exporting || state.saving;
  const canvasLocked =
    p.captureKind === "display" || p.appearance.background.type === "none";
  const aspectLabel =
    selectedAspect === "original"
      ? p.captureKind === "display"
        ? "Screen"
        : "Window"
      : selectedAspect;
  const resolutionLabels: Record<string, string> = {
    original: "Original",
    high: "High",
    standard: "Medium",
    medium: "Medium",
    small: "Small",
  };
  return (
    <section
      className={`export-panel animate-in fade-in ${done ? "export-complete" : ""} ${!exporting && (working || state.saving) ? "settings-saving" : ""} ${p.captureKind === "display" ? "screen-capture" : ""}`}
    >
      <div className="export-heading">
        <div>
          <span className="eyebrow">
            {done ? "EXPORT COMPLETE" : "EXPORT SETTINGS"}
          </span>
          <h1>{done ? "Video saved" : "Export recording"}</h1>
        </div>
      </div>
      <RecordingPreview project={p} />
      {!done && (
        <div className="media-meta">
          <span>
            <Icon name="video" size={13} />
            {time(p.durationUs / 1e6)}
          </span>
          <span>
            {p.width} × {p.height}
            <i />
            30 fps
          </span>
        </div>
      )}
      {done ? (
        <div className="done-content">
          <p className="output-name" title={state.outputPath ?? ""}>
            {fileName(state.outputPath ?? "")}
          </p>
          <p className="done-description">
            Your MP4 is saved next to your project, unless you chose another
            location.
          </p>
          <div className="completion-actions">
            <Button
              variant="outline"
              resetHoverOnClick
              onClick={() => run(() => api.file("reveal", true))}
              disabled={working}
            >
              <Icon name="folder" />
              Show in Finder
            </Button>
            <Button
              variant="outline"
              onClick={() => run(api.edit)}
              disabled={working}
            >
              <Icon name="restart" />
              Export again
            </Button>
            <Button
              variant="outline"
              onClick={() => run(api.newRecording)}
              disabled={working}
            >
              <Icon name="plus" />
              New recording
            </Button>
          </div>
        </div>
      ) : (
        <>
          <BackgroundPicker
            value={p.appearance.background}
            backgroundPath={p.backgroundPath}
            backgroundRevision={p.backgroundRevision}
            disabled={disabled || p.captureKind === "display"}
            visuallyDisabled={exporting || p.captureKind === "display"}
            onChange={(background) =>
              run(() => api.appearance({ ...p.appearance, background }))
            }
            onImage={() => run(api.background)}
            onPreset={(preset) => run(() => api.builtinBackground(preset))}
          />
          <div className="background-row">
            <div
              className={
                exporting || canvasLocked ? "option-label-disabled" : undefined
              }
            >
              <strong>Canvas dimensions</strong>
              <p>Aspect ratio</p>
            </div>
            <Select
              value={selectedAspect}
              onValueChange={(ratio) => {
                if (!ratio) return;
                setPendingAspect(ratio);
                void run(() => api.aspectRatio(ratio)).then((success) => {
                  if (!success) setPendingAspect(null);
                });
              }}
              disabled={disabled || canvasLocked}
            >
              <SelectTrigger
                aria-label="Aspect ratio"
                data-canvas-locked={canvasLocked ? "true" : undefined}
                className="w-auto min-w-24"
              >
                <SelectValue>{aspectLabel}</SelectValue>
              </SelectTrigger>
              <SelectPopup>
                {["original", "16:10", "16:9", "1:1", "9:16"].map((ratio) => (
                  <SelectItem key={ratio} value={ratio}>
                    {ratio === "original"
                      ? p.captureKind === "display"
                        ? "Screen"
                        : "Window"
                      : ratio}
                  </SelectItem>
                ))}
              </SelectPopup>
            </Select>
          </div>
          <div className="background-row">
            <div>
              <strong>Resolution</strong>
              <p>
                {p.exportWidth} × {p.exportHeight} pixels
              </p>
            </div>
            <Select
              value={selectedResolution}
              onValueChange={(resolution) => {
                if (!resolution) return;
                setPendingResolution(resolution);
                void run(() => api.resolution(resolution)).then((success) => {
                  if (!success) setPendingResolution(null);
                });
              }}
              disabled={disabled}
            >
              <SelectTrigger
                aria-label="Resolution"
                className="w-auto min-w-24"
              >
                <SelectValue>
                  {resolutionLabels[selectedResolution] ?? "High"}
                </SelectValue>
              </SelectTrigger>
              <SelectPopup>
                {[
                  ["original", "Original"],
                  ["high", "High"],
                  ["medium", "Medium"],
                  ["small", "Small"],
                ].map(([value, label]) => (
                  <SelectItem key={value} value={value}>
                    {label}
                  </SelectItem>
                ))}
              </SelectPopup>
            </Select>
          </div>
          {p.separateAudio && (p.hasSystemAudio || p.hasMicrophoneAudio) && (
            <div className="export-audio-settings">
              <strong>Audio in exported video</strong>
              <div className="audio-options">
                {p.hasSystemAudio && (
                  <label>
                    <span>System sound</span>
                    <Switch
                      aria-label="Include system sound in export"
                      checked={selectedAudio.system}
                      disabled={disabled}
                      onCheckedChange={(enabled) =>
                        updateAudio(enabled, selectedAudio.microphone)
                      }
                    />
                  </label>
                )}
                {p.hasMicrophoneAudio && (
                  <label>
                    <span>Microphone audio</span>
                    <Switch
                      aria-label="Include microphone audio in export"
                      checked={selectedAudio.microphone}
                      disabled={disabled}
                      onCheckedChange={(enabled) =>
                        updateAudio(selectedAudio.system, enabled)
                      }
                    />
                  </label>
                )}
              </div>
            </div>
          )}
          {actionFooter &&
            createPortal(
              exporting ? (
                <div className="export-progress">
                  <Progress value={Math.round(state.progress * 100)}>
                    <div className="progress-heading">
                      <ProgressLabel>
                        {state.progress >= 0.99
                          ? "Finishing your video…"
                          : "Making your video…"}
                      </ProgressLabel>
                      <ProgressValue />
                    </div>
                    <ProgressTrack>
                      <ProgressIndicator
                        style={{ width: `${state.progress * 100}%` }}
                      />
                    </ProgressTrack>
                  </Progress>
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    aria-label="Cancel export"
                    disabled={working}
                    onClick={() =>
                      state.jobId && run(() => api.cancel(state.jobId!))
                    }
                  >
                    <Icon name="x" />
                  </Button>
                </div>
              ) : (
                <Button
                  className="w-full export-button"
                  size="lg"
                  onClick={() => run(() => api.export())}
                  disabled={disabled}
                >
                  <span className="export-button-label">
                    <Icon name="download" />
                    Export MP4
                  </span>
                  <span className="export-button-details">{`${p.exportWidth} × ${p.exportHeight}  ·  ${aspectLabel}  ·  ${p.exportFps} fps`}</span>
                </Button>
              ),
              actionFooter,
            )}
        </>
      )}
    </section>
  );
}
