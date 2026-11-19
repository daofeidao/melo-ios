import SwiftUI

/// 音源设置页（大修版）。
///
/// 新模型是「来源绑定」而不是「兜底池」：内容从哪来就固定用哪个源，系统不自动跨源切换。
/// 这一页分四块：
///   1. 来源绑定规则（只读展示 + 艺人名单可编辑）——让用户一眼看懂谁用哪个源
///   2. 登录 / 验证凭据——各源的能力增强（无损、VIP、过验证），不是切源开关
///   3. 备选音源（b5i）——只留名字，不启用
///   4. 自定义解析源——用户自带的接口
struct DataSourceSettingsView: View {
    @ObservedObject private var prefs = SourcePrefs.shared

    private enum ActiveSheet: Identifiable {
        case webLogin(SourcePrefs.SourceInfo)
        case newCustom
        case editArtists

        var id: String {
            switch self {
            case .webLogin(let info): return "web-\(info.id)"
            case .newCustom: return "new-custom"
            case .editArtists: return "edit-artists"
            }
        }
    }

    @State private var activeSheet: ActiveSheet?
    @State private var customName = ""
    @State private var customTemplate = ""

    var body: some View {
        List {
            // MARK: 来源绑定规则
            Section {
                bindingRow(
                    icon: "play.rectangle.fill",
                    title: "YouTube",
                    detail: L("Songs, albums, playlists and links from YouTube — always YouTube, no substitute."),
                    locked: true
                )
                ForEach(SourceRouting.artistBindings.sorted(by: { $0.key < $1.key }), id: \.key) { artist, source in
                    bindingRow(
                        icon: "music.note",
                        title: artist,
                        detail: String(format: L("Always use %@ for this artist."), SourceNames.label(source)),
                        locked: true
                    )
                }
                NavigationLink {
                    ArtistBindingEditView()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .foregroundColor(Theme.accent)
                        Text(L("Edit artist bindings"))
                    }
                    .font(.system(size: 15))
                }
            } header: {
                Text(L("Source Binding"))
            } footer: {
                Text(L("Each kind of content has one fixed source. The app never switches to a different source, even when playback fails."))
            }

            // MARK: 登录 / 验证
            Section {
                ForEach(credentialSources) { info in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.name)
                                .font(.system(size: 16))
                            Text(statusText(info))
                                .font(.system(size: 12))
                                .foregroundColor(Theme.secondaryLabel)
                        }
                        Spacer(minLength: 8)
                        if info.login != .none {
                            Button(actionText(info)) {
                                activeSheet = .webLogin(info)
                            }
                            .font(.system(size: 14))
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            } header: {
                Text(L("Sign-in & Verification"))
            } footer: {
                Text(L("Sign in on the platform's own page inside the app; the resulting Cookie is captured automatically. Melo never sees your password. This unlocks higher quality — it does not change which source a song uses."))
            }

            // MARK: 备选音源
            Section {
                ForEach(AlternativeSources.items, id: \.id) { item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.system(size: 15))
                                .foregroundColor(Theme.secondaryLabel)
                            Text(item.note)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.secondaryLabel.opacity(0.75))
                        }
                        Spacer()
                        Image(systemName: "circle.dashed")
                            .foregroundColor(Theme.secondaryLabel.opacity(0.6))
                    }
                }
            } header: {
                Text(L("Alternative Sources"))
            } footer: {
                Text(L("Listed for reference only. Not active — currently unused for playback."))
            }

            // MARK: 自定义源
            Section {
                Button {
                    customName = ""
                    customTemplate = ""
                    activeSheet = .newCustom
                } label: {
                    HStack {
                        Text(L("Add Source"))
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(Theme.accent)
                    }
                }
                ForEach(prefs.customSources) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name)
                            .font(.system(size: 15))
                        Text(source.template)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.secondaryLabel)
                            .lineLimit(2)
                    }
                }
                .onDelete { offsets in
                    offsets.map { prefs.customSources[$0].id }.forEach(prefs.removeCustom)
                }
            } header: {
                Text(L("Custom Sources"))
            } footer: {
                Text(L("Template: https://api.example.com/resolve?title={title}&artist={artist}. Returns a plain URL or JSON with url / data.url / play_url."))
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("Sources"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .webLogin(let info):
                WebLoginView(platform: info)
            case .newCustom:
                customSheet()
            case .editArtists:
                NavigationView { ArtistBindingEditView() }
                    .navigationViewStyle(StackNavigationViewStyle())
            }
        }
    }

    /// 需要凭据的源（YouTube / 国内平台 / 歌曲宝）。flachi 用自带凭据，不在这里显示。
    private var credentialSources: [SourcePrefs.SourceInfo] {
        prefs.builtIn.filter { $0.id == "youtube" || $0.id == "gequbao" || $0.login != .none }
    }

    private func bindingRow(icon: String, title: String, detail: String, locked: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryLabel)
            }
            Spacer(minLength: 4)
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryLabel)
            }
        }
    }

    private func customSheet() -> some View {
        NavigationView {
            Form {
                Section {
                    TextField(L("Name"), text: $customName)
                    TextField(L("Resolve template URL"), text: $customTemplate)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } footer: {
                    Text(L("Placeholders: {title} {artist} {duration}"))
                }
            }
            .navigationTitle(L("Add Source"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { activeSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Add")) {
                        prefs.addCustom(name: customName, template: customTemplate)
                        activeSheet = nil
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func actionText(_ info: SourcePrefs.SourceInfo) -> String {
        let signed = prefs.cookie(info.id) != nil
        if info.login == .verify {
            return signed ? L("Verified") : L("Verify")
        }
        if signed { return L("Signed In") }
        return info.login == .required ? L("Sign In") : L("Sign In (Optional)")
    }

    private func statusText(_ info: SourcePrefs.SourceInfo) -> String {
        if info.id == "flachi" { return "flac.music.hi.cn · " + L("No sign-in needed") }
        let signed = prefs.cookie(info.id) != nil
        switch info.login {
        case .none:
            return L("No sign-in needed")
        case .required:
            return signed ? L("Signed in · lossless available") : L("Not signed in · 128 kbps only")
        case .optional:
            if info.id == "youtube" {
                return signed ? L("Signed in") : L("Not signed in · still plays")
            }
            return signed ? L("Signed in · lossless available") : L("Not signed in · 320 kbps available")
        case .verify:
            return signed ? L("Verified · direct link available") : L("Not verified · may be blocked")
        }
    }
}

/// 艺人绑定编辑：增删「某艺人 → 唯一源」规则。源目前固定歌曲宝（用户的主要场景），
/// 界面上展示为可选项以便将来扩展，值只用 gequbao。
struct ArtistBindingEditView: View {
    @State private var newArtist = ""
    private var bindings: [String: String] { SourceRouting.artistBindings }

    var body: some View {
        List {
            Section {
                ForEach(bindings.sorted(by: { $0.key < $1.key }), id: \.key) { artist, source in
                    HStack {
                        Text(artist).font(.system(size: 15))
                        Spacer()
                        Text(SourceNames.label(source))
                            .font(.system(size: 13))
                            .foregroundColor(Theme.secondaryLabel)
                    }
                }
                .onDelete { offsets in
                    let keys = bindings.sorted(by: { $0.key < $1.key }).map(\.key)
                    offsets.map { keys[$0] }.forEach(SourceRouting.removeArtist)
                }
            } header: {
                Text(L("Pinned Artists"))
            } footer: {
                Text(L("Songs by these artists always use the pinned source. Add a name to pin it."))
            }

            Section {
                HStack {
                    TextField(L("Artist name"), text: $newArtist)
                    Button(L("Add")) {
                        SourceRouting.addArtist(newArtist)
                        newArtist = ""
                    }
                    .disabled(newArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("Artist Bindings"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
