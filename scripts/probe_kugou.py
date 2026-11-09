#!/usr/bin/env python3
"""酷狗搜索接口排查：为什么搜索结果为空，以及能否补上免费曲库。

酷狗的免费曲目比例明显高于网易云（后者热门歌几乎全是 VIP），
如果搜索可用，它就是最有价值的补充源。
"""

import gzip
import json
import urllib.parse
import urllib.request

KEYWORD = "孤勇者"
ENCODED = urllib.parse.quote(KEYWORD)

WEBB_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)
MOBILE_UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
)

SEARCH_ENDPOINTS = [
    (
        "msearchcdn v3",
        "https://msearchcdn.kugou.com/api/v3/search/song?keyword=%s&page=1&pagesize=20&showtype=1" % ENCODED,
        MOBILE_UA,
    ),
    (
        "mobilecdn v3",
        "https://mobilecdn.kugou.com/api/v3/search/song?keyword=%s&page=1&pagesize=20&showtype=1" % ENCODED,
        MOBILE_UA,
    ),
    (
        "songsearch v2",
        "https://songsearch.kugou.com/song_search_v2?keyword=%s&page=1&pagesize=20" % ENCODED,
        WEBB_UA,
    ),
    (
        "complexsearch v2",
        "https://complexsearch.kugou.com/v2/search/song?keyword=%s&page=1&pagesize=20&platform=WebFilter" % ENCODED,
        WEBB_UA,
    ),
    (
        "m.kugou 搜索页",
        "https://m.kugou.com/search?keyword=%s" % ENCODED,
        MOBILE_UA,
    ),
    (
        "kugou v2 旧接口",
        "https://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=%s&page=1&pagesize=20" % ENCODED,
        MOBILE_UA,
    ),
]


def get(url, ua, referer=None, timeout=20):
    req = urllib.request.Request(url)
    req.add_header("User-Agent", ua)
    req.add_header("Accept-Encoding", "gzip")
    if referer:
        req.add_header("Referer", referer)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                raw = gzip.decompress(raw)
            return resp.status, raw
    except Exception as exc:  # noqa: BLE001
        return None, str(exc).encode()


def count_songs(raw):
    try:
        root = json.loads(raw.decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        return None, raw[:70].decode("utf-8", "replace").replace("\n", " ")
    data = root.get("data")
    if isinstance(data, dict):
        for key in ("info", "lists"):
            items = data.get(key)
            if isinstance(items, list):
                return len(items), "data.%s" % key
    if isinstance(root.get("candidates"), list):
        return len(root["candidates"]), "candidates"
    return None, json.dumps(root, ensure_ascii=False)[:70]


def play_info(hash_value):
    url = "https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=%s" % hash_value
    status, raw = get(url, MOBILE_UA)
    if status != 200:
        return None
    try:
        root = json.loads(raw.decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        return None
    return root.get("url")


def main():
    print("=" * 78)
    print("酷狗搜索接口排查    keyword=%s" % KEYWORD)
    print("=" * 78)

    first_hashes = []
    for label, url, ua in SEARCH_ENDPOINTS:
        status, raw = get(url, ua, referer="https://www.kugou.com/")
        count, detail = count_songs(raw)
        mark = "✅" if (count or 0) > 0 else "❌"
        print("%s %-18s http=%-4s bytes=%-6d %s %s" % (mark, label, status, len(raw), ("%d 首" % count) if count is not None else "?", detail))

        if (count or 0) > 0:
            try:
                root = json.loads(raw.decode("utf-8", "replace"))
                data = root.get("data") or {}
                items = data.get("info") or data.get("lists") or root.get("candidates") or []
                for item in items[:3]:
                    h = item.get("hash") or item.get("FileHash")
                    name = item.get("songname") or item.get("SongName") or item.get("filename")
                    singer = item.get("singername") or item.get("SingerName")
                    print("      %-28s %-14s hash=%s" % (str(name)[:28], str(singer)[:14], h))
                    if h:
                        first_hashes.append((name, h))
            except Exception as exc:  # noqa: BLE001
                print("      解析样本失败：%s" % exc)

    if first_hashes:
        print()
        print("== playInfo 直链测试 ==")
        for name, h in first_hashes[:5]:
            stream = play_info(h)
            print("   %s %-28s %s" % ("✅" if stream else "❌", str(name)[:28], (stream or "无 url")[:70]))


if __name__ == "__main__":
    main()
