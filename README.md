# Melo

为 iOS 15 定制的原生 SwiftUI YouTube Music 客户端（个人学习用）。

- 部署目标 iOS 15.0，零第三方依赖
- 数据：YouTube Music InnerTube（WEB_REMIX）+ ANDROID_VR 取音频直链（AAC itag 140）
- 播放：AVPlayer + AVAudioSession 后台音频 + 锁屏/控制中心远程控制
- 界面：Apple Music 风格，五标签 + 迷你播放器 + 全屏播放页

构建见 `.github/workflows/build.yml`，产物为未签名 IPA（TrollStore 直装）。
