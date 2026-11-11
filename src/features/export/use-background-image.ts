import { useEffect, useState } from "react";
import { asset } from "@/lib/tauri";
import type { Background } from "@/lib/contracts";

const gradients = {
  dawn: "linear-gradient(135deg,#a2b5ee,#d6bfde 50%,#f4c6ac)",
  dusk: "linear-gradient(135deg,#6667ac,#b894ba 50%,#edbdac)",
  mint: "linear-gradient(135deg,#224c4b,#6a9f8c 50%,#d1dfb2)",
  ink: "linear-gradient(135deg,#1a1d24,#424b5a 50%,#777d87)",
};
export function useBackgroundImage(
  value: Background,
  path?: string | null,
  revision?: number | null,
) {
  const url =
    value.type === "embeddedImage"
      ? value.preset
        ? `/wallpapers/${encodeURIComponent(value.preset)}`
        : path
          ? `${asset(path)}?v=${revision ?? 0}`
          : null
      : null;
  const immediate =
    value.type === "gradient"
      ? gradients[value.preset]
      : value.type === "none"
        ? "#202226"
        : null;
  const [loaded, setLoaded] = useState<string | null>(immediate);
  useEffect(() => {
    if (immediate !== null) {
      setLoaded(immediate);
      return;
    }
    if (!url) return;
    let cancelled = false;
    const image = new Image();
    image.onload = () => {
      if (!cancelled) setLoaded(`url("${url}")`);
    };
    image.src = url;
    return () => {
      cancelled = true;
      image.onload = null;
    };
  }, [immediate, url]);
  return immediate ?? loaded;
}
