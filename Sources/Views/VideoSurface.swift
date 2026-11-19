import AVFoundation
import SwiftUI
import UIKit

/// 把 AVPlayer 的画面显示出来。
///
/// 为什么需要它：受保护视频只有「视频+音频」合体的 format 18 可读（96k 音质），
/// 画面本来就在流里，白白丢掉太浪费 —— 播放页直接把这一路画面显示出来，
/// 用户至少看到的是原视频，而不是一张静止封面。
///
/// 注意复用同一个 AVPlayer：绝不能为显示画面另建播放器，否则音画会各播各的。
struct VideoSurface: UIViewRepresentable {

    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .clear
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    /// 离开视图层级时解绑，免得 AVPlayer 继续往一个已经没人看的 layer 里推帧
    static func dismantleUIView(_ uiView: PlayerLayerView, coordinator: ()) {
        uiView.playerLayer.player = nil
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // layerClass 已固定成 AVPlayerLayer，这里的强转不会失败
        layer as! AVPlayerLayer
    }
}
