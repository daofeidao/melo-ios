import SwiftUI

struct ChangelogEntry: Identifiable {
    let version: String
    let date: String
    let notes: [String]

    var id: String { version }
}

/// 版本更新细节。藏在「版本号连点 7 次」后面，平时不占地方。
enum Changelog {
    static var entries: [ChangelogEntry] {
        [
            ChangelogEntry(version: "1.17.2", date: "2026-11-13", notes: [
                "缓存/下载入口从播放页挪到「播放源」面板最上面一行：播放页恢复干净（标题旁只剩收藏，底部只剩历史 / 音源 / 收起）。面板里会写清楚状态——已缓存到本地 / 正在下载到本机… / 失败原因，未缓存时右侧显示「下载」。",
                "修正「原唱」标误判：标题里自己写着「原唱 某某」的其实是别人的翻录版（搜「晴天」第一条「晴天 (原唱 周杰伦) / RyaVocal」会被错误打上原唱标）。现在这类标题，以及 piano / ver. / 弦乐版 / 翻自 / 改编 等标记一律不打原唱标。",
                "下载大文件不再被超时打断：缓存下载单独设置超时（连接 15 秒、读写 60 秒，不设总时长），并校验「实际字节数 == 服务器给的长度」，没下完不算缓存成功。",
            ]),
            ChangelogEntry(version: "1.17.1", date: "2026-11-13", notes: [
                "播放页加了看得见的「缓存」按钮：标题右侧一个带文字的胶囊（缓存 / 缓存中 / 已缓存），底部那一排也加了一个下载图标（历史 / 缓存 / 音源 / 收起）。原来只有一个跟收藏挤在一起的小图标，很难发现。",
                "点缓存会有反馈：正在下时标题下面显示「正在缓存…」，下完变「已缓存到本地」；失败、或自动缓存已在设置里关闭，也会明确写出来，不再点了没反应。当前这首还没解析出直链时，点缓存会先解析一条再下，不用先播一遍。",
                "修复「各平台明明都有这首歌，却提示没有源」：严格匹配的时长容差从 ±5 秒放宽到 ±25 秒。根因是酷我登记的时长系统性偏短（《稻香》网易云 223 秒、酷我 203 秒），唯一能播的那条被判成「不同版本」直接扔掉。真正的 Live / 加长版通常差 40 秒以上，仍然挡得住。",
                "艺人页「歌曲」不再截断 50 首：改用「艺人全部歌曲」接口（每页 100 首、并发翻页），有多少列多少。",
                "靠兜底播出来的歌现在也会自动缓存：以前只有「曲目自带平台 id 换直链」那条路才落盘，严格匹配通过、按歌名找到的歌一首都没存下来。",
                "兜底命中的音源现在会正确显示在「播放源」里（以前快路径不记来源，面板上看不出到底用的哪个源）。",
                "兜底音源「歌曲宝」加固：三重搜索（移动 UA → 桌面 UA → 只按歌名）、候选从 3 条放宽到 6 条、带 Origin / Sec-Fetch 取流；标题里带片段 / 伴奏 / 翻唱 / DJ 的一律不取；一旦站点要求「人机验证」立即收手，不反复重试免得被限得更久。",
            ]),
            ChangelogEntry(version: "1.17.0", date: "2026-11-13", notes: [
                "艺人页改版：专辑、简介不再空白。专辑改成按网易云艺人 id 直取本人全部专辑 —— 原来用「专辑关键词搜索」，搜「周杰伦」回来的是 Jay / 周杰伦♚ 这类同名野生账号和单曲拼的假专辑，真正的《范特西》《七里香》一张都没有。",
                "艺人页歌曲改成三路合并：本人专辑里的曲目 + 热门榜里本人主唱 + 多源搜索兜底；本人主唱排前面，和别人的合唱 / 助阵放后面，Live、对唱合辑、原声带里的一律剔掉。",
                "「简介」从页面最底部挪到头像正下方，折叠 4 行，点展开看完整生平；头像是下面新增统计「艺人 · N 张专辑 · N 首歌」。",
                "专辑和歌曲都支持「显示全部 / 收起」；去掉了「播放全部」和「代表作」两块。",
                "艺人名匹配改成按分隔符拆 token 后整段相等：查「周杰」不会再点进「周杰伦」的页面；单字「李」仍能搜到李健 / 李荣浩。",
                "搜索结果里的艺人区只列与查询词真正相关的艺人，翻唱者、合唱另一方的名字不再混进来；搜过的艺人都记进艺人库，上限从 12 提到 60。",
                "严格匹配默认开启：歌名 + 艺人 + 时长（±5 秒）全对上才跨源兜底。以前默认关着，等于这个功能一直没生效。",
                "专辑曲目不再被「只能用自带 id」一刀切挡住兜底：可以按歌名回落，但强制严格匹配，所以「专辑里放不了、外面搜同一首却能放」的问题解决了。",
                "所有歌曲列表默认显示音源角标（酷狗 / 酷我 / 网易云 / Hi·FLAC …），标题里没有翻唱 / DJ / Live / 伴奏标记的曲目加实心「原唱」标。",
                "酷我取流加了广告过滤：匿名时会员歌会返回「免费听歌」短音频（~170KB），现在按文件大小识别并丢弃，换其它源。",
                "新增兜底音源「歌曲宝」：所有内置源都拿不到直链时，走它的网页取流（搜索 → 详情页取 play_id → 换直链），实测回到的是酷我 CDN 的真歌（128k、约 3.5MB）。默认开启，可在数据来源里关掉。",
                "酷我歌单链接可以导入了（nplserver 接口，匿名可用）；播放页点艺名直接进艺人页。",
                "分类浏览新增【古琴】【BPM】两格，走歌单关键词搜索；「按风格浏览」正式改名为「分类浏览」。"
            ]),
            ChangelogEntry(version: "1.16.12", date: "2026-11-12", notes: [
                L("Playback failures now show a single-line notice instead of a tall card, so the play and list buttons stay in place."),
                L("Removed the Retry and Switch Source prompts and the divider from the failure notice."),
                L("Playable versions moved into the Playback Source sheet, listed above Quality.")
            ]),
            ChangelogEntry(version: "1.16.11", date: "2026-11-12", notes: [
                L("Search now shows Hi·FLAC results first, with a source badge on every song."),
                L("A new Artists section with circular cards appears both on the search page and in search results, like Apple Music."),
                L("Artists you search for are saved automatically."),
                L("Tapping an artist opens a page with representative works, albums, top songs and a biography."),
                L("Album track lists are now complete: songs without a playable version stay in the list, greyed out, and are never replaced by a cover or live take.")
            ]),
            ChangelogEntry(version: "1.16.10", date: "2026-11-12", notes: [
                L("Hi·FLAC now checks title, artist and duration before accepting a match, so covers, live takes and DJ edits are no longer played as the original."),
                L("Hi·FLAC searches by song title only: adding the artist made the site return no results at all."),
                L("A stream found by name search is no longer written to the local audio cache."),
                L("Cached audio now records its source and quality. Turning a source off, switching sources or changing quality invalidates that file instead of replaying it."),
                L("Wrong cached files left by older versions are removed automatically on upgrade."),
                L("Playback errors now name the sources you turned off.")
            ]),
            ChangelogEntry(version: "1.16.9", date: "2026-11-12", notes: [
                L("Picking a source in the player now really switches the source: the previous stream is no longer reused from cache."),
                L("Turning a source off in Data Sources now takes effect immediately; picking a disabled source reports it instead of silently playing the old one."),
                L("Backup restore now works, and a backup exported on Android can be restored on iPhone (and the other way round)."),
                L("Importing a playlist now runs in the background with a progress bar, and long playlists load much faster."),
                L("Hi·FLAC is now tried first when resolving a song; other sources are used only when it has no match.")
            ]),
            ChangelogEntry(version: "1.16.7", date: "2026-11-12", notes: [
                L("Hi·FLAC added as a built-in source: it can serve 320 kbps and real FLAC lossless."),
                L("The source sheet no longer pushes its last rows off the screen."),
                L("Local files can now be played through an online source instead of the file on the device."),
                L("QQ Music sign-in opens the mobile login page instead of the desktop home page.")
            ]),
            ChangelogEntry(version: "1.16.4", date: "2026-11-11", notes: [
                L("Cached audio now lives in Local Music: every cached song can be browsed and deleted there."),
                L("Cached files are named title – artist_4min29s_ so the duration is readable at a glance."),
                L("Cache survives app restarts and is only removed when you clear it; when the limit is hit, the songs you have not played for the longest time go first."),
                L("The decorative quote icon at the bottom-left of the player is now Play History."),
                L("Settings gained strict matching: title, artist and duration (±5 s) must all agree, otherwise the song reports no source and offers to switch sources."),
                L("Data Sources can be toggled, signed in with a Cookie, or extended with your own resolve endpoint."),
                L("Connection diagnostics moved to About → Advanced Diagnostics.")
            ]),
            ChangelogEntry(version: "1.16.3", date: "2026-11-10", notes: [
                L("Fixed YouTube playback: the blocked ANDROID_VR client identity was replaced with IOS and ANDROID."),
                L("Playback now sends the User-Agent matching the identity that resolved the stream, so audio CDN links no longer return 403."),
                L("The app remembers which YouTube identity works and switches automatically if it stops working.")
            ]),
            ChangelogEntry(version: "1.16.2", date: "2026-11-10", notes: [
                L("Kuwo Music added as a third playback source; a failed link now falls back across Kugou, NetEase and Kuwo."),
                L("NetEase gained a second direct-link API, so fewer songs fall through to a name search."),
                L("Chart lists are cached on disk for 6 hours. Reopening Charts no longer refetches them."),
                L("Kugou chart covers now load (the {size} cover template is resolved)."),
                L("Settings → About lists every data source and what it provides."),
                L("Tap the version number seven times to open this page.")
            ]),
            ChangelogEntry(version: "1.16.1", date: "2026-11-10", notes: [
                L("Kugou charts load in about a second (switched to mobilecdn)."),
                L("Search returns playlists and albums without waiting for YouTube."),
                L("Playback keeps the previous song only when it should.")
            ]),
            ChangelogEntry(version: "1.16.0", date: "2026-11-09", notes: [
                L("Domestic-first search: results in under a second, YouTube folded behind a button."),
                L("Startup no longer waits for an extra probe; three tracks are prefetched ahead."),
                L("Genres in the search empty state play domestic links directly.")
            ]),
            ChangelogEntry(version: "1.14.0", date: "2026-11-09", notes: [
                L("Favorites no longer collapse into a single card."),
                L("Library has a Local Music section; duplicate favorites and history were removed."),
                L("Backup and restore to Files, including iCloud Drive.")
            ])
        ]
    }
}

