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
}
