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

    @State private var showClearConfirm = false
    @State private var probing = false
    @State private var probes: [InnerTube.HostProbe] = []
    @State private var playbackTesting = false
    @State private var playbackLines: [DiagnosticLine] = []

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
                Text(L("High quality is AAC 128 kbps. YouTube Music does not offer lossless."))
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
                    Task { await runDiagnose() }
                } label: {
                    HStack {
                        Text(L("Connection Test"))
                        Spacer()
                        if probing {
                            ProgressView()
                        }
                    }
                }
                ForEach(probes, id: \.host) { probe in
                    HStack {
                        Text(probe.host)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.secondaryLabel)
                        Spacer()
                        if let ms = probe.milliseconds {
                            Text("\(ms) ms").font(.system(size: 13)).foregroundColor(.green)
                        } else {
                            Text(probe.failure ?? "—")
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                                .lineLimit(1)
                        }
                    }
                }
                Button {
                    Task { await runPlaybackTest() }
                } label: {
                    HStack {
                        Text(L("Playback Test"))
                        Spacer()
                        if playbackTesting {
                            ProgressView()
                        }
                    }
                }
                ForEach(playbackLines) { line in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: line.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(line.ok ? .green : .red)
                            Text(line.title)
                                .font(.system(size: 13))
                        }
                        Text(line.detail)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text(L("Network"))
            } footer: {
                Text(L("Both hosts serve the same API. If only one responds, adjust your proxy rules."))
                Text(L("If step 1 fails, this IP is likely flagged as a bot; if step 2 fails, your proxy probably does not forward googlevideo.com."))
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

                NavigationLink(destination: DataSourcesView()) {
                    HStack {
                        Text(L("Data Sources"))
                        Spacer()
                        Text(L("6 sources"))
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
            if SmokeTest.showsChangelog { aboutPage = .changelog }
            if SmokeTest.showsDataSources { aboutPage = .dataSources }
            if SmokeTest.showsChangelog || SmokeTest.showsDataSources {
                NSLog("SMOKE_ABOUT changelog=\(SmokeTest.showsChangelog) sources=\(SmokeTest.showsDataSources)")
            }
            guard SmokeTest.runsPlaybackTest, playbackLines.isEmpty, !playbackTesting else { return }
            Task { await runPlaybackTest() }
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

    /// 连点 7 次才打开更新记录。中间停顿超过 2.5 秒就重新计数，
    /// 免得平时误触把页面弹出来。
    private func registerVersionTap() {
        let now = Date()
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

    private func runPlaybackTest() async {
        await MainActor.run {
            playbackTesting = true
            playbackLines = []
        }
        let lines = await PlaybackDiagnostics.run()
        await MainActor.run {
            playbackLines = lines
            playbackTesting = false
        }
    }

    private func runDiagnose() async {
        await MainActor.run {
            probing = true
            probes = []
        }
        let result = await InnerTube.shared.diagnose()
        await MainActor.run {
            probes = result
            probing = false
        }
    }
}
