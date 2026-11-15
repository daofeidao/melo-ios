import Foundation
import SwiftUI

/// 个人账号（多账号）。
///
/// 存储方案：账号信息只存在**本机 App 沙盒**（UserDefaults）里，不上传任何服务器。
/// 每个登录过的人 = 一个账号条目（昵称 + 网易云 Cookie），互相独立、可随时切换；
/// 别人在这台设备上想用自己的账号，就再登录一次，变成第二个条目。
///
/// 生效方式：激活某个账号 = 把它的 Cookie 写进 SourcePrefs 的网易云 Cookie 位，
/// 搜索 / 取流 / 歌单那条链路读的是同一个槽位，不用改任何网络代码。
@MainActor
final class AccountsStore: ObservableObject {
    static let shared = AccountsStore()

    struct Account: Identifiable, Codable {
        var id: String
        var nickname: String
        var cookie: String
        var createdAt: Date
    }

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var activeId: String?

    private let listKey = "melo.accounts.list"
    private let activeKey = "melo.accounts.active"

    private init() {
        if let data = UserDefaults.standard.data(forKey: listKey),
           let list = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = list
        }
        let saved = UserDefaults.standard.string(forKey: activeKey)
        activeId = saved.flatMap { id in accounts.first { $0.id == id }?.id }
            ?? accounts.first?.id
        migrateLegacyCookieIfNeeded()
    }

    /// 老版本在「数据来源」里录入过网易云 Cookie 的话，自动升级成一个账号条目
    private func migrateLegacyCookieIfNeeded() {
        guard accounts.isEmpty,
              let legacy = SourcePrefs.shared.cookie("netease"),
              legacy.contains("MUSIC_U=") else { return }
        add(cookie: legacy, nickname: nil, activate: true)
    }

    var activeAccount: Account? { accounts.first { $0.id == activeId } }

    /// 登录完成（Cookie 已 harvest 进 SourcePrefs）后调用：保存为新账号并激活
    @discardableResult
    func add(cookie: String, nickname: String?, activate: Bool = true) -> Account {
        let clean = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = Account(
            id: "acc-\(Int(Date().timeIntervalSince1970 * 1000))",
            nickname: (nickname ?? "网易云账号").trimmingCharacters(in: .whitespaces).isEmpty
                ? "网易云账号" : (nickname ?? "").trimmingCharacters(in: .whitespaces),
            cookie: clean,
            createdAt: Date()
        )
        // 同一份 Cookie 重复登录就去重：旧条目直接替换昵称
        if let index = accounts.firstIndex(where: { $0.cookie == clean }) {
            let old = accounts[index]
            accounts[index] = Account(
                id: old.id,
                nickname: (nickname?.isEmpty == false ? nickname! : old.nickname),
                cookie: old.cookie,
                createdAt: old.createdAt
            )
            if activate { activeId = old.id }
        } else {
            accounts.insert(account, at: 0)
            if activate { activeId = account.id }
        }
        persist()
        if activate { applyActiveCookie() }
        return account
    }

    /// 切换使用中的账号：Cookie 写回 SourcePrefs，请求链路立即生效
    func activate(_ id: String) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        activeId = id
        UserDefaults.standard.set(id, forKey: activeKey)
        applyActiveCookie()
    }

    /// 退出登录：请求链路退回匿名设备 Cookie；账号条目保留，随时可再切回来
    func signOut() {
        activeId = nil
        UserDefaults.standard.removeObject(forKey: activeKey)
        SourcePrefs.shared.setCookie("netease", "")
    }

    func remove(_ id: String) {
        let wasActive = activeId == id
        accounts.removeAll { $0.id == id }
        if wasActive { signOut() }
        persist()
    }

    private func applyActiveCookie() {
        SourcePrefs.shared.setCookie("netease", activeAccount?.cookie ?? "")
    }

    /// 用 Cookie 反查昵称（网易云账号接口），拿到后回写条目
    func refreshNickname(_ accountId: String) async {
        guard let account = accounts.first(where: { $0.id == accountId }) else { return }
        guard let url = URL(string: "https://music.163.com/api/nuser/account/get") else { return }
        var request = URLRequest(url: url)
        request.setValue(account.cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let nickname = profile["nickname"] as? String,
              !nickname.isEmpty else { return }
        guard let index = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        accounts[index].nickname = nickname
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: listKey)
        }
        UserDefaults.standard.set(activeId, forKey: activeKey)
    }
}

