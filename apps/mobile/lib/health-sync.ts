import { requireOptionalNativeModule } from "expo-modules-core";
import { Platform } from "react-native";

/**
 * homelab branch: pushes HealthKit data to the self-hosted health service (homelab apps/health).
 * Native side: modules/rakazo-health. Absent on Android, web, and builds without the module.
 */
export type HealthTypeInfo = {
  id: string;
  label: string;
  group: string;
  sensitive: boolean;
  available: boolean;
};

export type HealthSyncConfig = {
  endpoint: string;
  types: string[];
  hasToken: boolean;
  /** Names of the extra headers saved for the ingest endpoint (Cloudflare Access). Missing on older builds. */
  accessHeaders?: string[];
};

export type HealthSyncStatus = {
  lastSuccessAt?: number;
  lastAttemptAt?: number;
  lastError?: string;
  pendingTypes: string[];
  uploaded: number;
  /** Missing on builds before the flag existed. */
  running?: boolean;
  /** v2: the last run that moved data. */
  lastRunUploaded?: number;
  lastRunSeconds?: number;
  /** v2: ran out of background time; continues later on its own. */
  interrupted?: boolean;
};

/** v2: live view of the current run. */
export type HealthSyncProgress = {
  running: boolean;
  startedAt?: number;
  activeTypes: string[];
  doneTypes: number;
  typeCount: number;
  uploaded: number;
  wireBytes: number;
  rawBytes: number;
  readMs: number;
  encodeMs: number;
  postMs: number;
};

type HealthModule = {
  isAvailable(): boolean;
  types(): HealthTypeInfo[];
  getConfig(): HealthSyncConfig | null;
  status(): HealthSyncStatus;
  /** Missing on v1 builds. */
  progress?(): HealthSyncProgress;
  requestAuthorization(types: string[]): Promise<boolean>;
  /** headers: null keeps the saved ones, {} clears them. */
  configure(
    endpoint: string,
    token: string | null,
    types: string[],
    headers: Record<string, string> | null,
  ): Promise<void>;
  disable(): Promise<void>;
  syncNow(): Promise<HealthSyncStatus>;
  resetAnchors(): Promise<void>;
};

export function healthSync(): HealthModule | null {
  if (Platform.OS !== "ios") return null;
  const native = requireOptionalNativeModule<HealthModule>("RakazoHealth");
  return native && native.isAvailable() ? native : null;
}

/** Types grouped for the settings list, in the order the native side declares them. */
export function groupTypes(types: HealthTypeInfo[]): [string, HealthTypeInfo[]][] {
  const groups = new Map<string, HealthTypeInfo[]>();
  for (const type of types) {
    if (!type.available) continue;
    groups.set(type.group, [...(groups.get(type.group) ?? []), type]);
  }
  return [...groups.entries()];
}

/** First-time selection: everything except the sensitive categories. */
export function defaultSelection(types: HealthTypeInfo[]): string[] {
  return types.filter((t) => t.available && !t.sensitive).map((t) => t.id);
}

/**
 * The ingest endpoint has to be HTTPS: the Tailscale serve address (`https://<host>.<tailnet>.ts.net:8444`)
 * or the public one behind Cloudflare Access (`https://homelab.0458001.xyz/health`, needs the access headers).
 */
export function endpointError(endpoint: string): string | null {
  let url: URL;
  try {
    url = new URL(endpoint.trim());
  } catch {
    return "填完整地址，比如 https://homelab.0458001.xyz/health";
  }
  if (url.protocol !== "https:") return "要用 https://";
  if (url.search || url.hash) return "地址里不要带 ? 或 #";
  if (/\/ingest(\/|$)/.test(url.pathname)) return "填到 /health 为止，/ingest/healthkit 会自动加";
  return null;
}

/** Tailscale addresses never need the Cloudflare Access headers. */
export function needsAccessHeaders(endpoint: string): boolean {
  try {
    return !new URL(endpoint.trim()).hostname.endsWith(".ts.net");
  } catch {
    return false;
  }
}

const count = (n: number) => Math.round(n).toLocaleString("en-US");

export function formatDuration(seconds: number): string {
  if (seconds < 60) return `${Math.max(1, Math.round(seconds))} 秒`;
  const minutes = Math.round(seconds / 60);
  return minutes < 60 ? `${minutes} 分钟` : `${Math.floor(minutes / 60)} 小时 ${minutes % 60} 分钟`;
}

/** Two lines for the status row while a run is going: what is syncing, and how much so far. */
export function describeProgress(p: HealthSyncProgress, now = Date.now()): { title: string; detail: string } {
  const which = p.activeTypes.length ? p.activeTypes.join("、") : p.doneTypes >= p.typeCount ? "收尾" : "准备";
  const title = `正在同步：${which}（${Math.min(p.doneTypes, p.typeCount)}/${p.typeCount} 类）`;
  const seconds = p.startedAt ? Math.max(0.001, (now - p.startedAt) / 1000) : 0;
  const parts = [`本轮已传 ${count(p.uploaded)} 条`];
  if (seconds >= 3 && p.uploaded > 0) parts.push(`每秒约 ${count(p.uploaded / seconds)} 条`);
  if (p.wireBytes > 0 && p.rawBytes > 0) parts.push(`压缩到 ${Math.max(1, Math.round((p.wireBytes / p.rawBytes) * 100))}%`);
  if (seconds >= 60) parts.push(`已用 ${formatDuration(seconds)}`);
  return { title, detail: parts.join(" · ") };
}

/** Detail line when idle. */
export function describeTotals(status: HealthSyncStatus): string {
  const total = `累计上传 ${count(status.uploaded)} 条`;
  if (status.lastRunUploaded && status.lastRunSeconds !== undefined) {
    return `${total} · 上一轮 ${count(status.lastRunUploaded)} 条，用时 ${formatDuration(status.lastRunSeconds)}`;
  }
  return total;
}

export function describeStatus(status: HealthSyncStatus, now = Date.now()): string {
  if (status.running) return "正在同步…（首次或重新上传会传全部历史，可能要十几分钟，别切走或锁屏）";
  if (status.lastError) return `上次失败：${status.lastError}`;
  if (status.interrupted) return "后台时间用完了，已传的都保存了，剩下的稍后自动续传（打开 App 也会接着传）";
  if (status.pendingTypes.length) return `${status.pendingTypes.length} 类等手机解锁后补传`;
  if (!status.lastSuccessAt) return "还没同步过";
  const minutes = Math.round((now - status.lastSuccessAt) / 60000);
  if (minutes < 1) return "刚刚同步";
  if (minutes < 60) return `${minutes} 分钟前同步`;
  const hours = Math.round(minutes / 60);
  return hours < 48 ? `${hours} 小时前同步` : `${Math.round(hours / 24)} 天前同步`;
}
