import SwiftUI

/// 「添加喜欢艺人」面板。
///
/// 之前喜欢艺人只能靠长按移除、没有任何添加入口（toggleLikedArtist 写了但没人调用），
/// 这里补上两条路径：
///   1. 输入框手打名字 —— 先过网易云艺人白名单校验，查得到才加；
///   2. 推荐宫格点选 —— 内置常见艺人 + 搜过的艺人，点一下加进去。
///
/// 校验失败要明确告诉用户，不能点了没反应：最常见的原因是名字不是真人艺人
/// （`周杰伦电台`、`孙-` 这种派生号 / 截断名），而不是网络问题。
struct AddLikedArtistSheet: View {
    @EnvironmentObject private var library: Library
    @Environment(\.presentationMode) private var presentationMode

    @State private var query = ""
    @State private var busy = false
    @State private var errorText: String?
    /// 校验通过后用它驱动一次性的「已添加」提示，避免用户以为没成功
    @State private var addedName: String?

    private var suggestions: [String] {
        let liked = Set(library.likedArtists.map { ArtistName.key($0) })
        return ArtistStore.all().filter { !liked.contains(ArtistName.key($0)) }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    searchRow
                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: 0xE0455E))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let addedName {
                        Text(String(format: L("Added %@"), addedName))
                            .font(.system(size: 13))
                            .foregroundColor(Theme.accent)
                    }
                    if !suggestions.isEmpty {
                        SectionHeader(title: L("Suggestions"))
                        grid
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, Layout.contentBottomInset)
            }
            .navigationTitle(L("Add Artist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("Done")) { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - 输入

    private var searchRow: some View {
        HStack(spacing: 10) {
            TextField(L("Artist name"), text: $query)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .onSubmit { submit() }
            Button(action: submit) {
                if busy {
                    ProgressView().scaleEffect(0.8)
                        .frame(width: 44, height: 32)
                } else {
                    Text(L("Add"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Theme.accent)
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(busy || query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 14)], spacing: 16) {
            ForEach(suggestions, id: \.self) { name in
                Button {
                    add(name)
                } label: {
                    ArtistCircleTile(name: name, size: 68)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(busy)
            }
        }
    }

    // MARK: - 校验并添加

    private func submit() {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        add(typed)
    }

    private func add(_ raw: String) {
        let clean = ArtistName.primary(raw)
        guard !clean.isEmpty else { return }
        errorText = nil
        addedName = nil
        guard ArtistName.isPlausible(clean) else {
            errorText = L("This doesn't look like an artist name. Try the name only, without 「radio」 or version notes.")
            return
        }
        guard !library.isLikedArtist(clean) else {
            errorText = String(format: L("%@ is already in Liked Artists."), clean)
            return
        }
        busy = true
        Task {
            let found = await ArtistResolver.resolve(clean) != nil
            await MainActor.run {
                busy = false
                if found {
                    library.addLikedArtist(clean)
                    addedName = clean
                    query = ""
                } else {
                    errorText = String(format: L("No such artist in the library: %@"), clean)
                }
            }
        }
    }
}
