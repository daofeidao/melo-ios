# MEMORY

项目里那些「不看就会踩第二次」的事实。改代码前先扫一眼。

## 构建 / CI

- CI 改为手动触发，默认跳过冒烟测试；出全套截图用 `full_smoke=true`。
  ```bash
  gh workflow run "Build IPA" --ref main                       # 精简构建，约 8~10 分钟
  gh workflow run "Build IPA" --ref main -f full_smoke=true     # 带 15 张截图
  gh run watch --exit-status
  ```
- 推代码不再自动构建。Release tag 仍是 `build-<run_number>`，IPA 名 `Melo-vX.Y.Z.BN.ipa`。
- CI 里不能发邮件：macOS runner 在 Azure 上，出站 SMTP 被平台封。投递一律本机做。
- 本机是 Windows，没有 Xcode / Swift 工具链，Swift 代码只能靠 CI 验证编译。

## 容易踩的坑

- **不要用 `async let`**。Swift 6 的 async-let 在「某一路先抛错、父作用域提前退出」时
  会二次 finish 上下文并 `fatalError`，直接 SIGABRT（搜索页崩过三次）。
  一律用 `Task { } + await .value`。
- **`Track.videoId` 对国内音源是空串**。任何按 videoId 做的比较/缓存键/去重都会串歌，
  统一用 `Track.id`（国内源是 `source:sourceID`）。
- **酷狗封面 `Image` 是模板串**，含 `{size}` 占位，必须替换成像素数并升 https，
  否则永远只显示占位图。优先取 `AlbumImage`。
- **网易云境外 IP 返回加密体** `{"result":"<hex>"}`，公开 AES 密钥解不开；
  加 `X-Real-IP: 116.25.146.177` 直接拿明文。
- **超时别压太狠**。kugou playInfo 压到 6 秒时，境外机房 6~10 秒的链路会让
  「可播」判定全部失败（搜索页国内音源整片变空）。
- **网易云歌单详情必须带 `n=1000&s=0`**，否则只返回 10 首。
- **`charts.youtube.com` / `music.youtube.com` 都要代理**，真正免代理的只有国内源。

## 数据

- 收藏 / 最近播放：`UserDefaults`；歌单：`Documents/playlists.json`；
  直链缓存与服务端缓存：`Caches/`。
- 覆盖安装（同 bundle id）保留数据；删除 App 会清空。备份走
  「设置 → 备份与恢复」，导出到「文件」（可放 iCloud Drive）。
- 真 iCloud 同步做不了：假签名包没有 Apple 开发者 Team，iCloud 容器注册不了。

## YouTube 播放（2026-11-10 实测，别再重复验证）

- **元数据能拿、播放拿不到**不是代理问题：用户 VPN 下 Safari 与官方客户端都能播。
  根因是 Melo 自称 iOS 客户端却没有 PO Token / visitorData。
- **App 内嵌 WKWebView 能完整播放 YouTube**（真机同款引擎，已验证）。
  设置 →「YouTube 网页验证」可复现：页面 videoReady=4、正在播放、向
  `rr*.googlevideo.com` 发过请求。
- **但网页端不给直链**：`playabilityStatus=OK`、`streamingData` 有 30 条格式，
  `withURL=0` —— 全是 SABR（`serverAbrStreamingUrl`）。所以「从网页抠 URL 交给
  AVPlayer」这条路**不通**，不用再试。
- 想原生播放只剩两条：
  1. WKWebView 跑 BotGuard 铸 PO Token，再用自己的 IOS/ANDROID player 请求取直链（未验证能否拿到直链）；
  2. 自建服务端（yt-dlp + bgutil PO token provider）中转音频。
- 验证入口：`-smoke-yt-web`，CI 用 `verify_only=true` 跑（只编译 + 模拟器，不出 IPA）。
## 半验证结果（2026-11-10，run 42844410430）

- **App 自己的 IOS / ANDROID player 请求，不铸 PO Token 就能拿到直链**：
  IOS 27 条格式全部带 `url`（音频 itag 139/140/249/250），ANDROID 30 条全部带 `url`
  （139/140/249/251）。测试视频 `dQw4w9WgXcQ`，CI runner 在境外机房。
  → 「必须先有 PO Token」这个判断**没有被验证支持**，至少在这个出口 IP 上不成立。
- 网页端仍然 0 条直链（30 条全是 SABR），所以「从网页抠 URL」这条路依旧不通。
- BotGuard 铸造那步没跑通：`Waa/Create` 响应里没找到 `globalName` / `program`，
  报 `challenge not found`。**还没修**，目前也用不上（直链不需要 token 就有了）。
- **踩坑：`callAsyncJavaScript` / `WKContentWorld` 会把 `libswiftWebKit.dylib` 拖进来，
  这个库只有 iOS 16+ 才有**。链接能过，但 dyld 在启动时报
  `Library not loaded: /usr/lib/swift/libswiftWebKit.dylib`，App 直接闪退。
  加 `-Wl,-weak-lswiftWebKit` 也不行（SDK 里没有这个 tbd，`ld: library not found`）。
  正确做法：**只用 `evaluateJavaScript(_:completionHandler:)`，把 async JS 的结果写到
  `window.__meloResult` 再轮询取回**。改完 App 正常启动。