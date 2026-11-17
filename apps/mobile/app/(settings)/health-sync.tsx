import { useCallback, useEffect, useMemo, useState } from "react";
import { Alert, ScrollView, StyleSheet, Text, TextInput } from "react-native";
import { SettingsGroup, SettingsRow, SettingsSwitch } from "../../components/settings-group";
import {
  defaultSelection,
  describeProgress,
  describeStatus,
  describeTotals,
  endpointError,
  groupTypes,
  healthSync,
  type HealthSyncProgress,
  type HealthSyncStatus,
  type HealthTypeInfo,
} from "../../lib/health-sync";
import { mobileTokens } from "../../lib/appearance";
import { native, useThemedStyles } from "../../lib/native";
import { useSideInsets } from "../../lib/side-insets";

/**
 * homelab branch: HealthKit → homelab health service. The phone pushes in the background
 * (HKObserverQuery + background delivery); this page only sets the endpoint, token and types.
 */
export default function HealthSync() {
  const sideInsets = useSideInsets();
  const styles = useThemedStyles(createStyles);
  const health = useMemo(() => healthSync(), []);
  const types = useMemo<HealthTypeInfo[]>(() => health?.types() ?? [], [health]);
  const [saved, setSaved] = useState(() => health?.getConfig() ?? null);
  const [endpoint, setEndpoint] = useState(saved?.endpoint ?? "");
  const [token, setToken] = useState("");
  const [selected, setSelected] = useState<string[]>(saved?.types ?? defaultSelection(types));
  const [status, setStatus] = useState<HealthSyncStatus | null>(() => health?.status() ?? null);
  const [progress, setProgress] = useState<HealthSyncProgress | null>(() => health?.progress?.() ?? null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(() => {
    setStatus(health?.status() ?? null);
    setProgress(health?.progress?.() ?? null);
  }, [health]);
  // 同步中每秒刷新（进度条数在动），空闲时 5 秒
  const syncing = Boolean(status?.running || progress?.running);
  useEffect(() => {
    const timer = setInterval(refresh, syncing ? 1000 : 5000);
    return () => clearInterval(timer);
  }, [refresh, syncing]);

  if (!health) {
    return (
      <ScrollView style={[styles.screen, sideInsets]} contentContainerStyle={styles.content}>
        <Text style={styles.note}>这台设备不支持健康数据，或者这个版本没有带健康同步模块。</Text>
      </ScrollView>
    );
  }

  async function save() {
    const problem = endpointError(endpoint);
    if (problem) return setError(problem);
    if (!token && !saved?.hasToken) return setError("填设备 token（homelab 的 env/health.env 里 iphone 那一项）");
    if (!selected.length) return setError("至少选一类数据");
    setBusy(true);
    setError(null);
    try {
      await health!.requestAuthorization(selected);
      await health!.configure(endpoint.trim(), token || null, selected);
      setSaved(health!.getConfig());
      setToken("");
      setStatus(await health!.syncNow());
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  async function syncNow() {
    setBusy(true);
    try {
      setStatus(await health!.syncNow());
    } finally {
      setBusy(false);
    }
  }

  function resend() {
    Alert.alert("重新上传全部历史？", "服务器按记录去重，不会重复；数据多时要一阵子。", [
      { text: "取消", style: "cancel" },
      {
        text: "重新上传",
        onPress: () => {
          // resetAnchors 自己会启动同步；这里只等它跑完刷新状态
          void health!.resetAnchors().then(syncNow);
        },
      },
    ]);
  }

  function disable() {
    Alert.alert("停止健康同步？", "手机不再推送；服务器上已有的数据不动。", [
      { text: "取消", style: "cancel" },
      {
        text: "停止",
        style: "destructive",
        onPress: () => {
          void health!.disable().then(() => {
            setSaved(null);
            refresh();
          });
        },
      },
    ]);
  }

  const toggle = (id: string, on: boolean) =>
    setSelected((cur) => (on ? [...new Set([...cur, id])] : cur.filter((x) => x !== id)));

  return (
    <ScrollView
      style={[styles.screen, sideInsets]}
      contentContainerStyle={styles.content}
      contentInsetAdjustmentBehavior="automatic"
      keyboardShouldPersistTaps="handled"
    >
      <SettingsGroup label="状态">
        {progress?.running ? (
          <SettingsRow title={describeProgress(progress).title} detail={describeProgress(progress).detail} />
        ) : (
          <SettingsRow title={status ? describeStatus(status) : "—"} detail={status ? describeTotals(status) : undefined} />
        )}
        <SettingsRow accessibilityRole="button" title="立即同步" tinted disabled={busy || !saved} onPress={syncNow} />
      </SettingsGroup>

      <SettingsGroup label="服务器" footer="Mac 上 tailscale serve 的 :8444 地址；token 存在钥匙串里，不会显示。">
        <TextInput
          accessibilityLabel="地址"
          autoCapitalize="none"
          autoCorrect={false}
          keyboardType="url"
          editable={!busy}
          onChangeText={setEndpoint}
          placeholder="https://<主机>.<tailnet>.ts.net:8444"
          placeholderTextColor={native.tertiaryLabel}
          style={styles.input}
          value={endpoint}
        />
        <TextInput
          accessibilityLabel="设备 token"
          autoCapitalize="none"
          autoCorrect={false}
          editable={!busy}
          onChangeText={setToken}
          placeholder={saved?.hasToken ? "已保存（要换才填）" : "设备 token"}
          placeholderTextColor={native.tertiaryLabel}
          secureTextEntry
          style={styles.input}
          value={token}
        />
      </SettingsGroup>

      {groupTypes(types).map(([group, items]) => (
        <SettingsGroup key={group} label={group}>
          {items.map((type) => (
            <SettingsSwitch
              key={type.id}
              label={type.label}
              detail={type.sensitive ? "敏感类目，默认不同步" : undefined}
              value={selected.includes(type.id)}
              disabled={busy}
              onChange={(on) => toggle(type.id, on)}
            />
          ))}
        </SettingsGroup>
      ))}

      {error ? (
        <Text accessibilityRole="alert" style={styles.error}>
          {error}
        </Text>
      ) : null}
      <SettingsGroup>
        <SettingsRow accessibilityRole="button" title={busy ? "正在保存…" : "保存并授权"} tinted disabled={busy} onPress={save} />
        {saved ? <SettingsRow accessibilityRole="button" title="重新上传全部历史" disabled={busy} onPress={resend} /> : null}
        {saved ? <SettingsRow accessibilityRole="button" title="停止同步" destructive disabled={busy} onPress={disable} /> : null}
      </SettingsGroup>
    </ScrollView>
  );
}

function createStyles() {
  const tokens = mobileTokens();
  return StyleSheet.create({
    screen: { flex: 1, backgroundColor: native.groupedPage },
    content: { paddingHorizontal: 16, paddingTop: 16, paddingBottom: 48, gap: 4 },
    note: { color: native.secondaryLabel, fontSize: 15, padding: 16 },
    input: {
      minHeight: 48,
      backgroundColor: native.fill,
      color: native.label,
      paddingHorizontal: 14,
      paddingVertical: 12,
      fontSize: 16,
      marginVertical: 4,
      borderRadius: 12,
    },
    error: { color: tokens.destructive, fontSize: 15, paddingHorizontal: 16, paddingVertical: 10 },
  });
}
