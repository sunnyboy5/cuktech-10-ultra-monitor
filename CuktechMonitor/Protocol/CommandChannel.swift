import Foundation
import CoreBluetooth

// 命令通道 —— 移植自原项目 controller.py 的帧收发状态机
//   - _send_encrypted:      发送 4 步握手 (header → RCV_RDY → frame → RCV_OK)
//   - _recv_auth_response:  认证响应 (内联/多帧两种格式)
//   - _try_decode_inline:   内联帧 ACK + 解密; 多帧头 RCV_RDY/RCV_OK
//   - wait_notify:          按通道的帧队列
//
// 约定: 所有方法在主线程调用 (CoreBluetooth 回调队列 = main)。

@MainActor
final class CommandChannel {

    // MARK: - 帧队列 (每通道一个, 对应原项目 wait_notify)

    private final class FrameQueue {
        private var buffer: [Data] = []
        private var waiters: [String: CheckedContinuation<Data?, Never>] = [:]
        private var order: [String] = []

        func push(_ data: Data) {
            if let id = order.first, let cont = waiters.removeValue(forKey: id) {
                order.removeFirst()
                cont.resume(returning: data)
                return
            }
            buffer.append(data)
        }

        /// 非阻塞取一帧, 无则 nil
        func popNow() -> Data? {
            buffer.isEmpty ? nil : buffer.removeFirst()
        }

