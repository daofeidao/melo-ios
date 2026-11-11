import Foundation

/// 诊断状态的中转站。
///
/// 为什么单独抽一个对象：诊断界面从「设置 → 网络」搬到了「关于 → 高级诊断」，
/// 但 CI 冒烟测试是在设置页 onAppear 时触发的（`SmokeTest.runsPlaybackTest`），
/// 状态放这里，两个入口读写的是同一份，不重复实现。
final class DiagnosticsModel: ObservableObject {

    static let shared = DiagnosticsModel()

    @Published private(set) var probing = false
    @Published private(set) var probes: [InnerTube.HostProbe] = []
    @Published private(set) var playbackTesting = false
    @Published private(set) var playbackLines: [DiagnosticLine] = []

    private init() {}

    @MainActor
    func runConnectionTest() async {
        guard !probing else { return }
        probing = true
        probes = []
        let result = await InnerTube.shared.diagnose()
        probes = result
        probing = false
    }

    @MainActor
    func runPlaybackTest() async {
        guard !playbackTesting else { return }
        playbackTesting = true
        playbackLines = []
        let lines = await PlaybackDiagnostics.run()
        playbackLines = lines
        playbackTesting = false
    }
}
