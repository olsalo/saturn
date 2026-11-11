import { describe, it, expect } from "vitest";
import { initialSnapshot, recorderReducer, isBusy } from "./recorder-machine";
describe("backend state contract", () => {
  it("never claims completion without a confirmed file", () => {
    const result = recorderReducer(
      { ...initialSnapshot, mode: "exporting" },
      { type: "backend", snapshot: { ...initialSnapshot, mode: "done" } },
    );
    expect(result.mode).toBe("exporting");
    expect(result.error).toContain("completed file");
  });
  it("rejects export mode without a loaded project", () => {
    const result = recorderReducer(initialSnapshot, {
      type: "backend",
      snapshot: { ...initialSnapshot, mode: "export_ready" },
    });
    expect(result.mode).toBe("idle");
    expect(result.error).toContain("project");
  });
  it("preserves a loaded project when reporting a recoverable error", () => {
    const state = { ...initialSnapshot, mode: "recording" as const };
    expect(
      recorderReducer(state, { type: "error", message: "Disk full" }).mode,
    ).toBe("recording");
    expect(isBusy("recording")).toBe(true);
    expect(isBusy("done")).toBe(false);
  });
});
