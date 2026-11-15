import test from "node:test";
import assert from "node:assert/strict";
import { launchArguments } from "./desktop-launch.mjs";
import {
  captureIdentity,
  prepareCapturePermission,
} from "./desktop-permissions.mjs";

const bundle = "/tmp/test/Saturn Local.app";
const signature = (requirement) =>
  `Identifier=com.saturn.recorder.local\nInfo.plist entries=18\n# designated => ${requirement}\n`;
const old = captureIdentity(signature('cdhash H"old"'), bundle);
const updated = captureIdentity(signature('cdhash H"new"'), bundle);
function fixture(previous, current = updated, extra = {}) {
  const calls = [];
  return {
    calls,
    options: {
      previous,
      current,
      ensureStopped() {
        calls.push("stopped");
      },
      async reset(...args) {
        calls.push(args);
      },
      async remember(identity) {
        calls.push(identity);
      },
      ...extra,
    },
  };
}
test("changed local builds reset only the local app before remembering its identity", async () => {
  const f = fixture(old);
  assert.equal(await prepareCapturePermission(f.options), true);
  assert.deepEqual(f.calls, [
    "stopped",
    ["ScreenCapture", "com.saturn.recorder.local"],
    updated,
  ]);
});
test("ordinary relaunch and first launch preserve existing consent", async () => {
  for (const previous of [updated, null]) {
    const f = fixture(previous);
    assert.equal(await prepareCapturePermission(f.options), false);
    assert.deepEqual(f.calls, [updated]);
  }
});
test("desktop:build followed by desktop resets once, then preserves approval", async () => {
  let remembered = old;
  const resets = [];
  const options = {
    current: updated,
    ensureStopped() {},
    async reset(service, identifier) {
      resets.push([service, identifier]);
    },
    async remember(value) {
      remembered = value;
    },
  };
  assert.equal(
    await prepareCapturePermission({ ...options, previous: remembered }),
    true,
  );
  assert.equal(
    await prepareCapturePermission({ ...options, previous: remembered }),
    false,
  );
  assert.deepEqual(resets, [["ScreenCapture", "com.saturn.recorder.local"]]);
});
test("moving the local bundle does not mask an identity change", async () => {
  const f = fixture({ ...old, bundle: "/previous/Saturn Local.app" });
  assert.equal(await prepareCapturePermission(f.options), true);
  assert.deepEqual(f.calls[1], ["ScreenCapture", "com.saturn.recorder.local"]);
});
test("the installed app identity cannot enter the local permission flow", () => {
  assert.throws(
    () =>
      captureIdentity(
        signature('cdhash H"installed"').replaceAll(
          "com.saturn.recorder.local",
          "com.saturn.recorder",
        ),
        "/Applications/Saturn.app",
      ),
    /wrong privacy identity/,
  );
});
test("certificate-signed rebuilds with the same designated requirement retain consent", async () => {
  const signed = captureIdentity(
    signature(
      'identifier "com.saturn.recorder.local" and anchor apple generic and certificate leaf[subject.OU] = "TEAM"',
    ),
    bundle,
  );
  const f = fixture(signed, { ...signed });
  assert.equal(await prepareCapturePermission(f.options), false);
  assert.deepEqual(f.calls, [signed]);
});
test("a running Saturn is never reset or marked as repaired", async () => {
  const f = fixture(old, updated, {
    ensureStopped() {
      throw new Error("running");
    },
  });
  await assert.rejects(prepareCapturePermission(f.options), /running/);
  assert.deepEqual(f.calls, []);
});
test("failed automatic repairs do not remember success", async () => {
  const f = fixture(old, updated, {
    async reset() {
      throw new Error("reset failed");
    },
  });
  await assert.rejects(prepareCapturePermission(f.options), /reset failed/);
  assert.deepEqual(f.calls, ["stopped"]);
});
test("explicit repair works without a previous identity", async () => {
  const f = fixture(null, updated, { force: true });
  assert.equal(await prepareCapturePermission(f.options), true);
  assert.deepEqual(f.calls, [
    "stopped",
    ["ScreenCapture", "com.saturn.recorder.local"],
    updated,
  ]);
});
test("a different app identity or unbound Info.plist is rejected before any reset", () => {
  assert.throws(() =>
    captureIdentity(
      signature('cdhash H"new"').replace(
        "com.saturn.recorder.local",
        "other.app",
      ),
      bundle,
    ),
  );
  assert.throws(() =>
    captureIdentity(
      signature('cdhash H"new"') + "Info.plist=not bound\n",
      bundle,
    ),
  );
  assert.throws(() =>
    captureIdentity("Identifier=com.saturn.recorder.local\n", bundle),
  );
});

test("launches the exact bundle and refuses to reuse a different app copy", () => {
  assert.deepEqual(launchArguments(bundle, []), ["-n", "-a", bundle]);
  assert.deepEqual(
    launchArguments(bundle, [`${bundle}/Contents/MacOS/saturn-recorder`]),
    ["-a", bundle],
  );
  assert.throws(
    () =>
      launchArguments(bundle, [
        "/Applications/Saturn.app/Contents/MacOS/saturn-recorder",
      ]),
    /Another Saturn copy/,
  );
  assert.throws(
    () => launchArguments(bundle, ["/repo/target/debug/saturn-recorder"]),
    /Another Saturn copy/,
  );
});
