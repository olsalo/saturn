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
import { useCallback, useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { api, native } from "@/lib/tauri";
import type { CaptureSource, ScreenPermissionStatus } from "@/lib/contracts";

export function SourcePicker({
  onSelect,
  value,
  disabled,
  preserveSelection,
}: {
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
  const inFlight = useRef(false);
  const loweredWindow = useRef(false);
  const permissionRequestInProgress = useRef(false);
  const mounted = useRef(true);
  const selectionRef = useRef(value);
  const selectRef = useRef(onSelect);
  const preserveSelectionRef = useRef(preserveSelection);
  selectionRef.current = value;
  selectRef.current = onSelect;
  preserveSelectionRef.current = preserveSelection;
  const refresh = useCallback(async () => {
    if (!native || inFlight.current) return;
    inFlight.current = true;
    setLoading(true);
    setError("");
    try {
      const status = await api.permissions();
      if (!mounted.current) return;
      setPermission(status);
      if (status.screen) setPermissionOpen(false);
      if (status.screen) {
        const result = await api.sources();
        if (!mounted.current) return;
        if (result.permissionRequired) {
          setPermission({
            screen: false,
            canRequest: false,
            needsRestart: result.needsRestart ?? false,
          });
        } else {
          setSources(result.sources);
          const selected = selectionRef.current;
          if (selected && !preserveSelectionRef.current) {
            const current = result.sources.find(
              (source) =>
                source.kind === selected.kind &&
                source.id === selected.id &&
                (source.kind === "display" ||
                  source.application === selected.application),
            );
            if (!current) selectRef.current(null);
            else if (
              current.label !== selected.label ||
              current.application !== selected.application ||
              current.primary !== selected.primary
            )
              selectRef.current(current);
          }
        }
      }
    } catch (e) {
      if (mounted.current) setError(String(e));
    } finally {
      inFlight.current = false;
      if (mounted.current) setLoading(false);
    }
  }, []);
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
