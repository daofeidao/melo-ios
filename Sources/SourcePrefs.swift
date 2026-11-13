import Foundation

/// 数据来源偏好：哪些源参与兜底、各自的登录凭据、用户手动添加的自定义源。
///
/// 关于「登录」的现实约束：这些平台的账号体系没有对外开放的登录接口，
/// 公开请求能走通的凭据形式就是 Cookie（浏览器登录后复制）。
/// 所以这里提供的是 Cookie 录入窗口，而不是账号密码——录密码既拿不到会话，
/// 还会让人误以为密码被保存了。
final class SourcePrefs: ObservableObject {

    static let shared = SourcePrefs()

    struct SourceInfo: Identifiable {
        let id: String
        let name: String
        let needsLogin: Bool
    }

    struct CustomSource: Codable, Identifiable {
        let id: String
        var name: String
        var template: String
    }

    /// 内置源，顺序即兜底优先级
    let builtIn: [SourceInfo] = [
        SourceInfo(id: "kugou", name: "酷狗音乐", needsLogin: false),
        SourceInfo(id: "kuwo", name: "酷我音乐", needsLogin: false),
        // 排在酷我之后：它其实也是拿酷我的资源，但能补上 320 / flac 两档
        SourceInfo(id: "flachi", name: "Hi·FLAC 无损", needsLogin: false),
        SourceInfo(id: "netease", name: "网易云音乐", needsLogin: true),
        SourceInfo(id: "qq", name: "QQ 音乐", needsLogin: true),
        SourceInfo(id: "youtube", name: "YouTube Music", needsLogin: false),
        // 最后兜底：走歌曲宝的网页取流，回到酷我 CDN 的 128k。不开也能正常用，只是少救几首
        SourceInfo(id: "gequbao", name: "歌曲宝（128k 兜底）", needsLogin: false)
    ]

    @Published private(set) var enabled: [String: Bool] = [:]
    @Published private(set) var cookies: [String: String] = [:]
    @Published private(set) var customSources: [CustomSource] = []

    private let enabledPrefix = "melo.sourceEnabled."
    private let cookiePrefix = "melo.sourceCookie."
    private let customKey = "melo.customSources"

    private init() {
        var flags: [String: Bool] = [:]
        for info in builtIn {
            let stored = UserDefaults.standard.object(forKey: enabledPrefix + info.id) as? Bool
            flags[info.id] = stored ?? true
        }
        enabled = flags

        var saved: [String: String] = [:]
        for info in builtIn {
            if let value = UserDefaults.standard.string(forKey: cookiePrefix + info.id), !value.isEmpty {
                saved[info.id] = value
            }
        }
        cookies = saved

        if let data = UserDefaults.standard.data(forKey: customKey),
           let decoded = try? JSONDecoder().decode([CustomSource].self, from: data) {
            customSources = decoded
        }
    }

    /// 各平台的网页登录入口。用它们自己的登录页，凭据只输在平台页面里，我们只取 Cookie。
    func loginURL(_ id: String) -> String {
        switch id {
        case "netease": return "https://y.music.163.com/m/login"
        // QQ 音乐的移动版网页没有登录入口，只有 PC 版首页右上角能登录；
        // WebLoginView 检测到 y.qq.com 会换成桌面 UA
        case "qq": return "https://y.qq.com/"
        case "kuwo": return "https://m.kuwo.cn/newh5app/"
        case "kugou": return "https://www.kugou.com/"
        default: return "https://y.music.163.com/m/login"
        }
    }

    /// 判定「已登录」的关键 Cookie 名。只用来做自动收起的提示，
    /// 判不出来也不影响用户点「完成」手动保存。
    func cookieHint(_ id: String) -> String? {
        switch id {
        case "netease": return "MUSIC_U="
        case "qq": return "qm_keyst="
        case "kuwo": return "kw_token="
        case "kugou": return "KuGoo="
        default: return nil
        }
    }

    /// 收集 Cookie 时按域名过滤，别把其他平台的凭据混进同一个 header
    func cookieDomain(_ id: String) -> String {
        switch id {
        case "netease": return "163.com"
        case "qq": return "qq.com"
        case "kuwo": return "kuwo.cn"
        case "kugou": return "kugou.com"
        default: return ""
        }
    }

    func isEnabled(_ id: String) -> Bool { enabled[id] ?? true }

