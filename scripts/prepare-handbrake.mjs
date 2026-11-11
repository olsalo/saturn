import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import {
  access,
  chmod,
  copyFile,
  mkdir,
  mkdtemp,
  rename,
  rm,
} from "node:fs/promises";
import { spawn } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const version = "1.11.2";
const archiveSHA =
  "14463aa81038aaa3ce421dc6cee65fd6c82fdabda040931541ccca38939299fa";
const binarySHA =
  "74f79497a96cd996032bafc562a978f69af9a94ec0c99e55ed9de93596987d0b";
async function digest(file) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest("hex");
}
function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: "inherit" });
    child.once("error", reject);
    child.once("exit", (code) =>
      code === 0
        ? resolve()
        : reject(new Error(`${command} exited with ${code}`)),
    );
  });
}
try {
  if (process.platform !== "darwin" || !["arm64", "x64"].includes(process.arch))
    throw new Error("The bundled encoder currently supports macOS arm64/x64.");
  const target =
    process.arch === "arm64" ? "aarch64-apple-darwin" : "x86_64-apple-darwin";
  const destination = path.join(
    root,
    "src-tauri",
    "binaries",
    `HandBrakeCLI-${target}`,
  );
  const exists = await access(destination).then(
    () => true,
    () => false,
  );
  if (exists && (await digest(destination)) === binarySHA) {
    console.log(`HandBrakeCLI ${version} is ready (verified SHA-256).`);
  } else {
    const temporary = await mkdtemp(path.join(os.tmpdir(), "saturn-encoder-"));
    const mount = path.join(temporary, "volume");
    let mounted = false;
    try {
      const archive = path.join(temporary, "HandBrakeCLI.dmg");
      console.log(`Downloading official HandBrakeCLI ${version}…`);
      await run("/usr/bin/curl", [
        "--fail",
        "--location",
        "--retry",
        "2",
        "--max-time",
        "180",
        "--output",
        archive,
        `https://github.com/HandBrake/HandBrake/releases/download/${version}/HandBrakeCLI-${version}.dmg`,
      ]);
      if ((await digest(archive)) !== archiveSHA)
        throw new Error("HandBrake archive checksum mismatch.");
      await run("/usr/bin/hdiutil", [
        "attach",
        archive,
        "-nobrowse",
        "-readonly",
        "-mountpoint",
        mount,
      ]);
      mounted = true;
      const binary = path.join(mount, "HandBrakeCLI");
      if ((await digest(binary)) !== binarySHA)
        throw new Error("HandBrake binary checksum mismatch.");
      await mkdir(path.dirname(destination), { recursive: true });
      const pending = `${destination}.next`;
      await copyFile(binary, pending);
      await chmod(pending, 0o755);
      await rename(pending, destination);
      const notices = path.join(root, "public", "legal", "handbrake");
      await mkdir(notices, { recursive: true });
      for (const name of ["LICENSE", "COPYING", "AUTHORS.markdown"])
        await copyFile(path.join(mount, "doc", name), path.join(notices, name));
      console.log(`HandBrakeCLI ${version} installed for ${target}.`);
    } finally {
      if (mounted) await run("/usr/bin/hdiutil", ["detach", mount, "-quiet"]);
      await rm(temporary, { recursive: true, force: true });
    }
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
