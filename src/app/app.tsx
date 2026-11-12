import { useEffect, useRef, useState } from "react";
import Icon from "@/components/ui/icons/icons";
import { Button } from "@/components/ui/button";
import {
  Popover,
  PopoverTrigger,
  PopoverPopup,
  PopoverTitle,
} from "@/components/ui/popover";
import { Alert, AlertTitle, AlertAction } from "@/components/ui/alert";
import {
  AlertDialog, AlertDialogPopup, AlertDialogHeader, AlertDialogTitle,
  AlertDialogDescription, AlertDialogFooter,
} from "@/components/ui/alert-dialog";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
  CapturePanel,
  type CaptureOptions,
} from "@/features/capture/capture-panel";
import { ExportPanel } from "@/features/export/export-panel";
import { ProjectMenu } from "@/features/project/project-menu";
import { api, native } from "@/lib/tauri";
import type { CaptureSource } from "@/lib/contracts";
import { useAppEvents } from "./use-app-events";
import { isBusy } from "./recorder-machine";
import { getCurrentWindow } from "@tauri-apps/api/window";
export default function App() {
  const { state, working, run, dismiss } = useAppEvents();
  const [source, setSource] = useState<CaptureSource | null>(null);
  const [captureOptions, setCaptureOptions] = useState<CaptureOptions>({
    audio: true,
    mic: false,
    countdownEnabled: false,
  });
  const [help, setHelp] = useState(false);
  const [fileAccessOpen, setFileAccessOpen] = useState(false);
  const [fileAccessError, setFileAccessError] = useState("");
  const fileSettingsOpen = useRef(false);
  const [actionFooter, setActionFooter] = useState<HTMLElement | null>(null);
  const busy = isBusy(state.mode);
  const editing =
    !!state.project &&
    !["starting", "recording", "stopping", "finalizing"].includes(state.mode);
  const showRecovery = !editing && state.recoveries.length > 0 && !busy;
  const recoveryError = showRecovery &&
    state.error?.startsWith("Saturn couldn’t finish the recording")
      ? state.error
      : null;
  const recover = (chooseFolder = false) => {
    void run(async () => {
      if (chooseFolder) {
        setFileAccessOpen(false);
        if (native) await getCurrentWindow().setAlwaysOnTop(false).catch(() => {});
      }
      try {
        await api.recover(state.recoveries[0], chooseFolder);
        setFileAccessError("");
      } catch (error) {
        const message = String(error);
        if (message.includes("SATURN_FILE_ACCESS_REQUIRED")) {
          setFileAccessError(chooseFolder ? "Saturn still can’t access the recording or that folder. Choose another folder or allow access in System Settings." : "");
          setFileAccessOpen(true);
        } else if (chooseFolder && message.includes("No folder selected")) {
          setFileAccessError("");
        } else {
          throw error;
        }
      } finally {
        if (chooseFolder && native) await getCurrentWindow().setAlwaysOnTop(true).catch(() => {});
      }
    });
  };
  useEffect(() => {
    if (!native) return;
    let unlisten: (() => void) | undefined;
    let disposed = false;
    void api.subscribeFocus(() => {
      if (!fileSettingsOpen.current) return;
      fileSettingsOpen.current = false;
      void getCurrentWindow().setAlwaysOnTop(true).catch(() => {});
      setFileAccessOpen(true);
    }).then((stop) => { if (disposed) stop(); else unlisten = stop; });
    return () => { disposed = true; unlisten?.(); };
  }, []);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        setHelp(false);
      }
      if ((e.metaKey || e.ctrlKey) && e.key === "o" && !busy && !working) {
        e.preventDefault();
        void run(() => api.open());
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [busy, working, run]);
  return (
    <main className="floating-panel">
      <header className="panel-header">
        <div
          className="brand"
          data-tauri-drag-region
          onMouseDown={(e) => {
            if (native && e.button === 0)
              void getCurrentWindow().startDragging();
          }}
        >
          <span className="brand-mark" aria-hidden="true" />
          <span>
            saturn
          </span>
        </div>
        <Popover open={help} onOpenChange={setHelp}>
          <PopoverTrigger
            render={
              <Button
                variant="outline"
                size="icon-sm"
                aria-label="Help"
              />
            }
          >
            <Icon name="help" />
          </PopoverTrigger>
          <PopoverPopup
            className="help-popover"
            align="end"
            aria-label="Using Saturn"
          >
            <PopoverTitle>Using Saturn</PopoverTitle>
            <p>
              Choose a window or screen, select your audio, and start recording.
              When you’re done, adjust the appearance and export an MP4 or a
              website-ready video.
            </p>
            <p>
              Your .saturn project keeps your recording and settings together so
              you can reopen and export it again. Press Control + Option +
              Command + R (⌃⌥⌘R) to start or stop recording, even while Saturn
              is hidden.
            </p>
            <Button variant="ghost" size="xs" onClick={() => setHelp(false)}>
              Got it
            </Button>
          </PopoverPopup>
        </Popover>
        <ProjectMenu
          hasProject={!!state.project}
          disabled={busy || working}
          run={run}
        />
      </header>
      <ScrollArea className="panel-scroll" overscrollContain scrollFade>
        <div
          className={`panel-content ${editing ? "panel-content-export" : "panel-content-capture"}`}
        >
          {editing ? (
            <ExportPanel
              state={state}
              working={working}
              run={run}
              actionFooter={actionFooter}
            />
          ) : (
            <CapturePanel
              state={state}
              actionFooter={actionFooter}
              source={source}
              onSelect={setSource}
              options={captureOptions}
              onOptionsChange={setCaptureOptions}
              working={working}
              run={run}
            />
          )}
        </div>
      </ScrollArea>
      <AlertDialog open={fileAccessOpen} onOpenChange={setFileAccessOpen}>
        <AlertDialogPopup>
          <AlertDialogHeader>
            <AlertDialogTitle>Allow File Access</AlertDialogTitle>
            <AlertDialogDescription>
              Choose a folder where Saturn can save the recovered recording. If macOS denied access, allow Saturn under Privacy &amp; Security → Files and Folders in System Settings.
            </AlertDialogDescription>
            {fileAccessError && <p className="inline-error" role="alert">{fileAccessError}</p>}
          </AlertDialogHeader>
          <AlertDialogFooter>
            <Button variant="outline" disabled={working} onClick={() => setFileAccessOpen(false)}>Cancel</Button>
            {fileAccessError && <Button variant="outline" disabled={working} onClick={() => {
              void run(async () => {
                try {
                  if (native) await getCurrentWindow().setAlwaysOnTop(false);
                  fileSettingsOpen.current = true;
                  setFileAccessOpen(false);
                  await api.openFileAccessSettings();
                } catch (error) {
                  fileSettingsOpen.current = false;
                  if (native) await getCurrentWindow().setAlwaysOnTop(true).catch(() => {});
                  setFileAccessOpen(true);
                  throw error;
                }
              });
            }}>Open System Settings</Button>}
            <Button disabled={working} onClick={() => recover(true)}>Choose Folder</Button>
          </AlertDialogFooter>
        </AlertDialogPopup>
      </AlertDialog>
      <footer className="main-action-footer">
        {(state.error ||
          (!editing && state.pendingCount > 0) ||
          (!editing && state.recoveries.length > 0 && !busy)) && (
          <div className="footer-alerts">
            {state.error && !recoveryError && (
              <Alert>
                <AlertTitle>{state.error}</AlertTitle>
                <AlertAction>
                  <Button size="xs" onClick={dismiss}>
                    Got this
                  </Button>
                </AlertAction>
              </Alert>
            )}
            {!editing && state.pendingCount > 0 && (
              <Alert>
                <AlertTitle>
                  {busy
                    ? "A project is queued. Finish this session to open it."
                    : "A project is waiting to open."}
                </AlertTitle>
                <AlertAction>
                  <Button
                    size="xs"
                    disabled={busy || working}
                    onClick={() => run(() => api.open(true))}
                  >
                    Open
                  </Button>
                </AlertAction>
              </Alert>
            )}
            {showRecovery && (
              <Alert>
                <AlertTitle>{recoveryError ?? "There’s a recording to recover."}</AlertTitle>
                <AlertAction>
                  <Button
                    variant="ghost"
                    size="xs"
                    disabled={working}
                    onClick={() =>
                      run(() => api.discardRecovery(state.recoveries[0]))
                    }
                  >
                    Discard
                  </Button>
                  <Button
                    size="xs"
                    disabled={working}
                    onClick={() => recover()}
                  >
                    Recover
                  </Button>
                </AlertAction>
              </Alert>
            )}
          </div>
        )}
        <div className="footer-action" ref={setActionFooter} />
      </footer>
    </main>
  );
}
