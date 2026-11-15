import Foundation

/// 艺人名的统一清洗层。
///
/// 为什么需要它：各音源给的 artist 字段是「半结构化」的自由文本，实测会遇到三类脏数据：
///   1. 已转义的文本 —— 界面上直接显示 `孙楠\u0026那英`（`\u0026` 就是 `&`）；
///   2. 合唱拼成一串 —— `孙楠&那英`、`A、B、C`，整串被当成了一个人；
///   3. 凑数名 —— `周杰伦 原唱`、`DJ版`、`群星`、纯数字。
///
/// 所有「艺人名进入界面 / 进入艺人宫格 / 用来查艺人 id」的入口都必须先过这里，
/// 否则脏名会一路存进 ArtistStore，之后每次启动都还在。
enum ArtistName {

    // MARK: - 反转义

    /// 还原 `\uXXXX`（含代理对）与 HTML 实体。
    /// 只做一次性还原：如果原文是双转义的（`\\u0026`），还原一层后剩下 `\u0026`
    /// 这种残留也会被下面的清洗认作无效字符剔掉。
    static func unescape(_ raw: String) -> String {
        var text = raw
        // 最多解两层：有的上游是双转义的（`\\u0026`），解一层还剩 `\\u0026`
        var rounds = 0
        while (text.contains("\\u") || text.contains("\\/")), rounds < 2 {
            text = decodeUnicodeEscapes(text)
            rounds += 1
        }
        if text.contains("&") {
            text = decodeHTMLEntities(text)
        }
        return text
    }

    private static func decodeUnicodeEscapes(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        var idx = input.startIndex
        while idx < input.endIndex {
            let ch = input[idx]
            guard ch == "\\", input.index(after: idx) < input.endIndex else {
                out.append(ch)
                idx = input.index(after: idx)
                continue
            }
            let next = input[input.index(after: idx)]
            if next == "/" {
                out.append("/")
                idx = input.index(idx, offsetBy: 2)
                continue
            }
            guard next == "u" else {
                out.append(ch)
                idx = input.index(after: idx)
                continue
            }
            // \uXXXX（4 位十六进制）
            let hexStart = input.index(idx, offsetBy: 2)
            guard let hexEnd = input.index(hexStart, offsetBy: 4, limitedBy: input.endIndex),
                  let code = UInt32(input[hexStart..<hexEnd], radix: 16) else {
                out.append(ch)
                idx = input.index(after: idx)
                continue
            }
            var scalarValue = code
            var consumed = 6
            // 高代理：后面通常跟一个 \uDCxx 低代理，合成一个字符。
            // 这里每一步都要判边界，索引越界会直接崩。
            if code >= 0xD800, code <= 0xDBFF, hexEnd < input.endIndex, input[hexEnd] == "\\" {
                let afterSlash = input.index(after: hexEnd)
                if afterSlash < input.endIndex, input[afterSlash] == "u" {
                    let lowStart = input.index(after: afterSlash)
                    if let lowEnd = input.index(lowStart, offsetBy: 4, limitedBy: input.endIndex),
                       let low = UInt32(input[lowStart..<lowEnd], radix: 16),
                       low >= 0xDC00, low <= 0xDFFF {
                        scalarValue = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        consumed = 12
                    }
                }
            }
            if let scalar = Unicode.Scalar(scalarValue) {
                out.append(Character(scalar))
            }
            idx = input.index(idx, offsetBy: consumed, limitedBy: input.endIndex) ?? input.endIndex
        }
        return out
    }

