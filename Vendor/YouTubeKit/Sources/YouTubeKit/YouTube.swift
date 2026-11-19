//
//  YouTube.swift
//  YouTubeKit
//
//  Created by Alexander Eichhorn on 04.09.21.
//

import Foundation
@preconcurrency import os.log

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
public class YouTube {

    /// 调用方提供的「身份」：visitor + 内容绑定 PO Token。
    /// 两者必须来自同一次铸造，否则 player 请求与 token 对不上，YouTube 会照样 403。
    public struct YouTubeIdentity: Sendable {
        public let visitorData: String?
        public let playerToken: String?

        public init(visitorData: String?, playerToken: String?) {
            self.visitorData = visitorData
            self.playerToken = playerToken
        }
    }

    /// 本次解析使用的身份。设置后 lib 不再用 watch 页的 visitor 发 player 请求。
    public var identity: YouTubeIdentity?

    /// 全局兜底：没人设置 `identity` 时调用，让 App 有机会在 player 请求前把 token 铸好。
    #if swift(>=5.10)
    nonisolated(unsafe) public static var identityProvider: ((_ videoID: String) async -> YouTubeIdentity?)?
    #else
    public static var identityProvider: ((_ videoID: String) async -> YouTubeIdentity?)?
    #endif

    /// 诊断输出（App 接到自己的 trace 里）。库内部的 os_log 在 App 日志里看不到。
    #if swift(>=5.10)
    nonisolated(unsafe) public static var debugLog: ((String) -> Void)?
    #else
    public static var debugLog: ((String) -> Void)?
    #endif
    
    private var _js: String?
    private var _jsURL: URL?
    
#if swift(>=5.10)
    nonisolated(unsafe) private static var __js: String? // caches js between calls
    nonisolated(unsafe) private static var __jsURL: URL?
#else
    private static var __js: String? // caches js between calls
    private static var __jsURL: URL?
#endif
    
    private var _videoInfos: [InnerTube.VideoInfo]?
    
    private var _watchHTML: String?
    private var _embedHTML: String?
    private var playerConfigArgs: [String: Any]?
    private var _ageRestricted: Bool?
    private var _signatureTimestamp: Int?
    private var _ytcfg: Extraction.YtCfg?

    /// 本轮是否强制拉取解签名前置件（只在上一次拿到全签名流时置真）
    private var _forceCipherSetup = false

    /// 全部字段可空，所以空 JSON 就是一份合法的「什么都没有」配置
    private static let emptyYtCfg: Extraction.YtCfg =
        (try? JSONDecoder().decode(Extraction.YtCfg.self, from: Data("{}".utf8)))
        ?? (try! JSONDecoder().decode(Extraction.YtCfg.self, from: Data("{\"VISITOR_DATA\":null}".utf8)))
    
    private var _fmtStreams: [Stream]?
    
    private var initialData: Data?

    /// Represents a property that provides metadata for a YouTube video.
    ///
    /// This property allows you to retrieve metadata for a YouTube video asynchronously.
    /// - Note: Currently doesn't respect `method` set. It always uses `.local`
    public var metadata: YouTubeMetadata? {
        get async throws {
            return .metadata(from: try await videoDetails)
        }
    }

    public let videoID: String
    
    var watchURL: URL {
        URL(string: "https://youtube.com/watch?v=\(videoID)")!
    }
    
    private var extendedWatchURL: URL {
        URL(string: "https://youtube.com/watch?v=\(videoID)&bpctr=9999999999&has_verified=1")!
    }
    
    var embedURL: URL {
        URL(string: "https://www.youtube.com/embed/\(videoID)")!
    }
    
    // stream monostate TODO
    
    private var author: String?
    private var title: String?
    private var publishDate: String?
    
    let useOAuth: Bool
    let allowOAuthCache: Bool
    
    let methods: [ExtractionMethod]
    
    private let log = OSLog(YouTube.self)
    
    /// - parameter methods: Methods used to extract streams from the video - ordered by priority (Default: `local` on iOS, macOS, tvOS, visionOS; `remote` on watchOS)
    public init(videoID: String, proxies: [String: URL] = [:], useOAuth: Bool = false, allowOAuthCache: Bool = false, methods: [ExtractionMethod] = .default) {
        self.videoID = videoID
        self.useOAuth = useOAuth
        self.allowOAuthCache = allowOAuthCache
        // TODO: install proxies if needed
        
        if methods.isEmpty {
#if canImport(JavaScriptCore)
            self.methods = [.local]
#else
            self.methods = [.remote]
#endif
        } else {
            self.methods = methods.removeDuplicates()
        }
    }
    
