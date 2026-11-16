# rakazo-health 模拟器验收

不依赖 React Native：一个最小宿主 App（直接编译 `../ios` 里的同步引擎）+ XCUITest，在模拟器的 HealthKit 里
写入 / 删除体重，推到一个本机起的 homelab 健康服务，验证：

1. 写入 → 推送成功
2. 服务端连不上 → 失败、锚点不前移；恢复后补传（锁屏读不到时走的是同一条补传路径）
3. 在「健康」里删除 → 服务端跟着删

```bash
brew install xcodegen
cd apps/mobile/modules/rakazo-health/harness && xcodegen generate
TOK=$(openssl rand -hex 24)
docker run -d --name health-harness -p 127.0.0.1:18101:8101 -v $PWD/hdata:/data \
  -e ACCESS_TEAM_DOMAIN=x.cloudflareaccess.com -e ACCESS_AUD=x -e SERVICE_TOKENS=iphone:$TOK homelab-health:current
TEST_RUNNER_HARNESS_TOKEN=$TOK TEST_RUNNER_HARNESS_ENDPOINT=http://localhost:18101 \
  xcodebuild test -project HealthHarness.xcodeproj -scheme HealthHarness -destination "platform=iOS Simulator,name=iPhone 17 Pro"
sqlite3 hdata/health.db "select caller, samples, deleted from sync_log"
```

2026-11-17 首次运行四项全过。注意：HealthKit 会校验用途说明，太短（比如「测试：读取体重」）直接 abort。
锁屏本身（errorDatabaseInaccessible）只能在真机上验。
