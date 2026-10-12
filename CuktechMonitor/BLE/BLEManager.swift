import Foundation
import CoreBluetooth

// BLE 通信层 —— 对应原项目 ble_manager.py, 通信原语替换为 CoreBluetooth:
//   BleakScanner.find_device_by_address → CBCentralManager 扫描 (按 0xFE95 过滤)
//   BleakClient.connect → central.connect(peripheral)
//   client.write_gatt_char(uuid, data, response=False) → peripheral.writeValue(from:.withoutResponse)
//   client.start_notify(uuid, handler) → peripheral.setNotifyValue(true, for:)
//   bluetoothctl power cycle → 不需要 (macOS 系统管理蓝牙)

@MainActor
final class BLEManager: NSObject, ObservableObject {

    struct DiscoveredDevice: Identifiable, Equatable {
        let id: UUID
        let peripheral: CBPeripheral
        var name: String
        var rssi: Int
    }

    struct CharInfo: Identifiable {
        let id: String
        let uuid: String
        let name: String
        let properties: String
        var notifyOn: Bool
    }

    // MARK: - 对外状态

    @Published var peripherals: [DiscoveredDevice] = []
    @Published var status = DeviceStatus()
    @Published var discoveredChars: [CharInfo] = []
    @Published var authSteps: [String] = []
    @Published var scanning = false
    @Published var tokenHex: String = AppConfig.tokenHex

    // MARK: - 内部状态

    private var central: CBCentralManager!
    private var channel: CommandChannel?
    private var sessionTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var activePeripheral: CBPeripheral?
    private var reconnectAttempts = 0
    private var charMap: [CBUUID: CBCharacteristic] = [:]
    private var pendingNotifyCount = 0
    private var lastPortPush = Date.distantPast
    private var lastKeepalive = Date.distantPast
    private var lastRefresh = Date.distantPast
    private var fwResume: ((String) -> Void)?
    private var hwProtocol: [Int: UInt8] = [:]
    private var authenticator: MiOTAuthenticator?
    private var authFailureStreak = 0  // 连续认证失败次数 → 重连退避

    private let charChannelNames: [CBUUID: String] = [
        BLEConstants.charDeviceInfo: "dev_info",
        BLEConstants.charAuthCtrl: "auth_ctrl",
        BLEConstants.charAuthData: "auth_data",
        BLEConstants.charCmdSend: "cmd_send",
        BLEConstants.charCmdRecv: "cmd_recv",
    ]

    private let charDisplayNames: [CBUUID: String] = [
        BLEConstants.charDeviceInfo: "设备信息",
        BLEConstants.charAuthCtrl: "认证控制",
        BLEConstants.charAuthData: "认证数据",
        BLEConstants.charCmdSend: "命令发送",
        BLEConstants.charCmdRecv: "命令接收",
        BLEConstants.charFwVersion: "固件版本",
    ]

    override init() {
        LogFile.write("[BLE] BLEManager init, 创建 CBCentralManager...")
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        LogFile.write("[BLE] CBCentralManager 已创建")
    }

    // 运行时诊断 (stdout/os_log + 文件日志, open 实例也能查)
    private func dlog(_ s: String) {
        LogFile.write("[CuktechBLE] " + s)
        NSLog("[CuktechBLE] %@", s)
    }

    deinit {
        sessionTask?.cancel()
        reconnectTask?.cancel()
    }

    // MARK: - 用户动作

    func saveToken(_ newToken: String) {
        var t = newToken.replacingOccurrences(of: " ", with: "").uppercased()
        if t.hasPrefix("0x") { t = String(t.dropFirst(2)) }
        tokenHex = t
        AppConfig.tokenHex = t
    }

    func startScan() {
        guard central.state == .poweredOn else {
            status.phase = .disconnected("蓝牙未就绪 (state=\(central.state.rawValue))")
            return
        }
        peripherals.removeAll()
        scanning = true
        central.scanForPeripherals(withServices: [BLEConstants.miotServiceUUID], options: nil)
        autoConnectIfPossible()
    }

