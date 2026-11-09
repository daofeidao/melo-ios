import Foundation

/// InnerTube 返回的是深度嵌套、随版本漂移的动态 JSON。
/// 用通用遍历而不是强类型 Codable，避免字段一改就整页解析失败。
enum JS {

    static func dict(_ any: Any?) -> [String: Any]? {
        if let d = any as? [String: Any] { return d }
        if let d = any as? NSDictionary { return d as? [String: Any] }
        return nil
    }

    static func array(_ any: Any?) -> [Any]? {
        if let a = any as? [Any] { return a }
        if let a = any as? NSArray { return a as? [Any] }
        return nil
    }

    static func string(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    static func int(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    static func value(_ root: Any?, _ key: String) -> Any? {
        dict(root)?[key]
    }

    /// 收集所有 key 对应的数组（用于 thumbnails 这类数组字段）
    static func collectArrays(_ key: String, in root: Any?) -> [Any] {
        guard let root = root else { return [] }
        var out: [Any] = []
        var queue: [Any] = [root]
        var cursor = 0
        while cursor < queue.count {
            let node = queue[cursor]
            cursor += 1
            if let d = dict(node) {
                if let hit = d[key] as? [Any] { out.append(hit) }
                for (_, v) in d {
                    if v is [String: Any] || v is [Any] { queue.append(v) }
                }
            } else if let a = array(node) {
                for v in a where v is [String: Any] || v is [Any] {
                    queue.append(v)
                }
            }
        }
        return out
    }

    /// 按文档顺序收集所有 key 对应的字典（广度优先，保持层级顺序）
    static func collect(_ key: String, in root: Any?) -> [[String: Any]] {
        guard let root = root else { return [] }
        var out: [[String: Any]] = []
        var queue: [Any] = [root]
        var cursor = 0
        while cursor < queue.count {
            let node = queue[cursor]
            cursor += 1
            if let d = dict(node) {
                if let hit = dict(d[key]) { out.append(hit) }
                for (_, v) in d {
                    if v is [String: Any] || v is [Any] { queue.append(v) }
                }
            } else if let a = array(node) {
                for v in a where v is [String: Any] || v is [Any] {
                    queue.append(v)
                }
            }
        }
        return out
    }

    /// 取第一个匹配的字典
    static func first(_ key: String, in root: Any?) -> [String: Any]? {
        collect(key, in: root).first
    }

    /// 解析 text / runs / simpleText 三种文本结构
    static func text(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        guard let d = dict(any) else { return nil }
        if let runs = array(d["runs"]) {
            let joined = runs.compactMap { run -> String? in
                guard let rd = dict(run) else { return nil }
                return string(rd["text"])
            }.joined()
            return joined.isEmpty ? nil : joined
        }
        if let s = string(d["simpleText"]) { return s }
        if let s = string(d["content"]) { return s }
        if let s = string(d["text"]) { return s }
        return nil
    }

    /// 从 text 结构里取出每个 run 的文本与 pageType
    struct Run {
        var text: String
        var pageType: String?
        var browseId: String?
        var videoId: String?
    }

    static func runs(_ any: Any?) -> [Run] {
        guard let d = dict(any), let arr = array(d["runs"]) else {
            if let s = text(any) { return [Run(text: s, pageType: nil, browseId: nil, videoId: nil)] }
            return []
        }
        return arr.compactMap { item in
            guard let rd = dict(item), let t = string(rd["text"]) else { return nil }
            let nav = dict(rd["navigationEndpoint"])
            let browse = dict(nav?["browseEndpoint"])
            let watch = dict(nav?["watchEndpoint"])
            let pageType = string(
                dict(dict(browse?["browseEndpointContextSupportedConfigs"])?["browseEndpointContextMusicConfig"])?["pageType"]
            )
            return Run(
                text: t,
                pageType: pageType,
                browseId: string(browse?["browseId"]),
                videoId: string(watch?["videoId"])
            )
        }
    }

    /// 时长 "3:45" / "1:02:03" -> 秒
    static func seconds(fromClock clock: String?) -> Int {
        guard let clock = clock?.trimmingCharacters(in: .whitespacesAndNewlines), !clock.isEmpty else { return 0 }
        let parts = clock.split(separator: ":").map { Int($0) ?? -1 }
        if parts.contains(-1) || parts.isEmpty { return 0 }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }

    private static let clockPattern = try? NSRegularExpression(pattern: "^\\d{1,2}:\\d{2}(:\\d{2})?$")

    static func looksLikeClock(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return clockPattern?.firstMatch(in: s, options: [], range: range) != nil
    }
}
