import CoreBluetooth

// 酷态科 10 Ultra 的 BLE 常量 —— 移植自原项目 src/cuktech_ble/protocol.py L135-199
enum BLEConstants {

    // 主服务: 小米 MiOT (等级 0xFE95 = 0000FE95-0000-1000-8000-00805F9B34FB)
    static let miotServiceUUID = CBUUID(string: "0000FE95-0000-1000-8000-00805F9B34FB")

    // 6 个特征 (全部 Write-Without-Response + Notify, 固件版本为 Read)
    static let charDeviceInfo = CBUUID(string: "0000001C-0000-1000-8000-00805F9B34FB")  // 设备信息查询
    static let charAuthCtrl   = CBUUID(string: "00000010-0000-1000-8000-00805F9B34FB")  // 认证控制
    static let charAuthData   = CBUUID(string: "00000019-0000-1000-8000-00805F9B34FB")  // 认证数据
    static let charCmdSend    = CBUUID(string: "0000001A-0000-1000-8000-00805F9B34FB")  // 命令发送
    static let charCmdRecv    = CBUUID(string: "0000001B-0000-1000-8000-00805F9B34FB")  // 命令接收 (实时数据)
    static let charFwVersion  = CBUUID(string: "00000004-0000-1000-8000-00805F9B34FB")  // 固件版本 (Read)

    // MiOT 属性定义 (SIID=2, 充电器服务)
    static let siidCharger: UInt8 = 2
    // PIID 1-4: 四个端口实时数据; 17/18: 硬件协议号 (C1C2 / C3A)
    static let portPIIDs = [1, 2, 3, 4]
    static let piidNames: [Int: String] = [
        1: "C1口数据", 2: "C2口数据", 3: "C3口数据", 4: "A口数据",
        5: "场景模式", 6: "息屏时间", 7: "协议控制", 8: "倒计时设置",
        13: "语言", 16: "端口控制", 17: "C1C2协议号", 18: "C3A协议号"
    ]

    // 端口控制位掩码 (PIID 16): bit0=C1 bit1=C2 bit2=C3 bit3=A
    static let portBits: [String: Int] = ["c1": 0, "c2": 1, "c3": 2, "a": 3]

    // 常用 ACK / 握手字节串
    static let rcvRdy = Data([0x00, 0x00, 0x01, 0x01])   // RCV_RDY: 准备接收多帧
    static let rcvOK  = Data([0x00, 0x00, 0x01, 0x00])   // RCV_OK:  接收完成
    static let ackInline = Data([0x00, 0x00, 0x03, 0x00]) // 内联帧 ACK
    static let keepalive = Data([0x00, 0x00, 0x00, 0x00]) // 保活 (对应 ble_manager keepalive)

    // 协议名映射 (对应原项目 PROTOCOL_NAMES, 调试显示用)
    static let protocolNames: [UInt8: String] = [
        0x01: "PD", 0x03: "PD", 0x04: "PD", 0x05: "PD", 0x06: "PD",
        0x07: "PD Fixed", 0x08: "PD PPS", 0x0A: "PD", 0x0B: "PD",
        0x30: "PD", 0x60: "USB-A", 0x70: "QC", 0x80: "PD"
    ]
}