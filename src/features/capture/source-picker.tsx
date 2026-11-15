import {
  Select,
  SelectTrigger,
  SelectValue,
  SelectPopup,
  SelectItem,
} from "@/components/ui/select";
import {
  AlertDialog,
  AlertDialogPopup,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogDescription,
  AlertDialogFooter,
} from "@/components/ui/alert-dialog";
import {
  useCallback,
  useEffect,
  useImperativeHandle,
  useRef,
  useState,
  type Ref,
} from "react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { api, native } from "@/lib/tauri";
import type { CaptureSource, ScreenPermissionStatus } from "@/lib/contracts";

export type SourcePickerHandle = {
  refresh: () => Promise<CaptureSource[] | null>;
};

export function SourcePicker({
  ref,
  onSelect,
  value,
  disabled,
  preserveSelection,
}: {
  ref?: Ref<SourcePickerHandle>;
  onSelect: (source: CaptureSource | null) => void;
  value: CaptureSource | null;
  disabled: boolean;
  preserveSelection: boolean;
}) {
  const [sources, setSources] = useState<CaptureSource[]>([]);
  const [permission, setPermission] = useState<ScreenPermissionStatus | null>(
    null,
  );
  const [loading, setLoading] = useState(native);
  const [error, setError] = useState("");
  const [permissionOpen, setPermissionOpen] = useState(false);
  const inFlight = useRef<Promise<CaptureSource[] | null> | null>(null);
  const loweredWindow = useRef(false);
  const permissionRequestInProgress = useRef(false);
  const mounted = useRef(true);
  const selectionRef = useRef(value);
  const selectRef = useRef(onSelect);
  const preserveSelectionRef = useRef(preserveSelection);
  selectionRef.current = value;
  selectRef.current = onSelect;
  preserveSelectionRef.current = preserveSelection;
  const refresh = useCallback((): Promise<CaptureSource[] | null> => {
    if (!native) return Promise.resolve(null);
    if (inFlight.current) return inFlight.current;
    const task = (async () => {
      setLoading(true);
      setError("");
      try {
        const status = await api.permissions();
        if (!mounted.current) return null;
        setPermission(status);
        if (status.screen) setPermissionOpen(false);
        if (!status.screen) return null;
        const result = await api.sources();
        if (!mounted.current) return null;
        if (result.permissionRequired) {
          setPermission({
            screen: false,
            canRequest: false,
            needsRestart: result.needsRestart ?? false,
          });
          return null;
        }
        setSources(result.sources);
        const selected = selectionRef.current;
        if (selected && !preserveSelectionRef.current) {
          const current = result.sources.find((source) =>
            sameCaptureSource(source, selected),
          );
          if (!current) selectRef.current(null);
          else if (
            current.label !== selected.label ||
            current.application !== selected.application ||
            current.primary !== selected.primary
          )
            selectRef.current(current);
        }
        return result.sources;
      } catch (e) {
        if (mounted.current) setError(String(e));
        return null;
      } finally {
        if (mounted.current) setLoading(false);
      }
    })();
    inFlight.current = task;
    void task.finally(() => {
      inFlight.current = null;
    });
    return task;
  }, []);
  useImperativeHandle(
    ref,
    () => ({
      refresh: async () => {
        // A pre-start check must follow any older background enumeration.
        if (inFlight.current) await inFlight.current;
        return refresh();
      },
    }),
    [refresh],
  );
  useEffect(() => {
    mounted.current = true;
    void refresh();
    let disposed = false;
    let unlisten: (() => void) | undefined;
    if (native)
      void api
        .subscribeFocus(() => {
          if (loweredWindow.current && !permissionRequestInProgress.current) {
            loweredWindow.current = false;
            void getCurrentWindow().setAlwaysOnTop(true);
          }
          void refresh();
        })
        .then((stop) => {
          if (disposed) stop();
          else unlisten = stop;
        })
        .catch(() => {});
    return () => {
      mounted.current = false;
      disposed = true;
      unlisten?.();
    };
  }, [refresh]);
  useEffect(() => {
    if (
      !native ||
      !permission?.screen ||
      permissionOpen ||
      disabled ||
      preserveSelection ||
      value?.kind !== "window"
    )
      return;
    // Detect a closed target even while another app has focus. Keep the current
    // selection visible until a completed enumeration confirms it is gone.
    const timer = setInterval(() => {
      void refresh();
    }, 750);
    return () => clearInterval(timer);
  }, [
    permission?.screen,
    permissionOpen,
    disabled,
    preserveSelection,
    value?.kind,
    value?.id,
    refresh,
  ]);
  return (
    <div>
      {permission?.screen ? (
        <Select<CaptureSource>
          value={value}
          itemToStringValue={(source) => `${source.kind}:${source.id}`}
          itemToStringLabel={(source) =>
            source ? `${source.application} — ${source.label}` : ""
          }
          isItemEqualToValue={(a, b) => a.id === b.id && a.kind === b.kind}
          onValueChange={(source) => {
            if (source) onSelect(source);
          }}
          disabled={disabled}
          onOpenChange={(open) => {
            if (open) void refresh();
          }}
        >
          <SelectTrigger
            aria-label="Choose a window or screen"
            className="py-1"
          >
            <SelectValue
              placeholder={
                <span className="flex flex-col">
                  <span>Choose what to record</span>
                  <span className="text-muted-foreground text-xs">
                    Select a window or screen
                  </span>
                </span>
              }
            >
              {(source: CaptureSource | null) =>
                source ? (
                  <span className="flex min-w-0 flex-col">
                    <span className="truncate">{source.label}</span>
                    <span className="truncate text-muted-foreground text-xs">
                      {source.application}
                    </span>
                  </span>
                ) : (
                  <span className="flex flex-col">
                    <span>Choose what to record</span>
                    <span className="text-muted-foreground text-xs">
                      Select a window or screen
                    </span>
                  </span>
                )
              }
            </SelectValue>
          </SelectTrigger>
          <SelectPopup
            side="bottom"
            collisionAvoidance={{ side: "none", align: "shift" }}
          >
            {sources.map((source) => (
              <SelectItem key={`${source.kind}:${source.id}`} value={source}>
                <span className="flex min-w-0 flex-col">
                  <span className="flex items-center gap-2">
                    <span className="truncate">{source.label}</span>
                    {source.primary && (
                      <Badge variant="secondary" size="sm">
                        Primary
                      </Badge>
                    )}
                  </span>
                  <span className="truncate text-muted-foreground text-xs">
                    {source.application}
                  </span>
                </span>
              </SelectItem>
            ))}
            {!sources.length && (
              <div className="p-3 text-sm text-muted-foreground">
                No screens or windows found.
              </div>
            )}
          </SelectPopup>
        </Select>
      ) : (
        <Button
          variant="outline"
          className="h-auto min-h-0 w-full justify-start py-1 text-left"
          disabled={disabled || loading || !native}
          onClick={() => setPermissionOpen(true)}
        >
          <span className="flex flex-col">
            <span>Choose what to record</span>
            <span className="text-muted-foreground text-xs">
              Select a window or screen
            </span>
          </span>
        </Button>
      )}
      <AlertDialog open={permissionOpen} onOpenChange={setPermissionOpen}>
        <AlertDialogPopup>
          <AlertDialogHeader>
            <AlertDialogTitle>Allow Screen Recording</AlertDialogTitle>
            <AlertDialogDescription>
              Enable Saturn under Privacy & Security → Screen & System Audio
              Recording. macOS may require you to reopen Saturn.
            </AlertDialogDescription>
            {error && (
              <p className="inline-error" role="alert">
                {error}
              </p>
            )}
          </AlertDialogHeader>
          <AlertDialogFooter>
            <Button variant="outline" onClick={() => setPermissionOpen(false)}>
              Cancel
            </Button>
            <Button
              onClick={() => {
                void (async () => {
                  if (permissionRequestInProgress.current) return;
                  try {
                    permissionRequestInProgress.current = true;
                    try {
                      await getCurrentWindow().setAlwaysOnTop(false);
                      loweredWindow.current = true;
                    } catch {
                      // Permission requests must still work if window layering fails.
                    }
                    if (permission?.canRequest) {
                      setPermissionOpen(false);
                      const status = await api.requestPermission();
                      setPermission(status);
                      if (status.screen) {
                        setPermissionOpen(false);
                        loweredWindow.current = false;
                        await getCurrentWindow().setAlwaysOnTop(true);
                        await refresh();
                      }
                      return;
                    }
                    setPermissionOpen(false);
                    await api.openScreenSettings();
                  } catch (e) {
                    if (loweredWindow.current) {
                      loweredWindow.current = false;
                      void getCurrentWindow()
                        .setAlwaysOnTop(true)
                        .catch(() => {});
                    }
                    setError(String(e));
                  } finally {
                    permissionRequestInProgress.current = false;
                  }
                })();
              }}
            >
              {permission?.canRequest ? "Continue" : "Open System Settings"}
            </Button>
          </AlertDialogFooter>
        </AlertDialogPopup>
      </AlertDialog>
      {error && !permissionOpen && (
        <p className="inline-error" role="alert">
          {error}
        </p>
      )}
    </div>
  );
}

export function sameCaptureSource(
  source: CaptureSource,
  selected: CaptureSource,
) {
  return (
    source.kind === selected.kind &&
    source.id === selected.id &&
    (source.kind === "display" || source.application === selected.application)
  );
}
