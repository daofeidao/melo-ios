import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var store: PlaylistStore
    @ObservedObject private var localMusic = LocalMusicStore.shared

    @State private var showImport = false
    @State private var showSettingsSheet = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        showImport = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(Theme.accent)
                            Text(L("Import Playlist"))
                                .foregroundColor(Theme.accent)
                            Spacer()
                        }
                    }

                    ForEach(store.playlists) { playlist in
                        NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                            PlaylistRow(playlist: playlist)
                        }
                    }
                } header: {
                    Text(L("My Playlists"))
                }

                Section {
                    NavigationLink(destination: LocalMusicView()) {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .foregroundColor(Theme.accent)
                            Text(L("Local Music"))
                            Spacer()
                            Text("\(localMusic.songs.count)")
                                .foregroundColor(Theme.secondaryLabel)
                        }
                    }
                } header: {
                    Text(L("My Music"))
                } footer: {
                    Text(L("Favorites and history live on the Listen Now page; this page keeps your imported files."))
                }

                if store.playlists.isEmpty {
                    EmptyHint(
                        symbol: "heart",
                        title: L("Your library is empty"),
                        message: L("Import a playlist link, or add audio files to Local Music.")
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(L("Library"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showImport) {
                ImportPlaylistView()
            }
            .sheet(isPresented: $showSettingsSheet) {
                NavigationView {
                    SettingsView()
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
            .onAppear {
                if SmokeTest.opensImport {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        showImport = true
                    }
                }
                if SmokeTest.opensSettingsPage {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        showSettingsSheet = true
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

private enum AboutPage: String, Identifiable {
    case changelog
    case dataSources

    var id: String { rawValue }
}

struct SettingsView: View {
    @EnvironmentObject private var library: Library

    @AppStorage("melo.quality") private var quality: String = StreamResolver.Quality.high.rawValue
    @AppStorage("melo.appearance") private var appearance: String = AppearanceMode.system.rawValue
    @AppStorage(AudioCache.enabledKey) private var cacheAudio = true
    @AppStorage(AudioCache.limitKey) private var cacheLimitMB = AudioCache.defaultLimitMB
    @AppStorage(DomesticSource.strictMatchKey) private var strictMatch = false
    @State private var cacheBytes: Int64 = 0
    @State private var showClearCacheConfirm = false

    @State private var showClearConfirm = false

    // 备份 / 恢复
    @State private var exporting = false
    @State private var importing = false
    @State private var exportDocument: BackupDocument?
    @State private var alertTitle = ""
    @State private var alertText = ""
    @State private var showAlert = false

    // 版本号彩蛋：7 次连点（间隔超过 2.5 秒重新计数）
    @State private var versionTaps = 0
    @State private var lastVersionTap = Date.distantPast
    /// 两个「关于」页共用一个 sheet：iOS 15 上同一视图叠两个 .sheet 会互相顶掉
    @State private var aboutPage: AboutPage?

    var body: some View {
        List {
            Section {
                Picker(L("Audio Quality"), selection: $quality) {
                    ForEach(StreamResolver.Quality.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
            } header: {
                Text(L("Playback"))
            } footer: {
                Text(L("Lossless needs a membership login. Without one the app automatically falls back to 320 kbps, then 128 kbps."))
            }

            Section {
                Toggle(L("Strict matching"), isOn: $strictMatch)
            } header: {
                Text(L("Fallback Matching"))
            } footer: {
                Text(L("When a direct link fails, Melo searches other sources for the same song. Strict mode requires the same title, artist and duration (±5 s). Turning it off may pick covers or live versions."))
            }

            Section {
                Toggle(L("Cache played audio"), isOn: $cacheAudio)
                Picker(L("Cache limit"), selection: $cacheLimitMB) {
                    Text("200 MB").tag(200)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                    Text("3 GB").tag(3072)
                    Text("5 GB").tag(5120)
                }
                HStack {
                    Text(L("Audio cache"))
                    Spacer()
                    Text(cacheBytes > 0
                         ? ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
                         : "—")
                        .foregroundColor(Theme.secondaryLabel)
                }
                Button {
                    showClearCacheConfirm = true
                } label: {
                    Text(L("Clear audio cache"))
                        .foregroundColor(.red)
                }
            } header: {
                Text(L("Storage"))
            } footer: {
                Text(L("Cached audio is kept until you clear it here. When the limit is reached, the songs you have not played for the longest time are removed first."))
            }

            Section {
                Picker(L("Appearance"), selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .labelsHidden()
            } header: {
                Text(L("Appearance"))
            } footer: {
                Text(L("Appearance follows the system by default. Pick Light or Dark to override it for this app only."))
            }

            Section {
                Button {
                    showClearConfirm = true
                } label: {
                    Text(L("Clear Recently Played"))
                        .foregroundColor(.red)
                }
            } header: {
                Text(L("Library"))
            }

            Section {
                Button {
                    prepareExport()
                } label: {
                    HStack {
                        Text(L("Export Backup"))
                        Spacer()
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(Theme.secondaryLabel)
                    }
                }
                Button {
                    importing = true
                } label: {
                    HStack {
                        Text(L("Restore from Backup"))
                        Spacer()
                        Image(systemName: "square.and.arrow.down")
                            .foregroundColor(Theme.secondaryLabel)
                    }
                }
            } header: {
                Text(L("Backup & Restore"))
            } footer: {
                Text(L("Your favorites and playlists live inside the app. Installing a new build over it keeps them; deleting the app erases them. Export to Files — iCloud Drive works — so you can restore after reinstalling."))
            }

            Section {
                HStack {
                    Text(L("Version"))
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .foregroundColor(Theme.secondaryLabel)
                }
                .contentShape(Rectangle())
                .onTapGesture { registerVersionTap() }

                NavigationLink(destination: DataSourceSettingsView()) {
                    HStack {
                        Text(L("Data Sources"))
                        Spacer()
                        Text(String(format: L("%d sources"),
                                    SourcePrefs.shared.builtIn.count + SourcePrefs.shared.customSources.count))
                            .foregroundColor(Theme.secondaryLabel)
                    }
                }

                NavigationLink(destination: AdvancedDiagnosticsView()) {
                    HStack {
                        Text(L("Advanced Diagnostics"))
                        Spacer()
                        Text(L("Read-only"))
                            .foregroundColor(Theme.secondaryLabel)
                    }
                }
            } header: {
                Text(L("About"))
            } footer: {
                Text(L("A third-party client built for iOS 15, for personal study only. Please follow local laws and the platform's terms."))
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshCacheSize()
            if SmokeTest.showsChangelog { aboutPage = .changelog }
            if SmokeTest.showsDataSources { aboutPage = .dataSources }
            if SmokeTest.showsChangelog || SmokeTest.showsDataSources {
                NSLog("SMOKE_ABOUT changelog=\(SmokeTest.showsChangelog) sources=\(SmokeTest.showsDataSources)")
            }
            guard SmokeTest.runsPlaybackTest, DiagnosticsModel.shared.playbackLines.isEmpty else { return }
            Task { await DiagnosticsModel.shared.runPlaybackTest() }
        }
        .onChange(of: cacheLimitMB) { _ in
            // 上限调小后立刻淘汰，不能等下次下载才生效
            AudioCache.shared.enforceLimit()
            refreshCacheSize()
        }
        .confirmationDialog(
            L("Clear recently played?"),
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button(L("Clear"), role: .destructive) {
                library.clearRecent()
            }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            L("Clear audio cache?"),
            isPresented: $showClearCacheConfirm,
            titleVisibility: .visible
        ) {
            Button(L("Clear"), role: .destructive) {
                AudioCache.shared.clear()
                cacheBytes = 0
            }
            Button(L("Cancel"), role: .cancel) {}
        }
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: BackupService.defaultFileName()
        ) { result in
            switch result {
            case .success:
                show(title: L("Backup & Restore"), message: L("Backup saved. Keep it in Files or iCloud Drive."))
            case .failure(let error):
                show(
                    title: L("Backup & Restore"),
                    message: String(format: L("Export failed: %@"), error.localizedDescription)
                )
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                restore(from: url)
            case .failure(let error):
                show(
                    title: L("Backup & Restore"),
                    message: String(format: L("Restore failed: %@"), error.localizedDescription)
                )
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button(L("Done"), role: .cancel) {}
        } message: {
            Text(alertText)
        }
        .sheet(item: $aboutPage) { page in
            switch page {
            case .changelog:
                ChangelogView()
            case .dataSources:
                NavigationView {
                    DataSourcesView()
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
        }
    }

    private func refreshCacheSize() {
        DispatchQueue.global(qos: .utility).async {
            let bytes = AudioCache.shared.size()
            DispatchQueue.main.async { cacheBytes = bytes }
        }
    }

    /// 连点 7 次才打开更新记录。中间停顿超过 2.5 秒就重新计数，
    /// 免得平时误触把页面弹出来。
    private func registerVersionTap() {        let now = Date()
        if now.timeIntervalSince(lastVersionTap) > 2.5 { versionTaps = 0 }
        lastVersionTap = now
        versionTaps += 1
        if versionTaps >= 7 {
            versionTaps = 0
            aboutPage = .changelog
        }
    }

    private func prepareExport() {
        do {
            exportDocument = BackupDocument(data: try BackupService.encoded())
            exporting = true
        } catch {
            show(
                title: L("Backup & Restore"),
                message: String(format: L("Export failed: %@"), error.localizedDescription)
            )
        }
    }

    private func restore(from url: URL) {
        do {
            let summary = try BackupService.restore(from: url)
            show(title: L("Backup & Restore"), message: summary.text)
        } catch {
            show(
                title: L("Backup & Restore"),
                message: String(format: L("Restore failed: %@"), error.localizedDescription)
            )
        }
    }

    private func show(title: String, message: String) {
        alertTitle = title
        alertText = message
        showAlert = true
    }
}