struct ChangelogView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                // 置顶：作者与项目地址（用户 2026-11-11 要求）
                Section {
                    HStack {
                        Text(L("Author"))
                        Spacer()
                        Text("张宏亮")
                            .foregroundColor(Theme.secondaryLabel)
                    }
                    Link(destination: URL(string: "https://github.com/daofeidao/melo-ios")!) {
                        HStack {
                            Text(L("Project"))
                            Spacer()
                            Text("github.com/daofeidao/melo-ios")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.accent)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text(L("About this build"))
                } footer: {
                    Text(L("A third-party client for personal study only."))
                }

                ForEach(Changelog.entries) { entry in
                    Section {
                        ForEach(entry.notes, id: \.self) { note in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 5))
                                    .foregroundColor(Theme.accent)
                                    .padding(.top, 6)
                                Text(note)
                                    .font(.system(size: 13))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } header: {
                        HStack {
                            Text("v" + entry.version)
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Text(entry.date)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.secondaryLabel)
                        }
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(L("What's New"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

/// 设置 → 关于 → 数据来源：把每个音源负责什么说清楚
struct DataSourcesView: View {
    private struct Row: Identifiable {
        let id = UUID()
        let name: String
        let role: String
        let detail: String
    }

    private var rows: [Row] {
        [
            Row(name: L("Kugou Music"), role: L("Charts · search · direct links"),
                detail: L("Highest hit rate. Chart lists come from mobilecdn.")),
            Row(name: L("NetEase Cloud Music"), role: L("Search · playlists · albums · lyrics"),
                detail: L("Two direct-link APIs. VIP tracks usually fail and fall back.")),
            Row(name: L("Kuwo Music"), role: L("Search · direct links"),
                detail: L("Third source, used when Kugou or NetEase has no playable link. No playlist API.")),
            Row(name: L("QQ Music"), role: L("Playlist import only"),
                detail: L("Streaming needs a logged-in key, so these tracks are matched by name.")),
            Row(name: L("YouTube Music"), role: L("Metadata · catalog"),
                detail: L("Only used when reachable; the app never blocks on it.")),
            Row(name: L("Local Files"), role: L("On-device playback"),
                detail: L("Imported audio in Local Music."))
        ]
    }

    var body: some View {
        List {
            Section {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name)
                            .font(.system(size: 15, weight: .semibold))
                        Text(row.role)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.accent)
                        Text(row.detail)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text(L("Data Sources"))
            } footer: {
                Text(L("Playback always prefers a direct domestic link. YouTube is never on the critical path."))
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("Data Sources"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
