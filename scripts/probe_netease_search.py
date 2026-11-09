#!/usr/bin/env python3
"""探测网易云搜索接口在不同请求特征下的返回形态。

背景：/api/search/get/web 在机房 IP 上会返回 {"result":"<hex>"} 这类加密体，
导致 JSON 解析拿不到 songs。这里试各种 cookie / realIP / 端点组合，
找出能稳定拿到明文 JSON 的那一种。
"""

import gzip
import json
import urllib.parse
import urllib.request

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)
QUERY = "孤勇者 陈奕迅"
ENCODED = urllib.parse.quote(QUERY)

BASE = "https://music.163.com/api/search/get/web"
CLOUD = "https://music.163.com/api/cloudsearch/pc"

VARIANTS = [
    ("裸请求", BASE + "?s=%s&type=1&limit=30&offset=0" % ENCODED, {}, {}),
    (
        "Cookie os=pc",
        BASE + "?s=%s&type=1&limit=30&offset=0" % ENCODED,
        {
            "Cookie": "os=pc; appver=8.9.70; channel=netease; __remember_me=true; NMTID=00Oxxx",
        },
        {},
    ),
    (
        "realIP 参数",
        BASE + "?s=%s&type=1&limit=30&offset=0&realIP=116.25.146.177" % ENCODED,
        {},
        {},
    ),
    (
        "X-Real-IP 头",
        BASE + "?s=%s&type=1&limit=30&offset=0" % ENCODED,
        {},
        {"X-Real-IP": "116.25.146.177", "X-Forwarded-For": "116.25.146.177"},
    ),
    (
        "cookie+realIP",
        BASE + "?s=%s&type=1&limit=30&offset=0&realIP=116.25.146.177" % ENCODED,
        {"Cookie": "os=pc; appver=8.9.70; NMTID=00Oxxx"},
        {"X-Real-IP": "116.25.146.177"},
    ),
    ("cloudsearch/pc", CLOUD + "?s=%s&type=1&limit=30&offset=0" % ENCODED, {}, {}),
    (
        "cloudsearch+os=pc",
        CLOUD + "?s=%s&type=1&limit=30&offset=0" % ENCODED,
        {"Cookie": "os=pc; appver=8.9.70; NMTID=00Oxxx"},
        {"X-Real-IP": "116.25.146.177"},
    ),
    (
        "search/get (无 web)",
        "https://music.163.com/api/search/get?s=%s&type=1&limit=30&offset=0" % ENCODED,
        {"Cookie": "os=pc; NMTID=00Oxxx"},
        {},
    ),
]


def fetch(url, headers, extra):
    req = urllib.request.Request(url, headers={})
    req.add_header("Referer", "https://music.163.com/")
    req.add_header("User-Agent", UA)
    req.add_header("Accept-Encoding", "gzip")
    for key, value in headers.items():
        req.add_header(key, value)
    for key, value in extra.items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            raw = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                raw = gzip.decompress(raw)
            return resp.status, raw
    except Exception as exc:  # noqa: BLE001
        return None, str(exc).encode()


def inspect(raw):
    """返回 (形态, 说明)"""
    try:
        root = json.loads(raw.decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        return "非 JSON", raw[:60].decode("utf-8", "replace")

    result = root.get("result")
    if isinstance(result, dict):
        songs = result.get("songs") or []
        sample = ""
        if songs:
            first = songs[0]
            artists = ",".join(a.get("name", "") for a in (first.get("artists") or []))
            sample = "%s | %s | dur=%s" % (first.get("name"), artists, first.get("duration"))
        return "明文", "code=%s songs=%d %s" % (root.get("code"), len(songs), sample)
    if isinstance(result, str):
        return "加密", "result 是 %d 字符的 hex 字符串" % len(result)
    return "其它", json.dumps(root, ensure_ascii=False)[:100]


def main():
    print("=" * 78)
    print("网易云搜索接口形态探测    query=%s" % QUERY)
    print("=" * 78)
    for label, url, headers, extra in VARIANTS:
        status, raw = fetch(url, headers, extra)
        shape, detail = inspect(raw)
        mark = "✅" if shape == "明文" else "❌"
        print("%s %-20s http=%-4s bytes=%-6d %-6s %s" % (mark, label, status, len(raw), shape, detail[:70]))


if __name__ == "__main__":
    main()