    /// - parameter methods: Methods used to extract streams from the video - ordered by priority (Default: `local` on iOS, macOS, tvOS, visionOS; `remote` on watchOS)
    public convenience init(url: URL, proxies: [String: URL] = [:], useOAuth: Bool = false, allowOAuthCache: Bool = false, methods: [ExtractionMethod] = .default) {
        let videoID = Extraction.extractVideoID(from: url.absoluteString) ?? ""
        self.init(videoID: videoID, proxies: proxies, useOAuth: useOAuth, allowOAuthCache: allowOAuthCache, methods: methods)
    }
    
    
    private var watchHTML: String {
        get async throws {
            if let cached = _watchHTML {
                return cached
            }
            var request = URLRequest(url: extendedWatchURL)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("en-US,en", forHTTPHeaderField: "accept-language")
            request.httpShouldHandleCookies = false
            let (data, _) = try await URLSession.shared.data(for: request)
            _watchHTML = String(data: data, encoding: .utf8) ?? ""
            return _watchHTML!
        }
    }
    
    private var embedHTML: String {
        get async throws {
            if let cached = _embedHTML {
                return cached
            }
            var request = URLRequest(url: embedURL)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("en-US,en", forHTTPHeaderField: "accept-language")
            request.setValue("https://www.reddit.com/", forHTTPHeaderField: "Referer")
            request.httpShouldHandleCookies = false
            let (data, _) = try await URLSession.shared.data(for: request)
            _embedHTML = String(data: data, encoding: .utf8) ?? ""
            return _embedHTML!
        }
    }
    
    
    /// check whether the video is available
    public func checkAvailability() async throws {
        let (status, messages) = try Extraction.playabilityStatus(watchHTML: await watchHTML)

        switch status {
        case .unplayable:
            if messages.contains(where: { $0.starts(with: "Join this channel to get access to members-only content") }) {
                throw YouTubeKitError.membersOnly
            }
        case .loginRequired:
            if messages.contains(where: {
                $0 == "Private video" || $0.starts(with: "This is a private video") || $0.starts(with: "This video is private")
            }) {
                throw YouTubeKitError.videoPrivate
            }
        case .error:
            throw YouTubeKitError.videoUnavailable
        case .liveStream:
            let streamingData = try await videoInfos.map { $0.streamingData }
            if streamingData.allSatisfy({ $0?.hlsManifestUrl == nil }) {
                throw YouTubeKitError.liveStreamError
            }
        case .ok, .none:
            break
        }
    }
    
    public var ageRestricted: Bool {
        get async throws {
            if let cached = _ageRestricted {
                return cached
            }
            
            _ageRestricted = try await Extraction.isAgeRestricted(watchHTML: watchHTML)
            return _ageRestricted!
        }
    }
    
    var jsURL: URL {
        get async throws {
            if let cached = _jsURL {
                return cached
            }
            
            if try await ageRestricted {
                _jsURL = try await URL(string: Extraction.jsURL(html: embedHTML))!
            } else {
                _jsURL = try await URL(string: Extraction.jsURL(html: watchHTML))!
            }
            return _jsURL!
        }
    }
    
    var js: String {
        get async throws {
            if let cached = _js {
                return cached
            }
            
            let jsURL = try await jsURL
            
            if YouTube.__jsURL != jsURL {
                let (data, _) = try await URLSession.shared.data(from: jsURL)
                _js = String(data: data, encoding: .utf8) ?? ""
                YouTube.__js = _js
                YouTube.__jsURL = jsURL
            } else {
                _js = YouTube.__js
            }
            return _js!
        }
    }

    var signatureTimestamp: Int? {
        get async throws {
            if let cached = _signatureTimestamp {
                return cached
            }
            
            _signatureTimestamp = try await Extraction.extractSignatureTimestamp(fromJS: js)
            return _signatureTimestamp
        }
    }
    
    var ytcfg: Extraction.YtCfg {
        get async throws {
            if let cached = _ytcfg {
                return cached
            }
            
            _ytcfg = try await Extraction.extractYtCfg(from: watchHTML)
            return _ytcfg!
        }
    }
    
