import { readdir, readFile, mkdir, writeFile, unlink } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const wallpapers = path.join(root, "public/wallpapers");
const catalogPath = path.join(root, "src/lib/wallpapers.json");
const previous = JSON.parse(await readFile(catalogPath, "utf8"));
const existing = new Map(previous.map((item) => [item.id, item]));
const found = new Map();

const folders = (await readdir(wallpapers, { withFileTypes: true }))
  .filter((entry) => entry.isDirectory() && entry.name !== "thumbs")
  .sort((a, b) => a.name.localeCompare(b.name));
for (const folder of folders) {
  const dir = path.join(wallpapers, folder.name);
  for (const file of (await readdir(dir, { withFileTypes: true }))
    .filter((entry) => entry.isFile() && /\.(jpe?g|png)$/i.test(entry.name))
    .sort((a, b) => a.name.localeCompare(b.name))) {
    if (found.has(file.name))
      throw new Error(`Duplicate wallpaper ID: ${file.name}`);
    const item = existing.get(file.name) ?? {
      id: file.name,
      label: path
        .parse(file.name)
        .name.replace(/[-_]+/g, " ")
        .replace(/\b\w/g, (c) => c.toUpperCase()),
    };
    const bytes = await readFile(path.join(dir, file.name));
    const sha = createHash("sha1")
      .update(`blob ${bytes.length}\0`)
      .update(bytes)
      .digest("hex");
    found.set(file.name, {
      ...item,
      sha,
      bytes: bytes.length,
      path: `${folder.name}/${file.name}`,
    });
  }
}
if (!found.size) throw new Error("No wallpapers found");

for (const item of found.values()) {
  const [folder, filename] = item.path.split("/");
  const output = path.join(wallpapers, folder, "thumbs", filename);
  await mkdir(path.dirname(output), { recursive: true });
  execFileSync(
    "sips",
    [
      "-Z",
      "320",
      "-s",
      "format",
      filename.toLowerCase().endsWith(".png") ? "png" : "jpeg",
      "-s",
      "formatOptions",
      "75",
      path.join(wallpapers, item.path),
      "--out",
      output,
    ],
    { stdio: "ignore" },
  );
}
const ordered = [...found.values()].sort((a, b) =>
  a.path.localeCompare(b.path, "en", { numeric: true, sensitivity: "base" }),
);
await writeFile(catalogPath, `${JSON.stringify(ordered, null, 2)}\n`);
let removed = 0;
for (const folder of folders) {
  const thumbDir = path.join(wallpapers, folder.name, "thumbs");
  const entries = await readdir(thumbDir, { withFileTypes: true }).catch(
    (error) => {
      if (error.code === "ENOENT") return [];
      throw error;
    },
  );
  for (const entry of entries) {
    if (
      entry.isFile() &&
      /\.(jpe?g|png)$/i.test(entry.name) &&
      found.get(entry.name)?.path !== `${folder.name}/${entry.name}`
    ) {
      await unlink(path.join(thumbDir, entry.name));
      removed++;
    }
  }
}
console.log(
  `Generated ${ordered.length} wallpaper thumbnails, removed ${removed} obsolete thumbnails, and updated the catalog.`,
);
