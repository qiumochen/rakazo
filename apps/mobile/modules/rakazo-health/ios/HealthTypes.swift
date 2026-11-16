import Foundation
import HealthKit

/// The types the app can sync, the unit the server expects for each, and how they are grouped in
/// settings. Sensitive categories are off by default (`sensitive`), and clinical records are not here.
public struct HealthTypeInfo {
  public let id: String
  public let label: String
  public let group: String
  public let unit: HKUnit?        // nil for category types and workouts
  public let unitName: String     // what the server stores (apps/health ingest.CANONICAL_UNITS)
  public let sensitive: Bool
}

public enum HealthTypes {
  private static func q(_ id: HKQuantityTypeIdentifier, _ label: String, _ group: String, _ unit: HKUnit, _ name: String,
                        sensitive: Bool = false) -> HealthTypeInfo {
    HealthTypeInfo(id: id.rawValue, label: label, group: group, unit: unit, unitName: name, sensitive: sensitive)
  }

  private static func c(_ id: HKCategoryTypeIdentifier, _ label: String, _ group: String, sensitive: Bool = false)
    -> HealthTypeInfo
  {
    HealthTypeInfo(id: id.rawValue, label: label, group: group, unit: nil, unitName: "category", sensitive: sensitive)
  }

  static let bpm = HKUnit.count().unitDivided(by: .minute())

  public static let all: [HealthTypeInfo] = [
    q(.bodyMass, "体重", "身体测量", .gramUnit(with: .kilo), "kg"),
    q(.bodyFatPercentage, "体脂率", "身体测量", .percent(), "%"),
    q(.leanBodyMass, "去脂体重", "身体测量", .gramUnit(with: .kilo), "kg"),
    q(.bodyMassIndex, "BMI", "身体测量", .count(), "count"),
    q(.height, "身高", "身体测量", .meterUnit(with: .centi), "cm"),
    q(.waistCircumference, "腰围", "身体测量", .meterUnit(with: .centi), "cm"),
    q(.stepCount, "步数", "活动", .count(), "count"),
    q(.distanceWalkingRunning, "步行 + 跑步距离", "活动", .meter(), "m"),
    q(.distanceCycling, "骑行距离", "活动", .meter(), "m"),
    q(.flightsClimbed, "爬楼层数", "活动", .count(), "count"),
    q(.activeEnergyBurned, "活动能量", "活动", .kilocalorie(), "kcal"),
    q(.basalEnergyBurned, "静息能量", "活动", .kilocalorie(), "kcal"),
    q(.appleExerciseTime, "锻炼分钟数", "活动", .minute(), "min"),
    q(.appleStandTime, "站立分钟数", "活动", .minute(), "min"),
    // iOS 17+；在 16 上 quantityType(forIdentifier:) 返回 nil，自然被跳过
    q(HKQuantityTypeIdentifier(rawValue: "HKQuantityTypeIdentifierTimeInDaylight"), "日光下时间", "活动", .minute(), "min"),
    q(.heartRate, "心率", "心脏", bpm, "count/min"),
    q(.restingHeartRate, "静息心率", "心脏", bpm, "count/min"),
    q(.walkingHeartRateAverage, "步行平均心率", "心脏", bpm, "count/min"),
    q(.heartRateVariabilitySDNN, "心率变异性", "心脏", .secondUnit(with: .milli), "ms"),
    q(.vo2Max, "最大摄氧量", "心脏", HKUnit(from: "ml/kg*min"), "mL/kg·min"),
    q(.oxygenSaturation, "血氧", "呼吸", .percent(), "%"),
    q(.respiratoryRate, "呼吸频率", "呼吸", bpm, "count/min"),
    c(.sleepAnalysis, "睡眠", "睡眠"),
    c(.mindfulSession, "正念", "睡眠"),
    q(.dietaryEnergyConsumed, "膳食能量", "营养", .kilocalorie(), "kcal"),
    q(.dietaryProtein, "蛋白质", "营养", .gram(), "g"),
    q(.dietaryCarbohydrates, "碳水化合物", "营养", .gram(), "g"),
    q(.dietaryFatTotal, "总脂肪", "营养", .gram(), "g"),
    q(.dietaryWater, "饮水", "营养", .literUnit(with: .milli), "mL"),
    q(.bloodPressureSystolic, "收缩压", "生命体征", .millimeterOfMercury(), "mmHg", sensitive: true),
    q(.bloodPressureDiastolic, "舒张压", "生命体征", .millimeterOfMercury(), "mmHg", sensitive: true),
    q(.bloodGlucose, "血糖", "生命体征", HKUnit(from: "mmol<180.15588000005408>/L"), "mmol/L", sensitive: true),
    HealthTypeInfo(id: HKObjectType.workoutType().identifier, label: "体能训练", group: "体能训练", unit: nil,
                   unitName: "", sensitive: false),
  ]

  /// Types that should wake the app as soon as they change (cheap and low-volume). The rest are hourly.
  static let immediate: Set<String> = [
    HKQuantityTypeIdentifier.bodyMass.rawValue, HKQuantityTypeIdentifier.bodyFatPercentage.rawValue,
    HKObjectType.workoutType().identifier, HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
  ]

  public static var defaults: [String] { all.filter { !$0.sensitive }.map(\.id) }

