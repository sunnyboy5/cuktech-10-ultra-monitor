import Foundation

// 本地配置 (仅保存 token/设备记忆, 不上传任何数据)
// 监控版与调试版共用同一个 suite, 换 App 不用重新填 token
enum AppConfig {
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: "local.cuktech.monitor.shared") ?? .standard
    }

    // 旧调试版的存储域 (拆分前的 bundle id), 用于自动迁移 token
    private static var legacyDefaults: UserDefaults? {
        UserDefaults(suiteName: "local.cuktech.monitor.debug")
    }

    private static let tokenKey = "miot.token"
    private static let deviceKey = "miot.lastDeviceID"

    static var tokenHex: String {
        get {
            if let v = defaults.string(forKey: tokenKey), !v.isEmpty { return v }
            if let v = UserDefaults.standard.string(forKey: tokenKey), !v.isEmpty { return v }
            if let v = legacyDefaults?.string(forKey: tokenKey), !v.isEmpty {
                // 首次读到旧值后写回新存储, 完成迁移
                defaults.set(v, forKey: tokenKey)
                return v
            }
            return ""
        }
        set {
            defaults.set(newValue, forKey: tokenKey)
            UserDefaults.standard.set(newValue, forKey: tokenKey)
        }
    }

    static var tokenData: Data {
        tokenHex.hexData()
    }

    // 上次成功连接的设备 identifier (自动重连用)
    static var lastDeviceID: String? {
        get {
            if let v = defaults.string(forKey: deviceKey) { return v }
            return UserDefaults.standard.string(forKey: deviceKey)
        }
        set {
            defaults.set(newValue, forKey: deviceKey)
            UserDefaults.standard.set(newValue, forKey: deviceKey)
        }
    }

    // 上次成功连接设备的名称 (仅诊断显示用)
    static var lastDeviceName: String? {
        get { defaults.string(forKey: "miot.lastDeviceName") }
        set { defaults.set(newValue, forKey: "miot.lastDeviceName") }
    }

    // 刷新率 (秒): 设备推送停歇时主动查询的间隔
    static var refreshSeconds: Double {
        get {
            if defaults.object(forKey: "miot.refresh") == nil { return 1.0 }
            let v = defaults.double(forKey: "miot.refresh")
            return v > 0 ? v : 1.0
        }
        set { defaults.set(newValue, forKey: "miot.refresh") }
    }
}