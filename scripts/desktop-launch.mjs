import path from "node:path";

export function launchArguments(bundle, runningPaths) {
  const executable = path.join(bundle, "Contents/MacOS/saturn-recorder");
  const other = runningPaths.find((running) => running !== executable);
  if (other) {
    throw new Error(
      `Another Saturn copy is running from ${other}. Quit it before opening ${bundle}.`,
    );
  }
  return runningPaths.length ? ["-a", bundle] : ["-n", "-a", bundle];
}
