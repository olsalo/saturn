import { describe, expect, it } from "vitest";
import catalog from "./wallpapers.json";
import { wallpaperPresets, wallpaperPresetId } from "./wallpapers";

describe("background collection", () => {
  it("offers one tile for each image, including legacy selections", () => {
    for (const wallpaper of catalog) {
      const selected = wallpaperPresetId(wallpaper.id);
      expect(
        wallpaperPresets.filter((item) => item.id === selected),
      ).toHaveLength(1);
    }
    expect(wallpaperPresets).toHaveLength(catalog.length - 5);
  });

  it("maps duplicate IDs from saved projects to their visible tiles", () => {
    expect(wallpaperPresetId("wallpaper1.jpg")).toBe("ventura-dark.jpg");
    expect(wallpaperPresetId("wallpaper2.jpg")).toBe("sequoia-blue-orange.jpg");
    expect(wallpaperPresetId("wallpaper9.jpg")).toBe("sonoma-light.jpg");
    expect(wallpaperPresetId("wallpaper11.jpg")).toBe(
      "sequoia-blue-orange.jpg",
    );
    expect(wallpaperPresetId("wallpaper12.jpg")).toBe("sequoia-blue.jpg");
    expect(wallpaperPresetId("removed.jpg")).toBe("removed.jpg");
  });
});
