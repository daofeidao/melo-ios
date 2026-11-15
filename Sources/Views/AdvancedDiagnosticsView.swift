import SwiftUI
import UIKit

/// 高级诊断：连接测试 + 播放诊断 + YouTube 网页验证入口。
/// 之前这些散落在「设置 → 网络」，按用户要求集中到「关于 → 高级诊断」。
struct AdvancedDiagnosticsView: View {
    @ObservedObject private var model = DiagnosticsModel.shared
    @State private var trace: String = Diagnostics.tail(40)

    var body: some View {
        List {
            Section {
                Text(Diagnostics.logPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.secondaryLabel)
                    .textSelection(.enabled)

                ScrollView {
                    Text(trace.isEmpty ? "—" : trace)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)

                HStack {
                    Button(L("Copy")) {
                        UIPasteboard.general.string = Diagnostics.logPath + "\n\n" + Diagnostics.tail(200)
                    }
                    Spacer()
                    Button(L("Clear")) {
                        Diagnostics.clear()
                        trace = Diagnostics.tail(40)
                    }
                    .foregroundColor(.red)
                }
            } header: {
                Text(L("Run Log"))
            } footer: {
                Text(L("The last few steps before a crash are recorded here. If the app quits unexpectedly, copy this and send it over."))
            }

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
