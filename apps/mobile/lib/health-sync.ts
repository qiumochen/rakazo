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

export type HealthSyncConfig = { endpoint: string; types: string[]; hasToken: boolean };

export type HealthSyncStatus = {
  lastSuccessAt?: number;
  lastAttemptAt?: number;
  lastError?: string;
  pendingTypes: string[];
  uploaded: number;
};

type HealthModule = {
  isAvailable(): boolean;
  types(): HealthTypeInfo[];
  getConfig(): HealthSyncConfig | null;
  status(): HealthSyncStatus;
  requestAuthorization(types: string[]): Promise<boolean>;
  configure(endpoint: string, token: string | null, types: string[]): Promise<void>;
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

/** The ingest endpoint has to be HTTPS (Tailscale serve gives the tailnet host a certificate). */
export function endpointError(endpoint: string): string | null {
  let url: URL;
  try {
    url = new URL(endpoint.trim());
  } catch {
    return "填完整地址，比如 https://mac.tailnet.ts.net:8444";
  }
  if (url.protocol !== "https:") return "要用 https://（Tailscale 的地址自带证书）";
  if (url.pathname !== "/" && url.pathname !== "") return "只填到端口，不要带路径";
  return null;
}

export function describeStatus(status: HealthSyncStatus, now = Date.now()): string {
  if (status.lastError) return `上次失败：${status.lastError}`;
  if (status.pendingTypes.length) return `${status.pendingTypes.length} 类等手机解锁后补传`;
  if (!status.lastSuccessAt) return "还没同步过";
  const minutes = Math.round((now - status.lastSuccessAt) / 60000);
  if (minutes < 1) return "刚刚同步";
  if (minutes < 60) return `${minutes} 分钟前同步`;
  const hours = Math.round(minutes / 60);
  return hours < 48 ? `${hours} 小时前同步` : `${Math.round(hours / 24)} 天前同步`;
}
