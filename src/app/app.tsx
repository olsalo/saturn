import { useEffect, useState } from "react";
import Icon from "@/components/ui/icons/icons";
import { Button } from "@/components/ui/button";
import {
  Popover,
  PopoverTrigger,
  PopoverPopup,
  PopoverTitle,
} from "@/components/ui/popover";
import { Alert, AlertTitle, AlertAction } from "@/components/ui/alert";
import { ScrollArea } from "@/components/ui/scroll-area";
import { toastManager } from "@/components/ui/toast";
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
  const [actionFooter, setActionFooter] = useState<HTMLElement | null>(null);
  const busy = isBusy(state.mode);
  const editing =
    !!state.project &&
    !["starting", "recording", "stopping", "finalizing"].includes(state.mode);
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
                aria-label="About Saturn"
              />
            }
          >
            <Icon name="help" />
          </PopoverTrigger>
          <PopoverPopup
            className="help-popover"
            align="end"
            aria-label="About Saturn"
          >
            <PopoverTitle>A little space for your ideas.</PopoverTitle>
            <p>
              Saturn saves your original footage and styling inside one portable
              .saturn file. Your MP4 is a separate video you can share.
            </p>
            <p>
              Press Control + Option + Command + R (⌃⌥⌘R) to start or stop a
              recording, even while Saturn is hidden. Choose a window or screen
              first.
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
      <footer className="main-action-footer">
        {(state.error ||
          (!editing && state.pendingCount > 0) ||
          (!editing && state.recoveries.length > 0 && !busy)) && (
          <div className="footer-alerts">
            {state.error && (
              <Alert>
                <AlertTitle>{state.error}</AlertTitle>
                <AlertAction>
                  <Button
                    size="icon-xs"
                    variant="ghost"
                    onClick={dismiss}
                    aria-label="Dismiss error message"
                    title="Dismiss error message"
                  >
                    <Icon name="x" />
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
                    variant="outline"
                    size="xs"
                    disabled={busy || working}
                    onClick={() => run(() => api.open(true))}
                  >
                    Open
                  </Button>
                </AlertAction>
              </Alert>
            )}
            {!editing && state.recoveries.length > 0 && !busy && (
              <Alert>
                <AlertTitle>There’s a recording to recover.</AlertTitle>
                <AlertAction>
                  <Button
                    variant="outline"
                    size="xs"
                    disabled={working}
                    onClick={() =>
                      run(() => api.discardRecovery(state.recoveries[0]))
                    }
                  >
                    Discard
                  </Button>
                  <Button
                    variant="outline"
                    size="xs"
                    disabled={working}
                    onClick={() =>
                      run(async () => {
                        try {
                          await api.recover(state.recoveries[0]);
                        } catch {
                          toastManager.add({
                            title: "Couldn’t recover the recording",
                            description:
                              "The captured files were kept on this Mac.",
                            type: "error",
                          });
                        }
                      })
                    }
                  >
                    <Icon name="restart" />
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
