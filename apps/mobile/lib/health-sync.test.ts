import { describe, expect, it, vi } from "vitest";

vi.mock("react-native", () => ({ Platform: { OS: "ios" } }));
vi.mock("expo-modules-core", () => ({ requireOptionalNativeModule: () => null }));

import { defaultSelection, describeStatus, endpointError, groupTypes, healthSync } from "./health-sync";

const types = [
  { id: "a", label: "体重", group: "身体测量", sensitive: false, available: true },
  { id: "b", label: "血糖", group: "生命体征", sensitive: true, available: true },
  { id: "c", label: "日光", group: "活动", sensitive: false, available: false },
  { id: "d", label: "体脂", group: "身体测量", sensitive: false, available: true },
];

describe("health sync", () => {
  it("is absent without the native module", () => {
    expect(healthSync()).toBeNull();
  });

  it("groups available types and leaves sensitive ones out by default", () => {
    expect(groupTypes(types).map(([g, ts]) => [g, ts.map((t) => t.id)])).toEqual([
      ["身体测量", ["a", "d"]],
      ["生命体征", ["b"]],
    ]);
    expect(defaultSelection(types)).toEqual(["a", "d"]);
  });

  it("only accepts an https origin", () => {
    expect(endpointError("https://mac.example.ts.net:8444")).toBeNull();
    expect(endpointError("http://mac.example.ts.net:8444")).toMatch(/https/);
    expect(endpointError("https://mac.example.ts.net:8444/ingest")).toMatch(/路径/);
    expect(endpointError("mac")).toMatch(/完整地址/);
  });

  it("describes the sync state", () => {
    const now = 1_800_000_000_000;
    expect(describeStatus({ pendingTypes: [], uploaded: 0 }, now)).toBe("还没同步过");
    expect(describeStatus({ pendingTypes: [], uploaded: 3, lastSuccessAt: now - 5 * 60000 }, now)).toBe("5 分钟前同步");
    expect(describeStatus({ pendingTypes: ["x"], uploaded: 0 }, now)).toMatch(/解锁/);
    expect(describeStatus({ pendingTypes: [], uploaded: 0, lastError: "HTTP 401" }, now)).toMatch(/401/);
  });
});
