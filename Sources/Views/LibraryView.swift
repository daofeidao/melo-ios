import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var store: PlaylistStore

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

                if !library.favorites.isEmpty {
                    Section {
                        ForEach(Array(library.favorites.enumerated()), id: \.offset) { index, track in
                            TrackRow(track: track) {
                                player.play(tracks: library.favorites, startAt: index)
                            }
                        }
                    } header: {
                        Text(L("My Favorites"))
                    }
                }

                if !library.recent.isEmpty {
                    Section {
                        ForEach(Array(library.recent.enumerated()), id: \.offset) { index, track in
                            TrackRow(track: track) {
                                player.play(tracks: library.recent, startAt: index)
                            }
                        }
                    } header: {
                        Text(L("Recently Played"))
                    }
                }

                if library.favorites.isEmpty, library.recent.isEmpty, store.playlists.isEmpty {
                    EmptyHint(
                        symbol: "heart",
                        title: L("Your library is empty"),
                        message: L("Long-press a song to favorite it. Played songs are saved here automatically.")
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

struct SettingsView: View {
    @EnvironmentObject private var library: Library

    @AppStorage("melo.quality") private var quality: String = StreamResolver.Quality.high.rawValue
    @AppStorage("melo.appearance") private var appearance: String = AppearanceMode.system.rawValue

    @State private var showClearConfirm = false
    @State private var probing = false
    @State private var probes: [InnerTube.HostProbe] = []
    @State private var playbackTesting = false
    @State private var playbackLines: [DiagnosticLine] = []

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
                HStack {
                    Text(L("Version"))
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .foregroundColor(Theme.secondaryLabel)
                }
                HStack {
                    Text(L("Data Source"))
                    Spacer()
                    Text("YouTube Music")
                        .foregroundColor(Theme.secondaryLabel)
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