    /// Interface to query both adaptive (DASH) and progressive streams.
    /// Returns a list of streams if they have been initialized.
    /// If the streams have not been initialized, finds all relevant streams and initializes them.
    public var streams: [Stream] {
        get async throws {
            try await checkAvailability()
            if let cached = _fmtStreams {
                return cached
            }
            
            let result: [Stream] = try await Task<[Stream], Never>.retry(with: methods) { (method: YouTube.ExtractionMethod) -> [Stream] in
                switch method {
#if canImport(JavaScriptCore)
                case .local:
                    // loads fallback clients if the default ones returned no streaming data
                    _ = try await self.streamingData
                    let videoInfos = try await self.videoInfos
                    
                    var streams = [Stream]()
                    var existingITags = Set<Int>()
                    
                    func process(videoInfo: InnerTube.VideoInfo) async throws {
                        guard let streamingData = videoInfo.streamingData else { return }
                        
                        var streamManifest = Extraction.applyDescrambler(streamData: streamingData)
                        
                        // Melo 定制：解签名要下载几 MB 的 player JS，慢网下这一步能拖到超时，
                        // 而 ANDROID 返回的格式自带明文 url（无 s、无 n），根本用不着它。
                        // 只有真的存在签名流 / n 参数时才去拉 JS，其余情况整段跳过。
                        let needsSignature = streamManifest.contains { format in
                            if format.s != nil { return true }
                            if let url = format.url, url.contains("&n=") || url.contains("?n=") { return true }
                            return false
                        }
                        if needsSignature {
                            do {
                                try await Extraction.applySignature(streamManifest: &streamManifest, videoInfo: videoInfo, js: js)
                            } catch {
                                // to force an update to the js file, we clear the cache and retry
                                _js = nil
                                _jsURL = nil
                                YouTube.__js = nil
                                YouTube.__jsURL = nil
                                try await Extraction.applySignature(streamManifest: &streamManifest, videoInfo: videoInfo, js: js)
                            }
                        }
                        
                        // filter out dubbed audio tracks
                        streamManifest = Extraction.filterOutDubbedAudio(streamManifest: streamManifest)
                        
                        let newStreams = streamManifest.compactMap { try? Stream(format: $0, availableAt: videoInfo.streamsAvailableAt, clientUserAgent: videoInfo.clientUserAgent) }
                        
                        // make sure only one stream per itag exists
                        for stream in newStreams {
                            if existingITags.insert(stream.itag.itag).inserted {
                                streams.append(stream)
                            }
                        }
                    }
                    
                    for videoInfo in videoInfos {
                        try await process(videoInfo: videoInfo)
                    }
                    
                    // if no progressive (audio+video) tracks were found, try to do one more call to maybe get them
                    if !streams.contains(where: { $0.includesVideoAndAudioTrack }) {
                        if let videoInfo = try? await loadAdditionalVideoInfos(forClient: .mediaConnectFrontend), videoInfo.streamingData != nil {
                            os_log("Found no progressive streams. Called mediaConnectFrontend client to get additional video infos", log: log, type: .info)
                            try await process(videoInfo: videoInfo)
                        }
                    }
                    
                    return streams
#endif
                    
                case .remote(let serverURL):
                    let remoteClient = RemoteYouTubeClient(serverURL: serverURL)
                    let remoteStreams = try await remoteClient.extractStreams(forVideoID: videoID)
                    
                    return remoteStreams.compactMap { try? Stream(remoteStream: $0) }
                }
            }
            
            _fmtStreams = result
            return result
        }
    }
    
    /// Returns a list of live streams - currently only HLS supported
    /// - Note: Currently doesn't respect `method` set. It always uses `.local`
    public var livestreams: [Livestream] {
        get async throws {
            var livestreams = [Livestream]()
            let hlsURLs = try await streamingData.compactMap { $0.hlsManifestUrl }.compactMap { URL(string: $0) }
            livestreams.append(contentsOf: hlsURLs.map { Livestream(url: $0, streamType: .hls) })
            return livestreams
        }
    }

