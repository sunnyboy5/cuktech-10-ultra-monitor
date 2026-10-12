// 交叉验证 MiOTCrypto：读取 /tmp/ccm_vectors.json 逐一比对 AES-CCM/HKDF/HMAC
// 编译:  swiftc CuktechMonitor/Crypto/MiOTCrypto.swift CuktechMonitor/Support/DataExt.swift tools/verify_swift.swift -o /tmp/verify_swift
import Foundation

func hexData(_ s: String) -> Data {
    var b: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        b.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return Data(b)
}

guard let jsonData = FileManager.default.contents(atPath: "/tmp/ccm_vectors.json") else {
    print("FATAL: 无法读取 /tmp/ccm_vectors.json")
    exit(1)
}
let obj = try? JSONSerialization.jsonObject(with: jsonData)
guard let vectors = obj as? [[String: String]] else {
    print("FATAL: 向量文件格式错误")
    exit(1)
}

var failed = 0
for (i, v) in vectors.enumerated() {
    switch v["kind"] {
    case "ccm":
        let key = hexData(v["key"]!)
        let nonce = hexData(v["nonce"]!)
        let pt = hexData(v["pt"]!)
        let expected = hexData(v["ct"]!)
        let got = MiOTCrypto.ccmEncrypt(key: key, nonce: nonce, payload: pt)
        let okEnc = got == expected
        // 解密回验
        let back = MiOTCrypto.ccmDecrypt(key: key, nonce: nonce, input: expected)
        let okDec = back == pt
        // 篡改 tag 必须失败
        var tampered = expected
        if tampered.count > 0 { tampered[tampered.index(tampered.endIndex, offsetBy: -1)] ^= 0xFF }
        let okReject = MiOTCrypto.ccmDecrypt(key: key, nonce: nonce, input: tampered) == nil
        let pass = okEnc && okDec && okReject
        if !pass { failed += 1 }
        print("[CCM #\(i)] len=\(pt.count) enc=\(okEnc ? "OK" : "FAIL") dec=\(okDec ? "OK" : "FAIL") rejectTag=\(okReject ? "OK" : "FAIL")")
    case "hkdf":
        let ikm = hexData(v["ikm"]!)
        let salt = hexData(v["salt"]!)
        let out = MiOTCrypto.hkdfSHA256(ikm: ikm, salt: salt,
                                        info: Data("mible-login-info".utf8), outputByteCount: 64)
        let pass = out == hexData(v["out"]!)
        if !pass { failed += 1 }
        print("[HKDF #\(i)] \(pass ? "OK" : "FAIL")")
    case "hmac":
        let key = hexData(v["key"]!)
        let msg = hexData(v["msg"]!)
        let out = MiOTCrypto.hmacSHA256(key: key, message: msg)
        let pass = out == hexData(v["out"]!)
        if !pass { failed += 1 }
        print("[HMAC #\(i)] \(pass ? "OK" : "FAIL")")
    default:
        break
    }
}

print(failed == 0 ? "\n全部通过 ✔" : "\n有 \(failed) 项不匹配 ✘")
exit(failed == 0 ? 0 : 1)