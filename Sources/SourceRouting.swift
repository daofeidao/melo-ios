import Foundation

/// 来源绑定（Source Routing）。
///
/// 取代旧的「兜底链」模型：以前所有音源是一个池子，Auto 模式挨个试，谁先出声用谁。
/// 新原则只有一条——**内容从哪来，就固定用哪个源解析，系统不自动跨源切换**。
///
/// 绑定规则（按判定优先级）：
/// 1. YouTube 曲目（videoId 非空，含从 YouTube 链接导入的歌曲/专辑/歌单/音乐）
///    → 固定 YouTubeKit。硬锁，解析失败就明确报错，不去国内源找替身。
/// 2. 指定艺人（默认周杰伦）→ 固定歌曲宝。硬锁，失败也不回退 flachi / 国内源。
/// 3. 国内平台曲目（导入自网易云/QQ/酷狗/酷我）→ 固定它自己那一家的源。
/// 4. 本地文件 → 固定本地。
///
/// 用户仍然可以在【播放源】面板里**手动**改某一首的源——那是明确的主动选择，
/// 不算系统自动兜底；但默认值来自这里，且 YouTube / 艺人特例显示为锁定态。
enum SourceRouting {

    /// 一条绑定：目标源 + 为什么这么绑（展示给用户）+ 是否允许手动改。
    struct Binding {
        let sourceID: String
        let reason: String
        let locked: Bool
    }

    /// 指定艺人 → 唯一源。可在设置里增删（存 UserDefaults），默认周杰伦 → 歌曲宝。
    private static let artistsKey = "melo.routing.artists"
    private static let defaultArtists: [String: String] = ["周杰伦": "gequbao"]

    static var artistBindings: [String: String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: artistsKey),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
                return defaultArtists
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: artistsKey)
        }
    }

    static func addArtist(_ name: String, source: String = "gequbao") {
        let key = Zh.simplified(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !key.isEmpty else { return }
        var map = artistBindings
        map[key] = source
        artistBindings = map
    }

    static func removeArtist(_ name: String) {
        var map = artistBindings
        map.removeValue(forKey: Zh.simplified(name))
        artistBindings = map
    }

    /// 这首歌绑定的唯一源。nil = 无绑定（自由搜索出来的散歌，用户自己选）。
    static func binding(for track: Track) -> Binding? {
        // 1. YouTube：最高优先级，硬锁
        if !track.videoId.isEmpty {
            return Binding(
                sourceID: "youtube",
                reason: L("From YouTube — always play with YouTube, never substitute another source."),
                locked: true
            )
        }

        // 2. 艺人特例
        let primary = track.artist
            .components(separatedBy: CharacterSet(charactersIn: ",，/、&·"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = Zh.simplified(primary)
        if let source = artistBindings.first(where: { normalized.contains($0.key) })?.value {
            return Binding(
                sourceID: source,
                reason: String(format: L("Artist '%@' is pinned to %@."), primary, SourceNames.label(source)),
                locked: true
            )
        }

        // 3. 本地文件
        if track.source == LocalMusicStore.sourceTag {
            return Binding(sourceID: "local", reason: L("Local file"), locked: true)
        }

        // 4. 国内平台导入曲目：固定它自己那家
        if let source = track.source, PlaylistPlatform(rawValue: source) != nil {
            return Binding(
                sourceID: source,
                reason: String(format: L("Imported from %@ — play with its own source."), SourceNames.label(source)),
                locked: false
            )
        }

        return nil
    }

    /// 是否锁定（供面板决定要不要给换源按钮）。
    static func isLocked(_ track: Track) -> Bool { binding(for: track)?.locked ?? false }
}

/// 音源显示名，UI 与绑定理由共用一处，避免各面板各写一套 switch。
enum SourceNames {
    static func label(_ id: String) -> String {
        switch id.lowercased() {
        case "youtube": return "YouTube"
        case "gequbao": return L("Gequbao")
        case "flachi": return "Hi·FLAC"
        case "kugou": return L("Kugou Music")
        case "kuwo": return L("Kuwo Music")
        case "netease": return L("NetEase Cloud Music")
        case "qq": return "QQ " + L("Music")
        case "local": return L("Local Music")
        case "cache": return L("Local cache")
        case "b5i": return "b5i"
        default: return id
        }
    }
}

/// 解析策略：播放源面板顶部的三模式。
///
/// - `defaultSource`：按内容来源绑定唯一源（YouTube→YouTubeKit、艺人→歌曲宝、
///   国内导入→本平台），失败明确报错，不跨源。推荐，默认。
/// - `auto`：播不出来时按可用源顺序自动兜底，优先保证出声。
/// - `pinned`：用户手动钉死一个源，严谨不切换，失败就报错。
enum ResolveMode: String, CaseIterable, Identifiable {
    case defaultSource
    case auto
    case pinned

    var id: String { rawValue }

    var label: String {
        switch self {
        case .defaultSource: return L("Default Source")
        case .auto: return L("Auto Switch")
        case .pinned: return L("Pinned")
        }
    }

    var explain: String {
        switch self {
        case .defaultSource:
            return L("Each song uses its own source. Never switches, even on failure.")
        case .auto:
            return L("If playback fails, automatically try the next available source.")
        case .pinned:
            return L("Always use the source selected below. Never switch, even on failure.")
        }
    }

    /// 图标，让分段控件之外的说明区更直观
    var icon: String {
        switch self {
        case .defaultSource: return "hand.raised.fingers.spread"
        case .auto: return "arrow.triangle.2.circlepath"
        case .pinned: return "pin.fill"
        }
    }
}

/// 解析策略的持久化 + 指定源记忆，集中放在这里供逻辑层与面板共用。
enum ResolveModeStore {
    private static let modeKey = "melo.resolveMode"
    private static let pinnedKey = "melo.pinnedSource"

    static var mode: ResolveMode {
        get { ResolveMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .defaultSource }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// 指定源模式下钉死的源 id（内置源 id 或 custom-xxx）
    static var pinnedSource: String? {
        get {
            let v = UserDefaults.standard.string(forKey: pinnedKey) ?? ""
            return v.isEmpty ? nil : v
        }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: pinnedKey) }
            else { UserDefaults.standard.removeObject(forKey: pinnedKey) }
        }
    }
}

/// 备选音源：只作为名字展示，不参与解析（用户要求：放进设置即可，不启用）。
enum AlternativeSources {
    static let items: [(id: String, name: String, note: String)] = [
        ("b5i", "b5i · YouTubeKit (fork)", "备选 · 未启用")
    ]
}
