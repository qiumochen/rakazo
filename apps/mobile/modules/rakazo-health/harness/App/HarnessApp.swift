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
    if args.contains("--delete") {
      let pred = HKQuery.predicateForObjects(withMetadataKey: "harness")
      let n = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
        store.deleteObjects(of: bodyMass, predicate: pred) { _, n, e in e.map { c.resume(throwing: $0) } ?? c.resume(returning: n) }
      }
      return "deleted:\(n)"
    }
    if let i = args.firstIndex(of: "--sync") {
      HealthKeychain.write(args[i + 2])
      HealthSyncEngine.shared.config = .init(endpoint: args[i + 1], enabledTypes: [HKQuantityTypeIdentifier.bodyMass.rawValue])
      await withCheckedContinuation { c in HealthSyncEngine.shared.sync(reason: "harness") { c.resume() } }
      let s = HealthSyncEngine.shared.status
      return "sync:uploaded=\(s.uploaded);error=\(s.lastError ?? "none");pending=\(s.pendingTypes.count)"
    }
    return "idle"
  } catch {
    return "error:\(error.localizedDescription)"
  }
}
