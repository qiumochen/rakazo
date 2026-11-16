// homelab 分支：HealthKit 读取 + 后台推送（modules/rakazo-health）。
// 只在 iOS 加 entitlement 和权限说明；不申请写入、不读临床记录。
const { withEntitlementsPlist, withInfoPlist } = require("expo/config-plugins");

module.exports = function withHealthKit(config) {
  config = withEntitlementsPlist(config, (cfg) => {
    cfg.modResults["com.apple.developer.healthkit"] = true;
    cfg.modResults["com.apple.developer.healthkit.background-delivery"] = true;
    cfg.modResults["com.apple.developer.healthkit.access"] = [];
    return cfg;
  });
  return withInfoPlist(config, (cfg) => {
    cfg.modResults.NSHealthShareUsageDescription =
      "把你选的健康数据（体重、活动、睡眠、心率、训练等）同步到你自己家里的服务器，用于体重管理和你的 Bot 做周复盘。数据不经过任何第三方。";
    // 只读；但 iOS 要求声明了 HealthKit 的 App 两个描述都在
    cfg.modResults.NSHealthUpdateUsageDescription = "Rakazo 不会写入健康数据。";
    return cfg;
  });
};
