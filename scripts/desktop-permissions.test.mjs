import test from "node:test";
import assert from "node:assert/strict";
import {
  captureIdentity,
  prepareCapturePermission,
} from "./desktop-permissions.mjs";

const bundle = "/tmp/test/Saturn.app";
const signature = (requirement) =>
  `Identifier=com.saturn.recorder\nInfo.plist entries=18\n# designated => ${requirement}\n`;
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
test("changed build resets only Saturn ScreenCapture before remembering the new identity", async () => {
  const f = fixture(old);
  assert.equal(await prepareCapturePermission(f.options), true);
  assert.deepEqual(f.calls, [
    "stopped",
    ["ScreenCapture", "com.saturn.recorder"],
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
test("certificate-signed rebuilds with the same designated requirement retain consent", async () => {
  const signed = captureIdentity(
    signature(
      'identifier "com.saturn.recorder" and anchor apple generic and certificate leaf[subject.OU] = "TEAM"',
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
test("failed resets do not remember success, so the next launch retries", async () => {
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
    ["ScreenCapture", "com.saturn.recorder"],
    updated,
  ]);
});
test("a different app identity or unbound Info.plist is rejected before any reset", () => {
  assert.throws(() =>
    captureIdentity(
      signature('cdhash H"new"').replace("com.saturn.recorder", "other.app"),
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
    captureIdentity("Identifier=com.saturn.recorder\n", bundle),
  );
});
