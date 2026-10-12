import Foundation

extension Data {
    /// 大写十六进制字符串 (调试日志用)
    var hex: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// 无空格紧凑十六进制
    var hexCompact: String {
        map { String(format: "%02X", $0) }.joined()
    }
}

extension String {
    /// 去掉冒号/空格/0x 前缀后转为 Data (hex)
    func hexData() -> Data {
        var hex = uppercased()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
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