    func stopScan() {
        scanning = false
        central.stopScan()
    }

    func connect(to device: DiscoveredDevice) {
        stopScan()
        autoConnectTask?.cancel()
        reconnectAttempts = 0
        activePeripheral = device.peripheral
        activePeripheral?.delegate = self
        status.deviceName = device.name
        status.deviceIdentifier = device.id.uuidString
        status.phase = .connecting
        central.connect(device.peripheral, options: nil)
    }

    // MARK: - 自动连接 (悬浮窗模式)

    /// 判断名字是否像酷态科充电器
    static func isCuktech(_ name: String) -> Bool {
        let n = name.uppercased()
        return n.contains("CUKTECH") || n.contains("ULTRA") || n.contains("CHARGER") || n.contains("AD1204")
    }

    private var autoConnectTask: Task<Void, Never>?
    // 多设备候选: 广播名多为空, 只能逐个连接后用设备信息判定哪台是充电器
    private var blacklist: Set<String> = []          // 已判定非充电器的 identifier
    private var candidateQueue: [String] = []        // 待尝试的 identifier 队列
    private var currentCandidate: String?            // 当前正在尝试的 identifier

    /// 扫描到设备后自动选择目标: 连接台设备, 逐个用设备信息判定充电器
    func autoConnectIfPossible() {
        autoConnectTask?.cancel()
        autoConnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.status.phase == .idle || self.status.phase == .scanning else { return }
            guard !self.peripherals.isEmpty else { return }
            // 名称匹配酷态科的排前面优先尝试
            self.candidateQueue = self.peripherals
                .filter { !self.blacklist.contains($0.id.uuidString) }
                .sorted { BLEManager.isCuktech($0.name) && !BLEManager.isCuktech($1.name) }
                .map { $0.id.uuidString }
            self.currentCandidate = nil
            self.tryNextCandidate()
        }
    }

    /// 尝试连接候选队列中的下一台
    private func tryNextCandidate() {
        while let id = candidateQueue.first {
            candidateQueue.removeFirst()
            currentCandidate = id
            if let dev = peripherals.first(where: { $0.id.uuidString == id }) {
                dlog("尝试候选设备: \(id)")
                connect(to: dev)
                return
            }
        }
        currentCandidate = nil
        status.phase = .idle
        dlog("候选设备均已尝试完, 8s 后重新扫描 (等待充电器广播)")
        // 设备可能暂时没广播 (重启/休眠), 8s 后自动重新扫描一次
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.status.phase == .idle || self.status.phase == .scanning {
                self.startScan()
            }
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        sessionTask?.cancel()
        sessionTask = nil
        if let p = activePeripheral, p.state == .connected {
            central.cancelPeripheralConnection(p)
        }
        activePeripheral = nil
        channel?.reset()
        channel = nil
        status.phase = .idle
    }

    // MARK: - 会话编排 (连接并完成发现/订阅后执行)

    private func startSession() {
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            guard let self else { return }
            await self.runSession()
        }
    }

    private func runSession() async {
        guard let peripheral = activePeripheral, let channel else { return }

        // 1. 读设备信息 (无需认证)
        status.phase = .discovering
        status.log("== 读取设备信息 (无需认证) ==")
        var isCharger = false
        channel.writeTo(BLEConstants.charDeviceInfo, Data([0x00]))
        if let d = await channel.wait("dev_info", timeout: 2.0), d.count >= 2 {
            status.log("协议版本: v\(d[1]).\(d.count > 2 ? d[2] : 0)")
        }
        channel.writeTo(BLEConstants.charDeviceInfo, Data([0x03]))
        if let d = await channel.wait("dev_info", timeout: 2.0), d.count > 2 {
            let chipLen = Int(d[1])
            let chip = String(bytes: d[2..<min(d.count, 2 + chipLen)], encoding: .ascii) ?? ""
            status.deviceModel = "njcuk.fitting.ad1204_\(chip)"
            status.log("芯片: \(chip) → \(status.deviceModel)")
            isCharger = !chip.isEmpty   // 能返回芯片信息才算充电器
        }
        // 候选流程下判定: 不是充电器就换下一台 (附近可能有温湿度计等其它 FE95 设备)
        if !isCharger {
            blacklist.insert(peripheral.identifier.uuidString)
            dlog("非充电器设备(无芯片信息), 加入黑名单: \(peripheral.identifier)")
            status.log("✗ 非充电器设备 (无芯片信息), 尝试下一台")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        if let fwChar = charMap[BLEConstants.charFwVersion] {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                fwResume = { str in
                    if !str.isEmpty { self.status.firmware = str }
                    cont.resume()
                }
                peripheral.readValue(for: fwChar)
            }
        }

        // 2. 认证
        status.phase = .authenticating(0)
        let token = tokenData()
        let auth = MiOTAuthenticator(channel: channel, token: token)
        authenticator = auth
        let keys = await auth.authenticate()
        authSteps = auth.steps
        if let keys {
            authFailureStreak = 0
            dlog("A0 认证通过, 记录设备")
            currentCandidate = nil  // 认证成功, 候选流程结束, 后续断开按同一设备重连
            // 只有认证成功才算真正连对设备, 此时才记忆
            AppConfig.lastDeviceID = peripheral.identifier.uuidString
            AppConfig.lastDeviceName = status.deviceName
            dlog("A1 设备已记录")
            status.logPlain("√ 认证成功, 会话密钥已建立 (dev_key=\(keys.devKey.hex), app_key=\(keys.appKey.hex))")
            status.logPlain("  dev_iv=\(keys.devIV.hex) app_iv=\(keys.appIV.hex)")
            status.phase = .ready
            status.lastUpdate = Date()
            dlog("A2 状态已就绪, sleep 300ms")
            try? await Task.sleep(nanoseconds: 300_000_000)
            dlog("A3 sleep 结束, 排空初始推送...")
            // 对齐原项目 _setup_cmd_channel: 认证成功后设备会推送一批初始端口数据,
            // 必须先按时序 ACK 排空, 否则后续 GET 请求设备不应答
            await drainDevicePush(channel)
            dlog("初始推送排空完成, 读取硬件协议号...")

            // 3. 主动读取硬件协议号 (PIID 17/18), 验证 GET 通道
            await refreshHwProtocols(channel)
            dlog("硬件协议号读取完成, 进入主循环")

            // 4. 主循环: 持续监听 cmd_recv
            await mainLoop(peripheral, channel)
        } else {
            let last = auth.steps.last ?? "未知错误"
            if currentCandidate != nil {
                // 候选流程中: 认证失败视为该设备不匹配 (温湿度计等也会失败), 淘汰换下一台
                blacklist.insert(peripheral.identifier.uuidString)
                dlog("候选设备认证失败, 淘汰: \(peripheral.identifier)")
                status.phase = .disconnected("认证失败: \(last), 尝试下一台")
                status.log("✗ 认证失败: \(last), 尝试下一台设备")
                central.cancelPeripheralConnection(peripheral)
            } else {
                // 已确认设备: 认证失败走退避重试 (token 问题或设备会话卡死)
                authFailureStreak += 1
                dlog("认证失败(第\(authFailureStreak)次): \(last)")
                status.phase = .disconnected("认证失败: \(last)")
                status.log("✗ 认证失败: \(last)")
                central.cancelPeripheralConnection(peripheral)
            }
        }
    }

    // 刷新率 (秒): 主动查询间隔, 用户可在面板里调整
    private(set) var refreshSeconds: Double = AppConfig.refreshSeconds
    func setRefresh(_ seconds: Double) {
        refreshSeconds = seconds
        AppConfig.refreshSeconds = seconds
    }

    private func mainLoop(_ peripheral: CBPeripheral, _ channel: CommandChannel) async {
        while !Task.isCancelled && peripheral.state == .connected {
            // 快速档(<=1s)用 0.5s 短唤醒, 加快新接入设备的发现; 慢档按刷新率
            let waitTimeout = refreshSeconds <= 1.0 ? 0.5 : min(2.0, refreshSeconds)
            let frame = await channel.wait("cmd_recv", timeout: waitTimeout)
            if let frame {
                if let pt = await channel.processRecvFrame(frame) {
                    handlePlain(pt, channel: channel)
                }
            } else {
                // 空闲: 保活 + 按刷新率兜底主动查询
                // (设备刚推送过则不重复查; 否则每个周期都查, 避免跳轮)
                let now = Date()
                if now.timeIntervalSince(lastKeepalive) > 30 {
                    channel.writeTo(BLEConstants.charCmdRecv, BLEConstants.keepalive)
                    lastKeepalive = now
                }
                if now.timeIntervalSince(lastRefresh) >= refreshSeconds,
                   now.timeIntervalSince(lastPortPush) >= 0.6 {
                    // 快速档(<=1s)才启用自适应: 活跃端口快刷, 空闲端口低频
                    // 高密度查询会触发设备节流, 默认 2s 用全量轮询保稳定
                    await fetchPorts(channel, activeOnly: refreshSeconds <= 1.0)
                }
            }
        }
        if !Task.isCancelled {
            status.phase = .disconnected("连接丢失 (主循环退出)")
        }
    }

    // MARK: - 数据解析

    private func handlePlain(_ pt: Data, channel: CommandChannel) {
        guard pt.count >= 8 else { return }
        let b4 = pt[4]
        let siid = pt.count > 6 ? pt[6] : 0
        let piid = pt.count > 7 ? Int(pt[7]) : -1

        status.logPlain("解密: \(pt.prefix(24).hex)  opcode=0x\(String(format: "%02X", b4)) siid=\(siid) piid=\(piid)")

        guard siid == BLEConstants.siidCharger else { return }

        if b4 == 0x02, (1...4).contains(piid) {
            // 端口实时推送
            if let port = PortDecoder.decode(piid: piid, plaintext: pt, hwProtocol: hwProtocol[piid]) {
                status.ports[piid] = port
                status.lastUpdate = Date()
                lastPortPush = Date()
                dlog("推送 P\(piid): \(port.voltage)V \(port.current)A \(port.power)W")
                status.logPlain("→ \(port.displayName): V=\(port.voltage) I=\(port.current) P=\(port.power)W [status=0x\(String(format: "%02X", port.statusRaw)) code=0x\(String(format: "%02X", port.code))] proto=\(port.protocolName)")
            }
        } else if b4 == 0x02, piid == 17 || piid == 18 {
            updateHwProtocol(v32: MiOTCommand.valueFrom(pt: pt) ?? 0, piid: piid)
        }
        _ = channel
    }

    private func updateHwProtocol(v32: Int, piid: Int) {
        let v = UInt32(truncatingIfNeeded: v32)
        // 布局 MSB→LSB: [hi_proto][hi_power][lo_proto][lo_power]
        let hi = UInt8((v >> 24) & 0xFF)
        let lo = UInt8((v >> 8) & 0xFF)
        if piid == 17 { hwProtocol[1] = hi; hwProtocol[2] = lo }
        if piid == 18 { hwProtocol[3] = hi; hwProtocol[4] = lo }
        status.logPlain("PIID\(piid) 硬件协议: hi=\(hi) lo=\(lo) (0x\(String(format: "%08X", v)))")
    }

    private func refreshHwProtocols(_ channel: CommandChannel) async {
        for piid in [17, 18] {
            dlog("读取硬件协议号 PIID\(piid)...")
            if let v = await channel.get(BLEConstants.siidCharger, piid) {
                updateHwProtocol(v32: v, piid: piid)
            } else {
                dlog("读取硬件协议号 PIID\(piid) 失败/无响应")
            }
        }
        lastRefresh = Date()
    }

    /// 认证成功后排空设备初始推送 (对齐原项目 _drain_device_push + _drain_pending_pushes)
    /// 内联帧发 ACK 并尝试解析; 多帧走 RCV_RDY/RCV_OK 协议
    private func drainDevicePush(_ channel: CommandChannel) async {
        var pushCount = 0
        let deadline = Date().addingTimeInterval(6.0)
        while pushCount < 60, Date() < deadline {
            guard let data = await channel.wait("cmd_recv", timeout: 0.8) else { break }
            pushCount += 1
            if data.count >= 4, data[2] == 0x02 {
                // 内联推送: ACK + 尝试解密成端口数据
                channel.writeTo(BLEConstants.charCmdRecv, BLEConstants.ackInline)
                if let pt = channel.decryptFrameIfPossible(Data(data.dropFirst(4))) {
                    handlePlain(pt, channel: channel)
                }
            } else if data.count >= 6, data[2] == 0x00 {
                // 多帧: RCV_RDY → 排空 → RCV_OK
                let n = min(Int(data[4]) + Int(data[5]) * 0x100, 100)
                channel.writeTo(BLEConstants.charCmdRecv, BLEConstants.rcvRdy)
                for _ in 0..<n {
                    guard let f = await channel.wait("cmd_recv", timeout: 0.8) else { break }
                    if f.count >= 6, f[2] == 0x02 {
                        channel.writeTo(BLEConstants.charCmdRecv, BLEConstants.ackInline)
                        if let pt = channel.decryptFrameIfPossible(Data(f.dropFirst(4))) {
                            handlePlain(pt, channel: channel)
                        }
                    }
                }
                channel.writeTo(BLEConstants.charCmdRecv, BLEConstants.rcvOK)
            }
        }
        dlog("初始推送排空: 收到 \(pushCount) 条")
    }

    /// 兜底主动查询端口 (对应原项目 verify_port)
