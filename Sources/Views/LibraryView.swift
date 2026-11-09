import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: PlayerEngine

    var body: some View {
        NavigationView {
            List {
                if !library.favorites.isEmpty {
                    Section {
                        ForEach(Array(library.favorites.enumerated()), id: \.offset) { index, track in
                            TrackRow(track: track) {
                                player.play(tracks: library.favorites, startAt: index)
                            }
                        }
                    } header: {
                        Text("我的收藏")
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
                        Text("最近播放")
                    }
                }

                if library.favorites.isEmpty, library.recent.isEmpty {
                    EmptyHint(
                        symbol: "heart",
                        title: "资料库是空的",
                        message: "长按歌曲可以收藏，播放过的歌会自动记录在这里。"
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                Section {
                    SettingsEntry()
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("资料库")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

private struct SettingsEntry: View {
    var body: some View {
        NavigationLink(destination: SettingsView()) {
            HStack(spacing: 12) {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(Theme.accent)
                Text("设置")
                Spacer()
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var library: Library
    @AppStorage("melo.quality") private var quality: String = StreamResolver.Quality.high.rawValue

    @State private var showClearConfirm = false

    var body: some View {
        List {
            Section {
                Picker("音质", selection: $quality) {
                    ForEach(StreamResolver.Quality.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(DefaultPickerStyle())
            } header: {
                Text("播放")
            } footer: {
                Text("高品质为标准 AAC 128kbps。无损格式 YouTube Music 不提供。")
            }

            Section {
                Button {
                    showClearConfirm = true
                } label: {
                    Text("清空最近播放")
                        .foregroundColor(.red)
                }
            } header: {
                Text("资料库")
            }

            Section {
                HStack {
                    Text("版本")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(Theme.secondaryLabel)
                }
                HStack {
                    Text("数据来源")
                    Spacer()
                    Text("YouTube Music")
                        .foregroundColor(Theme.secondaryLabel)
                }
            } header: {
                Text("关于")
            } footer: {
                Text("这是为 iOS 15 定制的第三方客户端，仅用于个人学习，请遵守当地法律与平台条款。")
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("确定清空最近播放？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                library.clearRecent()
            }
            Button("取消", role: .cancel) {}
        }
    }
}
