import Foundation
import HealthKit
import UIKit

/// Pushes HealthKit changes to the homelab health service (apps/health, POST /ingest/healthkit).
///
/// Design:
/// - One HKAnchoredObjectQuery per type, starting from the anchor stored for that type. New samples
///   and deletions go out in one batch; the anchor only moves forward after the server answers 2xx.
///   A failed or interrupted upload is therefore retried from the old anchor next time — the query
///   itself is the persistent outbox, and the server upserts by UUID so a repeat is harmless.
/// - HKObserverQuery + background delivery wake the app when a type changes. While the phone is
///   locked HealthKit is unreadable (errorDatabaseInaccessible); the type is marked pending and
///   synced again when protected data becomes available.
/// - Values are converted to the unit the server expects for each type (see apps/health ingest.py).
///
/// No dependency on Expo or React Native, so it can be compiled and tested on its own.
// 可变状态只在 `queue` 上读写，所以手动标 Sendable。
public final class HealthSyncEngine: @unchecked Sendable {
  public static let shared = HealthSyncEngine()

  public struct Config: Codable, Equatable {
    public var endpoint: String     // https://<host>.<tailnet>.ts.net:8444
    public var enabledTypes: [String]
    public init(endpoint: String, enabledTypes: [String]) {
      self.endpoint = endpoint
      self.enabledTypes = enabledTypes
    }
  }

  public struct Status: Codable {
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    public var lastError: String?
    public var pendingTypes: [String] = []
    public var uploaded: Int = 0
  }

  private let store = HKHealthStore()
  private let defaults = UserDefaults.standard
  private let queue = DispatchQueue(label: "rakazo.health.sync")
  private var observers: [HKObserverQuery] = []
  private var running = false
  private var rerun = false
  private var waiters: [() -> Void] = []
  private let batchLimit = 2000
  /// Token lives in the keychain; set by the JS side.
  public var tokenProvider: () -> String? = { HealthKeychain.read() }

  private init() {
    NotificationCenter.default.addObserver(
      forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil
    ) { [weak self] _ in
      guard let self, !self.status.pendingTypes.isEmpty else { return }
      self.sync(reason: "unlock")
    }
  }

  public static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

  // MARK: Config and status (UserDefaults)

  public var config: Config? {
    get {
      guard let data = defaults.data(forKey: "rakazo.health.config") else { return nil }
      return try? JSONDecoder().decode(Config.self, from: data)
    }
    set {
      if let newValue, let data = try? JSONEncoder().encode(newValue) {
        defaults.set(data, forKey: "rakazo.health.config")
      } else {
        defaults.removeObject(forKey: "rakazo.health.config")
      }
    }
  }

