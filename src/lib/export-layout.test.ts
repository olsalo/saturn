import { expect, test } from "vitest";
import { exportLayout, previewCanvasSize } from "./export-layout";
test("16:10 preview uses linked 38% padding", () => {
  const rect = exportLayout(640, 400);
  expect(rect.width).toBeCloseTo(0.848);
  expect(rect.height).toBeCloseTo(0.848);
  expect((1 - rect.width) / 2).toBeCloseTo(0.076);
  expect((1 - rect.height) / 2).toBeCloseTo(0.076);
});
test("wide and portrait footage stay contained at their original aspect ratio", () => {
  for (const [width, height] of [
    [1600, 900],
    [400, 640],
  ]) {
    const rect = exportLayout(width, height);
    expect(rect.width).toBeLessThanOrEqual(0.848 + Number.EPSILON);
    expect(rect.height).toBeLessThanOrEqual(0.848 + Number.EPSILON);
    expect((rect.width * 2560) / (rect.height * 1600)).toBeCloseTo(
      width / height,
    );
  }
  expect(exportLayout(640, 400, 38, true)).toEqual({ width: 1, height: 1 });
});

test("preview canvas uses the selected shape regardless of export pixel rounding", () => {
  const sourceWidth = 1366;
  const sourceHeight = 768;
  expect(previewCanvasSize("16:10", sourceWidth, sourceHeight)).toEqual({
    width: 16,
    height: 10,
  });
  expect(previewCanvasSize("9:16", sourceWidth, sourceHeight)).toEqual({
    width: 9,
    height: 16,
  });
  expect(previewCanvasSize("original", sourceWidth, sourceHeight)).toEqual({
    width: sourceWidth,
    height: sourceHeight,
  });
});
