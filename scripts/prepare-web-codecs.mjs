import { access, copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { download, sha, run, prepareAom } from "./prepare-aom.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
const tools = path.join(root, "src-tauri/target/encoder-tools");
export const webLibraries = [
  {
    name: "libvpx",
    version: "1.16.0",
    sha: "7a479a3c66b9f5d5542a4c6a1b7d3768a983b1e5c14c60a9396edc9b649e015c",
    url: "https://github.com/webmproject/libvpx/archive/refs/tags/v1.16.0.tar.gz",
    library: "libvpx.a",
    notices: ["LICENSE", "PATENTS", "AUTHORS"],
  },
  {
    name: "opus",
    version: "1.6.1",
    sha: "6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1",
    url: "https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz",
    library: "libopus.a",
    notices: ["COPYING"],
  },
];
export async function webSourcesReady() {
  try {
    for (const lib of webLibraries) {
      const dir = path.join(root, "public/legal", lib.name);
      if (
        (await sha(path.join(dir, `${lib.name}-${lib.version}.tar.gz`))) !==
        lib.sha
      )
        return false;
      for (const name of [...lib.notices, "BUILD.txt"])
        await access(path.join(dir, name));
    }
    return true;
  } catch {
    return false;
  }
}
export async function prepareWebCodecs() {
  const aom = await prepareAom();
  const prefixes = [aom.prefix];
  const jobs = String(Math.min(8, os.availableParallelism()));
  for (const lib of webLibraries) {
    const notices = path.join(root, "public/legal", lib.name);
    const archive = path.join(notices, `${lib.name}-${lib.version}.tar.gz`);
    await download(archive, lib.url, lib.sha);
    const prefix = path.join(
      tools,
      `${lib.name}-${lib.version}-${process.arch}`,
    );
    const source = path.join(tools, `${lib.name}-${lib.version}`);
    const options =
      lib.name === "libvpx"
        ? [
            `--prefix=${prefix}`,
            "--disable-shared",
            "--enable-static",
            "--enable-pic",
            "--disable-vp8",
            "--disable-examples",
            "--disable-tools",
            "--disable-docs",
            "--disable-unit-tests",
            ...(process.arch === "x64"
              ? ["--target=generic-gnu"]
              : ["--target=arm64-darwin24-gcc"]),
            "--extra-cflags=-mmacosx-version-min=15.0",
          ]
        : [
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
            "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
            "-DCMAKE_INSTALL_LIBDIR=lib",
            `-DCMAKE_INSTALL_PREFIX=${prefix}`,
            "-DOPUS_BUILD_TESTING=OFF",
            "-DOPUS_BUILD_PROGRAMS=OFF",
            "-DOPUS_INSTALL_PKG_CONFIG_MODULE=ON",
          ];
    const key = JSON.stringify({ ...lib, options, arch: process.arch });
    const stamp = path.join(prefix, "saturn-build.json");
    const library = path.join(prefix, "lib", lib.library);
    let ready = false;
    try {
      const saved = JSON.parse(await readFile(stamp, "utf8"));
      ready = saved.key === key && saved.sha === (await sha(library));
    } catch {
      /* First build. */
    }
    if (!ready) {
      await mkdir(prefix, { recursive: true });
      await run("/usr/bin/tar", ["-xf", archive, "-C", tools]);
      if (lib.name === "libvpx") {
        await run("/bin/sh", ["./configure", ...options], source);
        await run("/usr/bin/make", ["-j", jobs, "install"], source);
      } else {
        const build = path.join(tools, `opus-build-${process.arch}`);
        await run(aom.cmake, ["-S", source, "-B", build, ...options]);
        await run(aom.cmake, ["--build", build, "--parallel", jobs]);
        await run(aom.cmake, ["--install", build]);
      }
      await writeFile(
        stamp,
        JSON.stringify({ key, sha: await sha(library) }) + "\n",
      );
    }
    for (const name of lib.notices)
      await copyFile(path.join(source, name), path.join(notices, name));
    await writeFile(
      path.join(notices, "BUILD.txt"),
      `Unmodified ${lib.name} ${lib.version}.\nSource: ${lib.url}\nSHA-256: ${lib.sha}\n` +
        `Complete source is included alongside this file. Build with Apple command-line tools; Opus also requires CMake.\n` +
        `Configure options used: ${options.join(" ")}\n` +
        (lib.name === "libvpx"
          ? "./configure [options above]\nmake -j8 install\n"
          : "cmake -S . -B build [options above]\ncmake --build build --parallel 8\ncmake --install build\n") +
        "The installation prefix can be changed to a local staging directory. Link the resulting static library into FFmpeg using its pkg-config file.\n",
    );
    prefixes.push(prefix);
  }
  return {
    ...aom,
    pkgConfigPath: prefixes.map((p) => path.join(p, "lib/pkgconfig")).join(":"),
    prefixes,
  };
}