        /// 取下一帧, 超时返回 nil (原项目 wait_notify + TimeoutError)
        func next(timeout: TimeInterval) async -> Data? {
            if !buffer.isEmpty {
                return buffer.removeFirst()
            }
            return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                let id = UUID().uuidString
                waiters[id] = cont
                order.append(id)
                // 超时唤醒: 睡 timeout 后若仍在等待则返回 nil
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard let self else { return }
                    if let c = self.waiters.removeValue(forKey: id) {
                        if let idx = self.order.firstIndex(of: id) { self.order.remove(at: idx) }
                        c.resume(returning: nil)
                    }
                }
            }
        }

        func drain() {
            buffer.removeAll()
        }
    }

    // MARK: - 底层写入口 (由 BLE 层注入, 全部 withoutResponse)

    typealias Writer = (CBUUID, Data) -> Void
    private let write: Writer

    // 会话密钥与帧计数器 (认证成功后设置)
    private(set) var keys: MiOTCrypto.SessionKeys?
    private var sendIt: UInt32 = 0
    private var devItHi: UInt32 = 0
    private var lastDevItLo: UInt16 = 0
    private var miotSeq: UInt8 = 1

    private var queues: [String: FrameQueue] = [:]
    private var onDecryptedPortPush: ((Data, UInt8, Int) -> Void)?   // (明文, opcode, piid)
    private var onRawFrame: ((Data, String) -> Void)?                // 调试日志: (原始帧, 通道名)

    init(writer: @escaping Writer) {
        self.write = writer
    }

    private func queue(_ name: String) -> FrameQueue {
        if let q = queues[name] { return q }
        let q = FrameQueue()
        queues[name] = q
        return q
    }

    func setOnPortPush(_ cb: @escaping (Data, UInt8, Int) -> Void) { onDecryptedPortPush = cb }
    func setOnRawFrame(_ cb: @escaping (Data, String) -> Void) { onRawFrame = cb }

    /// 写入 (对外暴露, 认证器/设备信息查询使用)
    func writeTo(_ uuid: CBUUID, _ data: Data) { write(uuid, data) }

    func push(_ channel: String, data: Data) {
        queue(channel).push(data)
        onRawFrame?(data, channel)
    }

    func drain(_ channel: String) { queue(channel).drain() }

    /// 清空 cmd_recv 积压并按协议补发 ACK (对齐原项目 _drain_pending_pushes)
    /// 设备推送的内联帧必须 ACK, 否则其发送缓存被卡住, 后续 GET Result 不再返回
    func drainRecvWithAck() {
        while let d = queue("cmd_recv").popNow() {
            if d.count >= 4, d[2] == 0x02 {
                write(BLEConstants.charCmdRecv, BLEConstants.ackInline)
            } else if d.count >= 6, d[2] == 0x00 {
                write(BLEConstants.charCmdRecv, BLEConstants.rcvRdy)
                write(BLEConstants.charCmdRecv, BLEConstants.rcvOK)
            }
        }
    }

    func wait(_ channel: String, timeout: TimeInterval = 3.0) async -> Data? {
        await queue(channel).next(timeout: timeout)
    }

    // MARK: - 会话密钥安装 (认证成功后调用)

    func installKeys(_ newKeys: MiOTCrypto.SessionKeys) {
        keys = newKeys
        sendIt = 0
        devItHi = 0
        lastDevItLo = 0
        miotSeq = 1
    }

    /// 重连时重置整个通道 (清空所有队列与密钥)
    func reset() {
        keys = nil
        sendIt = 0
        devItHi = 0
        lastDevItLo = 0
        miotSeq = 1
        for q in queues.values { q.drain() }
        queues.removeAll()
    }

    // MARK: - 发送 (对应 controller.py _send_encrypted)

    func sendEncrypted(plaintext: Data) async -> Bool {
        guard let keys else { return false }
        drain("cmd_send")  // 清残留, 与 _clear_queue 一致

        let encrypted = MiOTCrypto.encryptFrame(keys: keys, sendIt: sendIt, payload: plaintext)
        sendIt &+= 1

        // 1. 告知设备要发 1 帧
        write(BLEConstants.charCmdSend, Data([0x00, 0x00, 0x00, 0x00, 0x01, 0x00]))
        let rdy = await wait("cmd_send")
        if rdy != Data([0x00, 0x00, 0x01, 0x01]) {
            LogFile.write("[CMDCH] send 等 RCV_RDY 失败, got=\(rdy?.hex ?? "nil")")
            return false
        }
        // 2. 数据帧 (帧号 0x0100 + 密文)
        write(BLEConstants.charCmdSend, Data([0x01, 0x00]) + encrypted)
        let ok = await wait("cmd_send")
        if ok != Data([0x00, 0x00, 0x01, 0x00]) {
            LogFile.write("[CMDCH] send 等 RCV_OK 失败, got=\(ok?.hex ?? "nil")")
            return false
        }
        return true
    }

    // MARK: - 认证响应 (对应 controller.py _recv_auth_response)

    /// 认证阶段接收设备数据, 支持内联与多帧两种格式
    func recvAuthResponse(channel: String, writeChar: CBUUID, timeout: TimeInterval = 3.0) async -> Data? {
        guard let data = await wait(channel, timeout: timeout), data.count >= 4 else { return nil }

        if data[2] == 0x02 {
            // 内联: [00 00 02 XX][data...]
            write(writeChar, BLEConstants.ackInline)   // ACK [00 00 03 00]
            return Data(data.dropFirst(4))
        }
        if data[2] == 0x00, data.count >= 6 {
            // 多帧头: [00 00 00 XX][count_lo count_hi]
            let frameCount = min(Int(data[4]) + Int(data[5]) * 0x100, 100)
            write(writeChar, BLEConstants.rcvRdy)   // RCV_RDY
            var received = Data()
            for _ in 0..<frameCount {
                guard let frame = await wait(channel, timeout: 3.0) else { break }
                received.append(frame.dropFirst(2))   // 帧头 [frm_lo frm_hi]
            }
            write(writeChar, BLEConstants.rcvOK)    // RCV_OK
            return received
        }
        return nil
    }

    // MARK: - 内联帧解密 (对应 controller.py decrypt + _try_decode_inline)

    /// 解密一帧原始数据, 自动处理 it 回绕跟踪; 失败返回 nil
    func decryptFrameIfPossible(_ data: Data) -> Data? {
        guard let keys, data.count >= 6 else {
            LogFile.write("[CMDCH] decrypt 长度不足/未认证: len=\(data.count) keys=\(keys == nil)")
            return nil
        }
        let itLo = UInt16(data[0]) | (UInt16(data[1]) << 8)
        if itLo < lastDevItLo && (lastDevItLo - itLo) > 32768 {
            devItHi &+= 1  // 低 16 位回绕 → 高 16 位进位
        }
        lastDevItLo = itLo
        let fullIt = (devItHi << 16) | UInt32(itLo)
        let result = MiOTCrypto.decryptFrame(keys: keys, fullIt: fullIt, input: data)
        if result == nil {
            LogFile.write("[CMDCH] decrypt 失败 it=\(fullIt) input=\(data.hexCompact)")
        }
        return result
    }

    // MARK: - cmd_recv 数据帧处理 (对应 ble_manager.py _handle_inline_data / _handle_multiframe)

    /// 处理一条 cmd_recv 原始帧, 返回解密明文 (内联); 多帧则排空并逐帧尝试解密
    func processRecvFrame(_ data: Data) async -> Data? {
        guard data.count >= 4 else { return nil }
        switch data[2] {
        case 0x02:
            // 内联帧: ACK + 解密
            write(BLEConstants.charCmdRecv, BLEConstants.ackInline)
            if let pt = decryptFrameIfPossible(Data(data.dropFirst(4))) {
                return pt
            } else {
                decodeInlineFallback(pt: nil, piid: -1)   // 解密失败计数交给上层
                return nil
            }
        case 0x00 where data.count >= 6:
            // 多帧头
            let frameCount = min(Int(data[4]) + Int(data[5]) * 0x100, 100)
            write(BLEConstants.charCmdRecv, BLEConstants.rcvRdy)
            for _ in 0..<frameCount {
                guard let frame = await wait("cmd_recv", timeout: 3.0) else { break }
                // 每帧尽量按内联尝试解密 (原项目 _try_process_inline_frame 同思路)
                if frame.count >= 6, frame[2] == 0x02 {
                    write(BLEConstants.charCmdRecv, BLEConstants.ackInline)
                    if let pt = decryptFrameIfPossible(Data(frame.dropFirst(4))) {
                        onDecryptedPortPush?(pt, 0x02, -1)
                    }
                }
            }
            write(BLEConstants.charCmdRecv, BLEConstants.rcvOK)
            return nil
        default:
            return nil
        }
    }

    private func decodeInlineFallback(pt: Data?, piid: Int) {
        // 解密失败可能意味着会话过期/帧错位, 第一版仅统计, 交上层判断
    }

    // MARK: - MiOT 命令 (对应 controller.py send_miot_command)

    /// GET siid/piid, 返回 value (u32 或 u8), 设备错误返回 nil
    func get(_ siid: UInt8, _ piid: Int) async -> Int? {
        guard keys != nil else { return nil }
        drainRecvWithAck()  // 与 _drain_pending_pushes 一致: 清积压并补发 ACK

        let seq = miotSeq
        miotSeq = (miotSeq &+ 1) & 0xFF
        let plaintext = MiOTCommand.buildTLV(seq: seq, siid: siid, piid: piid, value: nil)
        guard await sendEncrypted(plaintext: plaintext) else { return nil }

        // 等待 GET 结果 (B4=0x03), 超时 8s; 期间端口推送帧回投队列
        let deadline = Date().addingTimeInterval(8.0)
        while Date() < deadline {
            guard let frame = await wait("cmd_recv", timeout: min(deadline.timeIntervalSinceNow, 3.0)) else { continue }
            guard frame.count >= 4 else { continue }
            guard let pt = await processRecvFrame(frame) else { continue }
            guard pt.count >= 8 else { continue }

            let b4 = pt[4]
            let ptSiid = pt.count > 6 ? pt[6] : 0
            let ptPiid = pt.count > 7 ? Int(pt[7]) : -1

            if b4 == 0x03, ptSiid == siid, ptPiid == piid {
                // 错误码 pt[9:11] 非零 = 设备拒绝
                if pt.count > 10 && (pt[9] != 0 || pt[10] != 0) { return nil }
                return MiOTCommand.valueFrom(pt: pt)
            }
            // 端口实时推送 (b4==0x02, siid==2, piid 1..4): 已解密, 直接转发上层
            if b4 == 0x02, ptSiid == 2, ptPiid >= 1 && ptPiid <= 4 {
                onDecryptedPortPush?(pt, b4, ptPiid)
            }
        }
        return nil
    }

    // MARK: - 认证阶段通道状态 (供调试 UI)

    var sendCounter: UInt32 { sendIt }
    var devCounterLow: UInt16 { lastDevItLo }
    var devCounterHi: UInt32 { devItHi }
}