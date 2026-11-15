import { useEffect, useRef } from "react";
import { api, native } from "@/lib/tauri";

export function useWindowReady(ready: boolean) {
  const shown = useRef(false);
  useEffect(() => {
    if (!native || !ready || shown.current) return;
    let cancelled = false;
    void (async () => {
      await document.fonts.ready;
      if (cancelled) return;
      // React has committed the hydrated screen, including footer portals.
      // Flush layout before revealing it. Hidden WKWebViews can suspend animation
      // frames, so waiting for requestAnimationFrame here can deadlock startup.
      document.getElementById("root")?.getBoundingClientRect();
      await api.frontendReady();
      shown.current = true;
    })().catch((error) => console.error("Could not show Saturn", error));
    return () => {
      cancelled = true;
    };
  }, [ready]);
}
