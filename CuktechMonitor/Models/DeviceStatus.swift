import Foundation

// 单个充电端口的实时状态 (对应原项目 state_protocol_v2.py 的 decode_port 返回字段)
struct PortInfo: Equatable, Identifiable {
    let piid: Int             // 1=C1 2=C2 3=C3 4=USB-A
    var voltage: Double       // V
    var current: Double       // A
    var power: Double         // W = V × I
    var active: Bool
    var statusRaw: UInt8      // 0x00 空闲 / 0x01 单口 / 0x11 C3+A 合并
    var code: UInt8           // PDO 档位/硬件状态字节 (非协议号)
    var protocolName: String  // idle / PD / PPS / QC ...

    var id: Int { piid }

    var displayName: String {
        switch piid {
        case 1: return "C1"
        case 2: return "C2"
        case 3: return "C3"
        case 4: return "USB-A"
        default: return "P\(piid)"
        }
    }

    static let zero = PortInfo(piid: 0, voltage: 0, current: 0, power: 0,
                               active: false, statusRaw: 0, code: 0, protocolName: "idle")
}

// 设备整体状态 (对应原项目 ChargerState, 第一版裁剪)
final class DeviceStatus: ObservableObject {
    enum ConnPhase: Equatable {
        case idle                 // 未开始
        case scanning             // 扫描中
        case connecting           // 已选中设备, 连接中
        case discovering          // 发现服务/特征中
        case authenticating(Int)  // 认证步骤 (1...N), 附带当前步骤描述
        case ready                // 认证成功, 接收数据中
        case disconnected(String) // 已断开, 附带原因
    }

    @Published var phase: ConnPhase = .idle
    @Published var deviceName: String = ""
    @Published var deviceIdentifier: String = ""   // CBPeripheral.identifier (macOS 没有设备 MAC)
    @Published var rssi: Int? = nil
    @Published var firmware: String = ""
    @Published var deviceModel: String = ""
    @Published var lastUpdate = Date.distantPast
    @Published var ports: [Int: PortInfo] = [1: .zero, 2: .zero, 3: .zero, 4: .zero]
    @Published var rawLog: [String] = []           // 原始 HEX 日志 (环形缓冲)
    @Published var plainLog: [String] = []         // 解密后 HEX 日志

    var totalPower: Double {
        ports.values.reduce(0) { $0 + $1.power }
    }

    var isConnected: Bool { phase == .ready }

    func log(_ s: String) { rawLog.append(s); if rawLog.count > 500 { rawLog.removeFirst(rawLog.count - 500) } }
    func logPlain(_ s: String) { plainLog.append(s); if plainLog.count > 500 { plainLog.removeFirst(plainLog.count - 500) } }
}