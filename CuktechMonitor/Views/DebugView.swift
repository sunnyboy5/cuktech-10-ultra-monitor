import SwiftUI

// 第一阶段: BLE 调试版 —— 验证「macOS 能否认证读取酷态科 10 Ultra」
struct DebugView: View {
    @EnvironmentObject private var ble: BLEManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                deviceSection
                portsSection
                characteristicsSection
                authSection
                logsSection
            }
            .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("酷态科 10 Ultra · BLE 调试版")
    }

    // MARK: - 顶部状态

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("酷态科 10 Ultra · BLE 调试版")
                    .font(.title3.bold())
                Spacer()
                phaseBadge
            }

            HStack(spacing: 24) {
                infoItem("固件", ble.status.firmware.isEmpty ? "—" : ble.status.firmware)
                infoItem("型号", ble.status.deviceModel.isEmpty ? "—" : ble.status.deviceModel)
                infoItem("信号", ble.status.rssi.map { "\($0) dBm" } ?? "—")
                infoItem("更新", ble.status.lastUpdate == .distantPast ? "—" : timeAgo(ble.status.lastUpdate))
            }
            .font(.callout)
        }
    }

    private var phaseBadge: some View {
        let (text, color): (String, Color) = {
            switch ble.status.phase {
            case .idle: return ("待机", .secondary)
            case .scanning: return ("扫描中…", .blue)
            case .connecting: return ("连接中…", .orange)
            case .discovering: return ("发现服务…", .orange)
            case .authenticating: return ("认证中…", .orange)
            case .ready: return ("已连接 · 接收数据", .green)
            case .disconnected(let reason): return ("已断开 · \(reason)", .red)
            }
        }()
        return Text(text)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(6)
    }

    private func infoItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value).font(.callout).monospacedDigit()
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 0 { return "—" }
        if s < 60 { return "\(s) 秒前" }
        return "\(s / 60) 分前"
    }

    // MARK: - 设备扫描

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("设备").font(.headline)

            HStack(spacing: 8) {
                TextField("设备 Token (12 字节, 24 位十六进制)", text: bindingToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: 420)
                if ble.tokenHex.count == 24 {
                    Text("✓").foregroundColor(.green)
                } else {
                    Text("需要 12 字节").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(ble.scanning ? "停止扫描" : "扫描设备") {
                    ble.scanning ? ble.stopScan() : ble.startScan()
                }
                Button("重新扫描") { ble.startScan() }
                    .disabled(ble.scanning)
                Button("断开") { ble.disconnect() }
                    .disabled(ble.status.phase == .idle)
            }
            .font(.callout)

            Text("Token 获取: 在米家 App 绑定该充电器后, 用第三方提取器 (如 Xiaomi-cloud-tokens-extractor) 从你的小米账号取出 12 字节 token。App 不会联网。")
                .font(.caption)
                .foregroundColor(.secondary)

            if !ble.peripherals.isEmpty {
                VStack(spacing: 4) {
                    ForEach(ble.peripherals) { dev in
                        HStack {
                            Text(dev.name).frame(width: 160, alignment: .leading)
                            Text(dev.id.uuidString)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("\(dev.rssi) dBm").font(.callout).monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                            if isConnected(id: dev.id) {
                                Text("已连接").foregroundColor(.green)
                            } else {
                                Button("连接") { ble.connect(to: dev) }
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                        .cornerRadius(6)
                    }
                }
            } else if ble.scanning {
                Text("扫描中, 未发现 0xFE95 设备…").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var bindingToken: Binding<String> {
        Binding(get: { ble.tokenHex }, set: { ble.saveToken($0) })
    }

    private func isConnected(id: UUID) -> Bool {
        ble.status.deviceIdentifier == id.uuidString && ble.status.isConnected
    }

    // MARK: - 端口功率

    private var portsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("实时功率").font(.headline)

            HStack(alignment: .bottom, spacing: 24) {
                Text(String(format: "%.1f", ble.status.totalPower))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("W")
                    .font(.title2)
                    .padding(.bottom, 8)
                Text("总功率 (C1+C2+C3+USB-A)")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.bottom, 10)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(1...4, id: \.self) { piid in
                    portCard(ble.status.ports[piid] ?? .zero)
                }
            }
        }
    }

    private func portCard(_ p: PortInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(p.displayName).font(.callout.bold())
                Spacer()
                Text(p.protocolName)
                    .font(.caption2).foregroundColor(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12)).cornerRadius(4)
            }
            Text(String(format: "%.1f W", p.power))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(p.active ? .primary : .secondary)
            Text(String(format: "%.1f V · %.2f A", p.voltage, p.current))
                .font(.caption).foregroundColor(.secondary).monospacedDigit()
            Text(String(format: "status=0x%02X code=0x%02X", p.statusRaw, p.code))
                .font(.caption2).foregroundColor(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        .cornerRadius(8)
    }

    // MARK: - 特征明细

    private var characteristicsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Service 0xFE95 · Characteristic").font(.headline)
            if ble.discoveredChars.isEmpty {
                Text("连接设备后显示。").font(.caption).foregroundColor(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(ble.discoveredChars) { c in
                        HStack(spacing: 12) {
                            Text(c.name).frame(width: 80, alignment: .leading).font(.callout)
                            Text(c.uuid).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                            Spacer()
                            Text(c.properties).font(.caption).foregroundColor(.secondary)
                            Text(c.notifyOn ? "通知开启" : "通知关闭")
                                .font(.caption2)
                                .foregroundColor(c.notifyOn ? .green : .secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    // MARK: - 认证步骤

    private var authSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("认证流程").font(.headline)
            if ble.authSteps.isEmpty {
                Text("未开始认证。" ).font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(Array(ble.authSteps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 6) {
                        Text("·").foregroundColor(.orange)
                        Text(step).font(.caption).monospaced()
                    }
                }
            }
        }
    }

    // MARK: - 日志

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("通信日志").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                logBox(title: "原始 HEX (BLE 帧)", lines: ble.status.rawLog)
                logBox(title: "解密后明文 / 解析", lines: ble.status.plainLog)
            }
        }
    }

    private func logBox(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.suffix(200).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(4)
            }
            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 260)
            .background(Color(nsColor: .underPageBackgroundColor))
            .cornerRadius(6)
        }
        .frame(maxWidth: .infinity)
    }
}