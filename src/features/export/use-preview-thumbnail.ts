import { useEffect, useState } from "react";
import { asset } from "@/lib/tauri";
import { thumbnailCornerRadius } from "./thumbnail-corners";

export function usePreviewThumbnail(
  path: string | null,
  windowCapture: boolean,
) {
  const source = asset(path);
  const [processed, setProcessed] = useState<{
    source: string;
    cornerRadius: number;
  } | null>(null);
  useEffect(() => {
    if (!source || !windowCapture) return;
    let disposed = false;
    const image = new Image();
    image.crossOrigin = "anonymous";
    image.onload = () => {
      if (disposed) return;
      try {
        const canvas = document.createElement("canvas");
        // Bound this disposable working copy when opening older projects that
        // stored larger images. New saved JPEGs use the website poster bounds.
        const scale = Math.min(
          1,
          2048 / Math.max(image.naturalWidth, image.naturalHeight),
        );
        canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
        canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
        const context = canvas.getContext("2d");
        if (!context) {
          setProcessed({ source, cornerRadius: 0 });
          return;
        }
        context.drawImage(image, 0, 0, canvas.width, canvas.height);
        const data = context.getImageData(0, 0, canvas.width, canvas.height);
        setProcessed({
          source,
          cornerRadius:
            thumbnailCornerRadius(data.data, canvas.width, canvas.height) /
            canvas.width,
        });
      } catch {
        // Retain the original preview when a source cannot be read or processed.
        setProcessed({ source, cornerRadius: 0 });
      }
    };
    image.onerror = () => {
      if (!disposed) setProcessed({ source, cornerRadius: 0 });
    };
    image.src = source;
    return () => {
      disposed = true;
      image.onload = null;
      image.onerror = null;
    };
  }, [source, windowCapture]);
  if (!windowCapture) return { url: source, cornerRadius: 0 };
  // Do not show an unmasked thumbnail for one frame while its corners load.
  return processed && processed.source === source
    ? { url: source, cornerRadius: processed.cornerRadius }
    : { url: null, cornerRadius: 0 };
}
