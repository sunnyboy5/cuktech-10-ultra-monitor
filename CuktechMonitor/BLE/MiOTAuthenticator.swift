import Foundation

// MiOT 认证状态机 —— 移植自原项目 controller.py authenticate / _try_authenticate
//
// 协议流程 (同一份代码的注释, 此处为 Swift 实现):
//   Phase A: 设备初始化 (0xA4)
//   Phase B: 登录 (CMD_LOGIN=0x24) + 密钥交换
//     1. 双方交换 16 字节随机密钥
//     2. HKDF 派生会话密钥 (IKM=token, salt=rand_key+dev_random, info=“mible-login-info”)
//     3. 验证设备 HMAC (dev_key / salt_inv), 发送我方 HMAC (app_key / salt)
//     4. 挑战-应答第二轮 → auth_ctrl 收到 0x21(登录成功) 或 0x11(激活成功)

@MainActor
final class MiOTAuthenticator {

    private let channel: CommandChannel
    private let token: Data            // 12 字节设备 Token (从米家 App/云端获取)
    private(set) var steps: [String] = []

    init(channel: CommandChannel, token: Data) {
        self.channel = channel
        self.token = token
    }

    private func step(_ s: String) {
        steps.append(s)
    }

    /// 执行完整认证, 成功返回会话密钥
    func authenticate() async -> MiOTCrypto.SessionKeys? {
        steps.removeAll()
        guard token.count == 12 else {
            step("错误: token 长度必须为 12 字节 (24 位 hex)")
            return nil
        }

        // ---- Phase A: 设备初始化 ----
        step("[1/5] 设备初始化 (0xA4)...")
        channel.drain("auth_data")
        channel.writeTo(BLEConstants.charAuthCtrl, Data([0xA4]))
        guard let initResp = await channel.wait("auth_data", timeout: 3.0) else {
            step("未收到初始化响应")
            return nil
        }
        step("初始化响应: \(initResp.hex)")

        // 协议协商回传: byte[2] += 1
        var ackBytes = [UInt8](initResp)
        if ackBytes.count >= 3 { ackBytes[2] = ackBytes[2] &+ 1 }
        channel.writeTo(BLEConstants.charAuthData, Data(ackBytes))

        // 接收设备密钥交换数据 (常态 240 字节 0xF2 占位)
        var keyData = await channel.wait("auth_data", timeout: 5.0)
        let isDesync = keyData != nil && keyData!.count < 20 && keyData!.count >= 3 && keyData![2] == 0x04
        if isDesync {
            step("设备状态不同步 (key_data=\(keyData!.count)B), 等待恢复...")
            let deadline = Date().addingTimeInterval(12.0)
            for _ in 0..<3 {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                guard let extra = await channel.wait("auth_data", timeout: remaining) else { continue }
                if extra.count >= 20 && extra[2] == 0x04 {
                    keyData = extra
                    break
                }
            }
        }
        guard let kd = keyData else {
            step("未收到密钥交换数据")
            return nil
        }
        step("密钥交换数据: \(kd.count) 字节")

        // 回传相同长度占位 (对齐原项目 0xF2)
        let padLen = max(0, kd.count - 4)
        var placeholder = Data([0x00, 0x00, 0x05, 0x01])
        placeholder.append(Data(repeating: 0xF2, count: padLen))
        channel.writeTo(BLEConstants.charAuthData, placeholder)

        // 两次 drain 消费残留通知
        for _ in 0..<2 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            channel.drain("auth_data")
        }

        // ---- Phase B: 登录 ----
        step("[2/5] 发送登录命令 (CMD_LOGIN=0x24)...")
        channel.writeTo(BLEConstants.charAuthCtrl, Data([0x24, 0x00, 0x00, 0x00]))

