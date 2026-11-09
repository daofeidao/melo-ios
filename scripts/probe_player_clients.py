#!/usr/bin/env python3
"""在真实版权曲目上逐一测试 InnerTube 播放客户端，找出还能出直链的身份。

判定标准：player 返回 playabilityStatus.status == OK 且 streamingData 里有 audio 直链。
任何客户端只要拿到未加密音频地址，就说明"伪装客户端"这条路对当前 IP 有效。
"""

import json
import urllib.request
import urllib.error

PLAYER_KEY = "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w"
PLAYER_URL = "https://www.youtube.com/youtubei/v1/player?key=%s&prettyPrint=false" % PLAYER_KEY

# 真实版权曲目（非白名单热门视频）
TRACKS = [
    ("9q7JOQfcJQM", "以父之名 / 周杰伦"),
    ("kJQP7kiw5Fk", "Despacito"),
    ("0VjIjW4GlUZ", "Blinding Lights"),
]

BROWSER_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)
TV_UA = (
    "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version.24.lts.10 "
    "(unlike Gecko) v8/8.8.278.8-jit gles Starboard/13"
)
ANDROID_UA = "com.google.android.youtube/19.44.38 (Linux; U; Android 14; en_US) gzip"
IOS_UA = "com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X;)"
MWEB_UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
)
VR_UA = (
    "com.google.android.apps.youtube.vr.oculus/1.60.19 "
    "(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
)

# (标签, context.client, User-Agent, 额外字段)
CLIENTS = [
    (
        "TVHTML5",
        {
            "clientName": "TVHTML5",
            "clientVersion": "7.20241127.10.00",
            "hl": "en",
            "gl": "US",
            "userAgent": TV_UA,
        },
        TV_UA,
        {},
    ),
    (
        "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
        {
            "clientName": "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
            "clientVersion": "2.0",
            "hl": "en",
            "gl": "US",
            "userAgent": TV_UA,
        },
        TV_UA,
        {"thirdParty": {"embedUrl": "https://www.youtube.com/"}},
    ),
    (
        "TVHTML5_UNPLUGGED",
        {
            "clientName": "TVHTML5_UNPLUGGED",
            "clientVersion": "7.20241127.10.00",
            "hl": "en",
            "gl": "US",
            "userAgent": TV_UA,
        },
        TV_UA,
        {},
    ),
    (
        "ANDROID",
        {
            "clientName": "ANDROID",
            "clientVersion": "19.44.38",
            "androidSdkVersion": 34,
            "osName": "Android",
            "osVersion": "14",
            "hl": "en",
            "gl": "US",
            "userAgent": ANDROID_UA,
        },
        ANDROID_UA,
        {},
    ),
    (
        "IOS",
        {
            "clientName": "IOS",
            "clientVersion": "19.45.4",
            "deviceMake": "Apple",
            "deviceModel": "iPhone16,2",
            "osName": "iPhone",
            "osVersion": "18.1.0.22B83",
            "hl": "en",
            "gl": "US",
            "userAgent": IOS_UA,
        },
        IOS_UA,
        {},
    ),
    (
        "MWEB",
        {
            "clientName": "MWEB",
            "clientVersion": "2.20241126.01.00",
            "hl": "en",
            "gl": "US",
            "userAgent": MWEB_UA,
        },
        MWEB_UA,
        {},
    ),
    (
        "ANDROID_VR (基线)",
        {
            "clientName": "ANDROID_VR",
            "clientVersion": "1.60.19",
            "deviceMake": "Oculus",
            "deviceModel": "Quest 3",
            "androidSdkVersion": 32,
            "osName": "Android",
            "osVersion": "12L",
            "hl": "en",
            "gl": "US",
            "userAgent": VR_UA,
        },
        VR_UA,
        {},
    ),
    (
        "WEB",
        {
            "clientName": "WEB",
            "clientVersion": "2.20241126.01.00",
            "hl": "en",
            "gl": "US",
            "userAgent": BROWSER_UA,
        },
        BROWSER_UA,
        {},
    ),
    (
        "ANDROID_MUSIC",
        {
            "clientName": "ANDROID_MUSIC",
            "clientVersion": "7.27.52",
            "androidSdkVersion": 34,
            "osName": "Android",
            "osVersion": "14",
            "hl": "en",
            "gl": "US",
            "userAgent": "com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 14) gzip",
        },
        "com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 14) gzip",
        {},
    ),
]


def post(body, ua):
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(PLAYER_URL, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", ua)
    req.add_header("X-YouTube-Client-Name", "1")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        return {"__http_error__": exc.code, "__body__": exc.read()[:200].decode("utf-8", "replace")}
    except Exception as exc:  # noqa: BLE001
        return {"__error__": str(exc)}


def summarize(root):
    status = (root.get("playabilityStatus") or {})
    state = status.get("status")
    reason = status.get("reason") or ""
    streaming = root.get("streamingData") or {}
    formats = (streaming.get("adaptiveFormats") or []) + (streaming.get("formats") or [])

    urls = 0
    ciphered = 0
    audio_itags = []
    for fmt in formats:
        if fmt.get("url"):
            urls += 1
        if fmt.get("signatureCipher") or fmt.get("cipher"):
            ciphered += 1
        if str(fmt.get("mimeType", "")).startswith("audio/"):
            audio_itags.append(fmt.get("itag"))

    return state, reason, urls, ciphered, sorted(set(audio_itags))


def main():
    print("=" * 78)
    print("InnerTube 播放客户端伪装测试")
    print("=" * 78)

    scores = {}

    for client_label, client, ua, extra in CLIENTS:
        ok_tracks = 0
        print()
        print("### %s   UA=%s" % (client_label, ua[:44]))
        for video_id, title in TRACKS:
            body = {
                "context": {"client": client},
                "videoId": video_id,
                "contentCheckOk": True,
                "racyCheckOk": True,
            }
            body.update(extra)

            root = post(body, ua)
            if "__http_error__" in root:
                print("   %-22s HTTP %s  %s" % (video_id, root["__http_error__"], root["__body__"][:80]))
                continue
            if "__error__" in root:
                print("   %-22s ERROR %s" % (video_id, root["__error__"][:80]))
                continue

            state, reason, urls, ciphered, itags = summarize(root)
            verdict = "OK" if urls > 0 else "BLOCKED"
            if urls > 0:
                ok_tracks += 1
            print(
                "   %-22s %-8s urls=%-3d cipher=%-3d audio_itag=%s %s"
                % (video_id, verdict, urls, ciphered, itags[:4], ("| " + reason[:40]) if reason else "")
            )

        scores[client_label] = ok_tracks

    print()
    print("=" * 78)
    print("汇总：能出直链的曲目数 / 3")
    print("=" * 78)
    for label, count in sorted(scores.items(), key=lambda kv: -kv[1]):
        flag = "✅ 可用" if count == len(TRACKS) else ("⬚ 部分" if count else "❌ 全拦")
        print("   %-32s %d/3   %s" % (label, count, flag))


if __name__ == "__main__":
    main()
