import Foundation

// MiOT Spec TLV 命令构建与响应解析 —— 移植自原项目 controller.py
//   - _build_miot_tlv:   GET/SET 命令明文
//   - _recv_get_response / _recv_set_response: 响应值提取
//
// 明文帧格式:
//   [total_len:1][0x20][seq:1][0x00][opcode:1][cnt:1][siid:1][piid:2 LE][tl:2 LE][value:N]
//   tl = (type_id << 12) | byte_length
//   type_id: 1=UINT8, 5=UINT32
//   GET: opcode=0x02, type_id=1(占位), value=0x00 → 总长 12
//   SET: opcode=0x00, type_id=1(U8) 或 5(U32)

enum MiOTCommand {

    /// 构建 MiOT 属性命令明文 (value == nil 表示 GET)
    static func buildTLV(seq: UInt8, siid: UInt8, piid: Int, value: Int?) -> Data {
        let opcode: UInt8
        let typeID: UInt16
        let valueBytes: Data
        if let v = value {
            opcode = 0x00  // SET
            if v <= 0xFF {
                typeID = 1
                valueBytes = Data([UInt8(v & 0xFF)])
            } else {
                typeID = 5
                valueBytes = Data([
                    UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                    UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)
                ])
            }
        } else {
            opcode = 0x02  // GET
            typeID = 1
            valueBytes = Data([0x00])
        }

        let tl = UInt16((typeID << 12) | UInt16(valueBytes.count))
        let totalLen = UInt8(11 + valueBytes.count)

        var d = Data([
            totalLen, 0x20, seq, 0x00, opcode, 0x01, siid,
            UInt8(piid & 0xFF), UInt8((piid >> 8) & 0xFF),
            UInt8(tl & 0xFF), UInt8(tl >> 8)
        ])
        d.append(valueBytes)
        return d
    }

    /// 从响应明文提取属性值
    /// GET Result: [0x11][0x20][seq][0x00][0x03][0x01][siid][piid][err_hi][err_lo][len][type][value...]
    static func valueFrom(pt: Data) -> Int? {
        guard pt.count > 13 else { return nil }
        let vlen = Int(pt[11])
        if vlen >= 4, pt.count >= 17 {
            let v = UInt32(pt[13]) | UInt32(pt[14]) << 8 | UInt32(pt[15]) << 16 | UInt32(pt[16]) << 24
            return Int(v)
        }
        return Int(pt[13])
    }

    /// 响应操作码 (pt[4]): 0x02=设备推送 0x03=GET结果 0x04=SET结果 0x01=SET ACK
    static func opcode(from pt: Data) -> UInt8 {
        pt.count > 4 ? pt[4] : 0xFF
    }
}