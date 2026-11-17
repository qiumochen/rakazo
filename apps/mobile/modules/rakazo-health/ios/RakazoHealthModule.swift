import ExpoModulesCore
import HealthKit

/// Created at application launch, before the JavaScript bridge exists. Background delivery relaunches
/// the app in the background, so the observer queries have to be registered here, not from JS.
public class RakazoHealthAppDelegate: ExpoAppDelegateSubscriber {
  public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    HealthSyncEngine.shared.registerBackgroundTask()   // has to happen before launch finishes
    HealthSyncEngine.shared.start()
    return true
  }
}

/// JS surface of the HealthKit → homelab sync (lib/health-sync.ts).
public class RakazoHealthModule: Module {
  public func definition() -> ModuleDefinition {
    Name("RakazoHealth")

    Function("isAvailable") { HealthSyncEngine.isAvailable }

    Function("types") { () -> [[String: Any]] in
      HealthTypes.all.map {
        ["id": $0.id, "label": $0.label, "group": $0.group, "sensitive": $0.sensitive,
         "available": HealthTypes.sampleType($0.id) != nil]
      }
    }

    Function("getConfig") { () -> [String: Any]? in
      guard let c = HealthSyncEngine.shared.config else { return nil }
      return ["endpoint": c.endpoint, "types": c.enabledTypes, "hasToken": HealthKeychain.read() != nil,
              "accessHeaders": Array(HealthAccessHeaders.read().keys).sorted()]
    }

    Function("status") { () -> [String: Any] in Self.statusDict() }

    /// Live progress of the current run; the settings screen polls it every second while syncing.
    Function("progress") { () -> [String: Any] in
      let p = HealthSyncEngine.shared.progress
      var out: [String: Any] = [
        "running": p.running, "activeTypes": p.activeTypes, "doneTypes": p.doneTypes, "typeCount": p.typeCount,
        "uploaded": p.uploaded, "wireBytes": p.wireBytes, "rawBytes": p.rawBytes,
        "readMs": p.readMs, "encodeMs": p.encodeMs, "postMs": p.postMs,
      ]
      if let d = p.startedAt { out["startedAt"] = d.timeIntervalSince1970 * 1000 }
      return out
    }

    AsyncFunction("requestAuthorization") { (types: [String], promise: Promise) in
      HealthSyncEngine.shared.requestAuthorization(types: types) { ok, error in
        if let error {
          promise.reject("E_HEALTH_AUTH", error)
        } else {
          promise.resolve(ok)
        }
      }
    }

    /// Saves the endpoint, token (keychain; nil keeps the stored one), extra headers (nil keeps, empty clears)
    /// and types, then (re)starts observers.
    AsyncFunction("configure") { (endpoint: String, token: String?, types: [String], headers: [String: String]?) in
      guard HealthSyncEngine.ingestURL(endpoint) != nil else {
        throw Exception(name: "E_HEALTH_ENDPOINT", description: "地址要是 https://…")
      }
      if let token, !token.isEmpty { HealthKeychain.write(token) }
      if let headers { HealthAccessHeaders.write(headers) }
      HealthSyncEngine.shared.config = .init(endpoint: endpoint, enabledTypes: types)
      HealthSyncEngine.shared.start()
    }

    AsyncFunction("disable") {
      HealthSyncEngine.shared.stop()
      HealthSyncEngine.shared.config = nil
      HealthKeychain.write(nil)
      HealthAccessHeaders.write(nil)
    }

    AsyncFunction("syncNow") { (promise: Promise) in
      HealthSyncEngine.shared.sync(reason: "manual") { promise.resolve(Self.statusDict()) }
    }

    /// Re-sends all history on the next sync (the server ignores duplicates by UUID).
    AsyncFunction("resetAnchors") { HealthSyncEngine.shared.resetAnchors() }
  }

  static func statusDict() -> [String: Any] {
    let s = HealthSyncEngine.shared.status
    var out: [String: Any] = ["pendingTypes": s.pendingTypes, "uploaded": s.uploaded,
                              "running": HealthSyncEngine.shared.isRunning]
    if let d = s.lastSuccessAt { out["lastSuccessAt"] = d.timeIntervalSince1970 * 1000 }
    if let d = s.lastAttemptAt { out["lastAttemptAt"] = d.timeIntervalSince1970 * 1000 }
    if let e = s.lastError { out["lastError"] = e }
    if let n = s.lastRunUploaded { out["lastRunUploaded"] = n }
    if let t = s.lastRunSeconds { out["lastRunSeconds"] = t }
    if s.interrupted == true { out["interrupted"] = true }
    return out
  }
}
