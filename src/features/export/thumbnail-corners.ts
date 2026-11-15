/** Measure the minimum source-pixel mask covering the recorded corner matte.
 * Use the same radius at all four corners, as the native export does, so a
 * bright edge can also protect a corner with a dark or variable window border.
 * The thumbnail's pixels remain unchanged.
 */
export function thumbnailCornerRadius(
  pixels: Uint8ClampedArray,
  width: number,
  height: number,
) {
  // Native corner radii stay fixed as a window gets smaller. Leave enough
  // room to sample the straight edge beyond the curve even in small captures.
  const reach = Math.min(128, Math.floor(Math.min(width, height) / 3));
  if (reach < 8) return 0;
  let radius = 0;
  for (const [right, bottom] of [
    [false, false],
    [true, false],
    [false, true],
    [true, true],
  ]) {
    const index = (x: number, y: number) =>
      ((bottom ? height - 1 - y : y) * width + (right ? width - 1 - x : x)) * 4;
    const seed = index(0, 0);
    if (
      pixels[seed + 3] < 250 ||
      Math.max(pixels[seed], pixels[seed + 1], pixels[seed + 2]) > 40
    )
      continue;
    // Sample the straight horizontal window edge, beyond its corner curve.
    const samples = Array.from(
      { length: reach - Math.floor((reach * 3) / 4) },
      (_, n) => index(Math.floor((reach * 3) / 4) + n, 0),
    );
    const reference = [0, 1, 2].map((channel) => {
      const values = samples
        .map((i) => pixels[i + channel])
        .sort((a, b) => a - b);
      return values[Math.floor(values.length / 2)];
    });
    if (
      Math.max(...reference) < 32 ||
      samples.some((i) =>
        reference.some((v, c) => Math.abs(pixels[i + c] - v) > 20),
      )
    )
      continue;
    const norm = reference.reduce((sum, v) => sum + v * v, 0);
    const alphaAt = (i: number) =>
      reference.reduce((sum, v, c) => sum + pixels[i + c] * v, 0) / norm;
    // Dark window chrome is valid too; require contrast with its matte rather
    // than rejecting the whole corner simply because the border is dark.
    if (alphaAt(seed) >= 0.5) continue;
    // A bounded corner must become opaque on both straight edges. Never erase
    // an intentional black panel that extends beyond the corner neighborhood.
    if (
      alphaAt(index(reach - 1, 0)) < 0.94 ||
      alphaAt(index(0, reach - 1)) < 0.94
    )
      continue;
    const visited = new Uint8Array(reach * reach);
    const pending = [[0, 0]];
    let bounded = true;
    let candidate = 0;
    while (pending.length) {
      const [x, y] = pending.pop()!;
      if (x < 0 || y < 0 || x >= reach || y >= reach || visited[y * reach + x])
        continue;
      visited[y * reach + x] = 1;
      const i = index(x, y);
      const alpha = alphaAt(i);
      if (
        alpha >= 0.94 ||
        pixels[i + 3] < 250 ||
        reference.some((v, c) => Math.abs(pixels[i + c] - v * alpha) > 16)
      )
        continue;
      if (x === reach - 1 || y === reach - 1) {
        bounded = false;
        break;
      }
      // Match the native export mask, including antialiasing/resampling fringe.
      const px = x + 1,
        py = y + 1;
      candidate = Math.max(candidate, px + py + Math.sqrt(2 * px * py) + 1);
      pending.push([x + 1, y], [x - 1, y], [x, y + 1], [x, y - 1]);
    }
    if (!bounded || candidate > reach) continue;
    radius = Math.max(radius, candidate);
  }
  return radius;
}
