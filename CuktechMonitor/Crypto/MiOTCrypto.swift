import Foundation
import CryptoKit
import CommonCrypto

// 小米 MiOT 加密层 —— 移植自 cuktech-ble-server 的 controller.py
//
// 对应原项目代码位置：
//   - authenticate() 中的 HKDF 派生:
//       HKDF(algorithm=SHA256, length=64, salt=salt,
//            info=b"mible-login-info", backend=...).derive(self.token)
//       密钥切分: dev_key=derived[0:16] app_key=derived[16:32]
//                 dev_iv =derived[32:36] app_iv =derived[36:40]
//   - _encrypt / decrypt 中的 AES-CCM (cryptography 的 AESCCM, tag_length=4):
//       nonce = iv(4) + zeros(4) + it(4, LE)
//       发送方向用 app_key + app_iv, 输出 it 低 2 字节 + 密文
//       接收方向用 dev_key + dev_iv
//
// 说明: CryptoKit 不提供 AES-CCM, 这里按 RFC 3610 用 AES-128 单块
// (CommonCrypto ECB) 自行实现: CCM = CBC-MAC(认证) + AES-CTR(加密),
// tag 长度 4, L=3 (nonce 12 字节), 无关联数据。

enum MiOTCrypto {

    // MARK: - HKDF-SHA256

