import SwiftUI

// 调试版入口 —— 独立 App「酷态科调试器」
// 提供 token 填写 / BLE 扫描 / 原始 HEX 日志 / 认证步骤, 用于排查连接问题
@main
struct CuktechDebuggerApp: App {
    @StateObject private var ble = BLEManager()

    var body: some Scene {
        WindowGroup("酷态科 10 Ultra · BLE 调试版") {
            DebugView()
                .environmentObject(ble)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 880, height: 720)
    }
}