/// activeOnly=true 时: 有负载的端口每轮高频查询; 空闲端口 1s 节流(快速发现新接入)
    private var lastPortRefresh: [Int: Date] = [:]
    private func fetchPorts(_ channel: CommandChannel, activeOnly: Bool) async {
        lastRefresh = Date()
        let now = Date()
        var gotAny = false
        for piid in 1...4 {
            let ps = status.ports[piid]
            let isActive = (ps?.active ?? false) || (ps?.power ?? 0) > 0.2
            if activeOnly && !isActive {
                // 空闲端口 1s 节流: 既避免无谓占用通道, 又能秒级发现新插入的设备
                if now.timeIntervalSince(lastPortRefresh[piid] ?? .distantPast) < 1.0 { continue }
            }
            lastPortRefresh[piid] = now
            guard let v = await channel.get(BLEConstants.siidCharger, piid) else {
                dlog("GET P\(piid) 无响应 (通道可能繁忙)")
                status.log("GET P\(piid) 无响应")
                continue
            }
            gotAny = true
            let raw = UInt32(truncatingIfNeeded: v)
            let statusB = UInt8(raw & 0xFF)
            let codeB = UInt8((raw >> 8) & 0xFF)
            let cur = Double(UInt8((raw >> 16) & 0xFF)) / 10.0
            let vol = Double(UInt8((raw >> 24) & 0xFF)) / 10.0
            let active = statusB != 0 || vol > 0 || cur > 0
            let protoName = active
                ? (hwProtocol[piid].flatMap { hp in hp <= 10 ? PortDecoder.mijiaProtocols[hp] : nil } ?? PortDecoder.fallbackProtocol(piid: piid, voltage: vol))
                : "idle"
            status.ports[piid] = PortInfo(piid: piid, voltage: vol, current: cur, power: ((vol * cur) * 10).rounded() / 10,
                                          active: active, statusRaw: statusB, code: codeB, protocolName: protoName)
            status.lastUpdate = Date()
            lastPortPush = Date()
            dlog("GET P\(piid): \(vol)V \(cur)A \(String(format: "%.1f", vol * cur))W raw=0x\(String(format: "%08X", raw))")
            status.logPlain("GET P\(piid): raw=0x\(String(format: "%08X", raw)) → \(vol)V \(cur)A")
        }
        if !gotAny {
            status.log("本轮查询均无响应")
        }
    }

    private func tokenData() -> Data {
        var hex = tokenHex.replacingOccurrences(of: " ", with: "").uppercased()
        if hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard next <= hex.endIndex, let byte = UInt8(hex[idx..<next], radix: 16) else { break }
            bytes.append(byte)
            idx = next
        }
        return Data(bytes)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        dlog("central state -> \(central.state.rawValue)")
        if central.state == .poweredOn {
            status.log("蓝牙已就绪, 开始扫描 (Service 0xFE95)")
            startScan()
        } else {
            status.phase = .disconnected("蓝牙状态: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSINumber: NSNumber) {
        dlog("didDiscover \(peripheral.identifier) rssi=\(RSSINumber.intValue) name=\(peripheral.name ?? "nil")")
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "(未命名)"
        let rssi = RSSINumber.intValue
        if let idx = peripherals.firstIndex(where: { $0.id == peripheral.identifier }) {
            peripherals[idx].name = name
            peripherals[idx].rssi = rssi
        } else {
            peripherals.append(DiscoveredDevice(id: peripheral.identifier, peripheral: peripheral, name: name, rssi: rssi))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dlog("didConnect \(peripheral.identifier)")
        status.log("已连接, 发现服务...")
        status.phase = .discovering
        reconnectAttempts = 0
        peripheral.discoverServices([BLEConstants.miotServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dlog("didFailToConnect: \(error.map { "\($0)" } ?? "nil")")
        status.phase = .disconnected("连接失败: \(error?.localizedDescription ?? "未知")")
        scheduleReconnect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dlog("didDisconnect error=\(error.map { "\($0)" } ?? "nil")")
        guard peripheral == activePeripheral else { return }
        let reason = error.map { " (\($0.localizedDescription))" } ?? ""
        status.phase = .disconnected("设备已断开\(reason)")
        status.log("✗ 连接断开\(reason)")
        sessionTask?.cancel()
        sessionTask = nil
        scheduleReconnect(to: peripheral)
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            status.phase = .disconnected("服务发现失败: \(error!.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == BLEConstants.miotServiceUUID }) else {
            status.phase = .disconnected("未找到 MiOT 服务 (0xFE95)")
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            status.phase = .disconnected("特征发现失败: \(error!.localizedDescription)")
            return
        }
        charMap.removeAll()
        discoveredChars.removeAll()
        pendingNotifyCount = 0

        for c in service.characteristics ?? [] {
            charMap[c.uuid] = c
            discoveredChars.append(CharInfo(
                id: c.uuid.uuidString,
                uuid: c.uuid.uuidString,
                name: charDisplayNames[c.uuid] ?? "未知",
                properties: describeProps(c.properties),
                notifyOn: false
            ))
            if charChannelNames[c.uuid] != nil {
                peripheral.setNotifyValue(true, for: c)
                pendingNotifyCount += 1
            }
        }

        if pendingNotifyCount == 0 {
            startSession()
        }
        // 订阅结果在 didUpdateNotificationStateFor 汇总
    }

    private func describeProps(_ p: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if p.contains(.read) { parts.append("读") }
        if p.contains(.write) { parts.append("写") }
        if p.contains(.writeWithoutResponse) { parts.append("写无回") }
        if p.contains(.notify) { parts.append("通知") }
        if p.contains(.indicate) { parts.append("指示") }
        return parts.joined(separator: ",")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let idx = discoveredChars.firstIndex(where: { $0.id == characteristic.uuid.uuidString }) {
            discoveredChars[idx].notifyOn = characteristic.isNotifying
            status.log("订阅 \(charDisplayNames[characteristic.uuid] ?? characteristic.uuid.uuidString): \(characteristic.isNotifying ? "开" : "关")\(error != nil ? " (\(error!.localizedDescription))" : "")")
        }
        pendingNotifyCount = max(0, pendingNotifyCount - 1)
        if pendingNotifyCount == 0, error == nil {
            // 全部通知通道订阅完成, 初始化命令通道
            if channel == nil {
                channel = makeChannel(peripheral: peripheral)
            }
            startSession()
        }
    }

    private func makeChannel(peripheral: CBPeripheral) -> CommandChannel {
        let ch = CommandChannel(writer: { [weak self] uuid, data in
            guard let self else { return }
            guard let c = self.charMap[uuid] else { return }
            guard let p = self.activePeripheral else { return }
            p.writeValue(data, for: c, type: .withoutResponse)
        })
        ch.setOnRawFrame { [weak self] data, name in
            self?.status.log("[\(name)] \(data.hex)")
        }
        ch.setOnPortPush { [weak self] pt, _, piid in
            guard let self else { return }
            self.status.logPlain("多帧转发: piid=\(piid) \(pt.prefix(20).hex)")
            if piid >= 1 && piid <= 4 {
                if let port = PortDecoder.decode(piid: piid, plaintext: pt, hwProtocol: self.hwProtocol[piid]) {
                    self.status.ports[piid] = port
                    self.status.lastUpdate = Date()
                    self.lastPortPush = Date()
                }
            }
        }
        return ch
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == BLEConstants.charFwVersion {
            var str = ""
            if error == nil, let data = characteristic.value {
                str = String(bytes: data, encoding: .ascii)?.trimmingCharacters(in: .init(charactersIn: "\0")) ?? ""
                status.firmware = str
                status.log("固件版本: \(str)")
            }
            fwResume?(str)
            fwResume = nil
            return
        }
        if let name = charChannelNames[characteristic.uuid], let data = characteristic.value {
            channel?.push(name, data: data)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil { status.rssi = RSSI.intValue }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Write-Without-Response 不触发此回调, 留空
    }
}

// MARK: - 重连

extension BLEManager {

    private func scheduleReconnect(to peripheral: CBPeripheral) {
        dlog("scheduleReconnect attempt=\(reconnectAttempts + 1) authStreak=\(authFailureStreak)")
        reconnectTask?.cancel()
        // 候选流程: 当前设备被判定为「非充电器」(已在黑名单) → 直接换下一台, 不重连同一台
        if let current = currentCandidate, blacklist.contains(current) {
            dlog("候选淘汰, 换下一台")
            tryNextCandidate()
            return
        }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let attempt = self.reconnectAttempts
            self.reconnectAttempts += 1
            // 认证失败时退避 (对齐原项目 _auth_backoff_delay: 2*count 封顶, 这里封顶 3 分钟)
            let backoff: TimeInterval
            if self.authFailureStreak > 0 {
                backoff = min(Double(30 * self.authFailureStreak), 180)
            } else {
                let base = min(1.0 * pow(2.0, Double(min(self.reconnectAttempts, 5))), 30.0)
                let jitter = base * 0.25 * Double.random(in: -1...1)
                backoff = max(0.5, base + jitter)
            }
            self.status.log(String(format: "%.0fs 后自动重连 (第 %d 次)...", backoff, attempt + 1))
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let p = peripheral
            self.status.phase = .connecting
            self.central.connect(p, options: nil)
        }
    }
}