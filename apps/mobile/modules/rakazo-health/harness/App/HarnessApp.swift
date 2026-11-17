import HealthKit
import SwiftUI

/// 测试宿主：按启动参数做一件事，结果写在界面上的 result 标签里（UI 测试读它）。
/// --auth | --write <kg> | --delete | --sync <endpoint> <token>
@main
struct HarnessApp: App {
  @State private var result = "starting"
  var body: some Scene {
    WindowGroup {
      VStack {
        Text(result).accessibilityIdentifier("result")
      }
      .task { result = await run(CommandLine.arguments) }
    }
  }
}

let store = HKHealthStore()
let bodyMass = HKQuantityType.quantityType(forIdentifier: .bodyMass)!

func run(_ args: [String]) async -> String {
  do {
    if args.contains("--auth") {
      try await store.requestAuthorization(toShare: [bodyMass], read: [bodyMass])
      return "auth:ok"
    }
    if let i = args.firstIndex(of: "--write"), let kg = Double(args[i + 1]) {
      let q = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg)
      let now = Date()
      let s = HKQuantitySample(type: bodyMass, quantity: q, start: now, end: now, metadata: ["harness": "1"])
      try await store.save(s)
      return "wrote:\(s.uuid.uuidString)"
    }
    if let i = args.firstIndex(of: "--bulk"), let n = Int(args[i + 1]) {
      // 一次写 n 条体重（每分钟一条，往回倒），验证大批量：分页、流水线、gzip、进度
      let now = Date()
      let samples = (0..<n).map { k -> HKQuantitySample in
        let t = now.addingTimeInterval(-Double(k) * 60)
        let q = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 80 + Double(k % 100) / 100)
        return HKQuantitySample(type: bodyMass, quantity: q, start: t, end: t, metadata: ["harness": "1", "bulk": "\(k)"])
      }
      for chunk in stride(from: 0, to: samples.count, by: 2000) {
        try await store.save(Array(samples[chunk..<min(chunk + 2000, samples.count)]))
      }
      return "bulk:\(n)"
    }
    if args.contains("--delete") {
      let pred = HKQuery.predicateForObjects(withMetadataKey: "harness")
      let n = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
        store.deleteObjects(of: bodyMass, predicate: pred) { _, n, e in e.map { c.resume(throwing: $0) } ?? c.resume(returning: n) }
      }
      return "deleted:\(n)"
    }
    if let i = args.firstIndex(of: "--resync") {
      // 重新上传全部历史：重置锚点（它自己会启动同步），等同步跑完
      HealthKeychain.write(args[i + 2])
      HealthSyncEngine.shared.config = .init(endpoint: args[i + 1], enabledTypes: [HKQuantityTypeIdentifier.bodyMass.rawValue])
      let before = HealthSyncEngine.shared.status.uploaded
      HealthSyncEngine.shared.resetAnchors()
      await withCheckedContinuation { c in HealthSyncEngine.shared.sync(reason: "harness") { c.resume() } }
      let s = HealthSyncEngine.shared.status
      return "resync:resent=\(s.uploaded - before);error=\(s.lastError ?? "none")"
    }
    if let i = args.firstIndex(of: "--sync") {
      HealthKeychain.write(args[i + 2])
      HealthSyncEngine.shared.config = .init(endpoint: args[i + 1], enabledTypes: [HKQuantityTypeIdentifier.bodyMass.rawValue])
      await withCheckedContinuation { c in HealthSyncEngine.shared.sync(reason: "harness") { c.resume() } }
      let s = HealthSyncEngine.shared.status
      let p = HealthSyncEngine.shared.progress
      return "sync:uploaded=\(s.uploaded);error=\(s.lastError ?? "none");pending=\(s.pendingTypes.count)"
        + ";run=\(p.uploaded);wire=\(p.wireBytes);raw=\(p.rawBytes);secs=\(String(format: "%.1f", s.lastRunSeconds ?? 0))"
    }
    return "idle"
  } catch {
    return "error:\(error.localizedDescription)"
  }
}
