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
        SourceInfo(id: "netease", name: "网易云音乐", needsLogin: true),
        SourceInfo(id: "qq", name: "QQ 音乐", needsLogin: true),
        SourceInfo(id: "youtube", name: "YouTube Music", needsLogin: false)
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

    func isEnabled(_ id: String) -> Bool { enabled[id] ?? true }

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

extension URLRequest {
    /// 把设置里录入的 Cookie 加到对应源的请求上，不串源
    mutating func meloCookie(for source: String) {
        guard let cookie = SourcePrefs.shared.cookie(source) else { return }
        setValue(cookie, forHTTPHeaderField: "Cookie")
    }
}