    /// streaming data from video info
    var streamingData: [InnerTube.StreamingData] {
        get async throws {
            let streamingData = try await videoInfos.compactMap { $0.streamingData }
            if !streamingData.isEmpty {
                return streamingData
            } else {
                if let videoInfo = try? await loadAdditionalVideoInfos(forClient: .webEmbed), let streamingData = videoInfo.streamingData {
                    _videoInfos = [videoInfo]
                    return [streamingData]
                }

                try await bypassAgeGate()
                let streamingData = try await videoInfos.compactMap { $0.streamingData }
                if !streamingData.isEmpty {
                    return streamingData
                } else {
                    throw YouTubeKitError.extractError
                }
            }
        }
    }

    /// Video details from video info.
    var videoDetails: [InnerTube.VideoInfo.VideoDetails] {
        get async throws {
            try await videoInfos.compactMap { $0.videoDetails }
        }
    }
    
    var videoInfos: [InnerTube.VideoInfo] {
        get async throws {
            if let cached = _videoInfos {
                return cached
            }
            
            // try extracting video infos from watch html directly as well
            let watchVideoInfoTask = Task<InnerTube.VideoInfo?, Never> { [log] in
                do {
                    return nil //try await Extraction.getVideoInfo(fromHTML: watchHTML)  // (temporarily disabled)
                } catch let error {
                    os_log("Couldn't extract video info from main watch html: %{public}@", log: log, type: .debug, error.localizedDescription)
                    return nil
                }
            }

            // Melo 定制：ANDROID 排第一 —— 实测它是唯一稳定返回明文音频直链的客户端
            // （不受 SABR 强制、不需要 PO Token、不需要登录）。其余 Web 系客户端
            // 作为兜底保留，但它们多数只能拿到 SABR / 触发风控。
            // Melo 定制：tvSamsung / web 实测一律回 "The page needs to be reloaded"，
            // 留着只会多两条并发请求抢同一条慢链路，拖慢每次解析。只留两个能出明文流的。
            let innertubeClients: [InnerTube.ClientType] = [.android, .visionOS]

            // Melo 定制：解签名的两个前置件（player JS 几 MB、watch 页几百 KB）只在
            // 真需要时再拉。ANDROID 返回的格式自带明文 url，压根用不到它们；
            // 而慢网下这两次下载就是 5~10 秒，等于每首歌都白等。
            // 万一拿到的全是签名流，下面会置 _forceCipherSetup 再补拉一次。
            let skipCipherSetup = !_forceCipherSetup && innertubeClients.contains(.android)
            let sigTS: Int? = skipCipherSetup ? nil : try await signatureTimestamp
            let resolvedYtcfg: Extraction.YtCfg = skipCipherSetup ? Self.emptyYtCfg : try await ytcfg

            // 身份（visitor + PO Token）与 watch 页解析并行准备，省掉铸造的等待。
            let identityOverride = identity
            let provider = YouTube.identityProvider
            let videoIDForIdentity = videoID
            let identityTask = Task<YouTubeIdentity?, Never> {
                if let identityOverride = identityOverride { return identityOverride }
                return await provider?(videoIDForIdentity)
            }

            let resolvedIdentity = await identityTask.value

            let results: [Result<InnerTube.VideoInfo, Error>] = await innertubeClients.concurrentMap { [videoID, useOAuth, allowOAuthCache] client in
                let innertube = InnerTube(client: client, signatureTimestamp: sigTS, ytcfg: resolvedYtcfg, useOAuth: useOAuth, allowCache: allowOAuthCache,
                                          visitorData: resolvedIdentity?.visitorData, poToken: resolvedIdentity?.playerToken)
                
                do {
                    let innertubeResponse = try await innertube.player(videoID: videoID)
                    return .success(innertubeResponse)
                } catch let error {
                    return .failure(error)
                }
            }
            
            var videoInfos = [InnerTube.VideoInfo]()
            var errors = [Error]()
            
            for (index, result) in results.enumerated() {
                let clientName = index < innertubeClients.count ? innertubeClients[index].rawValue : "?"
                switch result {
                case .success(let innertubeResponse):
                    let status = innertubeResponse.playabilityStatus?.status ?? "-"
                    let formats = innertubeResponse.streamingData?.adaptiveFormats?.count ?? 0
                    let reason = innertubeResponse.playabilityStatus?.reason ?? "-"
                    YouTube.debugLog?("ytt: \(clientName) status=\(status) adaptive=\(formats) reason=\(reason)")
                    videoInfos.append(innertubeResponse)
                case .failure(let error):
                    YouTube.debugLog?("ytt: \(clientName) ERR \(error.localizedDescription)")
                    errors.append(error)
                }
            }
            
            // append potentially extracted video info (with least priority)
            if let watchVideoInfo = await watchVideoInfoTask.value {
                videoInfos.append(watchVideoInfo)
            }
            
            // remove video infos with incorrect videoID
            for (i, videoInfo) in videoInfos.enumerated() where videoInfo.videoDetails?.videoId != videoID {
                os_log("Skipping player response from client %{public}i. Got player response for %{public}@ instead of %{public}@", log: log, type: .info, i, videoInfo.videoDetails?.videoId ?? "nil", videoID)
            }
            videoInfos = videoInfos.filter { $0.videoDetails?.videoId == videoID }
            
            if videoInfos.isEmpty {
                throw errors.first ?? YouTubeKitError.extractError
            }

            // 上一轮为了省时间是空手（没带 sig/ytcfg）去问的：如果回来的全是签名流，
            // 就补一次带齐前置件的请求。正常情况下走不到这里。
            if skipCipherSetup {
                let hasPlainURL = videoInfos.contains { info in
                    let adaptive = info.streamingData?.adaptiveFormats ?? []
                    let progressive = info.streamingData?.formats ?? []
                    return adaptive.contains(where: { $0.url != nil })
                        || progressive.contains(where: { $0.url != nil })
                }
                if !hasPlainURL {
                    YouTube.debugLog?("ytt: 只有签名流，补拉 sig/ytcfg 重试")
                    _forceCipherSetup = true
                    defer { _forceCipherSetup = false }
                    return try await videoInfos
                }
            }

            _videoInfos = videoInfos
            return videoInfos
        }
    }
    