        // 发送我方随机密钥
        step("[3/5] 发送随机密钥...")
        var rand = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, 16, &rand)
        guard status == errSecSuccess else { return nil }
        let randKey = Data(rand)

        channel.writeTo(BLEConstants.charAuthData, Data([0x00, 0x00, 0x00, 0x0B, 0x01, 0x00]))
        var gotRdy = false
        for _ in 0..<5 {
            if let d = await channel.wait("auth_data", timeout: 3.0) {
                if d == Data([0x00, 0x00, 0x01, 0x01]) { gotRdy = true; break }
                step("跳过杂质帧: \(d.hex)")
            }
        }
        guard gotRdy else { step("未收到 RCV_RDY"); return nil }

        channel.writeTo(BLEConstants.charAuthData, Data([0x01, 0x00]) + randKey)
        guard let okData = await channel.wait("auth_data", timeout: 3.0),
              okData == Data([0x00, 0x00, 0x01, 0x00]) else {
            step("未收到 RCV_OK (发送随机密钥)")
            return nil
        }

        // 接收设备随机密钥与 HMAC
        step("[4/5] 接收设备密钥与 HMAC...")
        guard var devRandom = await channel.recvAuthResponse(channel: "auth_data",
                                                             writeChar: BLEConstants.charAuthData),
              devRandom.count >= 16 else {
            step("设备密钥无效")
            return nil
        }
        devRandom = devRandom.prefix(16)

        guard var devHmacInfo = await channel.recvAuthResponse(channel: "auth_data",
                                                               writeChar: BLEConstants.charAuthData),
              devHmacInfo.count >= 32 else {
            step("设备 HMAC 无效")
            return nil
        }
        devHmacInfo = devHmacInfo.prefix(32)

        // 派生会话密钥
        let salt = randKey + devRandom
        let saltInv = devRandom + randKey
        let derived = MiOTCrypto.hkdfSHA256(ikm: token, salt: salt,
                                            info: Data("mible-login-info".utf8),
                                            outputByteCount: 64)
        let keys = MiOTCrypto.SessionKeys(derived: derived)
        step("会话密钥已派生")

        // 验证设备 HMAC
        let expectedDevHmac = MiOTCrypto.hmacSHA256(key: keys.devKey, message: saltInv)
        guard constantTimeEqual(expectedDevHmac, Data(devHmacInfo)) else {
            step("设备 HMAC 验证失败! (token 可能不正确)")
            return nil
        }
        step("设备 HMAC 验证通过")

        // 发送我方 HMAC
        step("[5/5] 发送认证确认...")
        let ourHmac = MiOTCrypto.hmacSHA256(key: keys.appKey, message: salt)
        channel.writeTo(BLEConstants.charAuthData, Data([0x00, 0x00, 0x00, 0x0A, 0x01, 0x00]))
        guard let rdy = await channel.wait("auth_data", timeout: 3.0),
              rdy == Data([0x00, 0x00, 0x01, 0x01]) else {
            step("未收到 RCV_RDY (发送 HMAC)")
            return nil
        }
        channel.writeTo(BLEConstants.charAuthData, Data([0x01, 0x00]) + ourHmac)
        _ = await channel.wait("auth_data", timeout: 3.0)  // RCV_OK, 不强制校验

        // ---- 挑战-应答第二轮 ----
        step("挑战-应答...")
        var challengeSeen = false
        var responseData: Data? = nil
        let challengeDeadline = Date().addingTimeInterval(8.0)
        while Date() < challengeDeadline {
            let remaining = challengeDeadline.timeIntervalSinceNow
            guard let data = await channel.wait("auth_data", timeout: min(remaining, 3.0)) else { continue }
            if data.count >= 3 && data[2] == 0x0D {
                challengeSeen = true
                channel.writeTo(BLEConstants.charAuthData, Data([0x00, 0x00, 0x03, 0x00]))  // keepalive
            } else if data.count >= 3 && data[2] == 0x0C {
                responseData = data
                channel.writeTo(BLEConstants.charAuthData, Data([0x00, 0x00, 0x03, 0x00]))  // keepalive
                channel.writeTo(BLEConstants.charAuthData, Data([0x00, 0x00, 0x00, 0x0A, 0x01, 0x00]))  // ACK
            } else if data == Data([0x00, 0x00, 0x01, 0x01]) {
                break  // RCV_RDY
            } else if data == Data([0x00, 0x00, 0x01, 0x00]) {
                break  // RCV_OK
            }
        }

        // 发送第二轮 auth response
        if let resp = responseData, resp.count >= 3 {
            let payload = Data([0x01, 0x00, 0x0C]) + resp.dropFirst(3)
            channel.writeTo(BLEConstants.charAuthData, payload)
            _ = await channel.wait("auth_data", timeout: 3.0)
        }

        // ---- 等待认证结果 ----
        guard let result = await channel.wait("auth_ctrl", timeout: 5.0) else {
            step("未收到认证结果")
            return nil
        }
        switch result[0] {
        case 0x21:
            step("认证成功 (Login OK)")
        case 0x11:
            step("激活成功")
        case 0x23:
            step("登录失败 (Login Failed)")
            return nil
        case 0x12:
            step("激活失败")
            return nil
        default:
            step("未知结果: 0x\(String(format: "%02X", result[0]))")
            return nil
        }

        // 注入会话密钥, 初始化命令通道
        channel.installKeys(keys)
        channel.drain("cmd_recv")
        channel.drain("cmd_send")
        return keys
    }

    // MARK: - 工具

    private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    static func toString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}