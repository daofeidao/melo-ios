import SwiftUI

/// 数据来源：内置音源开关、各源登录 / 验证入口、自定义解析源。
/// 从「设置 → 数据来源」进入。
///
/// 这里是**唯一的**凭据入口：网易云、QQ 音乐、酷我、酷狗的登录，以及歌曲宝的
/// 人机验证，全部在这一页完成。设置里不再单独有一个「账号」页——
/// 之前那个页面写的是同一份 Cookie，两处入口只会让人误以为存在两种账号。
struct DataSourceSettingsView: View {
    @ObservedObject private var prefs = SourcePrefs.shared

    /// iOS 15 同一视图只允许挂一个 .sheet，所以用枚举区分
    private enum ActiveSheet: Identifiable {
        case webLogin(SourcePrefs.SourceInfo)
        case newCustom

        var id: String {
            switch self {
            case .webLogin(let info): return "web-\(info.id)"
            case .newCustom: return "new-custom"
            }
        }
    }

    @State private var activeSheet: ActiveSheet?
    @State private var customName = ""
    @State private var customTemplate = ""

    var body: some View {
        List {
            Section {
                ForEach(prefs.builtIn) { info in
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
                            // 直接弹登录页。
                            // 以前是「点登录 → confirmationDialog 选方式 → sheet」，
                            // iOS 15 上前一个弹窗还没收起就 present 第二个会被静默丢弃，
                            // 表现就是「点了登录没反应、网页调不起来」。
                            // 现在一步到位，「粘贴 Cookie」收进登录页里当备用入口。
                            Button(actionText(info)) {
                                activeSheet = .webLogin(info)
                            }
                            .font(.system(size: 14))
                            .buttonStyle(PlainButtonStyle())
                        }
                        Toggle("", isOn: Binding(
                            get: { prefs.isEnabled(info.id) },
                            set: { prefs.setEnabled(info.id, $0) }
                        ))
                        .labelsHidden()
                    }
                }
            } header: {
                Text(L("Built-in Sources"))
            } footer: {
                Text(L("Sign in inside the app: the platform's own login page opens in a browser view and the resulting Cookie is captured automatically. Melo never sees your password. A membership account unlocks 320 kbps and lossless."))
            }

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
                Text(L("Template example: https://api.example.com/resolve?title={title}&artist={artist}. The endpoint may return a plain URL or JSON with url / data.url / play_url. Custom sources are tried last."))
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("Data Sources"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .webLogin(let info):
                WebLoginView(platform: info)
            case .newCustom:
                customSheet()
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

    /// 右侧按钮文案
    private func actionText(_ info: SourcePrefs.SourceInfo) -> String {
        let signed = prefs.cookie(info.id) != nil
        if info.login == .verify {
            return signed ? L("Verified") : L("Verify")
        }
        if signed { return L("Signed In") }
        return info.login == .required ? L("Sign In") : L("Sign In (Optional)")
    }

    /// 左侧状态副标题：把「登不登录，差别在哪」写清楚，不用用户猜
    private func statusText(_ info: SourcePrefs.SourceInfo) -> String {
        if !prefs.isEnabled(info.id) { return L("Disabled") }
        // 这一项是自建聚合源，把域名写出来，用户才知道它是什么
        if info.id == "flachi" { return "flac.music.hi.cn · " + L("No sign-in needed") }
        let signed = prefs.cookie(info.id) != nil
        switch info.login {
        case .none:
            return L("No sign-in needed")
        case .required:
            return signed ? L("Signed in · lossless available") : L("Not signed in · 128 kbps only")
        case .optional:
            return signed ? L("Signed in · lossless available") : L("Not signed in · 320 kbps available")
        case .verify:
            return signed ? L("Verified · direct link available") : L("Not verified · may be blocked")
        }
    }
}
