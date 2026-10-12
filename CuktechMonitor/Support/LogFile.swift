import Foundation

// 轻量文件日志: 写入 ~/Library/Logs/CuktechMonitor.log
// open 启动的 GUI 实例的 NSLog 统一日志不可靠, 文件日志用于排查
enum LogFile {
    static let path = NSHomeDirectory() + "/Library/Logs/CuktechMonitor.log"

    static func write(_ s: String) {
        let line = "[\(Date().formattedForLog)] " + s + "\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            try? fh.write(contentsOf: data)
            try? fh.close()
        } else {
            try? data.write(to: url)
        }
    }
}

extension Date {
    var formattedForLog: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: self)
    }
}