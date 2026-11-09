#!/usr/bin/env python3
"""生成 en / zh-Hans 两份 Localizable.strings。

约定：英文原文即 key，中文放 zh-Hans。这样本地化一旦失效，
界面退化成英文而不是显示裸 key。
"""
import pathlib

TABLE = [
    # 标签栏
    ("Listen Now", "现在就听"),
    ("Browse", "浏览"),
    ("Charts", "排行榜"),
    ("Library", "资料库"),
    ("Search", "搜索"),

    # 通用
    ("Recently Played", "最近播放"),
    ("My Favorites", "我的收藏"),
    ("Settings", "设置"),
    ("Play", "播放"),
    ("Shuffle", "随机播放"),
    ("Done", "完成"),
    ("Cancel", "取消"),
    ("Clear", "清空"),
    ("Retry", "重试"),
    ("Favorite", "收藏"),
    ("Remove Favorite", "取消收藏"),
    ("Up Next", "待播清单"),
    ("Nothing Playing", "没有正在播放的歌曲"),
    ("Unknown Artist", "未知艺人"),
    ("Unknown Album", "未知专辑"),

    # 空状态 / 提示
    ("Start listening", "开始你的聆听"),
    ("Search for a song and play it — your listening history will show up here.",
     "去「搜索」找一首歌，播放后这里会记录你的最近播放。"),
    ("Nothing here yet", "暂无内容"),
    ("Pull to refresh and try again.", "下拉刷新试试。"),
    ("No tracks found", "没有找到曲目"),
    ("No results", "没有找到结果"),
    ("Try another keyword, like an artist or song name.",
     "换个关键词试试，比如歌手名或歌曲名。"),
    ("Search music", "搜索音乐"),
    ("Search songs and artists from YouTube Music.",
     "可搜索歌曲、艺人，结果来自 YouTube Music。"),
    ("Songs, artists", "搜索歌曲、艺人"),
    ("Songs", "歌曲"),
    ("Albums & Playlists", "专辑与歌单"),
    ("Your library is empty", "资料库是空的"),
    ("Long-press a song to favorite it. Played songs are saved here automatically.",
     "长按歌曲可以收藏，播放过的歌会自动记录在这里。"),

    # 设置
    ("Network", "网络"),
    ("Connection Test", "连接测试"),
    ("Both hosts serve the same API. If only one responds, adjust your proxy rules.",
     "两个域名提供同一套接口。如果只有一个能通，说明代理规则没覆盖另一个。"),
    ("No content was returned. Check that your proxy also covers music.youtube.com, then retry.",
     "接口没有返回内容。请确认代理规则也接管了 music.youtube.com，然后重试。"),
    ("%@ plays", "%@ 次播放"),
    ("Playback Test", "播放诊断"),
    ("Playback failed", "播放失败"),
    ("Playback failed: %@", "播放失败：%@"),
    ("Step 1 · Resolve audio URL", "步骤 1 · 解析播放地址"),
    ("Step 2 · Audio CDN", "步骤 2 · 音频节点"),
    ("Step 3 · AVPlayer", "步骤 3 · 播放器起播"),
    ("Ready to play", "可正常解码播放"),
    ("Timed out waiting for audio", "等待音频超时"),
    ("Unknown error", "未知错误"),
    ("If step 1 fails, this IP is likely flagged as a bot; if step 2 fails, your proxy probably does not forward googlevideo.com.",
     "步骤 1 失败多为当前 IP 被判定为机房；步骤 2 失败通常是代理没有转发 googlevideo.com。"),
    ("Playback", "播放"),
    ("Audio Quality", "音质"),
    ("High", "高品质"),
    ("Standard", "标准"),
    ("Data Saver", "省流量"),
    ("High quality is AAC 128 kbps. YouTube Music does not offer lossless.",
     "高品质为标准 AAC 128kbps。无损格式 YouTube Music 不提供。"),
    ("About 128 kbps AAC", "约 128 kbps AAC"),
    ("About 48 kbps AAC", "约 48 kbps AAC"),
    ("Appearance", "外观"),
    ("Follow System", "跟随系统"),
    ("Light", "浅色"),
    ("Dark", "深色"),
    ("Appearance follows the system by default. Pick Light or Dark to override it for this app only.",
     "默认跟随系统。选择浅色或深色只影响本应用。"),
    ("Clear Recently Played", "清空最近播放"),
    ("Clear recently played?", "确定清空最近播放？"),
    ("Version", "版本"),
    ("Data Source", "数据来源"),
    ("About", "关于"),
    ("A third-party client built for iOS 15, for personal study only. Please follow local laws and the platform's terms.",
     "这是为 iOS 15 定制的第三方客户端，仅用于个人学习，请遵守当地法律和平台条款。"),

    # 错误
    ("Invalid request URL", "请求地址无效"),
    ("Invalid response format", "响应格式异常"),
    ("Unable to parse response", "返回内容无法解析"),
    ("Search failed", "搜索失败"),
    ("Unknown reason", "未知原因"),
    ("Network request failed (HTTP %d)", "网络请求失败（HTTP %d）"),
    ("No audio stream available for this track", "该曲目没有可用的音频流"),
    ("Invalid audio URL", "音频地址无效"),
    ("Unable to resolve playback URL: %@", "无法获取播放地址：%@"),

    # 歌单导入
    ("My Playlists", "我的歌单"),
    ("Playlist", "歌单"),
    ("Import Playlist", "导入歌单"),
    ("Import", "导入"),
    ("Paste a playlist link from NetEase Cloud Music, QQ Music or Kugou.",
     "粘贴网易云音乐 / QQ音乐 / 酷狗音乐的歌单链接"),
    ("Playlist link", "歌单链接"),
    ("Recognizing…", "正在解析…"),
    ("Matching %d of %d", "正在匹配 %d/%d"),
    ("Imported %d of %d songs", "已导入 %d/%d 首"),
    ("No playlist found in this link", "链接里没识别到歌单"),
    ("Playlist not found", "歌单不存在，或已设为私密"),
    ("Playlist is empty", "歌单里没有歌曲"),
    ("Delete Playlist", "删除歌单"),
    ("Delete this playlist?", "确定删除这个歌单？"),
    ("Delete", "删除"),
    ("%d songs", "%d 首"),
    ("Import failed", "导入失败"),
    ("Try a different link", "换个链接试试"),
    ("NetEase Cloud Music", "网易云音乐"),
    ("QQ Music", "QQ音乐"),
    ("Kugou Music", "酷狗音乐"),
    ("YouTube requires human verification for this network. Try switching your proxy node and retry. (%@)",
     "YouTube 判定当前网络需要人机验证，请切换代理节点后重试。（%@）"),
]

HEADER = """/*
  由 scripts/gen_strings.py 生成，请勿手工编辑。
*/
"""


def escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def render(pairs):
    lines = [HEADER]
    for key, value in pairs:
        lines.append(f'"{escape(key)}" = "{escape(value)}";\n')
    return "".join(lines)


def main():
    root = pathlib.Path(__file__).resolve().parent.parent

    en_dir = root / "Localization" / "en.lproj"
    zh_dir = root / "Localization" / "zh-Hans.lproj"
    en_dir.mkdir(parents=True, exist_ok=True)
    zh_dir.mkdir(parents=True, exist_ok=True)

    (en_dir / "Localizable.strings").write_text(
        render([(k, k) for k, _ in TABLE]), encoding="utf-8"
    )
    (zh_dir / "Localizable.strings").write_text(render(TABLE), encoding="utf-8")

    keys = [k for k, _ in TABLE]
    duplicates = {k for k in keys if keys.count(k) > 1}
    if duplicates:
        raise SystemExit(f"重复的 key: {sorted(duplicates)}")

    print(f"generated {len(TABLE)} keys -> Localization/en.lproj, Localization/zh-Hans.lproj")


if __name__ == "__main__":
    main()