  public private(set) var status: Status {
    get {
      guard let data = defaults.data(forKey: "rakazo.health.status"),
        let s = try? JSONDecoder().decode(Status.self, from: data)
      else { return Status() }
      return s
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "rakazo.health.status") }
    }
  }

  private func anchorKey(_ id: String) -> String { "rakazo.health.anchor.\(id)" }

  private func anchor(for id: String) -> HKQueryAnchor? {
    guard let data = defaults.data(forKey: anchorKey(id)) else { return nil }
    return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
  }

  /// Saves unless a reset happened since `generation` was read; returns whether it saved.
  @discardableResult
  private func saveAnchorIfCurrent(_ anchor: HKQueryAnchor?, for id: String, generation gen: Int) -> Bool {
    generationLock.lock(); defer { generationLock.unlock() }
    guard gen == generation else { return false }
    saveAnchor(anchor, for: id)
    return true
  }

  private func saveAnchor(_ anchor: HKQueryAnchor?, for id: String) {
    guard let anchor,
      let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    else { return }
    defaults.set(data, forKey: anchorKey(id))
  }

  /// Bumped by resetAnchors(). A sync that started before a reset must not write its (old) anchors
  /// back afterwards: it checks the generation before every save and starts over instead.
  private let generationLock = NSLock()
  private var generation = 0
  private var currentGeneration: Int {
    generationLock.lock(); defer { generationLock.unlock() }
    return generation
  }

  /// Forget every anchor and re-send all history (the server dedupes by UUID). Safe while a sync runs.
  public func resetAnchors() {
    generationLock.lock()
    generation += 1
    for id in HealthTypes.all.map(\.id) { defaults.removeObject(forKey: anchorKey(id)) }
    generationLock.unlock()
    sync(reason: "reset")
  }

  /// Readable from any thread, including `queue` itself (completion callbacks run there).
  private var runningMirror = false
  public var isRunning: Bool {
    generationLock.lock(); defer { generationLock.unlock() }
    return runningMirror
  }

  private func setRunning(_ value: Bool) {
    running = value
    generationLock.lock(); runningMirror = value; generationLock.unlock()
  }

  // MARK: Authorization and background delivery

  public func requestAuthorization(types: [String], completion: @escaping (Bool, String?) -> Void) {
    let read = Set(HealthTypes.objectTypes(for: types))
    guard !read.isEmpty else { return completion(false, "no types") }
    store.requestAuthorization(toShare: nil, read: read) { ok, error in
      completion(ok, error?.localizedDescription)
    }
  }

  /// Called at every launch (foreground or background) from the app delegate, and after the user
  /// changes settings. Observer queries must be registered before background delivery can wake us.
  public func start() {
    queue.async { [self] in
      observers.forEach(store.stop)
      observers = []
      guard let config, Self.isAvailable, tokenProvider() != nil else { return }
      for type in HealthTypes.sampleTypes(for: config.enabledTypes) {
        let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, done, error in
          guard let self, error == nil else { return done() }
          // HealthKit backs off if done() is not called; call it after this round finishes.
          self.sync(reason: "observer") { done() }
        }
        store.execute(query)
        observers.append(query)
        let frequency: HKUpdateFrequency = HealthTypes.immediate.contains(type.identifier) ? .immediate : .hourly
        store.enableBackgroundDelivery(for: type, frequency: frequency) { _, _ in }
      }
    }
  }

  public func stop() {
    queue.async { [self] in
      observers.forEach(store.stop)
      observers = []
      store.disableAllBackgroundDelivery { _, _ in }
    }
  }

  // MARK: Sync

  /// Coalesces overlapping requests: a sync asked for while one is running runs once more after it.
  public func sync(reason: String, completion: (() -> Void)? = nil) {
    queue.async { [self] in
      if let completion { waiters.append(completion) }
      if running {
        rerun = true
        return
      }
      setRunning(true)
      runLoop()
    }
  }

  private func runLoop() {
    rerun = false
    let bg = beginBackgroundTask()
    Task {
      await self.syncAllTypes()
      self.queue.async { [self] in
        endBackgroundTask(bg)
        if rerun {
          runLoop()
        } else {
          setRunning(false)
          let done = waiters
          waiters = []
          done.forEach { $0() }
        }
      }
    }
  }

  private func beginBackgroundTask() -> UIBackgroundTaskIdentifier {
    var id = UIBackgroundTaskIdentifier.invalid
    DispatchQueue.main.sync {
      id = UIApplication.shared.beginBackgroundTask(withName: "rakazo.health.sync") {
        // Out of time: the anchors that did not move simply get retried next time.
      }
    }
    return id
  }

  private func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
    guard id != .invalid else { return }
    DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(id) }
  }

  private func syncAllTypes() async {
    guard let config, let token = tokenProvider(), let url = Self.ingestURL(config.endpoint) else { return }
    var s = status
    s.lastAttemptAt = Date()
    var pending: [String] = []
    var lastError: String?
    for type in HealthTypes.sampleTypes(for: config.enabledTypes) {
      do {
        s.uploaded += try await syncType(type, url: url, token: token)
      } catch let error as HKError where error.code == .errorDatabaseInaccessible {
        pending.append(type.identifier)   // locked: try again when protected data is available
      } catch {
        lastError = "\(HealthTypes.label(type.identifier)): \(error.localizedDescription)"
        pending.append(type.identifier)
      }
    }
    s.pendingTypes = pending
    s.lastError = lastError
    if lastError == nil && pending.isEmpty { s.lastSuccessAt = Date() }
    status = s
  }

  /// Pages through one type until HealthKit has nothing newer than the stored anchor.
  private func syncType(_ type: HKSampleType, url: URL, token: String) async throws -> Int {
    var total = 0
    while true {
      let gen = currentGeneration
      let (samples, deleted, newAnchor) = try await anchoredQuery(type, from: anchor(for: type.identifier))
      if samples.isEmpty && deleted.isEmpty {
        saveAnchorIfCurrent(newAnchor, for: type.identifier, generation: gen)
        return total
      }
      var batch = HealthPayload.Batch(device: UIDeviceName.current)
      for sample in samples {
        if let workout = sample as? HKWorkout {
          batch.workouts.append(HealthPayload.workout(workout))
        } else if let item = HealthPayload.sample(sample) {
          batch.samples.append(item)
        }
      }
      batch.deleted = deleted.map { HealthPayload.Deleted(uuid: $0.uuid.uuidString, type: type.identifier) }
      try await post(batch, to: url, token: token)
      // only after the server has it, and only if nobody reset the anchors meanwhile
      guard saveAnchorIfCurrent(newAnchor, for: type.identifier, generation: gen) else { continue }
      total += samples.count + deleted.count
      if samples.count + deleted.count < batchLimit { return total }
    }
  }

  private func anchoredQuery(_ type: HKSampleType, from anchor: HKQueryAnchor?) async throws
    -> ([HKSample], [HKDeletedObject], HKQueryAnchor?)
  {
    try await withCheckedThrowingContinuation { cont in
      let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: batchLimit) {
        _, samples, deleted, newAnchor, error in
        if let error {
          cont.resume(throwing: error)
        } else {
          cont.resume(returning: (samples ?? [], deleted ?? [], newAnchor))
        }
      }
      store.execute(query)
    }
  }

  private func post(_ batch: HealthPayload.Batch, to url: URL, token: String) async throws {
    var req = URLRequest(url: url, timeoutInterval: 60)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.httpBody = try JSONEncoder().encode(batch)
    let (data, response) = try await URLSession.shared.data(for: req)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else {
      let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
      throw HealthSyncError.server(code, detail ?? "")
    }
  }

  static func ingestURL(_ endpoint: String) -> URL? {
    var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    guard let url = URL(string: base + "/ingest/healthkit"), url.scheme == "https" || url.host == "localhost" else {
      return nil
    }
    return url
  }
}

public enum HealthSyncError: LocalizedError {
  case server(Int, String)
  public var errorDescription: String? {
    switch self {
    case let .server(code, detail): return "HTTP \(code)\(detail.isEmpty ? "" : " \(detail)")"
    }
  }
}

enum UIDeviceName {
  static var current: String {
    var name = ""
    if Thread.isMainThread {
      name = UIDevice.current.model
    } else {
      DispatchQueue.main.sync { name = UIDevice.current.model }
    }
    return name
  }
}

/// Token storage (keychain, this device only, readable after first unlock so background delivery works).
public enum HealthKeychain {
  private static let service = "rakazo.health"
  private static let account = "ingest-token"

  public static func read() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecReturnData as String: true,
    ]
    var out: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public static func write(_ token: String?) {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(base as CFDictionary)
    guard let token, !token.isEmpty else { return }
    var add = base
    add[kSecValueData as String] = Data(token.utf8)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(add as CFDictionary, nil)
  }
}
