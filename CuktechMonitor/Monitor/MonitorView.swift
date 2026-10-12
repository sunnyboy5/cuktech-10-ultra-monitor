import SwiftUI

// 菜单栏监控面板 —— 简约原生风
// 注意: 面板是 NSPanel, 在此环境下不要用 SwiftUI sheet / Menu,
//       弹窗一律走 NSAlert, 按钮全用图标, 避免渲染空白与崩溃
struct MonitorView: View {
    @EnvironmentObject private var ble: BLEManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if ble.peripherals.count > 1 { deviceStrip }
            Divider().opacity(0.2).padding(.vertical, 10)
            totalPower
            portRows
            Divider().opacity(0.2).padding(.vertical, 10)
            footer
        }
        .padding(14)
        .frame(width: 336)
        .background(.ultraThinMaterial)
        .onAppear { ble.startScan() }
    }

    // MARK: - 顶部一行

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if let rssi = ble.status.rssi {
                Text("\(rssi) dBm")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch ble.status.phase {
        case .ready: return .green
        case .scanning, .connecting, .discovering, .authenticating: return .orange
        case .idle: return Color.secondary.opacity(0.6)
        case .disconnected: return .red
        }
    }

    private var statusText: String {
        switch ble.status.phase {
        case .ready: return "酷态科 10 Ultra"
        case .scanning: return "搜索设备…"
        case .connecting: return "连接中…"
        case .discovering: return "同步设备信息…"
        case .authenticating: return "认证中…"
        case .idle: return "待机"
        case .disconnected(let reason): return "断开 · \(reason)"
        }
    }

    // MARK: - 设备选择条 (附近存在多台设备时显示)

    private var deviceStrip: some View {
        HStack(spacing: 6) {
            Text("设备")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            ForEach(ble.peripherals.prefix(4)) { dev in
                let isTarget = ble.status.deviceIdentifier == dev.id.uuidString
                Button {
                    ble.connect(to: dev)
                } label: {
                    Text(dev.name)
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isTarget ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                .cornerRadius(4)
                .foregroundStyle(isTarget ? .primary : .secondary)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - 总功率

    private var totalPower: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("总功率")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(String(format: "%.1f", ble.status.totalPower))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ble.status.totalPower > 0 ? .primary : Color.secondary.opacity(0.45))
                Text("W")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 端口列表

    private var portRows: some View {
        VStack(spacing: 0) {
            ForEach(1...4, id: \.self) { piid in
                portRow(ble.status.ports[piid] ?? .zero)
            }
        }
    }

    private func portRow(_ p: PortInfo) -> some View {
        HStack(spacing: 8) {
            Text(p.displayName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 46, alignment: .leading)
            Text(p.protocolName)
                .font(.system(size: 10))
                .foregroundStyle(p.active ? .secondary : Color.secondary.opacity(0.4))
                .frame(width: 40, alignment: .leading)
            Spacer()
            Text(String(format: "%.1f V · %.2f A", p.voltage, p.current))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(String(format: "%.1f W", p.power))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(p.active ? .primary : Color.secondary.opacity(0.45))
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    // MARK: - 底部 (图标按钮)

    private var footer: some View {
        HStack(spacing: 14) {
            Text(lastUpdateText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if ble.tokenHex.isEmpty {
                Button {
                    presentSettingsAlert()
                } label: {
                    Text("设置 Token")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                presentSettingsAlert()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("设置 (Token / 刷新率)")

            Button {
                ble.startScan()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("重新扫描")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("退出")
        }
    }

    // MARK: - 设置弹窗 (token + 刷新率, NSAlert 在面板环境下最可靠)

    private func presentSettingsAlert() {
        let alert = NSAlert()
        alert.messageText = "设置"
        alert.informativeText = "Token: 12 字节 (24 位十六进制), 从米家账号提取。\n刷新率: 设备推送停歇时主动查询的间隔。"

        // 组合控件: 上 = token 输入, 下 = 刷新率选择
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 74))
        let tokenField = NSTextField(frame: NSRect(x: 0, y: 48, width: 300, height: 24))
        tokenField.stringValue = ble.tokenHex
        tokenField.placeholderString = "24 位十六进制 token"
        accessory.addSubview(tokenField)

        let refreshLabel = NSTextField(labelWithString: "刷新率")
        refreshLabel.frame = NSRect(x: 0, y: 20, width: 60, height: 18)
        accessory.addSubview(refreshLabel)

        let values = [0.5, 1.0, 2.0, 3.0, 5.0]
        let popup = NSPopUpButton(frame: NSRect(x: 70, y: 14, width: 110, height: 26), pullsDown: false)
        popup.addItems(withTitles: values.map { String(format: "%.\(($0 * 10).truncatingRemainder(dividingBy: 10) == 0 ? 0 : 1)f 秒", $0) })
        if let idx = values.firstIndex(of: ble.refreshSeconds) { popup.selectItem(at: idx) }
        accessory.addSubview(popup)

        alert.accessoryView = accessory
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = tokenField
        alert.window.makeFirstResponder(tokenField)
        if alert.runModal() == .alertFirstButtonReturn {
            let t = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "")
            if !t.isEmpty { ble.saveToken(t) }
            ble.setRefresh(values[popup.indexOfSelectedItem])
            ble.stopScan()
            ble.startScan()
        }
    }

    private var lastUpdateText: String {
        let d = ble.status.lastUpdate
        if d == .distantPast { return "—" }
        let s = Int(Date().timeIntervalSince(d))
        if s < 0 { return "—" }
        if s < 60 { return "\(s)s 前" }
        return "\(s / 60)m 前"
    }
}