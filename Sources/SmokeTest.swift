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
