import Foundation


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

        let download = pickAsset(root["assets"] as? [[String: Any]] ?? [])
        return Info(
            version: version,
            notes: (root["body"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "修复问题与优化体验。",
            downloadUrl: download,
            pageUrl: root["html_url"] as? String ?? ""
        )
    }

    /// 按平台挑更新包。
    ///
    /// 以前这里只找 `.ipa`，于是 Mac 版点「下载」拿到的是 iOS 包 ——
    /// 双击装不上，等于白下一个十几兆。
    /// Mac Catalyst 要的是 `Melo-Mac-vX.zip`，iOS 要的是 `Melo-vX.Bn.ipa`；
    /// 两者都没有就返回空串，让界面退回打开发布页，而不是给一个错的文件。
    private static func pickAsset(_ assets: [[String: Any]]) -> String {
        var ipa = ""
        var macZip = ""
        var otherZip = ""
        for asset in assets {
            let name = (asset["name"] as? String ?? "").lowercased()
            let url = asset["browser_download_url"] as? String ?? ""
            guard !url.isEmpty else { continue }
            if name.hasSuffix(".ipa") {
                if ipa.isEmpty { ipa = url }
            } else if name.hasSuffix(".zip") {
                if name.contains("mac") {
                    if macZip.isEmpty { macZip = url }
                } else if otherZip.isEmpty {
                    otherZip = url
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        return macZip.isEmpty ? otherZip : macZip
        #else
        return ipa
        #endif
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
