import SwiftUI

/// 高级诊断：连接测试 + 播放诊断 + YouTube 网页验证入口。
/// 之前这些散落在「设置 → 网络」，按用户要求集中到「关于 → 高级诊断」。
struct AdvancedDiagnosticsView: View {
    @ObservedObject private var model = DiagnosticsModel.shared

    var body: some View {
        List {
            Section {
                Button {
                    Task { await model.runConnectionTest() }
                } label: {
                    HStack {
                        Text(L("Connection Test"))
                        Spacer()
                        if model.probing {
                            ProgressView()
                        }
                    }
                }
                ForEach(model.probes, id: \.host) { probe in
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
            } header: {
                Text(L("Connection Test"))
            } footer: {
                Text(L("Both hosts serve the same API. If only one responds, adjust your proxy rules."))
            }

            Section {
                Button {
                    Task { await model.runPlaybackTest() }
                } label: {
                    HStack {
                        Text(L("Playback Test"))
                        Spacer()
                        if model.playbackTesting {
                            ProgressView()
                        }
                    }
                }
                ForEach(model.playbackLines) { line in
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
                Text(L("Playback Test"))
            } footer: {
                Text(L("If step 1 fails, this IP is likely flagged as a bot; if step 2 fails, your proxy probably does not forward googlevideo.com."))
            }

            Section {
                NavigationLink(destination: YouTubeWebProbeView()) {
                    HStack {
                        Text(L("YouTube Web Probe"))
                        Spacer()
                        Text(L("Read-only"))
                            .foregroundColor(Theme.secondaryLabel)
                    }
                }
            } footer: {
                Text(L("Opens YouTube inside the app to check whether this network can play video at all."))
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(L("Advanced Diagnostics"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
