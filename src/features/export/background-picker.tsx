import { useCallback, useLayoutEffect, useState } from "react";
import {
  wallpaperPresets as wallpapers,
  wallpaperPresetId,
} from "@/lib/wallpapers";
import Icon from "@/components/ui/icons/icons";
import { Button } from "@/components/ui/button";
import { Popover, PopoverTrigger, PopoverPopup } from "@/components/ui/popover";
import { useBackgroundImage } from "./use-background-image";
import { ScrollArea } from "@/components/ui/scroll-area";
import type { Background } from "@/lib/contracts";
export function BackgroundPicker({
  value,
  backgroundPath,
  backgroundRevision,
  onChange,
  onImage,
  disabled,
  visuallyDisabled = disabled,
  onPreset,
}: {
  value: Background;
  backgroundPath?: string | null;
  backgroundRevision?: number | null;
  onChange: (b: Background) => void;
  onImage: () => void;
  disabled: boolean;
  visuallyDisabled?: boolean;
  onPreset: (preset: string) => Promise<boolean>;
}) {
  const [open, setOpen] = useState(false);
  const [grid, setGrid] = useState<HTMLDivElement | null>(null);
  const preview = useBackgroundImage(value, backgroundPath, backgroundRevision);
  const selectedPreset =
    value.type === "embeddedImage" && value.preset
      ? wallpaperPresetId(value.preset)
      : undefined;
  const missingPreset =
    value.type === "embeddedImage" &&
    !!value.preset &&
    !wallpapers.some((wallpaper) => wallpaper.id === selectedPreset);
  const centerSelection = useCallback(() => {
    if (!grid) return;
    const viewport = grid.closest<HTMLElement>(
      '[data-slot="scroll-area-viewport"]',
    );
    const selected = grid.querySelector<HTMLElement>('[aria-pressed="true"]');
    if (!viewport || !selected) return;
    const viewportRect = viewport.getBoundingClientRect();
    const selectedRect = selected.getBoundingClientRect();
    if (!viewport.clientHeight || !viewportRect.height) return;
    const scale = viewportRect.height / viewport.offsetHeight;
    viewport.scrollTop +=
      (selectedRect.top + selectedRect.height / 2 - viewportRect.top) / scale -
      viewport.clientHeight / 2;
  }, [grid]);
  useLayoutEffect(() => {
    if (!open || !grid) return;
    const viewport = grid.closest<HTMLElement>(
      '[data-slot="scroll-area-viewport"]',
    );
    if (!viewport) return;
    centerSelection();
    const observer = new ResizeObserver(centerSelection);
    observer.observe(viewport);
    observer.observe(grid);
    return () => observer.disconnect();
  }, [open, grid, centerSelection]);
  return (
    <div className="background-row">
      <div className={visuallyDisabled ? "option-label-disabled" : undefined}>
        <strong>Background</strong>
        <p>Choose a backdrop for your video</p>
      </div>
      <Popover
        open={open}
        onOpenChange={setOpen}
        onOpenChangeComplete={(opened) => {
          if (opened) centerSelection();
        }}
      >
        <PopoverTrigger
          render={
            <Button
              variant="outline"
              aria-label="Choose background"
              disabled={disabled}
              className="background-trigger"
            />
          }
        >
          <span
            className={`background-preview ${value.type === "none" ? "no-background" : ""}`}
            style={{ background: preview ?? undefined }}
          />
        </PopoverTrigger>
        <PopoverPopup
          align="end"
          side="top"
          aria-label="Choose background"
          className="background-popover"
          // Focusing the first tile would undo the selected tile's scroll position.
          initialFocus={() =>
            grid?.querySelector<HTMLElement>('[aria-pressed="true"]') ?? false
          }
        >
          <ScrollArea
            className="background-scroll"
            overscrollContain
            scrollFade
            scrollbarClassName="hidden"
          >
            <div
              ref={setGrid}
              className="background-grid"
              role="group"
              aria-label="Background options"
            >
              <Button
                variant="outline"
                className={`background-tile no-background ${value.type === "none" ? "selected" : ""}`}
                aria-label="No background"
                aria-pressed={value.type === "none"}
                onClick={() => {
                  onChange({ type: "none" });
                  setOpen(false);
                }}
              >
                <Icon
                  name={value.type === "none" ? "check" : "noBackground"}
                  className="tile-icon"
                />
              </Button>
              <Button
                variant="outline"
                className={`background-tile custom-tile ${value.type === "embeddedImage" && !value.preset ? "selected" : ""}`}
                style={{
                  backgroundImage:
                    value.type === "embeddedImage" && !value.preset
                      ? (preview ?? undefined)
                      : undefined,
                }}
                aria-pressed={value.type === "embeddedImage" && !value.preset}
                aria-label="Choose background image"
                onClick={() => {
                  setOpen(false);
                  onImage();
                }}
              >
                <Icon
                  name={
                    value.type === "embeddedImage" && !value.preset
                      ? "check"
                      : "photoPlus"
                  }
                  className="tile-icon"
                />
              </Button>
              {(["white", "black"] as const).map((color) => (
                <Button
                  key={color}
                  variant="outline"
                  className={`background-tile solid-tile ${color === "white" ? "white-tile" : ""} ${value.type === "solid" && value.color === color ? "selected" : ""}`}
                  style={{ background: color }}
                  aria-label={`${color} background`}
                  aria-pressed={value.type === "solid" && value.color === color}
                  onClick={() => {
                    onChange({ type: "solid", color });
                    setOpen(false);
                  }}
                >
                  {value.type === "solid" && value.color === color && (
                    <Icon name="check" className="tile-icon" />
                  )}
                </Button>
              ))}
              {missingPreset && (
                <Button
                  variant="outline"
                  className="background-tile saved-background-tile selected"
                  style={{ backgroundImage: preview ?? undefined }}
                  aria-label="Saved wallpaper, no longer in collection"
                  aria-pressed={true}
                  onClick={() => setOpen(false)}
                >
                  <Icon name="check" className="tile-icon" />
                </Button>
              )}
              {wallpapers.map((wallpaper) => (
                <Button
                  key={wallpaper.id}
                  variant="outline"
                  className={`background-tile ${selectedPreset === wallpaper.id ? "selected" : ""}`}
                  aria-label={`${wallpaper.label} background`}
                  aria-pressed={selectedPreset === wallpaper.id}
                  onClick={() => {
                    void onPreset(wallpaper.id);
                    setOpen(false);
                  }}
                >
                  <img
                    src={`/wallpapers/${wallpaper.path
                      .split("/")
                      .map(encodeURIComponent)
                      .join("/")
                      .replace(/\/([^/]+)$/, "/thumbs/$1")}`}
                    alt=""
                    loading="lazy"
                  />
                  {selectedPreset === wallpaper.id && (
                    <Icon name="check" className="tile-icon" />
                  )}
                </Button>
              ))}
            </div>
          </ScrollArea>
        </PopoverPopup>
      </Popover>
    </div>
  );
}
