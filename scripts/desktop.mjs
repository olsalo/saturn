import { spawn, spawnSync } from "node:child_process";
import { access, readFile, writeFile, rename, mkdir } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import {
  captureIdentity,
  prepareCapturePermission,
} from "./desktop-permissions.mjs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launchArguments } from "./desktop-launch.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
const cli = path.join(root, "node_modules/@tauri-apps/cli/tauri.js");

function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: root, stdio: "inherit" });
    const interrupt = () => child.kill("SIGINT");
    process.once("SIGINT", interrupt);
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      process.removeListener("SIGINT", interrupt);
      if (code === 0) resolve();
      else
        reject(
          new Error(
            signal
              ? `Stopped by ${signal}`
              : `${command} exited with code ${code}`,
          ),
        );
    });
  });
}

function ensureStopped() {
  const running = spawnSync("/usr/bin/pgrep", ["-x", "saturn-recorder"], {
    encoding: "utf8",
  });
  if (running.status === 0) {
    throw new Error(
      "Quit Saturn before rebuilding or repairing local-build permissions, then repeat the command. Active recordings and unsaved projects will be kept open.",
    );
  }
  if (running.error || running.status !== 1) {
    throw new Error(
      "Could not check whether Saturn is running. Refusing to change its build or permissions.",
    );
  }
}

function identity(bundle) {
  const result = spawnSync(
    "/usr/bin/codesign",
    ["-d", "--verbose=4", "-r-", bundle],
    { encoding: "utf8" },
  );
  if (result.status !== 0)
    throw new Error("Could not read Saturn's signing identity.");
  return captureIdentity(result.stderr + result.stdout, bundle);
}

try {
  if (process.platform !== "darwin") {
    throw new Error("Recording currently requires macOS 15 or later.");
  }
  const args = process.argv.slice(2);
  if (
    args.some((arg) => !["--rebuild", "--repair-permissions"].includes(arg))
  ) {
    throw new Error(
      "Usage: npm run desktop [-- --rebuild] [--repair-permissions]",
    );
  }
  const target = process.env.CARGO_TARGET_DIR
    ? path.resolve(root, process.env.CARGO_TARGET_DIR)
    : path.join(root, "src-tauri/target");
  const builtBundle = path.join(target, "debug/bundle/macos/Saturn Local.app");
  const bundle = builtBundle;
  const exists = await access(bundle).then(
    () => true,
    () => false,
  );
  const statePath = path.join(
    target,
    "debug",
    ".saturn-local-capture-identity.json",
  );
  let previous = null;
  try {
    previous = JSON.parse(await readFile(statePath, "utf8"));
    if (previous?.version !== 1) previous = null;
  } catch (error) {
    if (error.code !== "ENOENT" && !args.includes("--repair-permissions")) {
      throw new Error(
        "Could not read Saturn's permission identity record. Use --repair-permissions after quitting Saturn to recover it.",
      );
    }
  }
  const repair = args.includes("--repair-permissions");
  // An explicit repair can replace a corrupt/missing record, but only when
  // Saturn is closed. Ordinary launches never clear consent without evidence.
  if (repair) ensureStopped();
  if (!exists || args.includes("--rebuild")) {
    ensureStopped();
    // Also handle the first rebuild after installing this launcher, before any
    // identity record has been written.
    if (exists && !previous) previous = identity(bundle);
    await run(process.execPath, [
      cli,
      "build",
      "--debug",
      "--bundles",
      "app",
      "--config",
      path.join(root, "src-tauri/tauri.local.conf.json"),
    ]);
    await access(bundle);
  } else {
    console.log(
      "Using the existing signed Saturn Local app without rebuilding.",
    );
    console.log("To include code changes, run npm run desktop:build.");
  }
  // Fail before launch if the bundle is still using a linker's temporary identity.
  await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle]);
  const current = identity(bundle);
  const reset = await prepareCapturePermission({
    previous,
    current,
    force: repair,
    ensureStopped,
    reset: (service, identifier) =>
      run("/usr/bin/tccutil", ["reset", service, identifier]),
    remember: async (value) => {
      await mkdir(path.dirname(statePath), { recursive: true });
      const pending = `${statePath}.${randomUUID()}.next`;
      await writeFile(pending, JSON.stringify(value) + "\n", {
        mode: 0o600,
        flag: "wx",
      });
      await rename(pending, statePath);
    },
  });
  if (reset) {
    console.log(
      repair
        ? "Cleared Saturn Local’s Screen Recording decision for the requested repair."
        : "Cleared Saturn Local’s stale Screen Recording decision for the changed build.",
    );
    console.log(
      "Choose a window and approve macOS's prompt once. Reopen Saturn if macOS asks.",
    );
  }
  if (
    previous?.requirement !== current.requirement &&
    current.requirement.startsWith("cdhash ")
  ) {
    console.log(
      "This ad-hoc build has a new signing identity. macOS may require approval once.",
    );
    console.log(
      "Use a stable Apple Development signing certificate via APPLE_SIGNING_IDENTITY to preserve approval across rebuilds.",
    );
  }
  const processes = spawnSync("/bin/ps", ["-axo", "comm="], {
    encoding: "utf8",
  });
  if (processes.status !== 0)
    throw new Error("Could not check which Saturn copy is running.");
  const runningPaths = processes.stdout
    .split("\n")
    .map((line) => line.trim())
    .filter((command) => path.basename(command) === "saturn-recorder");
  // Start the exact app path, and only reuse an instance from that same bundle.
  await run("/usr/bin/open", launchArguments(bundle, runningPaths));
  console.log(`Opened ${bundle}`);
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
