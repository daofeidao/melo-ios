import Foundation
import SwiftUI

/// 后台歌单导入。
///
/// 以前导入是在导入页里同步做的：拉完整个歌单，再逐首去别的源匹配一遍，
/// 几十秒到几分钟不等，期间只能盯着那个页面，别的什么都干不了。
///
/// 现在改成后台任务：点一下就交给这里，用户立刻可以回到别的页面继续用；
/// 拉完之后自动存进资料库，并在这里播报进度和结果。
///
/// 另外不再逐首匹配 —— 平台接口给的歌单本身就带每首歌的平台 id，
/// 播放时按 id 取直链即可；真取不到，播放器还有按歌名去别的源兜底的链路。
/// 逐首匹配那种「几百首歌 × 每首一次搜索」的活儿，交给播放时按需做。
final class ImportCoordinator: ObservableObject {
    static let shared = ImportCoordinator()

    enum State {
        case idle
        case running(title: String, done: Int, total: Int)
        case done(title: String, count: Int)
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle

    private init() {}

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    @discardableResult
    func start(platform: PlaylistPlatform, id: String, isRank: Bool, fallbackTitle: String) -> Bool {
        guard !isRunning else { return false }
        state = .running(title: fallbackTitle, done: 0, total: 0)

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let remote = try await PlaylistFetcher.fetch(platform: platform, id: id, isRank: isRank)
                guard !remote.songs.isEmpty else { throw PlaylistImportError.empty }

                let tracks = remote.songs.map { song -> Track in
                    Track(
                        videoId: "",
                        title: song.title,
                        artist: song.artist,
                        album: song.album,
                        duration: song.duration,
                        artwork: song.artwork,
                        source: song.source.rawValue,
                        sourceID: song.sourceID,
                        isVip: song.isVip
                    )
                }

                await MainActor.run {
                    PlaylistStore.shared.save(
                        name: remote.name,
                        platform: remote.platform,
                        cover: remote.cover,
                        tracks: tracks,
                        totalCount: tracks.count,
                        sourceID: id
                    )
                    self?.state = .done(title: remote.name, count: tracks.count)
                }
            } catch {
                await MainActor.run {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self?.state = .failed(message: message)
                }
            }
        }
        return true
    }

    /// 结果提示看过了就清掉
    func clear() {
        state = .idle
    }
}
