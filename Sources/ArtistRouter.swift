import SwiftUI

/// 播放页 → 艺人页的跳板。
///
/// 播放页是 fullScreenCover 呈现的，里面直接放 NavigationLink 推不进主栈，
/// 所以这里记住「要打开的艺人」，先关掉播放页，回到「现在就听」后
/// 由隐藏的 NavigationLink 把艺人页推进去。
final class ArtistRouter: ObservableObject {
    static let shared = ArtistRouter()

    @Published var pending: String?

    private init() {}
}
