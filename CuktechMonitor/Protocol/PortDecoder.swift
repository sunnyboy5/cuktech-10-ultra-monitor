import Foundation

// 端口数据解码 —— 移植自原项目 state_protocol_v2.py (decode_port / RawPortData)
//
// 权威来源: BLE 推送帧解密后的明文, 最后一个 value 字段取最后 4 字节:
//   [status] [code] [current_raw] [voltage_raw]
//   current = current_raw / 10.0  (A)
//   voltage = voltage_raw / 10.0  (V)
//   power   = voltage × current   (W)
//
// 说明: 原项目注释声称当前/电压精度为 ×10mA / ×10mV, 但代码实际为 /10.0 得 A/V。
// 本调试版会同时打印原始字节便于实机对照确认(见 decode 返回的 statusRaw/code)。

enum PortDecoder {

    // 米家协议号 → 名称 (state_protocol_v2.py MIJIA_PROTOCOLS)
    static let mijiaProtocols: [UInt8: String] = [
        0: "idle", 1: "5V", 2: "5V", 3: "QC", 4: "AFC", 5: "FCP",
        6: "SCP", 7: "PD", 8: "PPS", 9: "PPS", 10: "UFCS"
    ]

    // PD Fixed 档位 (失败兜底用)
    static let pdFixedVoltages: [Double] = [5.0, 9.0, 12.0, 15.0, 20.0]

    /// 电压兜底协议判定 (仅在 PIID 17/18 硬件协议号缺失时使用)
    static func fallbackProtocol(piid: Int, voltage: Double) -> String {
        let num: UInt8
        if piid == 4 {  // USB-A
            num = voltage > 5.5 ? 3 : 1
        } else if piid == 3 {  // C3
            if voltage >= 15.0 { num = 7 }
            else { num = voltage >= 8.5 ? 3 : 1 }
        } else {  // C1/C2
            if voltage <= 5.5 { num = 1 }
            else if pdFixedVoltages.contains(where: { abs($0 - voltage) < 0.25 }) { num = 7 }
            else { num = 8 }
        }
        return mijiaProtocols[num] ?? "Unknown"
    }

    /// 从解密后的 MiOT 属性明文解码端口数据
    static func decode(piid: Int, plaintext: Data, hwProtocol: UInt8?) -> PortInfo? {
        guard plaintext.count >= 12 else { return nil }
        let b = Array(plaintext.suffix(4))
        let status = b[0]
        let code = b[1]
        let voltage = Double(b[3]) / 10.0
        let current = Double(b[2]) / 10.0
        let active = (b[0] != 0) || voltage > 0 || current > 0

        // 硬件协议号优先级 (与 estimate_protocol_number 一致)
        var protoName = "idle"
        if active {
            if let hp = hwProtocol, hp > 0 {
                if hp <= 10 {
                    protoName = mijiaProtocols[hp] ?? "Unknown"
                } else {
                    // C3/A 口的 MiOT code (0x60=USB-A, 0x70=QC, 0x80=PD)
                    protoName = (hp == 0x70 ? "QC" : (hp == 0x80 ? "PD" : "Unknown"))
                }
            } else {
                protoName = fallbackProtocol(piid: piid, voltage: voltage)
            }
        }

        return PortInfo(piid: piid,
                        voltage: (voltage * 10).rounded() / 10,
                        current: (current * 10).rounded() / 10,
                        power: ((voltage * current) * 10).rounded() / 10,
                        active: active,
                        statusRaw: status,
                        code: code,
                        protocolName: active ? protoName : "idle")
    }

    /// 解码 PIID 17/18 的 u32 硬件协议号 (byte[0]=高口协议, byte[2]=低口协议)
    static func decodeHwProtocol(value32: UInt32, isC3A: Bool = false) -> UInt8 {
        // 布局 MSB→LSB: [hi_proto][hi_power][lo_proto][lo_power]
        let hi = UInt8((value32 >> 24) & 0xFF)
        let lo = UInt8((value32 >> 8) & 0xFF)
        return isC3A ? hi : hi  // 两端口轮流查询, 上层按需取 hi/lo
    }
}