    private static func decodeHTMLEntities(_ input: String) -> String {
        var text = input
        let named = [
            "&nbsp;": " ", "&apos;": "'", "&#39;": "'", "&quot;": "\"",
            "&lt;": "<", "&gt;": ">", "&hellip;": "…", "&middot;": "·",
            "&amp;": "&"   // 必须最后替换，否则 &amp;lt; 会被解成 <
        ]
        for (entity, value) in named where text.contains(entity) {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text
    }

    // MARK: - 拆分

    /// 合唱分隔符。`&` 是最常见的（酷狗、酷我、第三方 API 都用它拼合唱）。
    private static let separators = CharacterSet(charactersIn: "&＆、,，;；/／|｜")

    /// 把一串艺人名拆成多个：`孙楠&那英` → ["孙楠", "那英"]
    static func split(_ raw: String) -> [String] {
        var text = sanitize(raw)
        // 英文合唱写法：`A feat. B` / `A ft. B` / `A vs B`，只有两侧有空格时才拆，
        // 免得把名字里本来就带 "x" 的艺人（如 `Mili x`）拆坏
        for token in [" feat. ", " feat ", " ft. ", " ft ", " vs. ", " vs "] {
            text = text.replacingOccurrences(of: token, with: "&", options: .caseInsensitive)
        }
        return text
            .components(separatedBy: separators)
            .map { sanitize($0) }
            .filter { !$0.isEmpty }
    }

    /// 主艺人（第一个）。用于「点歌手名进艺人页」「艺人宫格」这类只需要一个人的场景。
    static func primary(_ raw: String) -> String {
        split(raw).first ?? sanitize(raw)
    }

    // MARK: - 清洗

    /// 去转义、去零宽字符、压缩空白、去掉包的引号。
    static func sanitize(_ raw: String) -> String {
        var text = unescape(raw)
        // 零宽空格 / BOM / 软连字符：肉眼看不见，但会让「同名」判断失败
        for junk in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}"] {
            text = text.replacingOccurrences(of: junk, with: "")
        }
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 残留的双转义（`\\u0026` 还原一层后仍是 `\u0026`）直接判死，别让它上屏
        if text.contains("\\u") { return "" }
        let quotes = CharacterSet(charactersIn: "\"'“”‘’《》")
        return text.trimmingCharacters(in: quotes)
    }

    /// 归一化 key：小写 + 繁转简 + 去掉空白与常见标点，用于「是不是同一个人」的判断。
    static func key(_ raw: String) -> String {
        let base = Zh.simplified(sanitize(raw)).lowercased()
        let dropped = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "·・.．,，、-_()（）[]【】"))
        // 用 String.filter 而不是拼 UnicodeScalar 数组，避免 String 初始化器的坑
        return base.filter { ch in
            ch.unicodeScalars.allSatisfy { !dropped.contains($0) }
        }
    }

    // MARK: - 准入

    /// 像不像一个正常艺人名。翻唱者整串名、版本说明、凑数内容一律挡掉。
    static func isPlausible(_ raw: String) -> Bool {
        let clean = sanitize(raw)
        guard clean.count >= 2, clean.count <= 24 else { return false }
        guard !clean.contains("://"), !clean.contains("<") else { return false }
        // 必须至少有一个字母或汉字
        guard clean.rangeOfCharacter(from: .letters) != nil else { return false }

        let lower = clean.lowercased()
        let blocked = [
            "原唱", "翻唱", "翻自", "原曲", "cover", "remix", "伴奏", "纯音乐", "inst",
            "karaoke", "ktv", "dj", "live", "现场", "演唱会", "串烧", "合唱版", "对唱版",
            "铃声", "片段", "试听", "钢琴版", "吉他版", "小提琴版", "古筝版", "女声版",
            "男声版", "抖音", "快手", "车载", "慢摇", "的士高", "disco", "网络歌手",
            "群星", "华语群星", "various", "unknown", "未知艺人", "佚名", "bgm",
            "八音盒", "合集", "歌单", "无损", "flac", "320k", "128k", "高清",
            "完整版", "重制", "重置", "改编", "remake", "piano", "ver.", "version",
            "混音", "纯享", "纯人声", "acoustic", "instrumental"
        ]
        if blocked.contains(where: { lower.contains($0) }) { return false }
        return true
    }
}
