# Melo

为 iOS 15 定制的原生 SwiftUI YouTube Music 客户端（个人学习用）。

- 部署目标 iOS 15.0，零第三方依赖
- 界面语言跟随系统，内置 `en` / `zh-Hans`（英文原文作 key，中文在 zh-Hans.lproj）
- 外观支持 跟随系统 / 浅色 / 深色（设置内切换，持久化）
- 歌单导入：识别 网易云音乐 / QQ音乐 / 酷狗音乐 的分享链接，抓取曲目后逐首匹配到
  YouTube Music，存为本地歌单（可播放、随机、删除）
- 后台播放：AVAudioSession `.playback` + `UIBackgroundModes: audio`，
  锁屏/控制中心控制，拔耳机自动暂停，中断后按系统标记续播，直链过期自动重解析一次
- 数据：YouTube Music InnerTube（WEB_REMIX）+ ANDROID_VR 取音频直链（AAC itag 140）
- 界面：Apple Music 风格，五标签 + 迷你播放器 + 全屏播放页

文案表在 `scripts/gen_strings.py`，改完执行：

```
python scripts/gen_strings.py
```

构建见 `.github/workflows/build.yml`，产物为未签名 IPA（TrollStore 直装）。
CI 会跑模拟器冒烟测试并出七张截图：中文首页、设置页、迷你播放器、播放页、
英文+深色、资料库歌单、导入页。
