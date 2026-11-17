import XCTest

final class HarnessUITests: XCTestCase {
  let endpoint = ProcessInfo.processInfo.environment["HARNESS_ENDPOINT"] ?? "http://localhost:18101"
  let token = ProcessInfo.processInfo.environment["HARNESS_TOKEN"] ?? ""

  func launch(_ args: [String]) -> String {
    let app = XCUIApplication()
    app.launchArguments = args
    app.launch()
    let label = app.staticTexts["result"]
    // HealthKit 授权页：点「全部打开」+「允许」
    let deadline = Date().addingTimeInterval(40)
    while Date() < deadline {
      for name in ["Turn On All", "全部打开"] where app.staticTexts[name].exists || app.buttons[name].exists {
        (app.buttons[name].exists ? app.buttons[name] : app.staticTexts[name]).tap()
      }
      for name in ["Allow", "允许"] where app.buttons[name].exists && app.buttons[name].isEnabled {
        app.buttons[name].tap()
      }
      if label.exists, !["starting", ""].contains(label.label) { break }
      Thread.sleep(forTimeInterval: 0.5)
    }
    let value = label.label
    print("HARNESS \(args.first ?? "") => \(value)")
    app.terminate()
    return value
  }

  func test1Auth() { XCTAssertEqual(launch(["--auth"]), "auth:ok") }
  func test2WriteAndSync() {
    XCTAssertTrue(launch(["--write", "82.3"]).hasPrefix("wrote:"))
    XCTAssertTrue(launch(["--sync", endpoint, token]).contains("error=none"))
  }
  func test3ServerDownThenBackfill() {
    // 由外部脚本在这一步之前停掉服务端：同步失败、锚点不动
    XCTAssertTrue(launch(["--write", "81.9"]).hasPrefix("wrote:"))
    let down = launch(["--sync", "http://localhost:18199", token])
    XCTAssertFalse(down.contains("error=none"), down)
    let up = launch(["--sync", endpoint, token])
    XCTAssertTrue(up.contains("error=none"), up)
  }
  func test4DeleteSyncs() {
    XCTAssertTrue(launch(["--delete"]).hasPrefix("deleted:"))
    XCTAssertTrue(launch(["--sync", endpoint, token]).contains("error=none"))
  }

  func test5ResetResendsHistory() {
    XCTAssertTrue(launch(["--write", "80.5"]).hasPrefix("wrote:"))
    XCTAssertTrue(launch(["--sync", endpoint, token]).contains("error=none"))
    let r = launch(["--resync", endpoint, token])
    XCTAssertTrue(r.hasPrefix("resync:resent=") && !r.hasPrefix("resync:resent=0") && r.contains("error=none"), r)
    XCTAssertTrue(launch(["--delete"]).hasPrefix("deleted:"))
    XCTAssertTrue(launch(["--sync", endpoint, token]).contains("error=none"))
  }

  /// 1 万条：多页（每页 4500）、预读、gzip 都走到；本轮条数要和写入的一致，请求体要比 JSON 小
  func test6BulkPipelinedAndCompressed() {
    XCTAssertTrue(launch(["--sync", endpoint, token]).contains("error=none"))     // 先把旧的追平
    XCTAssertEqual(launch(["--bulk", "10000"]), "bulk:10000")
    let r = launch(["--sync", endpoint, token])
    XCTAssertTrue(r.contains("error=none") && r.contains("pending=0"), r)
    let fields = Dictionary(uniqueKeysWithValues: r.split(separator: ";").compactMap { part -> (String, String)? in
      let kv = part.split(separator: "=", maxSplits: 1)
      return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
    })
    XCTAssertEqual(Int(fields["run"] ?? ""), 10000, r)
    let wire = Int(fields["wire"] ?? "") ?? 0, raw = Int(fields["raw"] ?? "") ?? 0
    XCTAssertTrue(wire > 0 && wire * 3 < raw, "gzip 没起作用：\(r)")
    XCTAssertTrue(launch(["--delete"]).hasPrefix("deleted:"))
    let d = launch(["--sync", endpoint, token])
    XCTAssertTrue(d.contains("error=none"), d)
  }
}
