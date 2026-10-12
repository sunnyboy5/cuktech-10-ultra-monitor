import SwiftUI

// 菜单栏监控版入口 —— 菜单栏图标直接显示实时总功率, 点击弹出监控面板
@main
struct CuktechMonitorApp: App {
    @StateObject private var ble = BLEManager()

    init() {
        LogFile.write("[APP] 启动 monitor 版")
    }

    var body: some Scene {
        MenuBarExtra {
            MonitorView()
                .environmentObject(ble)
                .onAppear {
                    LogFile.write("[APP] MonitorView 已显示")
                }
        } label: {
            MenuBarLabel(ble: ble)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 菜单栏标签: 图标 + 实时总功率 (类似 iStat Menus)
private struct MenuBarLabel: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: ble.status.isConnected ? "bolt.fill" : "bolt")
                .font(.system(size: 11))
            if ble.status.isConnected {
                Text(String(format: "%.1fW", ble.status.totalPower))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel("酷态科 10 Ultra")
    }
}