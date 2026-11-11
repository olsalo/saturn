import { useState } from "react";
import wallpapers from "@/lib/wallpapers.json";
import Icon from "@/components/ui/icons/icons";
import { Button } from "@/components/ui/button";
import {
  Popover,
  PopoverTrigger,
  PopoverPopup,
} from "@/components/ui/popover";
import { useBackgroundImage } from "./use-background-image";
import { ScrollArea } from "@/components/ui/scroll-area";
import type { Background } from "@/lib/contracts";
export const backgroundCss = {
  dawn: "linear-gradient(135deg,#a2b5ee,#d6bfde 50%,#f4c6ac)",
  dusk: "linear-gradient(135deg,#6667ac,#b894ba 50%,#edbdac)",
  mint: "linear-gradient(135deg,#224c4b,#6a9f8c 50%,#d1dfb2)",
  ink: "linear-gradient(135deg,#1a1d24,#424b5a 50%,#777d87)",
};
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
  const preview = useBackgroundImage(value, backgroundPath, backgroundRevision);
  return (
    <div className="background-row">
      <div className={visuallyDisabled ? "option-label-disabled" : undefined}>
        <strong>Background</strong>
        <p>Choose a backdrop for your video</p>
      </div>
      <Popover open={open} onOpenChange={setOpen}>
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
        >
          <ScrollArea
            className="background-scroll"
            overscrollContain
            scrollFade
            scrollbarClassName="hidden"
          >
            <div
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
              {(
                Object.keys(backgroundCss) as (keyof typeof backgroundCss)[]
              ).map((preset) => (
                <Button
                  key={preset}
                  variant="outline"
                  className={`background-tile gradient-tile ${value.type === "gradient" && value.preset === preset ? "selected" : ""}`}
                  style={{ background: backgroundCss[preset] }}
                  aria-label={`${preset} background`}
                  aria-pressed={
                    value.type === "gradient" && value.preset === preset
                  }
                  onClick={() => {
                    onChange({ type: "gradient", preset });
                    setOpen(false);
                  }}
                >
                  {value.type === "gradient" && value.preset === preset && (
                    <Icon name="check" className="tile-icon" />
                  )}
                </Button>
              ))}
              {wallpapers.map((wallpaper) => (
                <Button
                  key={wallpaper.id}
                  variant="outline"
                  className={`background-tile ${value.type === "embeddedImage" && value.preset === wallpaper.id ? "selected" : ""}`}
                  aria-label={`${wallpaper.label} background`}
                  aria-pressed={
                    value.type === "embeddedImage" &&
                    value.preset === wallpaper.id
                  }
                  onClick={() => {
                    void onPreset(wallpaper.id);
                    setOpen(false);
                  }}
                >
                  <img
                    src={`/wallpapers/thumbs/${wallpaper.id}`}
                    alt=""
                    loading="lazy"
                  />
                  {value.type === "embeddedImage" &&
                    value.preset === wallpaper.id && (
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
