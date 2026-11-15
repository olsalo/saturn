import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import Icon from "@/components/ui/icons/icons";
import { Button } from "@/components/ui/button";
import { Alert, AlertDescription } from "@/components/ui/alert";
import {
  AlertDialog,
  AlertDialogPopup,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogDescription,
  AlertDialogFooter,
} from "@/components/ui/alert-dialog";
import {
  SourcePicker,
  sameCaptureSource,
  type SourcePickerHandle,
} from "./source-picker";
import captureArt from "@/assets/capture-art.svg";
import { Switch } from "@/components/ui/switch";
import { Spinner } from "@/components/ui/spinner";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { api, native } from "@/lib/tauri";
import { time } from "@/lib/format";
import type { CaptureSource, Snapshot } from "@/lib/contracts";
export type CaptureOptions = {
  audio: boolean;
  mic: boolean;
  countdownEnabled: boolean;
};
export function CapturePanel({
  state,
  actionFooter,
  source,
  onSelect,
  options,
  onOptionsChange,
  working,
  run,
}: {
  state: Snapshot;
  actionFooter: HTMLElement | null;
  source: CaptureSource | null;
  onSelect: (source: CaptureSource | null) => void;
  options: CaptureOptions;
  onOptionsChange: (options: CaptureOptions) => void;
  working: boolean;
  run: (f: () => Promise<unknown>) => Promise<boolean>;
}) {
  const { audio, mic, countdownEnabled } = options;
  const sourcePicker = useRef<SourcePickerHandle>(null);
  const [microphoneDialog, setMicrophoneDialog] = useState(false);
  const [microphoneCanRequest, setMicrophoneCanRequest] = useState(false);
  const [microphoneBusy, setMicrophoneBusy] = useState(false);
  const [microphoneError, setMicrophoneError] = useState("");
  const [elapsed, setElapsed] = useState(0);
  const [countdown, setCountdown] = useState<number | null>(null);
  const countdownTimer = useRef<ReturnType<typeof setInterval> | null>(null);
  const continueCountdown = useRef(false);
  const paused = state.mode === "paused";
  const recording = ["recording", "pausing", "paused", "resuming"].includes(
    state.mode,
  );
  const changingClip = state.mode === "pausing" || state.mode === "resuming";
  const pending = ["starting", "stopping", "finalizing"].includes(state.mode);
  const saving = state.mode === "stopping" || state.mode === "finalizing";
  const active = recording || pending;
  const shortcutBusy = useRef(false);
  const loweredForMicrophone = useRef(false);
  const loweredForSettings = useRef(false);
  const countdownStarting = useRef(false);
  const sawStarting = useRef(false);
  useEffect(() => {
    if (!countdownStarting.current) return;
    if (["starting", "resuming"].includes(state.mode))
      sawStarting.current = true;
    if (
      state.mode === "recording" ||
      (sawStarting.current && !["starting", "resuming"].includes(state.mode))
    ) {
      countdownStarting.current = false;
      sawStarting.current = false;
      setCountdown(null);
    }
  }, [state.mode]);
  useEffect(() => {
    if (
      state.mode !== "paused" &&
      continueCountdown.current &&
      countdownTimer.current
    ) {
      clearInterval(countdownTimer.current);
      countdownTimer.current = null;
      continueCountdown.current = false;
      setCountdown(null);
    }
  }, [state.mode]);
  useEffect(() => {
    if (loweredForMicrophone.current && state.mode !== "starting") {
      loweredForMicrophone.current = false;
      void getCurrentWindow().setAlwaysOnTop(true);
    }
  }, [state.mode]);
  useEffect(() => {
    const cancel = (event: KeyboardEvent) => {
      if (event.key === "Escape" && countdownTimer.current) {
        clearInterval(countdownTimer.current);
        countdownTimer.current = null;
        continueCountdown.current = false;
        setCountdown(null);
      }
    };
    window.addEventListener("keydown", cancel);
    return () => {
      window.removeEventListener("keydown", cancel);
      if (countdownTimer.current) clearInterval(countdownTimer.current);
    };
  }, []);
  useEffect(() => {
    if (!native) return;
    let disposed = false;
    let unlisten: (() => void) | undefined;
    void api
      .subscribeFocus(() => {
        if (!loweredForSettings.current) return;
        loweredForSettings.current = false;
        void getCurrentWindow().setAlwaysOnTop(true);
        void api
          .permissions()
          .then((status) => {
            if (!disposed && status.microphone)
              onOptionsChange({ ...options, mic: true });
          })
          .catch(() => {});
      })
      .then((stop) => {
        if (disposed) stop();
        else unlisten = stop;
      });
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [onOptionsChange, options]);
  useEffect(() => {
    // Native capture also validates the target. Refresh if it disappears in
    // the small interval between enumeration and native capture startup.
    if (state.error && !active) void sourcePicker.current?.refresh();
  }, [state.error, active]);
  const ensureMicrophone = async () => {
    try {
      const status = await api.permissions();
      if (status.microphone) return true;
      setMicrophoneCanRequest(status.microphoneCanRequest);
      setMicrophoneError("");
      setMicrophoneDialog(true);
    } catch (error) {
      await run(() => Promise.reject(error));
    }
    return false;
  };
  const enableMicrophone = async () => {
    setMicrophoneBusy(true);
    try {
      if (await ensureMicrophone()) onOptionsChange({ ...options, mic: true });
    } finally {
      setMicrophoneBusy(false);
    }
  };
  const toggleRecording = async () => {
    if (countdownTimer.current) {
      clearInterval(countdownTimer.current);
      countdownTimer.current = null;
      continueCountdown.current = false;
      setCountdown(null);
      if (!recording) return;
    }
    if (working || pending || microphoneBusy || shortcutBusy.current || !native)
      return;
    if (!recording && !source) {
      return;
    }
    if (!recording && mic) {
      setMicrophoneBusy(true);
      try {
        if (!(await ensureMicrophone())) return;
      } finally {
        setMicrophoneBusy(false);
      }
    }
    if (!recording) {
      shortcutBusy.current = true;
      try {
        let ready = false;
        const success = await run(async () => {
          ready = await api.prepareRecordingsFolder();
        });
        if (!success || !ready) return;
      } finally {
        shortcutBusy.current = false;
      }
    }
    if (!recording && countdownEnabled) {
      setCountdown(3);
      let remaining = 3;
      countdownTimer.current = setInterval(() => {
        remaining -= 1;
        if (remaining > 0) {
          setCountdown(remaining);
        } else {
          clearInterval(countdownTimer.current!);
          countdownTimer.current = null;
          countdownStarting.current = true;
          void performRecording();
        }
      }, 1000);
      return;
    }
    await performRecording();
  };
  const performRecording = async () => {
    shortcutBusy.current = true;
    try {
      if (!recording && mic) {
        try {
          await getCurrentWindow().setAlwaysOnTop(false);
          loweredForMicrophone.current = true;
        } catch {
          // Continue recording so the microphone permission request can appear.
        }
      }
      const success = await run(async () => {
        if (recording) return api.stop();
        const sources = await sourcePicker.current?.refresh();
        if (!sources)
          throw new Error(
            "Couldn’t check the capture source. Refresh the list and try again.",
          );
        const current =
          source &&
          sources.find((candidate) => sameCaptureSource(candidate, source));
        if (!current) {
          onSelect(null);
          throw new Error(
            `The selected ${source?.kind === "display" ? "screen" : "window"} is no longer available. Choose another source.`,
          );
        }
        return api.start(current, audio, mic);
      });
      if (!success && countdownStarting.current) {
        countdownStarting.current = false;
        sawStarting.current = false;
        setCountdown(null);
      }
      if (!success && loweredForMicrophone.current) {
        loweredForMicrophone.current = false;
        await getCurrentWindow().setAlwaysOnTop(true);
      }
    } finally {
      shortcutBusy.current = false;
    }
  };
  const performContinue = async () => {
    shortcutBusy.current = true;
    try {
      const success = await run(api.continue);
      if (!success) {
        countdownStarting.current = false;
        sawStarting.current = false;
        setCountdown(null);
      }
    } finally {
      shortcutBusy.current = false;
    }
  };
  const togglePause = async () => {
    if (countdownTimer.current) {
      clearInterval(countdownTimer.current);
      countdownTimer.current = null;
      continueCountdown.current = false;
      setCountdown(null);
      return;
    }
    if (
      !native ||
      working ||
      shortcutBusy.current ||
      !["recording", "paused"].includes(state.mode)
    )
      return;
    if (paused) {
      if (countdownEnabled) {
        setCountdown(3);
        continueCountdown.current = true;
        let remaining = 3;
        countdownTimer.current = setInterval(() => {
          remaining -= 1;
          if (remaining > 0) setCountdown(remaining);
          else {
            clearInterval(countdownTimer.current!);
            countdownTimer.current = null;
            continueCountdown.current = false;
            countdownStarting.current = true;
            void performContinue();
          }
        }, 1000);
      } else await performContinue();
      return;
    }
    shortcutBusy.current = true;
    try {
      await run(api.pause);
    } finally {
      shortcutBusy.current = false;
    }
  };
  const pauseAction = useRef(togglePause);
  useEffect(() => {
    pauseAction.current = togglePause;
  });
  useEffect(() => {
    if (!native) return;
    let disposed = false;
    let unsubscribe: (() => void) | undefined;
    void api
      .subscribePauseShortcut(() => {
        if (!disposed) void pauseAction.current();
      })
      .then((stop) => {
        if (disposed) stop();
        else unsubscribe = stop;
      })
      .catch((error) => {
        if (!disposed) void run(() => Promise.reject(error));
      });
    return () => {
      disposed = true;
      unsubscribe?.();
    };
  }, [run]);
  const shortcutAction = useRef(toggleRecording);
  useEffect(() => {
    shortcutAction.current = toggleRecording;
  });
  useEffect(() => {
    if (!native) return;
    let disposed = false;
    let unsubscribe: (() => void) | undefined;
    void api
      .subscribeRecordingShortcut(() => {
        if (!disposed) void shortcutAction.current();
      })
      .then((stop) => {
        if (disposed) stop();
        else unsubscribe = stop;
      })
      .catch((error) => {
        if (!disposed) void run(() => Promise.reject(error));
      });
    return () => {
      disposed = true;
      unsubscribe?.();
    };
  }, [run]);
  useEffect(() => {
    const recorded = (state.recordedDurationMs ?? 0) / 1000;
    const tick = () =>
      setElapsed(
        recording
          ? recorded +
              (["recording", "pausing"].includes(state.mode) &&
              state.startedAtMs
                ? Math.max(0, Date.now() - state.startedAtMs) / 1000
                : 0)
          : 0,
      );
    tick();
    const id = setInterval(tick, 250);
    return () => clearInterval(id);
  }, [recording, state.mode, state.startedAtMs, state.recordedDurationMs]);
  return (
    <section className="capture-panel animate-in fade-in">
      <div
        className={`capture-illustration ${state.mode === "recording" ? "is-recording" : ""}`}
        aria-hidden="true"
      >
        <div
          className="capture-art"
          style={{ backgroundImage: `url("${captureArt}")` }}
        />
        {state.mode === "recording" && (
          <span className="live-badge">
            <i /> REC
          </span>
        )}
      </div>
      <div className="capture-intro">
        <span className="eyebrow">
          {recording
            ? "IN THE MOMENT"
            : saving
              ? "ONE MOMENT"
              : "SCREEN RECORDER"}
        </span>
        <h1>
          {recording
            ? paused
              ? "Recording paused."
              : "You’re rolling."
            : saving
              ? "Saving your recording…"
              : "New recording"}
        </h1>
        <p>
          {recording
            ? paused
              ? "Continue when you’re ready. Your completed clips are safe."
              : "Take your time. We’ll take care of the details."
            : saving
              ? "Your original footage stays safe and untouched."
              : "Choose a window or screen to record."}
        </p>
      </div>
      <SourcePicker
        ref={sourcePicker}
        value={source}
        onSelect={onSelect}
        disabled={active || working}
        preserveSelection={active}
      />
      <div className="audio-options">
        <label>
          <Icon name="volume" size={16} />
          <span>System audio</span>
          <Switch
            aria-label="System audio"
            checked={audio}
            onCheckedChange={(audio) => onOptionsChange({ ...options, audio })}
            disabled={active || working}
          />
        </label>
        <label>
          <Icon name="microphone" size={16} />
          <span>Microphone</span>
          <Switch
            aria-label="Microphone"
            checked={mic}
            onCheckedChange={(mic) => {
              if (mic) void enableMicrophone();
              else onOptionsChange({ ...options, mic: false });
            }}
            disabled={active || working || microphoneBusy}
          />
        </label>
      </div>
      <div className="shortcut-notes">
        <p className="shortcut-note">
          <span>Start / Stop</span>
          <span>Control + Option + Command + R</span>
        </p>
        <p className="shortcut-note">
          <span>Pause / Continue</span>
          <span>Control + Option + Command + P</span>
        </p>
      </div>
      {actionFooter &&
        createPortal(
          <div className="capture-action">
            {recording ? (
              <>
                <Button
                  className="w-full mb-2"
                  size="lg"
                  onClick={togglePause}
                  title="Pause / Continue recording (Control + Option + Command + P)"
                  aria-keyshortcuts="Control+Alt+Meta+P"
                  disabled={working || changingClip}
                  style={changingClip ? { opacity: 1 } : undefined}
                >
                  <Icon
                    name={
                      paused || state.mode === "resuming" ? "record" : "pause"
                    }
                  />
                  {state.mode === "pausing"
                    ? "Pausing…"
                    : state.mode === "resuming"
                      ? "Continuing…"
                      : paused
                        ? "Continue recording"
                        : "Pause recording"}
                </Button>
                <Button
                  className="w-full"
                  size="lg"
                  onClick={toggleRecording}
                  title="Stop recording (Control + Option + Command + R)"
                  aria-keyshortcuts="Control+Alt+Meta+R"
                  disabled={working}
                >
                  <Icon name="stop" fill="currentColor" size={13} />
                  <span>Stop recording</span>
                  <span className="recording-time">{time(elapsed)}</span>
                </Button>
              </>
            ) : (
              <Button
                className="w-full"
                size="lg"
                style={
                  microphoneBusy && !!source && !pending && !working && native
                    ? { opacity: 1 }
                    : undefined
                }
                disabled={
                  !source || pending || working || microphoneBusy || !native
                }
                onClick={toggleRecording}
                title="Start recording (Control + Option + Command + R)"
                aria-keyshortcuts="Control+Alt+Meta+R"
              >
                {pending ? <Spinner /> : <Icon name="record" />}
                <span>
                  {pending
                    ? state.mode === "starting"
                      ? "Starting…"
                      : "Preparing project…"
                    : "Start recording"}
                </span>
              </Button>
            )}
          </div>,
          actionFooter,
        )}
      {(!recording || paused) && (
        <label className="countdown-option">
          <span>3-second countdown</span>
          <Switch
            checked={countdownEnabled}
            onCheckedChange={(countdownEnabled) =>
              onOptionsChange({ ...options, countdownEnabled })
            }
            disabled={(active && !paused) || working}
          />
        </label>
      )}
      {source && (
        <Alert className="mt-4">
          <AlertDescription>
            {source.kind === "window" &&
              "Keep the window fully visible on one screen before and during recording. "}
            Saturn’s window hides while recording. Stop with the shortcut or the
            menu bar controls.
          </AlertDescription>
        </Alert>
      )}
      <AlertDialog open={microphoneDialog} onOpenChange={setMicrophoneDialog}>
        <AlertDialogPopup>
          <AlertDialogHeader>
            <AlertDialogTitle>Allow Microphone Access</AlertDialogTitle>
            <AlertDialogDescription>
              {microphoneCanRequest
                ? "Allow Saturn to use your microphone to record your voice."
                : "Enable Saturn under Privacy & Security → Microphone in System Settings to record your voice."}
            </AlertDialogDescription>
            {microphoneError && (
              <p className="inline-error" role="alert">
                {microphoneError}
              </p>
            )}
          </AlertDialogHeader>
          <AlertDialogFooter>
            <Button
              variant="outline"
              disabled={microphoneBusy}
              onClick={() => setMicrophoneDialog(false)}
            >
              Cancel
            </Button>
            <Button
              disabled={microphoneBusy}
              onClick={() => {
                void (async () => {
                  setMicrophoneBusy(true);
                  setMicrophoneError("");
                  try {
                    const status = await api.permissions();
                    if (status.microphone) {
                      onOptionsChange({ ...options, mic: true });
                      setMicrophoneDialog(false);
                    } else if (status.microphoneCanRequest) {
                      setMicrophoneDialog(false);
                      try {
                        await getCurrentWindow().setAlwaysOnTop(false);
                      } catch {
                        /* Continue with the system prompt. */
                      }
                      let result;
                      try {
                        result = await api.requestMicrophonePermission();
                      } finally {
                        await getCurrentWindow()
                          .setAlwaysOnTop(true)
                          .catch(() => {});
                      }
                      if (result.microphone) {
                        onOptionsChange({ ...options, mic: true });
                      } else {
                        setMicrophoneCanRequest(result.microphoneCanRequest);
                        setMicrophoneDialog(true);
                      }
                    } else {
                      try {
                        await getCurrentWindow().setAlwaysOnTop(false);
                        loweredForSettings.current = true;
                      } catch {
                        /* Settings can still open. */
                      }
                      setMicrophoneDialog(false);
                      await api.openMicrophoneSettings();
                    }
                  } catch (error) {
                    if (loweredForSettings.current) {
                      loweredForSettings.current = false;
                      void getCurrentWindow()
                        .setAlwaysOnTop(true)
                        .catch(() => {});
                    }
                    setMicrophoneError(String(error));
                    setMicrophoneDialog(true);
                  } finally {
                    setMicrophoneBusy(false);
                  }
                })();
              }}
            >
              {microphoneCanRequest ? "Continue" : "Open System Settings"}
            </Button>
          </AlertDialogFooter>
        </AlertDialogPopup>
      </AlertDialog>
      {countdown !== null &&
        createPortal(
          <div
            className="countdown-overlay"
            role="status"
            aria-live="assertive"
            aria-label={`Recording starts in ${countdown}`}
          >
            <span aria-hidden="true">{countdown}</span>
          </div>,
          document.body,
        )}
    </section>
  );
}
