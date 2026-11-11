import { readFile, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const logo = await readFile(path.join(root, "public/saturn-logo.svg"), "utf8");
const artwork = logo
  .replace(/<svg\b[^>]*>/, "")
  .replace(/<\/svg>\s*$/, "")
  .replace(/\s*<title>.*?<\/title>/, "")
  .trim();
const source = `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <title>Saturn</title>
  <rect x="64" y="64" width="896" height="896" rx="200" fill="#fff"/>
  <g transform="translate(176 176) scale(28)" color="#262626" fill="currentColor">
${artwork}
  </g>
</svg>
`;

await writeFile(path.join(root, "src-tauri/icons/source.svg"), source);
await writeFile(path.join(root, "public/favicon.svg"), source);
const result = spawnSync(
  process.execPath,
  ["node_modules/@tauri-apps/cli/tauri.js", "icon", "src-tauri/icons/source.svg"],
  { cwd: root, stdio: "inherit" },
);
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
