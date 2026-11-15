const bundleID = "com.saturn.recorder.local";

export function captureIdentity(signature, bundle) {
  const requirement = signature.match(/^#?\s*designated => (.+)$/m)?.[1];
  if (
    !signature.includes(`Identifier=${bundleID}\n`) ||
    signature.includes("Info.plist=not bound") ||
    !requirement
  ) {
    throw new Error(
      "Saturn's app signature is invalid. Refusing to launch a build with the wrong privacy identity.",
    );
  }
  const cdhash = signature.match(/^CDHash=(.+)$/m)?.[1] ?? null;
  return { version: 1, bundle, requirement, cdhash };
}

// Repair stale ad-hoc grants once per changed local build. A later launch of
// that same build must preserve the newly approved decision.
export async function prepareCapturePermission({
  previous,
  current,
  force = false,
  ensureStopped,
  reset,
  remember,
}) {
  const changed =
    typeof previous?.requirement === "string" &&
    previous.requirement !== current.requirement;
  if (force || changed) {
    // Never revoke consent or restart the app during an active recording.
    ensureStopped();
    await reset("ScreenCapture", bundleID);
  }
  // Remember only after a successful reset. A failed reset must be retried.
  await remember(current);
  return force || changed;
}
