import SwiftUI
import UIKit

/// 高级诊断：连接测试 + 播放诊断 + YouTube 网页验证入口。
/// 之前这些散落在「设置 → 网络」，按用户要求集中到「关于 → 高级诊断」。
struct AdvancedDiagnosticsView: View {
    @ObservedObject private var model = DiagnosticsModel.shared
    @State private var trace: String = Diagnostics.tail(40)
    @State private var nowPlayingOn: Bool = NowPlayingBridge.isEnabled
    @State private var autoOpenPlayer: Bool = SafeMode.autoOpenPlayer

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

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
                    #if targetEnvironment(macCatalyst)
                    // 闪退之后点这里：把系统留下的 .ips 崩溃报告关键帧抄进日志，
                    // 复制发过来就能看到精确到符号的崩溃栈，不用手动翻目录
                    Button(L("Crash Report")) {
                        CrashReport.ingestLatest()
                        trace = Diagnostics.tail(40)
                    }
                    Spacer()
                    #endif
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

            #if targetEnvironment(macCatalyst)
            // Mac 版「一按播放就退」的现场开关：不用再等一版新包，
            // 在这里就能把媒体中心集成和自动弹播放页分别关掉试。
            Section {
                Toggle(isOn: $nowPlayingOn) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Now Playing integration"))
                        Text(L("Shows the track in the menu bar and responds to the media keys."))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.secondaryLabel)
                    }
                }
                .onChange(of: nowPlayingOn) { value in
                    NowPlayingBridge.isEnabled = value
                }

                Toggle(isOn: $autoOpenPlayer) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Open the player on play"))
                        Text(L("Off keeps the mini bar only, so you can pick a track without opening the full player."))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.secondaryLabel)
                    }
                }
                .onChange(of: autoOpenPlayer) { value in
                    SafeMode.autoOpenPlayer = value
                }
            } header: {
                Text(L("Mac Compatibility"))
            } footer: {
                if let at = SafeMode.lastCrashAt {
                    Text(String(format: L("Last session ended unexpectedly (%@). Melo may have turned these off by itself."), Self.formatter.string(from: at)))
                } else {
                    Text(L("If Melo quits right after a track starts, turn these off to narrow it down."))
                }
            }
            #endif

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
