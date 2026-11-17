import { describe, expect, it, vi } from "vitest";

vi.mock("react-native", () => ({ Platform: { OS: "ios" } }));
vi.mock("expo-modules-core", () => ({ requireOptionalNativeModule: () => null }));

import {
  defaultSelection,
  describeProgress,
  describeStatus,
  describeTotals,
  endpointError,
  needsAccessHeaders,
  formatDuration,
  groupTypes,
  healthSync,
} from "./health-sync";

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
    expect(endpointError("https://mac.example.ts.net:8444/ingest")).toMatch(/\/health 为止/);
    expect(endpointError("https://homelab.example.xyz/health")).toBeNull();
    expect(endpointError("https://homelab.example.xyz/health?x=1")).toMatch(/\?/);
    expect(endpointError("mac")).toMatch(/完整地址/);
    expect(needsAccessHeaders("https://homelab.example.xyz/health")).toBe(true);
    expect(needsAccessHeaders("https://mac.example.ts.net:8444")).toBe(false);
  });

  it("describes the sync state", () => {
    const now = 1_800_000_000_000;
    expect(describeStatus({ pendingTypes: [], uploaded: 0 }, now)).toBe("还没同步过");
    expect(describeStatus({ pendingTypes: [], uploaded: 3, lastSuccessAt: now - 5 * 60000 }, now)).toBe("5 分钟前同步");
    expect(describeStatus({ pendingTypes: ["x"], uploaded: 0 }, now)).toMatch(/解锁/);
    expect(describeStatus({ pendingTypes: [], uploaded: 0, lastError: "HTTP 401" }, now)).toMatch(/401/);
    expect(describeStatus({ pendingTypes: [], uploaded: 0, running: true }, now)).toMatch(/正在同步/);
  });

  it("describes live progress", () => {
    const now = 1_800_000_000_000;
    const base = { running: true, startedAt: now - 120_000, activeTypes: ["心率", "步数"], doneTypes: 3, typeCount: 18,
      uploaded: 108_000, wireBytes: 1_000, rawBytes: 10_000, readMs: 0, encodeMs: 0, postMs: 0 };
    const p = describeProgress(base, now);
    expect(p.title).toBe("正在同步：心率、步数（3/18 类）");
    expect(p.detail).toBe("本轮已传 108,000 条 · 每秒约 900 条 · 压缩到 10% · 已用 2 分钟");
    expect(describeProgress({ ...base, activeTypes: [], doneTypes: 0, uploaded: 0, wireBytes: 0, rawBytes: 0, startedAt: now - 1000 }, now))
      .toEqual({ title: "正在同步：准备（0/18 类）", detail: "本轮已传 0 条" });
  });

  it("describes totals and interruption", () => {
    expect(describeTotals({ pendingTypes: [], uploaded: 489_000, lastRunUploaded: 420_000, lastRunSeconds: 372 }))
      .toBe("累计上传 489,000 条 · 上一轮 420,000 条，用时 6 分钟");
    expect(describeTotals({ pendingTypes: [], uploaded: 5 })).toBe("累计上传 5 条");
    expect(describeStatus({ pendingTypes: ["x"], uploaded: 0, interrupted: true })).toMatch(/续传/);
    expect(formatDuration(30)).toBe("30 秒");
    expect(formatDuration(3 * 3600 + 5 * 60)).toBe("3 小时 5 分钟");
  });
});
