import { useEffect, useRef, useState } from "react";
import { exportLayout, previewCanvasSize } from "@/lib/export-layout";
import Icon from "@/components/ui/icons/icons";
import { asset } from "@/lib/tauri";
import type { Project } from "@/lib/contracts";
import { useBackgroundImage } from "./use-background-image";
export function RecordingPreview({ project }: { project: Project }) {
  const b = project.appearance.background;
  const ref = useRef<HTMLDivElement>(null);
  const [previewWidth, setPreviewWidth] = useState(368);
  useEffect(() => {
    if (!ref.current) return;
    const observer = new ResizeObserver(([entry]) =>
      setPreviewWidth(entry.contentRect.width),
    );
    observer.observe(ref.current);
    return () => observer.disconnect();
  }, []);
  const scale = previewWidth / 2560;
  const fullScreen = project.captureKind === "display";
  const canvas = previewCanvasSize(
    fullScreen ? "original" : project.aspectRatio,
    project.width,
    project.height,
  );
  // Recordly's three shadow layers at 20% intensity, scaled to the preview.
  const shadowScale = previewWidth / canvas.width;
  const shadow = [
    [2.4, 9.6, 0.14],
    [0.8, 3.2, 0.1],
    [0.4, 1.6, 0.06],
  ]
    .map(([offset, blur, alpha]) => `0 ${offset * shadowScale}px ${blur * 2 * shadowScale}px rgba(0, 0, 0, ${alpha})`)
    .join(", ");
  const layout = exportLayout(
    project.width,
    project.height,
    project.appearance.paddingPercent,
    b.type === "none",
    canvas.width,
    canvas.height,
  );
  const background =
    useBackgroundImage(b, project.backgroundPath, project.backgroundRevision) ??
    "#202226";
  return (
    <div
      ref={ref}
      className="recording-preview"
      style={{
        background,
        aspectRatio: `${canvas.width} / ${canvas.height}`,
      }}
      aria-label="Recording appearance preview"
    >
      <div
        className="preview-source"
        style={{
          width: fullScreen ? "100%" : `${layout.width * 100}%`,
          height: fullScreen ? "100%" : `${layout.height * 100}%`,
          borderRadius:
            b.type === "none" ? 0 : project.appearance.cornerRadiusPx * scale,
          backgroundImage: project.thumbnailPath
            ? `url("${asset(project.thumbnailPath)}")`
            : undefined,
          boxShadow:
            project.appearance.shadow && b.type !== "none"
              ? shadow
              : undefined,
        }}
      >
        {!project.thumbnailPath && (
          <div className="preview-unavailable">
            <Icon name="browser" />
            <span>Preview unavailable</span>
          </div>
        )}
      </div>
    </div>
  );
}
