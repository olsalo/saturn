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
import {
  aomSourcesReady,
  aomVersion,
  aomSHA,
  aomOptions,
} from "./prepare-aom.mjs";

import {
  prepareWebCodecs,
  webSourcesReady,
  webLibraries,
} from "./prepare-web-codecs.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
const version = "8.0.1";
const sourceSHA =
  "05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41";
// External codecs are permissive libaom, libvpx and Opus. No GPL/nonfree components.
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
  "--enable-ffprobe",
  "--disable-x86asm",
  "--enable-ffmpeg",
  "--enable-videotoolbox",
  "--enable-libaom",
  "--enable-libvpx",
  "--enable-libopus",
  "--enable-audiotoolbox",
  "--enable-protocol=file,pipe",
  "--enable-demuxer=mov,matroska",
  "--enable-indev=lavfi",
  "--enable-muxer=mp4,webm,null,rawvideo",
  "--enable-decoder=prores,h264,hevc,aac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,rawvideo,wrapped_avframe,libaom_av1,libvpx_vp9,opus",
  "--enable-encoder=hevc_videotoolbox,h264_videotoolbox,libaom_av1,libvpx_vp9,libopus,aac_at,wrapped_avframe,rawvideo",
  "--enable-parser=h264,hevc,aac,av1,vp9,opus",
  "--enable-filter=scale,format,fps,aresample,aformat,anull,null,color,psnr",
  "--extra-cflags=-mmacosx-version-min=15.0",
  "--extra-ldflags=-mmacosx-version-min=15.0",
];

async function digest(file) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest("hex");
}
function run(command, args, cwd, env = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: { ...process.env, ...env },
      stdio: "inherit",
    });
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
  const probeDestination = path.join(
    root,
    "src-tauri/binaries",
    `ffprobe-${target}`,
  );
  const notices = path.join(root, "public/legal/ffmpeg");
  const archiveName = `ffmpeg-${version}.tar.xz`;
  const archive = path.join(notices, archiveName);
  const key = JSON.stringify({
    version,
    sourceSHA,
    configure,
    target,
    aomVersion,
    aomSHA,
    aomOptions,
    webLibraries,
  });
  let ready = false;
  try {
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    ready =
      manifest.key === key &&
      manifest.binarySHA === (await digest(destination)) &&
      manifest.probeSHA === (await digest(probeDestination)) &&
      sourceSHA === (await digest(archive)) &&
      (await aomSourcesReady()) &&
      (await webSourcesReady());
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
    const { prefix, pkgconf, pkgConfigPath } = await prepareWebCodecs();
    const buildConfigure = configure
      .map((option) =>
        option.startsWith("--extra-cflags=")
          ? `${option} -I${prefix}/include`
          : option.startsWith("--extra-ldflags=")
            ? `${option} -L${prefix}/lib`
            : option,
      )
      .concat([`--pkg-config=${pkgconf}`, "--pkg-config-flags=--static"]);
    const buildEnv = { PKG_CONFIG_LIBDIR: pkgConfigPath };
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
        `Building FFmpeg ${version} for ${target} (LGPL with BSD AV1/VP9/Opus libraries)…`,
      );
      await run(
        "/bin/sh",
        ["./configure", ...buildConfigure],
        source,
        buildEnv,
      );
      await run(
        "/usr/bin/make",
        [
          "-j",
          String(Math.min(8, os.availableParallelism())),
          "ffmpeg",
          "ffprobe",
        ],
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
          `First build libaom, libvpx and Opus using their adjacent BUILD.txt files. Set PKG_CONFIG_PATH to all three lib/pkgconfig directories (colon-separated), and use pkgconf 2.3.0 or compatible.\n` +
          `tar -xf ${archiveName}\ncd ffmpeg-${version}\n./configure ${configure.join(" ")} --pkg-config-flags=--static\nmake -j8 ffmpeg ffprobe\n` +
          `No patches. Linked statically with libaom, libvpx and Opus; their complete source, copyright and patent notices accompany this file in adjacent directories. See scripts/prepare-ffmpeg.mjs for packaging.\n`,
      );
      await mkdir(path.dirname(destination), { recursive: true });
      await copyFile(path.join(source, "ffmpeg"), `${destination}.next`);
      await chmod(`${destination}.next`, 0o755);
      await rename(`${destination}.next`, destination);
      await copyFile(path.join(source, "ffprobe"), `${probeDestination}.next`);
      await chmod(`${probeDestination}.next`, 0o755);
      await rename(`${probeDestination}.next`, probeDestination);
      await writeFile(
        manifestPath,
        JSON.stringify({
          key,
          binarySHA: await digest(destination),
          probeSHA: await digest(probeDestination),
        }) + "\n",
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
