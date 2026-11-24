import Foundation
import SwiftUI

/// 让「已选中的 Search tab 再点一次」能回到搜索根界面。
///
/// 系统 `TabView` 默认点已选中的 tab 不会 pop 导航栈，所以从艺人页 / 专辑页
/// 点底部搜索按钮会毫无反应。这里用一个递增令牌，由 `RootView` 在重选 Search
/// tab（tag 3）时调用 `popToRoot()`，`SearchView` 监听令牌、通过改变 `NavigationView`
/// 的 `id` 把整条栈拆掉、直接回到搜索主界面（兼容任意深度：搜索 → 艺人 → 专辑）。
final class SearchCoordinator: ObservableObject {
    static let shared = SearchCoordinator()

    @Published private(set) var resetToken = 0

    func popToRoot() {
        resetToken += 1
    }

    private init() {}
}

/// 让「已选中的 Library tab 再点一次」回到资料库首页。
///
/// 和 Search 同一套令牌机制：`RootView` 在重选 Library tab（tag 2）时调用
/// `popToRoot()`，`LibraryView` 用令牌给 `NavigationView` 换 `id`，把整条栈拆掉，
/// 无论当前在歌单详情、本地音乐、还是设置页，都会回到资料库根界面。
final class LibraryCoordinator: ObservableObject {
    static let shared = LibraryCoordinator()

    @Published private(set) var resetToken = 0
    /// 重选事件可能从两条路同时来（SwiftUI selection 绑定 + tab bar 兜底识别），
    /// 短时间内重复调用只生效一次，避免导航栈被连拆两遍导致闪一下。
    private var lastPop = Date.distantPast

    func popToRoot() {
        let now = Date()
        guard now.timeIntervalSince(lastPop) > 0.3 else { return }
        lastPop = now
        resetToken += 1
    }

    private init() {}
}