    private func loadAdditionalVideoInfos(forClient client: InnerTube.ClientType) async throws -> InnerTube.VideoInfo {
        let signatureTimestamp = try await signatureTimestamp
        let resolvedYtcfg: Extraction.YtCfg
        if client == .webEmbed {
            resolvedYtcfg = try await Extraction.extractYtCfg(from: embedHTML)
        } else {
            resolvedYtcfg = try await ytcfg
        }
        let innertube = InnerTube(client: client, signatureTimestamp: signatureTimestamp, ytcfg: resolvedYtcfg, useOAuth: useOAuth, allowCache: allowOAuthCache,
                                  visitorData: identity?.visitorData, poToken: identity?.playerToken)
        let videoInfo = try await innertube.player(videoID: videoID)
        
        // ignore if incorrect videoID
        if videoInfo.videoDetails?.videoId != videoID {
            os_log("Skipping player response from %{public}@ client. Got player response for %{public}@ instead of %{public}@", log: log, type: .info, client.rawValue, videoInfo.videoDetails?.videoId ?? "nil", videoID)
            throw YouTubeKitError.extractError
        }
        
        return videoInfo
    }
    
    private func bypassAgeGate() async throws {
        let signatureTimestamp = try await signatureTimestamp
        let ytcfg = try await ytcfg
        let innertube = InnerTube(client: .webCreator, signatureTimestamp: signatureTimestamp, ytcfg: ytcfg, useOAuth: useOAuth, allowCache: allowOAuthCache,
                                  visitorData: identity?.visitorData, poToken: identity?.playerToken)
        let innertubeResponse = try await innertube.player(videoID: videoID)

        if innertubeResponse.playabilityStatus?.status == "UNPLAYABLE" || innertubeResponse.playabilityStatus?.status == "LOGIN_REQUIRED" {
            throw YouTubeKitError.videoAgeRestricted
        }

        if innertubeResponse.videoDetails?.videoId != videoID {
            os_log("Skipping player response from webCreator client. Got player response for %{public}@ instead of %{public}@", log: log, type: .info, innertubeResponse.videoDetails?.videoId ?? "nil", videoID)
            throw YouTubeKitError.extractError
        }

        _videoInfos = [innertubeResponse]
    }
    
    /// Interface to query both adaptive (DASH) and progressive streams.
    /*public var streams: StreamQuery {
        get async throws {
            //try await checkAvailability()
            return StreamQuery(fmtStreams: try await fmtStreams)
        }
    }*/
    
}
