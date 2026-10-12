#!/usr/bin/env python3
"""生成 MiOTCrypto 交叉验证向量：用 cryptography 库产生 AES-CCM/HKDF/HMAC 输出。
用法: python3 tools/gen_vectors.py   （输出 /tmp/ccm_vectors.json）
配合: tools/verify_swift.swift  →  swiftc MiOTCrypto.swift tools/verify_swift.swift
"""
import json, hmac, hashlib, secrets
from cryptography.hazmat.primitives.ciphers.aead import AESCCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes

vectors = []

# 1) AES-CCM: 多种 payload 长度（覆盖块对齐/非对齐、空载荷）
key = secrets.token_bytes(16)
nonce = secrets.token_bytes(12)   # 米家协议 nonce 恒为 12 字节
for n in [0, 1, 4, 11, 12, 15, 16, 17, 20, 23, 24, 31, 40]:
    pt = secrets.token_bytes(n)
    aesccm = AESCCM(key, tag_length=4)
    ct = aesccm.encrypt(nonce, pt, None)   # ciphertext || tag(4)
    vectors.append({
        "kind": "ccm", "key": key.hex(), "nonce": nonce.hex(),
        "pt": pt.hex(), "ct": ct.hex()
    })

# 2) HKDF-SHA256 (IKM=12字节 token, salt=rand+dev, info=mible-login-info, len=64) → 密钥切分
token = secrets.token_bytes(12)
salt = secrets.token_bytes(32)
hkdf = HKDF(algorithm=hashes.SHA256(), length=64, salt=salt, info=b"mible-login-info")
derived = hkdf.derive(token)
vectors.append({
    "kind": "hkdf", "ikm": token.hex(), "salt": salt.hex(),
    "info": "b'mible-login-info'", "out": derived.hex()
})

# 3) HMAC-SHA256
m = secrets.token_bytes(32)
digest = hmac.new(derived[:16], m, hashlib.sha256).digest()
vectors.append({"kind": "hmac", "key": derived[:16].hex(), "msg": m.hex(), "out": digest.hex()})

with open("/tmp/ccm_vectors.json", "w") as f:
    json.dump(vectors, f)
print(f"generated {len(vectors)} vectors -> /tmp/ccm_vectors.json")