#!/usr/bin/env python3
"""评估国内音源的可播放覆盖率，并测试酷狗作为补充源。

目的：网易云外链只对免费曲目有效（VIP/无版权会跳到 404 网页），
单靠它覆盖面不够。这里量一下真实命中率，同时看酷狗搜索 + playInfo
能不能补上，避免"列表里全是点不动的歌"。
"""

import gzip
import json
import urllib.parse
import urllib.request

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)
IP = "116.25.146.177"
QUERIES = ["孤勇者 陈奕迅", "晴天 周杰伦", "Shape of You Ed Sheeran"]


def get(url, headers=None, timeout=20):
    req = urllib.request.Request(url)
    req.add_header("User-Agent", UA)
    req.add_header("Accept-Encoding", "gzip")
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                raw = gzip.decompress(raw)
            return resp.status, raw, resp.headers.get("Content-Type", "")
    except Exception as exc:  # noqa: BLE001
        return None, str(exc).encode(), ""


def netease_search(query):
    url = "https://music.163.com/api/search/get/web?s=%s&type=1&limit=30&offset=0" % urllib.parse.quote(query)
    status, raw, _ = get(url, {"Referer": "https://music.163.com/", "X-Real-IP": IP})
    if status != 200:
        return []
    try:
        root = json.loads(raw.decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        return []
    result = root.get("result")
    if not isinstance(result, dict):
        return []
    out = []
    for song in result.get("songs") or []:
        artists = ",".join(a.get("name", "") for a in (song.get("artists") or []))
        out.append(
            {
                "id": str(song.get("id")),
                "title": song.get("name"),
                "artist": artists,
                "duration": (song.get("duration") or 0) // 1000,
            }
        )
    return out


def netease_playable(song_id):
    url = "https://music.163.com/song/media/outer/url?id=%s.mp3" % song_id
    status, raw, ctype = get(url, {"Referer": "https://music.163.com/", "Range": "bytes=0-1023"})
    ok = status in (200, 206) and ("audio" in ctype or "mpeg" in ctype) and len(raw) > 512
    return ok


def kugou_search(query):
    url = (
        "https://msearchcdn.kugou.com/api/v3/search/song?keyword=%s&page=1&pagesize=10&showtype=1"
        % urllib.parse.quote(query)
    )
    status, raw, _ = get(url)
    if status != 200:
        return []
    try:
        root = json.loads(raw.decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        return []
    data = root.get("data") or {}
    out = []
    for item in data.get("info") or []:
        out.append(
            {
                "hash": item.get("hash"),
                "title": item.get("songname"),
                "artist": item.get("singername"),
                "duration": item.get("duration"),
                "album_id": item.get("album_id"),
            }
        )
    return out


def kugou_stream(hash_value):
    url = "https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=%s" % hash_value
    status, raw, _ = get(url, {"User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"})
    if status != 200:
        return None, "http=%s" % status
    try:
        root = json.loads(raw.decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        return None, "parse-fail"
    stream = root.get("url")
    if not stream:
        return None, "no url (err=%s)" % root.get("error")
    probe_status, probe_raw, ctype = get(stream, {"Range": "bytes=0-1023"})
    ok = probe_status in (200, 206) and len(probe_raw) > 512
    return (stream if ok else None), "probe=%s type=%s bytes=%d" % (probe_status, ctype, len(probe_raw))


def main():
    print("=" * 78)
    print("国内音源可播放覆盖率")
    print("=" * 78)

    for query in QUERIES:
        print()
        print("### %s" % query)

        songs = netease_search(query)
        print("   网易云搜索：%d 首" % len(songs))

        checked = songs[:10]
        hits = 0
        for song in checked:
            ok = netease_playable(song["id"])
            hits += 1 if ok else 0
            print("      %s %-26s %-16s %ds" % ("✅" if ok else "❌", song["title"][:26], song["artist"][:16], song["duration"]))
        print("   网易云外链命中：%d/%d" % (hits, len(checked)))

        kugou = kugou_search(query)
        print("   酷狗搜索：%d 首" % len(kugou))
        k_hits = 0
        for item in kugou[:5]:
            if not item.get("hash"):
                continue
            stream, detail = kugou_stream(item["hash"])
            k_hits += 1 if stream else 0
            title = (item.get("title") or "")[:24]
            artist = (item.get("artist") or "")[:14]
            print("      %s %-24s %-14s %s" % ("✅" if stream else "❌", title, artist, detail[:44]))
        print("   酷狗 playInfo 命中：%d/5" % k_hits)


if __name__ == "__main__":
    main()
