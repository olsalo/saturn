import catalog from "./wallpapers.json";

// Keep legacy IDs in the catalog for saved projects, but offer each image once.
export const wallpaperPresets = catalog.filter((item) => !item.duplicateOf);

export function wallpaperPresetId(id: string) {
  return catalog.find((item) => item.id === id)?.duplicateOf ?? id;
}