/// App 内检查更新：查 GitHub Releases 最新正式版，与当前版本号比较。
///
/// 更新源是仓库的 **非预发布** Release（`releases/latest` 只会返回正式版，
/// CI 每次构建产生的 build-N 预发布不会干扰）。有新版时弹窗显示更新说明，
/// 「前往下载」打开 Safari 下载 IPA（TrollStore 安装）。
enum AppUpdate {
    struct Info {
        var version: String
        var notes: String
        var downloadUrl: String
        var pageUrl: String
    }

    static let repo = "daofeidao/melo-ios"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func check(current: String) async -> Info? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String else { return nil }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(version, than: current) else { return nil }

        var download = ""
        if let assets = root["assets"] as? [[String: Any]] {
            for asset in assets {
                let name = asset["name"] as? String ?? ""
                if name.hasSuffix(".ipa") {
                    download = asset["browser_download_url"] as? String ?? ""
                }
            }
        }
        return Info(
            version: version,
            notes: (root["body"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "修复问题与优化体验。",
            downloadUrl: download,
            pageUrl: root["html_url"] as? String ?? ""
        )
    }

    /// 语义比较：按「.」分段逐段比数字，段数不足当 0
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = latest.dropFirst(latest.hasPrefix("v") ? 1 : 0)
            .split(separator: ".").map { Int($0) ?? 0 }
        let b = current.dropFirst(current.hasPrefix("v") ? 1 : 0)
            .split(separator: ".").map { Int($0) ?? 0 }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// 账号管理页：列表 + 添加 + 退出。
/// 登录复用网易云的网页登录（WebLoginView），Cookie 落进 SourcePrefs 后
/// 回到这里存成一个账号条目并自动反查昵称。
struct AccountsView: View {
    @ObservedObject private var store = AccountsStore.shared
    @State private var showLogin = false

    var body: some View {
        List {
            Section {
                ForEach(store.accounts) { account in
                    Button {
                        store.activate(account.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.nickname)
                                    .foregroundColor(.primary)
                                Text(L("Tap to switch"))
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.secondaryLabel)
                            }
                            Spacer()
                            if store.activeId == account.id {
                                Text(L("In Use"))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Theme.accent)
                            }
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                Button {
                    showLogin = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(Theme.accent)
                        Text(L("Add Netease Account"))
                            .foregroundColor(Theme.accent)
                    }
                }
                .buttonStyle(PlainButtonStyle())

                if store.activeAccount != nil {
                    Button {
                        store.signOut()
                    } label: {
                        Text(L("Log Out"))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            } header: {
                Text(L("Account"))
            } footer: {
                Text(L("Account cookies are stored only in this device's app sandbox and are never uploaded. Others can log in with their own account and you can switch back anytime."))
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("Account"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLogin) {
            NavigationView {
                loginSheet
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
        // 登录页关掉后收割 Cookie：harvest 已经把它写进 SourcePrefs 了
        .onChange(of: showLogin) { active in
            guard !active else { return }
            guard let cookie = SourcePrefs.shared.cookie("netease"),
                  cookie.contains("MUSIC_U=") else { return }
            let account = store.add(cookie: cookie, nickname: nil)
            Task { await store.refreshNickname(account.id) }
        }
    }

    @ViewBuilder
    private var loginSheet: some View {
        if let info = SourcePrefs.shared.builtIn.first(where: { $0.id == "netease" }) {
            WebLoginView(platform: info)
        }
    }
}
