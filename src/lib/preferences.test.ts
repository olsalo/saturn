import { afterEach, describe, expect, it, vi } from "vitest";
import { readPreferences } from "./preferences";

afterEach(() => vi.unstubAllGlobals());
describe("saved preferences", () => {
  const defaults = { audio: true, mic: false, countdownEnabled: false };
  it("restores saved choices on a fresh load without restoring a capture target", () => {
    vi.stubGlobal("localStorage", { getItem: () => JSON.stringify({
      audio: false, mic: true, countdownEnabled: true, source: { id: "123" },
    }) });
    expect(readPreferences("capture", defaults)).toEqual({
      audio: false, mic: true, countdownEnabled: true,
    });
  });
  it("retains defaults for missing or invalid options", () => {
    vi.stubGlobal("localStorage", { getItem: () => '{"audio":false,"mic":"true"}' });
    expect(readPreferences("capture", defaults)).toEqual({ ...defaults, audio: false });
  });
  it("handles corrupt or unavailable storage", () => {
    vi.stubGlobal("localStorage", { getItem: () => "bad json" });
    expect(readPreferences("capture", defaults)).toEqual(defaults);
    vi.stubGlobal("localStorage", { getItem: () => { throw new Error("unavailable"); } });
    expect(readPreferences("capture", defaults)).toEqual(defaults);
  });
});
