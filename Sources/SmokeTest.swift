import Foundation

/// CI 冒烟测试钩子：通过启动参数驱动一次真实播放，
/// 让构建流水线能验证「解析音频直链 → AVPlayer → 播放页」整条链路。
/// 正常使用不会触发（参数不存在时全部为 nil/false）。
enum SmokeTest {
    static var autoPlayVideoId: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-smoke-play"), index + 1 < args.count else {
            return nil
        }
        let value = args[index + 1]
        return value.isEmpty ? nil : value
    }

    static var presentsPlayer: Bool {
        ProcessInfo.processInfo.arguments.contains("-smoke-player")
    }

    static var showsSettings: Bool {
        ProcessInfo.processInfo.arguments.contains("-smoke-settings")
    }

    static var initialTab: Int? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-smoke-tab"), index + 1 < args.count else {
            return nil
        }
        return Int(args[index + 1])
    }

    static var seedsPlaylist: Bool {
        ProcessInfo.processInfo.arguments.contains("-smoke-seed-playlist")
    }

    static var opensImport: Bool {
        ProcessInfo.processInfo.arguments.contains("-smoke-import")
    }

    static var opensSettingsPage: Bool {
        ProcessInfo.processInfo.arguments.contains("-smoke-settings-page")
    }

    static var runsPlaybackTest: Bool {
        ProcessInfo.processInfo.arguments.contains("-smoke-playback-test")
    }

    /// 只抓取歌单不逐首匹配，用来在 CI 里验证「拿到的是全量曲目」
    static var countsOnly: Bool {
        ProcessInfo.processInfo.arguments.contains("-smoke-count-only")
    }

    /// 备份文件编解码往返一次，验证 Codable 没有漏字段
    static var runsBackupTest: Bool {
        ProcessInfo.processInfo.arguments.contains("-smoke-backup")
    }

    /// 直接播一首网易云歌曲，用来验证国内音源链路
    static var neteaseSongID: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-smoke-play-netease"), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    /// 搜一首真实歌曲并播放，用来验证不是只有白名单视频能播
    static var playSearchQuery: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-smoke-play-search"), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    /// 直接执行一次搜索，用来验证「YouTube + 国内音源」双源结果
    static var searchQuery: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-smoke-search"), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    /// 预填的歌单链接，用于在 CI 里跑通「抓取 → 匹配 → 落库」整条链路
    static var importURL: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-smoke-import-url"), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    static func makeTrack(videoId: String) -> Track {
        Track(
            videoId: videoId,
            title: "Smoke Test",
            artist: "CI Runner",
            album: nil,
            duration: 213,
            artwork: "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg"
        )
    }
}
