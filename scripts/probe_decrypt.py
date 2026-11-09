#!/usr/bin/env python3
"""验证网易云 `{"result":"<hex>"}` 加密体能否离线解密。

不看传闻，只做实测：拿到真实密文后，穷举已知密钥与算法组合，
检查解出来的字节是否是可解析的 JSON。哪个组合成功就打印哪个。

依赖：cryptography（如缺失则跳过 AES 分支）
"""

import binascii
import gzip
import json
import urllib.parse
import urllib.request
import zlib

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)
QUERY = "孤勇者 陈奕迅"
URL = "https://music.163.com/api/search/get/web?s=%s&type=1&limit=30&offset=0" % urllib.parse.quote(QUERY)

# 生态里公开出现过的网易云密钥
CANDIDATE_KEYS = [
    b"e82ckenh8dichen8",   # eapi 常用 key
    b"0CoJUm6Qyw8W8jud",   # weapi 请求体 key
    b"3go8&$8*3*3h0k(2)",  # 老版 eapi 变体
    b"a44e8f1e9b2d7c3f",   # 噪声
]


def fetch(url):
    req = urllib.request.Request(url)
    req.add_header("Referer", "https://music.163.com/")
    req.add_header("User-Agent", UA)
    req.add_header("Accept-Encoding", "gzip")
    with urllib.request.urlopen(req, timeout=25) as resp:
        raw = resp.read()
        if resp.headers.get("Content-Encoding") == "gzip":
            raw = gzip.decompress(raw)
        return raw


def try_parse(data):
    if not isinstance(data, (bytes, bytearray)) or len(data) < 2:
        return None
    try:
        text = data.decode("utf-8")
    except Exception:  # noqa: BLE001
        return None
    stripped = text.strip()
    if not stripped or stripped[0] not in "{[":
        return None
    try:
        return json.loads(stripped)
    except Exception:  # noqa: BLE001
        return None


def attempt(label, fn, blob):
    try:
        out = fn(blob)
    except Exception as exc:  # noqa: BLE001
        return None
    parsed = try_parse(out)
    if parsed is None:
        return None
    preview = json.dumps(parsed, ensure_ascii=False)[:80]
    print("   ✅ %-34s 明文 JSON: %s" % (label, preview))
    return parsed


def main():
    raw = fetch(URL)
    print("响应 %d 字节，前 60 字符：%s" % (len(raw), raw[:60].decode("utf-8", "replace")))
    print()

    try:
        root = json.loads(raw.decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        print("响应本身就是明文，无需解密。")
        return

    payload = root.get("result")
    if isinstance(payload, dict):
        print("响应是明文 JSON（result 为对象），无需解密。")
        print("songs =", len(payload.get("songs") or []))
        return
    if not isinstance(payload, str):
        print("result 不是字符串，形态：", type(payload).__name__)
        return

    print("result 是字符串，长度 %d，看起来像 %s" % (len(payload), "hex" if all(c in "0123456789abcdef" for c in payload[:64].lower()) else "非 hex"))
    print()

    # 先试非对称算法类的可能：纯 hex 编码 / 压缩
    print("== 编码与压缩假设 ==")
    try:
        blob = binascii.unhexlify(payload)
        print("   解 hex 成功，%d 字节，前 16 字节：%s" % (len(blob), blob[:16].hex()))
    except Exception as exc:  # noqa: BLE001
        print("   hex 解码失败：%s" % exc)
        return

    for label, fn in [
        ("zlib.decompress(hex)", lambda b: zlib.decompress(b)),
        ("gzip.decompress(hex)", lambda b: gzip.decompress(b)),
    ]:
        attempt(label, fn, blob)

    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    except Exception as exc:  # noqa: BLE001
        print()
        print("cryptography 不可用（%s），跳过 AES 分支。" % exc)
        return

    print()
    print("== AES-128-ECB 假设（%d 个候选密钥）==" % len(CANDIDATE_KEYS))
    for key in CANDIDATE_KEYS:
        if len(key) != 16:
            continue
        label = "AES-128-ECB key=%s" % key.decode("latin-1")
        attempt(label, lambda b, k=key: Cipher(algorithms.AES(k), modes.ECB()).decryptor().update(b), blob)

    print()
    print("== AES-128-CBC 假设（IV = 16 个 0 或 与 key 相同）==")
    for key in CANDIDATE_KEYS:
        if len(key) != 16:
            continue
        for iv_label, iv in [("iv=0", b"\x00" * 16), ("iv=key", key)]:
            label = "AES-128-CBC key=%s %s" % (key.decode("latin-1"), iv_label)
            attempt(
                label,
                lambda b, k=key, v=iv: Cipher(algorithms.AES(k), modes.CBC(v)).decryptor().update(b),
                blob,
            )

    print()
    print("（以上没有任何 ✅ 表示当前密文无法用已知公开密钥解出）")


if __name__ == "__main__":
    main()
