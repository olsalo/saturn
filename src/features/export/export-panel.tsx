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
import { usePreferences } from "@/lib/preferences";
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
  const [exportOptions, setExportOptions] = usePreferences<{ website: boolean }>(
    "saturn.export-options",
    { website: true },
  );
  const websiteExport = exportOptions.website;
  const setWebsiteExport = (website: boolean) => setExportOptions({ website });
  const exportFormat = websiteExport ? "web" : "h264";
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
      className={`export-panel animate-in fade-in ${done ? "export-complete" : ""} ${exporting ? "exporting" : ""} ${!exporting && (working || state.saving) ? "settings-saving" : ""} ${p.captureKind === "display" ? "screen-capture" : ""}`}
    >
      <div className="export-heading">
        <div>
          <span className="eyebrow">
            {done ? "EXPORT COMPLETE" : "EXPORT SETTINGS"}
          </span>
          <h1>
            {done
              ? state.outputIsWebsite
                ? "Website videos saved"
                : "Video saved"
              : "Export recording"}
          </h1>
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
            {state.outputIsWebsite
              ? "Your folder contains AV1 video, a VP9 fallback, a poster and an embed snippet. Upload them together to your website."
              : "Your MP4 is saved next to your project, unless you chose another location."}
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
            <div className={exporting ? "option-label-disabled" : undefined}>
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
          <div className="website-export-setting">
            <label htmlFor="website-export" className={exporting ? "option-label-disabled" : undefined}>
              <strong>Web export</strong>
              <span id="website-export-description">
                AV1 and VP9 videos
              </span>
            </label>
            <Switch
              id="website-export"
              aria-describedby="website-export-description"
              checked={websiteExport}
              disabled={disabled}
              onCheckedChange={setWebsiteExport}
            />
          </div>
          <div className="export-audio-settings">
            <strong>Audio</strong>
            <div className="audio-options">
              <label data-unavailable={!p.separateAudio || !p.hasSystemAudio || undefined}>
                <span>System sound</span>
                <Switch
                  aria-label="Include system sound in export"
                  data-available={p.separateAudio && p.hasSystemAudio ? "true" : undefined}
                  checked={p.separateAudio && p.hasSystemAudio && selectedAudio.system}
                  disabled={disabled || !p.separateAudio || !p.hasSystemAudio}
                  onCheckedChange={(enabled) =>
                    updateAudio(enabled, selectedAudio.microphone)
                  }
                />
              </label>
              <label data-unavailable={!p.separateAudio || !p.hasMicrophoneAudio || undefined}>
                <span>Microphone audio</span>
                <Switch
                  aria-label="Include microphone audio in export"
                  data-available={p.separateAudio && p.hasMicrophoneAudio ? "true" : undefined}
                  checked={p.separateAudio && p.hasMicrophoneAudio && selectedAudio.microphone}
                  disabled={disabled || !p.separateAudio || !p.hasMicrophoneAudio}
                  onCheckedChange={(enabled) =>
                    updateAudio(selectedAudio.system, enabled)
                  }
                />
              </label>
            </div>
          </div>
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
                  onClick={() => run(() => api.export(false, exportFormat))}
                  disabled={disabled}
                >
                  <span className="export-button-label">
                    <Icon name="download" />
                    {websiteExport ? "Export web" : "Export MP4"}
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
