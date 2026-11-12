import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { spawn } from "node:child_process";
import {
  access,
  copyFile,
  mkdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
export const aomVersion = "3.15.1";
export const aomSHA =
  "8ca0c52746174603500f0adb6f2a215d69c9ca2aab2acb3caa06fb791d8d01bf";
export const aomOptions = [
  "-DCMAKE_BUILD_TYPE=Release",
  "-DBUILD_SHARED_LIBS=OFF",
  "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
  "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
  "-DCMAKE_INSTALL_LIBDIR=lib",
  "-DENABLE_TESTS=OFF",
  "-DENABLE_EXAMPLES=OFF",
  "-DENABLE_TOOLS=OFF",
  "-DENABLE_DOCS=OFF",
];
const tools = path.join(root, "src-tauri/target/encoder-tools");
const notices = path.join(root, "public/legal/libaom");
export async function sha(file) {
  const hash = createHash("sha256");
  for await (const data of createReadStream(file)) hash.update(data);
  return hash.digest("hex");
}
export function run(command, args, cwd, env = {}) {
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
export async function download(file, url, checksum) {
  if ((await sha(file).catch(() => null)) === checksum) return;
  await mkdir(path.dirname(file), { recursive: true });
  await run("/usr/bin/curl", [
    "--fail",
    "--location",
    "--retry",
    "3",
    "--max-time",
    "180",
    "--output",
    `${file}.next`,
    url,
  ]);
  if ((await sha(`${file}.next`)) !== checksum)
    throw new Error(`Checksum mismatch: ${url}`);
  await copyFile(`${file}.next`, file);
  await rm(`${file}.next`);
}

export async function aomSourcesReady() {
  try {
    for (const name of ["LICENSE", "PATENTS", "AUTHORS", "BUILD.txt"])
      await access(path.join(notices, name));
    return (
      (await sha(path.join(notices, `libaom-${aomVersion}.tar.gz`))) === aomSHA
    );
  } catch {
    return false;
  }
}

export async function prepareAom() {
  await mkdir(tools, { recursive: true });
  const cmakeArchive = path.join(tools, "downloads/cmake-3.31.6.tar.gz");
  await download(
    cmakeArchive,
    "https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-macos-universal.tar.gz",
    "330b9514f5112e5ed4fb08b8b05803b776fd9b539a6ae12927d14dcc0ee2ba8d",
  );
  const cmake = path.join(
    tools,
    "cmake-3.31.6-macos-universal/CMake.app/Contents/bin/cmake",
  );
  if (
    !(await access(cmake).then(
      () => true,
      () => false,
    ))
  )
    await run("/usr/bin/tar", ["-xf", cmakeArchive, "-C", tools]);
  const pkgArchive = path.join(tools, "downloads/pkgconf-2.3.0.tar.xz");
  await download(
    pkgArchive,
    "https://distfiles.dereferenced.org/pkgconf/pkgconf-2.3.0.tar.xz",
    "3a9080ac51d03615e7c1910a0a2a8df08424892b5f13b0628a204d3fcce0ea8b",
  );
  const pkgconf = path.join(tools, "pkgconf/bin/pkgconf");
  const jobs = String(Math.min(8, os.availableParallelism()));
  if (
    !(await access(pkgconf).then(
      () => true,
      () => false,
    ))
  ) {
    await run("/usr/bin/tar", ["-xf", pkgArchive, "-C", tools]);
    const source = path.join(tools, "pkgconf-2.3.0");
    await run(
      "/bin/sh",
      [
        "./configure",
        `--prefix=${path.join(tools, "pkgconf")}`,
        "--disable-shared",
        "--enable-static",
      ],
      source,
    );
    await run("/usr/bin/make", ["-j", jobs, "install"], source);
  }
  const archive = path.join(notices, `libaom-${aomVersion}.tar.gz`);
  await download(
    archive,
    `https://storage.googleapis.com/aom-releases/libaom-${aomVersion}.tar.gz`,
    aomSHA,
  );
  const prefix = path.join(tools, `aom-${aomVersion}-${process.arch}`);
  const stamp = path.join(prefix, "saturn-build.json");
  // Generic x86 build avoids requiring a separate NASM installation.
  const options =
    process.arch === "x64"
      ? [...aomOptions, "-DAOM_TARGET_CPU=generic"]
      : aomOptions;
  const key = JSON.stringify({ aomSHA, options, arch: process.arch });
  const library = path.join(prefix, "lib/libaom.a");
  let ready = false;
  try {
    const saved = JSON.parse(await readFile(stamp, "utf8"));
    ready =
      saved.key === key &&
      saved.sha === (await sha(library)) &&
      (await aomSourcesReady());
  } catch {
    /* Build on the first run. */
  }
  if (!ready) {
    await run("/usr/bin/tar", ["-xf", archive, "-C", tools]);
    const source = path.join(tools, `libaom-${aomVersion}`);
    const build = path.join(tools, `aom-build-${process.arch}`);
    await run(cmake, [
      "-S",
      source,
      "-B",
      build,
      `-DCMAKE_INSTALL_PREFIX=${prefix}`,
      ...options,
    ]);
    await run(cmake, ["--build", build, "--parallel", jobs]);
    await run(cmake, ["--install", build]);
    for (const name of ["LICENSE", "PATENTS", "AUTHORS"])
      await copyFile(path.join(source, name), path.join(notices, name));
    await writeFile(
      path.join(notices, "BUILD.txt"),
      `Unmodified libaom ${aomVersion}, BSD-2-Clause with separate patent terms.\n` +
        `Source: https://storage.googleapis.com/aom-releases/libaom-${aomVersion}.tar.gz\nSHA-256: ${aomSHA}\n` +
        `Complete source is included alongside this file. With CMake 3.31.6 and Apple command-line tools:\n` +
        `tar -xf libaom-${aomVersion}.tar.gz\ncmake -S libaom-${aomVersion} -B build -DCMAKE_INSTALL_PREFIX="$PWD/aom-install" ${options.join(" ")}\n` +
        `cmake --build build --parallel 8\ncmake --install build\n` +
        `Saturn's build bootstraps CMake and pkgconf locally; neither build tool is bundled in the app.\n`,
    );
    await writeFile(
      stamp,
      JSON.stringify({ key, sha: await sha(library) }) + "\n",
    );
  }
  return { prefix, pkgconf, cmake };
}
