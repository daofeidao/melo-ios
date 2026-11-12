import SwiftUI

/// 数据来源：内置音源开关、需要登录的源的凭据录入、自定义解析源。
/// 从「设置 → 关于 → 数据来源」进入。
struct DataSourceSettingsView: View {
    @ObservedObject private var prefs = SourcePrefs.shared

    /// iOS 15 同一视图只允许挂一个 .sheet，所以用枚举区分
    private enum ActiveSheet: Identifiable {
        case webLogin(SourcePrefs.SourceInfo)
        case login(SourcePrefs.SourceInfo)
        case newCustom

        var id: String {
            switch self {
            case .webLogin(let info): return "web-\(info.id)"
            case .login(let info): return "login-\(info.id)"
            case .newCustom: return "new-custom"
            }
        }
    }

    @State private var activeSheet: ActiveSheet?
    /// 点「登录」先问用哪种方式，选中后才决定弹哪个 sheet
    @State private var loginChooser: SourcePrefs.SourceInfo?
    @State private var loginText = ""
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
                        if info.needsLogin {
                            Button(prefs.cookie(info.id) == nil ? L("Sign In") : L("Replace")) {
                                loginChooser = info
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
                Text(L("Turned-off sources are skipped in search and fallback. Tap Sign In to open the platform's own login page inside the app; the Cookie is captured automatically. Sign in with a membership account to unlock 320 kbps and lossless."))
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
        .confirmationDialog(
            L("Sign In"),
            isPresented: Binding(
                get: { loginChooser != nil },
                set: { if !$0 { loginChooser = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("Sign in with the web page")) {
                if let info = loginChooser { activeSheet = .webLogin(info) }
                loginChooser = nil
            }
            Button(L("Paste Cookie")) {
                if let info = loginChooser {
                    loginText = prefs.cookie(info.id) ?? ""
                    activeSheet = .login(info)
                }
                loginChooser = nil
            }
            Button(L("Cancel"), role: .cancel) { loginChooser = nil }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .webLogin(let info):
                WebLoginView(platform: info)
            case .login(let info):
                loginSheet(info)
            case .newCustom:
                customSheet()
            }
        }
    }

    private func loginSheet(_ info: SourcePrefs.SourceInfo) -> some View {
        NavigationView {
            Form {
                Section {
                    // iOS 15 没有 TextField(axis:)，多行输入用 TextEditor
                    TextEditor(text: $loginText)
                        .frame(minHeight: 90)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } footer: {
                    Text(L("Use the web page sign-in unless you already have a Cookie header at hand. The app never sees your password - only the resulting Cookie is stored, on this device."))
                }
            }
            .navigationTitle(L("Sign In"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { activeSheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save")) {
                        prefs.setCookie(info.id, loginText)
                        activeSheet = nil
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
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

    private func statusText(_ info: SourcePrefs.SourceInfo) -> String {
        if !prefs.isEnabled(info.id) { return L("Disabled") }
        // 这一项是自己后端代取的聚合源，把域名写出来，用户才知道它是什么
        if info.id == "flachi" { return "flac.music.hi.cn · " + L("No sign-in needed") }
        if info.needsLogin {
            return prefs.cookie(info.id) == nil ? L("Not signed in") : L("Signed in")
        }
        return L("No sign-in needed")
    }
}
