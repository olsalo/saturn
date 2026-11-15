import { expect, test } from "vitest";
import { thumbnailCornerRadius } from "./thumbnail-corners";

function thumbnail() {
  const pixels = new Uint8ClampedArray(100 * 80 * 4).fill(255);
  const set = (x: number, y: number, rgb: number, alpha = 255) => {
    pixels.set([rgb, rgb, rgb, alpha], (y * 100 + x) * 4);
  };
  return { pixels, set };
}

test("measures noisy and antialiased matte without changing source pixels", () => {
  const { pixels, set } = thumbnail();
  for (let y = 0; y < 3; y++) for (let x = 0; x < 3; x++) set(x, y, 0);
  set(0, 0, 8); // JPEG noise in an otherwise black corner.
  set(3, 0, 128);
  set(50, 40, 0);
  const original = pixels.slice();
  expect(thumbnailCornerRadius(pixels, 100, 80)).toBeGreaterThan(10);
  expect(pixels).toEqual(original);
});

test("dark borders, existing alpha and unbounded black areas are preserved", () => {
  const dark = new Uint8ClampedArray(100 * 80 * 4);
  for (let i = 3; i < dark.length; i += 4) dark[i] = 255;
  const original = dark.slice();
  expect(thumbnailCornerRadius(dark, 100, 80)).toBe(0);
  expect(dark).toEqual(original);
  const { pixels, set } = thumbnail();
  set(0, 0, 0, 0);
  expect(thumbnailCornerRadius(pixels, 100, 80)).toBe(0);
  expect(pixels[3]).toBe(0);
});

test.each([160, 320, 640])(
  "small %ipx window corners are recovered without clipping interior content",
  (width) => {
    const height = (width * 5) / 8;
    const radius = 24;
    const pixels = new Uint8ClampedArray(width * height * 4).fill(255);
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const cx = Math.min(x + 0.5, width - x - 0.5);
        const cy = Math.min(y + 0.5, height - y - 0.5);
        if (
          cx < radius &&
          cy < radius &&
          Math.hypot(radius - cx, radius - cy) > radius
        ) {
          pixels.set([0, 0, 0, 255], (y * width + x) * 4);
        }
      }
    }
    const center = (Math.floor(height / 2) * width + width / 2) * 4;
    pixels.set([0, 0, 0, 255], center);
    const original = pixels.slice();
    const measured = thumbnailCornerRadius(pixels, width, height);
    expect(measured).toBeGreaterThanOrEqual(radius);
    expect(measured).toBeLessThan(34);
    expect(pixels).toEqual(original);
    // A dark title bar prevents local alpha recovery at the top. The shared
    // mask must still protect all four corners using the bright bottom border.
    const mixed = pixels.slice();
    for (let i = 0; i < width * 30 * 4; i += 4) {
      mixed[i] = Math.min(50, mixed[i]);
      mixed[i + 1] = Math.min(50, mixed[i + 1]);
      mixed[i + 2] = Math.min(50, mixed[i + 2]);
    }
    expect(thumbnailCornerRadius(mixed, width, height)).toBe(measured);
    const darkChrome = pixels.map((channel, i) =>
      i % 4 === 3 ? channel : Math.round(channel * 0.2),
    );
    expect(thumbnailCornerRadius(darkChrome, width, height)).toBe(measured);
    // Every matte pixel must lie outside the measured circular clip, including
    // the fringe. The center must remain inside the mask.
    for (let y = 0; y < radius; y++) {
      for (let x = 0; x < radius; x++) {
        if (pixels[(y * width + x) * 4] !== 0) continue;
        expect(
          Math.hypot(measured - x - 0.5, measured - y - 0.5),
        ).toBeGreaterThan(measured);
      }
    }
    expect([...pixels.slice(center, center + 4)]).toEqual([0, 0, 0, 255]);
  },
);
