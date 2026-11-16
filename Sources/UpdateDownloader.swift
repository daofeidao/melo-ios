import Foundation
import SwiftUI
import UIKit

/// 更新包的内建下载。
///
/// iOS 的系统限制：**未签名的 IPA 无法静默安装**。TrollStore 拿到的也是「用户点一下安装」，
/// 没有任何 App 能绕开。所以这里做到能做到的最好：
///   1. 在 App 内直接下载 IPA（不跳浏览器）；
///   2. 下载完把文件交给系统分享面板 —— 选 TrollStore 就是安装，
///      选「存储到文件」就是留档。
///
/// 对比以前「点下载 → 跳 Safari → 再点一次」少一次跳转，也不会因为浏览器丢失下载。
@MainActor
final class UpdateDownloader: ObservableObject {

    enum Phase: Equatable {
        case idle
        case downloading
        case ready(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0

    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    func downloadAndShare(_ info: AppUpdate.Info) {
        let raw = info.downloadUrl.isEmpty ? info.pageUrl : info.downloadUrl
        guard let url = URL(string: raw) else {
            phase = .failed(L("Invalid download link."))
            return
        }
        // 没有直链（老版本发布没挂附件）时退回打开发布页，别让按钮变成死键
        guard raw.lowercased().hasSuffix(".ipa") || raw.contains("/releases/download/") else {
            UIApplication.shared.open(url)
            return
        }

        phase = .downloading
        progress = 0

        let session = URLSession(configuration: .default)
        let downloadTask = session.downloadTask(with: url) { [weak self] tmp, response, error in
            guard let self else { return }
            Task { @MainActor in
                guard error == nil, let tmp else {
                    self.phase = .failed(error?.localizedDescription ?? L("Download failed."))
                    return
                }
                // 文件名用链接里的真实名字（Melo-v2.0.4.B128.ipa / Melo-Mac-v2.0.4.zip），
                // 分享面板里一眼能看出下的是哪个包
                let remoteName = URL(string: raw)?.lastPathComponent ?? ""
                let name = remoteName.isEmpty ? "Melo-update" : remoteName
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    self.phase = .ready(dest.path)
                    self.share(dest)
                } catch {
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
        observation = downloadTask.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            // 先绑定成强引用常量再进并发闭包：Swift 5.8 不允许在并发闭包里引用"被捕获的 var self"
            guard let self = self else { return }
            let value = p.fractionCompleted
            Task { @MainActor in self.progress = value }
        }
        task = downloadTask
        downloadTask.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        observation = nil
        phase = .idle
    }

    private func share(_ file: URL) {
        guard let root = Self.topViewController() else { return }
        let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        // iPad 上必须给 popover 锚点，否则直接崩
        controller.popoverPresentationController?.sourceView = root.view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0
        )
        root.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
