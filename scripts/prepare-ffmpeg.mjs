import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { createReadStream } from "node:fs";
import {
  access,
  chmod,
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const version = "8.0.1";
const sourceSHA =
  "05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41";
// No external libraries, GPL components, network protocols or nonfree options.
// FFmpeg's static libraries form a separate LGPL CLI, not part of Saturn.
const configure = [
  "--disable-autodetect",
  "--disable-everything",
  "--disable-network",
  "--disable-doc",
  "--disable-debug",
  "--disable-shared",
  "--enable-static",
  "--disable-ffplay",
  "--disable-ffprobe",
  "--disable-x86asm",
  "--enable-ffmpeg",
  "--enable-videotoolbox",
  "--enable-audiotoolbox",
  "--enable-protocol=file,pipe",
  "--enable-demuxer=mov,lavfi",
  "--enable-indev=lavfi",
  "--enable-muxer=mp4,null",
  "--enable-decoder=prores,h264,hevc,aac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,rawvideo,wrapped_avframe",
  "--enable-encoder=hevc_videotoolbox,aac_at,wrapped_avframe",
  "--enable-parser=h264,hevc,aac",
  "--enable-filter=scale,format,fps,aresample,aformat,anull,null,color",
  "--extra-cflags=-mmacosx-version-min=15.0",
  "--extra-ldflags=-mmacosx-version-min=15.0",
];

async function digest(file) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest("hex");
}
function run(command, args, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, stdio: "inherit" });
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
    throw new Error(
      "Saturn's FFmpeg export currently supports macOS arm64/x64.",
    );
  const target =
    process.arch === "arm64" ? "aarch64-apple-darwin" : "x86_64-apple-darwin";
  const destination = path.join(root, "src-tauri/binaries", `ffmpeg-${target}`);
  const manifestPath = `${destination}.json`;
  const notices = path.join(root, "public/legal/ffmpeg");
  const archiveName = `ffmpeg-${version}.tar.xz`;
  const archive = path.join(notices, archiveName);
  const key = JSON.stringify({ version, sourceSHA, configure, target });
  let ready = false;
  try {
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    ready =
      manifest.key === key &&
      manifest.binarySHA === (await digest(destination)) &&
      sourceSHA === (await digest(archive));
    for (const name of ["COPYING.LGPLv2.1", "LICENSE.md", "BUILD.txt"])
      await access(path.join(notices, name));
  } catch {
    ready = false;
  }
  if (ready) {
    console.log(
      `FFmpeg ${version} is ready (verified binary and source SHA-256).`,
    );
  } else {
    const temporary = await mkdtemp(path.join(os.tmpdir(), "saturn-ffmpeg-"));
    try {
      await mkdir(notices, { recursive: true });
      const cached = await digest(archive).catch(() => null);
      if (cached !== sourceSHA) {
        const pendingArchive = path.join(temporary, archiveName);
        await run("/usr/bin/curl", [
          "--fail",
          "--location",
          "--retry",
          "3",
          "--max-time",
          "180",
          "--output",
          pendingArchive,
          `https://ffmpeg.org/releases/${archiveName}`,
        ]);
        if ((await digest(pendingArchive)) !== sourceSHA)
          throw new Error("FFmpeg source checksum mismatch.");
        await copyFile(pendingArchive, archive);
      }
      await run("/usr/bin/tar", ["-xf", archive, "-C", temporary]);
      const source = path.join(temporary, `ffmpeg-${version}`);
      console.log(
        `Building FFmpeg ${version} for ${target} (LGPL, system frameworks only)…`,
      );
      await run("/bin/sh", ["./configure", ...configure], source);
      await run(
        "/usr/bin/make",
        ["-j", String(Math.min(8, os.availableParallelism())), "ffmpeg"],
        source,
      );
      for (const name of ["COPYING.LGPLv2.1", "LICENSE.md"])
        await copyFile(path.join(source, name), path.join(notices, name));
      await writeFile(
        path.join(notices, "BUILD.txt"),
        `FFmpeg ${version}, an unmodified, separate LGPL-2.1-or-later executable bundled with Saturn.\n` +
          `Source: https://ffmpeg.org/releases/${archiveName}\nSHA-256: ${sourceSHA}\n` +
          `The complete corresponding source is included here as ${archiveName}.\n` +
          `Build on macOS 15+ with Apple command-line tools for the target architecture:\n` +
          `tar -xf ${archiveName}\ncd ffmpeg-${version}\n./configure ${configure.join(" ")}\nmake -j8 ffmpeg\n` +
          `No patches or external libraries. See scripts/prepare-ffmpeg.mjs for packaging.\n`,
      );
      await mkdir(path.dirname(destination), { recursive: true });
      await copyFile(path.join(source, "ffmpeg"), `${destination}.next`);
      await chmod(`${destination}.next`, 0o755);
      await rename(`${destination}.next`, destination);
      await writeFile(
        manifestPath,
        JSON.stringify({ key, binarySHA: await digest(destination) }) + "\n",
      );
      console.log(
        `FFmpeg ${version} installed with corresponding source and build instructions.`,
      );
    } finally {
      await rm(temporary, { recursive: true, force: true });
    }
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
