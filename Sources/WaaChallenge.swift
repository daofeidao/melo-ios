import Foundation

/// Waa/Create（BotGuard 挑战）响应解析。
///
/// 2025 年起 Create 的响应被加扰：外层 `[null, "<base64>"]`，
/// 解扰算法（与 BgUtils/PoTokenService 一致）：base64 解码 → 每字节 +97（Uint8 溢出）
/// → UTF-8 → JSON。解出来是位置数组：
///   [0] messageId · [1] interpreterJavascript（数组时取其中最长串）· [3] interpreterHash
///   [4] program · [5] globalName · [7] clientExperimentsStateBlob
/// 旧格式是带字段名的字典（interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue），
/// 这里一并兼容。GenerateIT 的响应没加扰，`[null, ttl, null, integrityToken]`，
/// 直接找长串即可，但也留了解扰兜底。
enum WaaChallenge {

    struct Challenge {
        let interpreter: String
        let program: String
        let globalName: String
    }

    /// 解析 Create 响应；加扰/未加扰、字典/位置数组都认。
    static func parse(_ json: Any) -> Challenge? {
        if let c = fromNamedFields(json) { return c }
        if let c = fromPositional(json) { return c }
        for inner in descrambledCandidates(json) {
            if let c = fromNamedFields(inner) { return c }
            if let c = fromPositional(inner) { return c }
        }
        return nil
    }

    /// 取 GenerateIT 的 integrityToken：响应是 `[integrityToken, ttl, refresh, fallbackToken]`，
    /// 按 BgUtils 契约 [0] 就是 integrityToken；退化时找长串（解扰兜底）。
    static func parseLooseString(_ json: Any) -> String? {
        if let arr = json as? [Any] {
            if let first = arr.first as? String, !first.isEmpty { return first }
            for el in arr {
                guard let text = el as? String, text.count > 64 else { continue }
                if let inner = descrambledJSON(text), let found = longestString(in: inner), found.count > 100 {
                    return found
                }
            }
        }
        return longestString(in: json)
    }

    // MARK: - 加扰

    /// `[null, "<base64>"]` → 解扰后的 JSON 对象
    private static func descrambledCandidates(_ json: Any) -> [Any] {
        guard let arr = json as? [Any] else { return [] }
        var out: [Any] = []
        for el in arr {
            guard let text = el as? String, text.count > 64,
                  let inner = descrambledJSON(text) else { continue }
            out.append(inner)
        }
        return out
    }

    /// base64 解码 → 每字节 +97（Uint8 自然溢出，JS 的 buffer.map(b => b + 97) 同款）→ JSON
    static func descrambledJSON(_ base64: String) -> Any? {
        var s = base64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let raw = Data(base64Encoded: s), !raw.isEmpty else { return nil }
        var bytes = [UInt8](repeating: 0, count: raw.count)
        raw.copyBytes(to: &bytes, count: raw.count)
        let decoded = bytes.map { UInt8(truncatingIfNeeded: Int($0) + 97) }
        guard let data = try? JSONSerialization.jsonObject(with: Data(decoded)) else { return nil }
        return data
    }

    // MARK: - 旧格式（带字段名的字典）

    private static func fromNamedFields(_ node: Any) -> Challenge? {
        if let dict = node as? [String: Any],
           let globalName = dict["globalName"] as? String,
           let program = dict["program"] as? String {
            let js: String?
            if let text = dict["interpreterJavascript"] as? String {
                js = text
            } else {
                js = longestString(in: dict["interpreterJavascript"] ?? "")
            }
            if let js = js, !js.isEmpty {
                return Challenge(interpreter: js, program: program, globalName: globalName)
            }
        }
        if let array = node as? [Any] {
            for item in array { if let found = fromNamedFields(item) { return found } }
        } else if let dict = node as? [String: Any] {
            for value in dict.values { if let found = fromNamedFields(value) { return found } }
        }
        return nil
    }

    // MARK: - 新格式（位置数组）

    private static func fromPositional(_ node: Any) -> Challenge? {
        guard let arr = node as? [Any], arr.count >= 6 else { return nil }
        // [0] messageId · [1] interpreterJavascript · [3] interpreterHash
        // [4] program · [5] globalName
        guard let program = arr[4] as? String, !program.isEmpty,
              let globalName = arr[5] as? String, !globalName.isEmpty else { return nil }
        guard let js = longestString(in: arr[1]), js.count > 100 else { return nil }
        return Challenge(interpreter: js, program: program, globalName: globalName)
    }

    // MARK: - 工具

    static func longestString(in node: Any) -> String? {
        if let text = node as? String { return text.isEmpty ? nil : text }
        if let arr = node as? [Any] {
            return arr.compactMap { longestString(in: $0) }.max(by: { $0.count < $1.count })
        }
        if let dict = node as? [String: Any] {
            return dict.values.compactMap { longestString(in: $0) }.max(by: { $0.count < $1.count })
        }
        return nil
    }
}