    /// 这个源在给定音质档位上有没有把握。
    ///
    /// 只用来「灰显提示」，不用来禁用：用户可能就是想试一下，
    /// 或者接受它自动降到低一档。所以面板里照样可以点，只是文案说明清楚。
    ///
    /// 档位能力是按实测结论定的：酷狗/酷我匿名只到 320；Hi·FLAC 用它的会员凭据
    /// 代取，能出 flac；网易云 320 与无损都要 Cookie；QQ 的无损要会员态。
    func supports(_ id: String, quality: StreamResolver.Quality) -> Bool {
        let signedIn = cookie(id) != nil
        switch id {
        case "kugou", "kuwo":
            return quality != .lossless
        case "flachi":
            return true
        case "netease":
            return quality == .normal || quality == .low || signedIn
        case "qq":
            return quality != .lossless || signedIn
        case "gequbao":
            // 兜底源：能播比音质重要，选无损时也不关掉这一层
            return true
        default:
            // 自定义源面向用户自己的接口，能力未知，不做假设
            return true
        }
    }

    func setEnabled(_ id: String, _ value: Bool) {
        enabled[id] = value
        UserDefaults.standard.set(value, forKey: enabledPrefix + id)
    }

    func cookie(_ id: String) -> String? {
        let value = cookies[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    func setCookie(_ id: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            cookies.removeValue(forKey: id)
            UserDefaults.standard.removeObject(forKey: cookiePrefix + id)
        } else {
            cookies[id] = trimmed
            UserDefaults.standard.set(trimmed, forKey: cookiePrefix + id)
        }
    }

    func addCustom(name: String, template: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !link.isEmpty else { return }
        customSources.append(
            CustomSource(id: "custom-\(Int(Date().timeIntervalSince1970))", name: title, template: link)
        )
        persistCustom()
    }

    func removeCustom(id: String) {
        customSources.removeAll { $0.id == id }
        persistCustom()
    }

    /// 自定义源：把 {title} / {artist} / {duration} 填进模板，GET 回来一个直链。
    /// 响应允许是纯文本 URL，也可以是 JSON（取 url / data.url / play_url 任一字段）。
    func resolveCustom(_ source: CustomSource, track: Track) async -> String? {
        let encoded = source.template
            .replacingOccurrences(of: "{title}", with: Self.encode(track.title))
            .replacingOccurrences(of: "{artist}", with: Self.encode(track.artist))
            .replacingOccurrences(of: "{duration}", with: String(track.duration))
        guard let url = URL(string: encoded) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(AudioSource.browserUA, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http") { return trimmed }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let value = JS.string(root["url"]), value.hasPrefix("http") { return value }
        if let nested = JS.dict(root["data"]), let value = JS.string(nested["url"]), value.hasPrefix("http") {
            return value
        }
        if let value = JS.string(root["play_url"]), value.hasPrefix("http") { return value }
        return nil
    }

    private func persistCustom() {
        guard let data = try? JSONEncoder().encode(customSources) else { return }
        UserDefaults.standard.set(data, forKey: customKey)
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}

/// 网易云对「完全没有 Cookie 的匿名请求」会概率性返回 code=-462（限流、内容为空），
/// 表现为专辑打开是空的、点重试偶尔又出来、返回再进又空。
/// 实测交替对照：带一个 NMTID 设备 Cookie 4/4 成功，不带 0/4。
/// 这不是登录，只是给请求一个稳定的浏览器设备标识；进程内固定一个值即可。
enum NeteaseDeviceCookie {
    static let value: String = {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        return "NMTID=00O\(id)AA; _ntes_nnid=\(String(id.prefix(16))),\(stamp); _ntes_nuid=\(String(id.prefix(16)))"
    }()
}

extension URLRequest {
    /// 把设置里录入的 Cookie 加到对应源的请求上，不串源。
    /// 网易云没登录态时补一个匿名设备 Cookie，绕开 -462 匿名限流（用户录入的会员 Cookie 优先）。
    mutating func meloCookie(for source: String) {
        if let cookie = SourcePrefs.shared.cookie(source) {
            setValue(cookie, forHTTPHeaderField: "Cookie")
        } else if source == "netease" {
            setValue(NeteaseDeviceCookie.value, forHTTPHeaderField: "Cookie")
        }
    }
}