    static func hkdfSHA256(ikm: Data, salt: Data, info: Data, outputByteCount: Int) -> Data {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: outputByteCount
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    // MARK: - HMAC-SHA256

    static func hmacSHA256(key: Data, message: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(mac)
    }

    // MARK: - AES-128 单块 (ECB), CCM 内部使用

    private static func aesBlock(_ key: Data, _ block: Data) -> Data {
        precondition(key.count == 16 && block.count == 16)
        var out = [UInt8](repeating: 0, count: 16)
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBuf in
            block.withUnsafeBytes { blockBuf in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyBuf.baseAddress, key.count, nil,
                    blockBuf.baseAddress, block.count,
                    &out, out.count, nil
                )
            }
        }
        precondition(status == kCCSuccess, "AES-ECB 单块失败: \(status)")
        return Data(out)
    }

    private static func xor(_ a: Data, _ b: Data) -> Data {
        Data(zip(a, b).map { $0 ^ $1 })
    }

    // MARK: - CCM 块构造 (L=3, M=4, 无关联数据)

    /// CTR 块: [flag] + nonce(12) + counter(3, big-endian)
    /// flag = L-1 = 2
    private static func ctrBlock(nonce: Data, counter: UInt32) -> Data {
        var block = Data([0x02])
        block.append(nonce)
        block.append(UInt8((counter >> 16) & 0xFF))
        block.append(UInt8((counter >> 8) & 0xFF))
        block.append(UInt8(counter & 0xFF))
        return block
    }

    /// 认证起始块 B0: [flags] + nonce(12) + payloadLen(3, big-endian)
    /// flags = ((M-2)/2 << 3) | (L-1) = 0x08 | 0x02 = 0x0A
    private static func b0Block(nonce: Data, payloadCount: Int) -> Data {
        var block = Data([0x0A])
        block.append(nonce)
        block.append(UInt8((payloadCount >> 16) & 0xFF))
        block.append(UInt8((payloadCount >> 8) & 0xFF))
        block.append(UInt8(payloadCount & 0xFF))
        return block
    }

    /// 按 16 字节块计算 CBC-MAC (初始 X0 = 0, 末块不足 16 补零)
    private static func cbcMac(key: Data, data: Data) -> Data {
        var input = data
        if input.count % 16 != 0 {
            input.append(Data(repeating: 0, count: 16 - input.count % 16))
        }
        var x = Data(repeating: 0, count: 16)
        var offset = 0
        while offset < input.count {
            let block = input[offset..<offset + 16]
            x = aesBlock(key, xor(x, Data(block)))
            offset += 16
        }
        return x
    }

    /// 生成 counter=1..n 的 AES-CTR 密钥流 (长度 = length)
    private static func keyStream(key: Data, nonce: Data, length: Int) -> Data {
        guard length > 0 else { return Data() }
        let blocks = (length + 15) / 16
        var stream = Data()
        for i in 1...blocks {
            stream.append(aesBlock(key, ctrBlock(nonce: nonce, counter: UInt32(i))))
        }
        return stream.prefix(length)
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    // MARK: - AES-CCM 加密/解密 (tag = 4 字节, 输出 = 密文 + tag)

    static func ccmEncrypt(key: Data, nonce: Data, payload: Data) -> Data {
        precondition(nonce.count == 12)
        let stream = keyStream(key: key, nonce: nonce, length: payload.count)
        let ctBody = xor(payload, stream)
        // MAC 输入 = B0 || payload
        var macInput = b0Block(nonce: nonce, payloadCount: payload.count)
        macInput.append(payload)
        let mac = cbcMac(key: key, data: macInput)
        let s0 = aesBlock(key, ctrBlock(nonce: nonce, counter: 0))
        let tag = xor(mac, s0.prefix(4))
        return ctBody + tag
    }

    /// 解密并验证 tag, 验证失败返回 nil
    static func ccmDecrypt(key: Data, nonce: Data, input: Data) -> Data? {
        precondition(nonce.count == 12)
        guard input.count >= 4 else { return nil }
        let ct = Data(input.dropLast(4))
        let tag = Data(input.suffix(4))
        let stream = keyStream(key: key, nonce: nonce, length: ct.count)
        let ptBody = xor(ct, stream)
        var macInput = b0Block(nonce: nonce, payloadCount: ptBody.count)
        macInput.append(ptBody)
        let mac = cbcMac(key: key, data: macInput)
        let s0 = aesBlock(key, ctrBlock(nonce: nonce, counter: 0))
        let expected = xor(mac, s0.prefix(4))
        guard constantTimeEqual(expected, tag) else { return nil }
        return ptBody
    }

    // MARK: - 会话密钥

    /// 派生 64 字节后的会话密钥切分 (对应原项目 self._session_keys)
    struct SessionKeys {
        let devKey: Data   // 16 字节, 接收方向
        let appKey: Data   // 16 字节, 发送方向
        let devIV: Data    // 4  字节, 接收方向
        let appIV: Data    // 4  字节, 发送方向

        init(derived: Data) {
            devKey = derived[derived.startIndex..<derived.startIndex + 16]
            appKey = derived[derived.startIndex + 16..<derived.startIndex + 32]
            devIV  = derived[derived.startIndex + 32..<derived.startIndex + 36]
            appIV  = derived[derived.startIndex + 36..<derived.startIndex + 40]
        }
    }

    // MARK: - 帧级加解密 (对应 controller.py _encrypt / decrypt)

    /// 发送方向: 输出 = it 低 2 字节 + AES-CCM 密文
    static func encryptFrame(keys: SessionKeys, sendIt: UInt32, payload: Data) -> Data {
        var it = sendIt
        let itBytes = withUnsafeBytes(of: &it) { Data($0) }  // 小端 UInt32 = 4 字节
        var nonce = keys.appIV
        nonce.append(Data(repeating: 0, count: 4))
        nonce.append(itBytes)
        let ct = ccmEncrypt(key: keys.appKey, nonce: nonce, payload: payload)
        return itBytes[0..<2] + ct
    }

    /// 接收方向: 输入 = it 低 2 字节 + 密文, it 高 16 位由调用方 (含回绕跟踪) 提供
    static func decryptFrame(keys: SessionKeys, fullIt: UInt32, input: Data) -> Data? {
        guard input.count >= 6 else { return nil }  // 2 字节 it + 至少 4 字节 tag
        var it = fullIt
        let itBytes = withUnsafeBytes(of: &it) { Data($0) }
        var nonce = keys.devIV
        nonce.append(Data(repeating: 0, count: 4))
        nonce.append(itBytes)
        return ccmDecrypt(key: keys.devKey, nonce: nonce, input: Data(input.dropFirst(2)))
    }
}