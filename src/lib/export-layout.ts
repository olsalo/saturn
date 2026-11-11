export const EXPORT_WIDTH = 2560;
export const EXPORT_HEIGHT = 1600;
export const EXPORT_PADDING = 38;
/** Stable preview shape; encoded dimensions can differ by a pixel after rounding. */
export function previewCanvasSize(
  aspectRatio: string,
  sourceWidth: number,
  sourceHeight: number,
) {
  switch (aspectRatio) {
    case "16:10":
      return { width: 16, height: 10 };
    case "16:9":
      return { width: 16, height: 9 };
    case "9:16":
      return { width: 9, height: 16 };
    case "1:1":
      return { width: 1, height: 1 };
    default:
      return { width: sourceWidth, height: sourceHeight };
  }
}
export function exportLayout(
  width: number,
  height: number,
  paddingPercent = EXPORT_PADDING,
  none = false,
  canvasWidth = EXPORT_WIDTH,
  canvasHeight = EXPORT_HEIGHT,
) {
  const inset = none
    ? 0
    : (Math.min(100, Math.max(0, paddingPercent)) / 100) * 0.2;
  const scale = Math.min(
    (canvasWidth * (1 - 2 * inset)) / width,
    (canvasHeight * (1 - 2 * inset)) / height,
  );
  return {
    width: (width * scale) / canvasWidth,
    height: (height * scale) / canvasHeight,
  };
}