  static func info(_ id: String) -> HealthTypeInfo? { all.first { $0.id == id } }

  static func label(_ id: String) -> String { info(id)?.label ?? id }

  static func sampleType(_ id: String) -> HKSampleType? {
    if id == HKObjectType.workoutType().identifier { return HKObjectType.workoutType() }
    if let t = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: id)) { return t }
    return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: id))
  }

  static func sampleTypes(for ids: [String]) -> [HKSampleType] {
    ids.filter { info($0) != nil }.compactMap(sampleType)
  }

  /// Workouts read their heart rate and energy from those types too, so ask for them alongside.
  static func objectTypes(for ids: [String]) -> [HKObjectType] {
    var out = sampleTypes(for: ids) as [HKObjectType]
    if ids.contains(HKObjectType.workoutType().identifier) {
      out += [HKQuantityTypeIdentifier.heartRate, .activeEnergyBurned, .distanceWalkingRunning]
        .compactMap { HKObjectType.quantityType(forIdentifier: $0) }
    }
    return out
  }
}

/// JSON shapes of POST /ingest/healthkit.
enum HealthPayload {
  struct Sample: Encodable {
    let uuid: String
    let type: String
    let start: Double
    let end: Double
    let value: Double
    let unit: String
    let source: String
    let device: String
    let metadata: [String: String]?
  }

  struct Workout: Encodable {
    let uuid: String
    let activity: String
    let start: Double
    let end: Double
    let duration_s: Double
    let energy_kcal: Double?
    let distance_m: Double?
    let avg_hr: Double?
    let max_hr: Double?
    let source: String
    let metadata: [String: String]?
  }

  struct Deleted: Encodable {
    let uuid: String
    let type: String
  }

  struct Batch: Encodable {
    let device: String
    var samples: [Sample] = []
    var workouts: [Workout] = []
    var deleted: [Deleted] = []
    init(device: String) { self.device = device }
  }

  static func sample(_ s: HKSample) -> Sample? {
    guard let info = HealthTypes.info(s.sampleType.identifier) else { return nil }
    let value: Double
    if let q = s as? HKQuantitySample, let unit = info.unit {
      guard q.quantity.is(compatibleWith: unit) else { return nil }
      value = q.quantity.doubleValue(for: unit) * (info.unitName == "%" ? 100 : 1)
    } else if let c = s as? HKCategorySample {
      value = Double(c.value)
    } else {
      return nil
    }
    return Sample(uuid: s.uuid.uuidString, type: info.id, start: s.startDate.timeIntervalSince1970,
                  end: s.endDate.timeIntervalSince1970, value: value, unit: info.unitName,
                  source: s.sourceRevision.source.name, device: s.device?.name ?? "", metadata: metadata(s.metadata))
  }

  static func workout(_ w: HKWorkout) -> Workout {
    func stat(_ id: HKQuantityTypeIdentifier) -> HKStatistics? {
      HKObjectType.quantityType(forIdentifier: id).flatMap { w.statistics(for: $0) }
    }
    let bpm = HealthTypes.bpm
    let distance = stat(.distanceWalkingRunning) ?? stat(.distanceCycling) ?? stat(.distanceSwimming)
    return Workout(
      uuid: w.uuid.uuidString, activity: activityName(w.workoutActivityType),
      start: w.startDate.timeIntervalSince1970, end: w.endDate.timeIntervalSince1970, duration_s: w.duration,
      energy_kcal: stat(.activeEnergyBurned)?.sumQuantity()?.doubleValue(for: .kilocalorie()),
      distance_m: distance?.sumQuantity()?.doubleValue(for: .meter()),
      avg_hr: stat(.heartRate)?.averageQuantity()?.doubleValue(for: bpm),
      max_hr: stat(.heartRate)?.maximumQuantity()?.doubleValue(for: bpm),
      source: w.sourceRevision.source.name, metadata: metadata(w.metadata))
  }

  /// Metadata values flattened to strings (dates, quantities and numbers all have a description).
  static func metadata(_ m: [String: Any]?) -> [String: String]? {
    guard let m, !m.isEmpty else { return nil }
    var out: [String: String] = [:]
    for (k, v) in m.prefix(30) { out[k] = String(describing: v).prefix(200).description }
    return out
  }

  static func activityName(_ t: HKWorkoutActivityType) -> String {
    switch t {
    case .walking: return "walking"
    case .running: return "running"
    case .cycling: return "cycling"
    case .swimming: return "swimming"
    case .hiking: return "hiking"
    case .yoga: return "yoga"
    case .stairClimbing: return "stairClimbing"
    case .stairs: return "stairs"
    case .traditionalStrengthTraining: return "traditionalStrengthTraining"
    case .functionalStrengthTraining: return "functionalStrengthTraining"
    case .highIntensityIntervalTraining: return "highIntensityIntervalTraining"
    case .elliptical: return "elliptical"
    case .rowing: return "rowing"
    case .badminton: return "badminton"
    case .basketball: return "basketball"
    case .tableTennis: return "tableTennis"
    case .socialDance, .cardioDance: return "dance"
    case .coreTraining: return "coreTraining"
    case .pilates: return "pilates"
    case .mixedCardio: return "mixedCardio"
    case .cooldown: return "cooldown"
    default: return "other_\(t.rawValue)"
    }
  }
}
