import Foundation

/// 全局通知名。
///
/// 这些名字同时被 Mac 手势层（targetEnvironment(macCatalyst)）和通用视图层引用，
/// 所以必须放在无条件编译的文件里——放在 MacGestures.swift 内会导致 iOS 真机
/// 编译时视图层找不到符号（该文件整段被 #if macCatalyst 包住）。
/// 当前是否有卡片式页面（设置等）盖在最上层。
///
/// Mac 的两指手势是挂在 window 上的全局识别器，卡片打开时如果不收手，
/// 手势会穿透到下面的视图去切栏目 / 调音量 —— 表现就是「在设置里两指一滑就卡死」。
/// 所有全局手势都必须先看这个标志。
enum GestureContext {
    static var sheetOpen = false
}

extension Notification.Name {
    /// Mac 上左右滑切栏（由手势层发出，RootView 接收）
    static let meloSwitchTab = Notification.Name("melo.switchTab")
    /// 刷新键盘快捷键注册
    static let meloRefreshKeyCommands = Notification.Name("melo.refreshKeyCommands")
    /// Mac 两指上滑打开播放页「播放源」面板
    static let meloOpenPlayerSource = Notification.Name("melo.openPlayerSource")
    /// Mac 在资料库页两指下滑打开「设置」
    static let meloOpenSettings = Notification.Name("melo.openSettings")
    /// 播放页点艺人名 → 全局跳到艺人页（任何 tab 都能接，不再只依赖「现在就听」）
    static let meloOpenArtist = Notification.Name("melo.openArtist")
    /// Mac 设置页滚到底继续下滑退出设置
    static let meloDismissSettings = Notification.Name("melo.dismissSettings")
    /// Mac 两指下滑关闭播放页上的浮层（播放源/待播清单）
    static let meloCloseSheet = Notification.Name("melo.closeSheet")
}
