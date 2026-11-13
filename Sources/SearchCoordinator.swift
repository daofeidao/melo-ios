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
