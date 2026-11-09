import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var store: PlaylistStore

    @State private var showImport = false

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

                Section {
                    NavigationLink(destination: SettingsView()) {
                        HStack(spacing: 12) {
                            Image(systemName: "gearshape.fill")
                                .foregroundColor(Theme.accent)
                            Text(L("Settings"))
                            Spacer()
                        }
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(L("Library"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showImport = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showImport) {
                ImportPlaylistView()
            }
            .onAppear {
                if SmokeTest.opensImport {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        showImport = true
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
}
