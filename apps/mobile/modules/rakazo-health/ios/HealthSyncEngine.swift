import BackgroundTasks
import Compression
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
/// - Speed (v2, homelab docs/personal-agent/health-sync-v2.md): gzip request bodies, 4500 per batch,
///   the next batch is read from HealthKit while the current one uploads, and two types sync at once.
/// - Progress: an in-memory snapshot (`progress`) the settings screen polls every second.
/// - Out of background time: stop after the current batch (saved anchors stay), end the background
///   task, and ask BGTaskScheduler for a processing task to continue later.
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
    /// Last run that moved data: how many and how long. Optional so status saved by v1 still decodes.
    public var lastRunUploaded: Int?
    public var lastRunSeconds: Double?
    /// The last run ran out of background time; the rest continues later.
    public var interrupted: Bool?
  }

  /// Live view of the current run (memory only).
  public struct Progress {
    public var running = false
    public var startedAt: Date?
    public var activeTypes: [String] = []
    public var doneTypes = 0
    public var typeCount = 0
    public var uploaded = 0
    public var wireBytes = 0
    public var rawBytes = 0
    public var readMs = 0.0
    public var encodeMs = 0.0
    public var postMs = 0.0
  }

  private let store = HKHealthStore()
  private let defaults = UserDefaults.standard
  private let queue = DispatchQueue(label: "rakazo.health.sync")
  private var observers: [HKObserverQuery] = []
  private var running = false
  private var rerun = false
  private var waiters: [() -> Void] = []
  /// HealthKit query page size. The server takes at most 5000 per request; bigger pages get split.
  private let batchLimit = 4500
  private let serverMax = 5000
  private let parallelTypes = 2
  public static let backgroundTaskId = "rakazo.health.sync"
  /// Token lives in the keychain; set by the JS side.
  public var tokenProvider: () -> String? = { HealthKeychain.read() }

  private init() {
    NotificationCenter.default.addObserver(
      forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil
    ) { [weak self] _ in
      guard let self, !self.status.pendingTypes.isEmpty else { return }
      self.sync(reason: "unlock")
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
    ) { [weak self] _ in
      guard let self, !self.status.pendingTypes.isEmpty else { return }
      self.sync(reason: "active")
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

  // MARK: Progress and background-time expiry (any thread)

  private let progressLock = NSLock()
  private var progressValue = Progress()
  private var expiredValue = false

  public var progress: Progress {
    progressLock.lock(); defer { progressLock.unlock() }
    return progressValue
  }

  private func updateProgress(_ change: (inout Progress) -> Void) {
    progressLock.lock(); change(&progressValue); progressLock.unlock()
  }

  /// Background time is up: finish the batch in flight, then stop (see syncType).
  public func expire() {
    progressLock.lock(); expiredValue = true; progressLock.unlock()
  }

  private var isExpired: Bool {
    progressLock.lock(); defer { progressLock.unlock() }
    return expiredValue
  }

  private func clearExpired() {
    progressLock.lock(); expiredValue = false; progressLock.unlock()
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
    clearExpired()
    let bg = BackgroundTime.begin { [weak self] in self?.expire() }
    Task {
      await self.syncAllTypes()
      self.queue.async { [self] in
        bg.end()
        if rerun && !isExpired {
          runLoop()
        } else {
          if isExpired { scheduleContinuation() }
          setRunning(false)
          let done = waiters
          waiters = []
          done.forEach { $0() }
        }
      }
    }
  }

  /// Registers the BGProcessingTask that continues an interrupted sync. Must run before launch
  /// finishes; skipped when the Info.plist does not permit the identifier (registering would crash).
  public func registerBackgroundTask() {
    let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
    guard permitted.contains(Self.backgroundTaskId) else { return }
    BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundTaskId, using: nil) { [weak self] task in
      guard let self else { return task.setTaskCompleted(success: false) }
      task.expirationHandler = { self.expire() }
      self.sync(reason: "bg-processing") {
        task.setTaskCompleted(success: self.status.interrupted != true)
      }
    }
  }

  private func scheduleContinuation() {
    let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
    guard permitted.contains(Self.backgroundTaskId) else { return }
    let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskId)
    request.requiresNetworkConnectivity = true
    request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
    try? BGTaskScheduler.shared.submit(request)
  }

  private func syncAllTypes() async {
    guard let config, let token = tokenProvider(), let url = Self.ingestURL(config.endpoint) else { return }
    let types = HealthTypes.sampleTypes(for: config.enabledTypes)
    let started = Date()
    updateProgress { $0 = Progress(running: true, startedAt: started, typeCount: types.count) }
    var s = status
    s.lastAttemptAt = started
    let outcome = RunOutcome()

    // `parallelTypes` workers pull types off one list; a type is skipped (left pending) once time is up.
    await withTaskGroup(of: Void.self) { group in
      var next = 0
      func launch() {
        guard next < types.count else { return }
        let type = types[next]
        next += 1
        group.addTask { await self.syncOne(type, url: url, token: token, outcome: outcome) }
      }
      for _ in 0..<min(parallelTypes, types.count) { launch() }
      while await group.next() != nil { launch() }
    }

    let result = outcome.snapshot()
    s.uploaded += result.uploaded
    s.pendingTypes = types.map(\.identifier).filter(result.pending.contains)
    s.lastError = result.error
    s.interrupted = result.interrupted
    if result.uploaded > 0 {
      s.lastRunUploaded = result.uploaded
      s.lastRunSeconds = Date().timeIntervalSince(started)
    }
    if result.error == nil && result.pending.isEmpty { s.lastSuccessAt = Date() }
    status = s
    updateProgress { $0.running = false; $0.activeTypes = [] }
  }

  private func syncOne(_ type: HKSampleType, url: URL, token: String, outcome: RunOutcome) async {
    let id = type.identifier
    if isExpired {
      outcome.pend(id, interrupted: true)
      return
    }
    let label = HealthTypes.label(id)
    updateProgress { $0.activeTypes.append(label) }
    do {
      outcome.add(try await syncType(type, url: url, token: token))
    } catch is SyncInterrupted {
      outcome.pend(id, interrupted: true)
    } catch let error as HKError where error.code == .errorDatabaseInaccessible {
      outcome.pend(id)   // locked: try again when protected data is available
    } catch {
      outcome.fail(id, "\(label): \(error.localizedDescription)")
    }
    updateProgress {
      if let i = $0.activeTypes.firstIndex(of: label) { $0.activeTypes.remove(at: i) }
      $0.doneTypes += 1
    }
  }

  private struct Fetched {
    let samples: [HKSample]
    let deleted: [HKDeletedObject]
    let anchor: HKQueryAnchor?
    var count: Int { samples.count + deleted.count }
  }

  private func fetch(_ type: HKSampleType, from anchor: HKQueryAnchor?) async throws -> Fetched {
    let t0 = Date()
    let (samples, deleted, newAnchor) = try await anchoredQuery(type, from: anchor)
    let ms = Date().timeIntervalSince(t0) * 1000
    updateProgress { $0.readMs += ms }
    return Fetched(samples: samples, deleted: deleted, anchor: newAnchor)
  }

  /// Pages through one type until HealthKit has nothing newer than the stored anchor. While page N
  /// uploads, page N+1 is already being read; page N's anchor is saved only after the server has it.
  private func syncType(_ type: HKSampleType, url: URL, token: String) async throws -> Int {
    let id = type.identifier
    var total = 0
    var gen = currentGeneration
    var current = try await fetch(type, from: anchor(for: id))
    while true {
      if current.count == 0 {
        saveAnchorIfCurrent(current.anchor, for: id, generation: gen)
        return total
      }
      if isExpired { throw SyncInterrupted() }
      let more = current.count >= batchLimit
      let prefetch: Task<Fetched, Error>? = more
        ? Task { [anchor = current.anchor] in try await self.fetch(type, from: anchor) } : nil
      do {
        for body in try encode(current, type: id) { try await post(body, to: url, token: token) }
      } catch {
        prefetch?.cancel()
        throw error
      }
      updateProgress { $0.uploaded += current.count }
      // only if nobody reset the anchors meanwhile; otherwise start this type over from scratch
      guard saveAnchorIfCurrent(current.anchor, for: id, generation: gen) else {
        prefetch?.cancel()
        gen = currentGeneration
        current = try await fetch(type, from: anchor(for: id))
        continue
      }
      total += current.count
      guard let prefetch else { return total }
      current = try await prefetch.value
    }
  }

  /// One page → request bodies of at most `serverMax` items each (gzipped when that helps).
  private func encode(_ page: Fetched, type: String) throws -> [Body] {
    let t0 = Date()
    let device = UIDeviceName.current
    var batches: [HealthPayload.Batch] = []
    var batch = HealthPayload.Batch(device: device)
    var size = 0
    func add(_ change: (inout HealthPayload.Batch) -> Void) {
      if size == serverMax {
        batches.append(batch)
        batch = HealthPayload.Batch(device: device)
        size = 0
      }
      change(&batch)
      size += 1
    }
    for sample in page.samples {
      if let workout = sample as? HKWorkout {
        add { $0.workouts.append(HealthPayload.workout(workout)) }
      } else if let item = HealthPayload.sample(sample) {
        add { $0.samples.append(item) }
      }
    }
    for d in page.deleted { add { $0.deleted.append(HealthPayload.Deleted(uuid: d.uuid.uuidString, type: type)) } }
    if size > 0 { batches.append(batch) }

    var bodies: [Body] = []
    for b in batches {
      let json = try JSONEncoder().encode(b)
      let t1 = Date()
      let gz = Gzip.compress(json)
      let gzipMs = Date().timeIntervalSince(t1) * 1000
      bodies.append(Body(data: gz ?? json, gzipped: gz != nil, rawBytes: json.count,
                         timing: String(format: "n=%d;gzip=%.0f", b.samples.count + b.workouts.count + b.deleted.count, gzipMs)))
    }
    let ms = Date().timeIntervalSince(t0) * 1000
    updateProgress { p in
      p.encodeMs += ms
      p.rawBytes += bodies.reduce(0) { $0 + $1.rawBytes }
    }
    return bodies
  }

  private struct Body {
    let data: Data
    let gzipped: Bool
    let rawBytes: Int
    let timing: String
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

  private func post(_ body: Body, to url: URL, token: String) async throws {
    var req = URLRequest(url: url, timeoutInterval: 120)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if body.gzipped { req.setValue("gzip", forHTTPHeaderField: "Content-Encoding") }
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    // Cloudflare Access 的服务令牌（不挂 Tailscale、走 homelab.0458001.xyz 时要）。只发给这个地址。
    for (name, value) in HealthAccessHeaders.read() where !name.isEmpty {
      req.setValue(value, forHTTPHeaderField: name)
    }
    let p = progress
    req.setValue(String(format: "%@;read=%.0f;encode=%.0f", body.timing, p.readMs, p.encodeMs),
                 forHTTPHeaderField: "X-Health-Timing")
    req.httpBody = body.data
    let t0 = Date()
    // 不跟随重定向：令牌不对时 Access 会 302 到登录页，跟过去拿到的是 200 的 HTML——当成成功就会前移锚点、丢数据
    let (data, response) = try await URLSession.shared.data(for: req, delegate: NoRedirect.shared)
    let ms = Date().timeIntervalSince(t0) * 1000
    updateProgress { $0.postMs += ms; $0.wireBytes += body.data.count }
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    guard (200..<300).contains(code) else {
      throw HealthSyncError.server(code, json?["detail"] as? String ?? (code == 302 ? "被登录页拦了（Access 凭据不对？）" : ""))
    }
    // 2xx 也要是健康服务自己的回执，别的（代理、登录页）一律不算数
    guard json?["ok"] as? Bool == true else {
      throw HealthSyncError.server(code, "回应不是健康服务的（中间有代理或登录页？）")
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

struct SyncInterrupted: Error {}

/// What one run achieved, collected from the parallel type workers.
final class RunOutcome: @unchecked Sendable {
  struct Snapshot {
    var uploaded = 0
    var pending: Set<String> = []
    var error: String?
    var interrupted = false
  }
  private let lock = NSLock()
  private var value = Snapshot()
  func add(_ n: Int) { lock.lock(); value.uploaded += n; lock.unlock() }
  func pend(_ id: String, interrupted: Bool = false) {
    lock.lock(); value.pending.insert(id); if interrupted { value.interrupted = true }; lock.unlock()
  }
  func fail(_ id: String, _ message: String) {
    lock.lock(); value.pending.insert(id); value.error = value.error ?? message; lock.unlock()
  }
  func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return value }
}

/// UIApplication background time for one run. iOS kills an app that does not end its task when the
/// time runs out, so the expiration handler ends it right away (after telling the engine to stop).
final class BackgroundTime: @unchecked Sendable {
  private let lock = NSLock()
  private var id = UIBackgroundTaskIdentifier.invalid

  static func begin(onExpire: @escaping () -> Void) -> BackgroundTime {
    let token = BackgroundTime()
    let start = {
      token.id = UIApplication.shared.beginBackgroundTask(withName: "rakazo.health.sync") {
        onExpire()
        token.end()
      }
    }
    if Thread.isMainThread { start() } else { DispatchQueue.main.sync(execute: start) }
    return token
  }

  func end() {
    lock.lock()
    let current = id
    id = .invalid
    lock.unlock()
    guard current != .invalid else { return }
    DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(current) }
  }
}

/// gzip (RFC 1952) around the Compression framework's raw DEFLATE. Returns nil when it does not help.
enum Gzip {
  static func compress(_ input: Data) -> Data? {
    guard input.count > 512 else { return nil }
    let capacity = input.count + input.count / 8 + 1024
    var deflated = Data(count: capacity)
    let written = deflated.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
      input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
        compression_encode_buffer(
          dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
          src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
      }
    }
    guard written > 0, written < input.count else { return nil }
    var out = Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0x03])
    out.append(deflated.prefix(written))
    var crc = crc32(input).littleEndian
    var size = UInt32(truncatingIfNeeded: input.count).littleEndian
    withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
    withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
    return out
  }

  private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
  }

  static func crc32(_ data: Data) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    table.withUnsafeBufferPointer { t in
      data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        for b in bytes { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
      }
    }
    return c ^ 0xFFFF_FFFF
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

/// Refuses every redirect, so a login page never passes for the ingest service.
final class NoRedirect: NSObject, URLSessionTaskDelegate {
  static let shared = NoRedirect()
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

/// Extra request headers (Cloudflare Access service token), kept in the keychain next to the token.
public enum HealthAccessHeaders {
  private static let account = "access-headers"

  public static func read() -> [String: String] {
    guard let text = HealthKeychain.read(account: account), let data = text.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
    return dict
  }

  /// Empty or nil removes them.
  public static func write(_ headers: [String: String]?) {
    guard let headers, !headers.isEmpty, let data = try? JSONSerialization.data(withJSONObject: headers),
          let text = String(data: data, encoding: .utf8) else {
      HealthKeychain.write(nil, account: account)
      return
    }
    HealthKeychain.write(text, account: account)
  }
}

/// Token storage (keychain, this device only, readable after first unlock so background delivery works).
public enum HealthKeychain {
  private static let service = "rakazo.health"
  private static let tokenAccount = "ingest-token"

  public static func read() -> String? { read(account: tokenAccount) }
  public static func write(_ token: String?) { write(token, account: tokenAccount) }

  static func read(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecReturnData as String: true,
    ]
    var out: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func write(_ token: String?, account: String) {
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
