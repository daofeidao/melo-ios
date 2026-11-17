import AVFoundation
import Foundation

/// 让 AVPlayer 走我们自己的网络栈拉流。
///
/// 为什么需要（2026-11-17 Mac 实测）：
/// 1. **AVFoundation 的网络栈不跟随 macOS 系统 HTTP 代理**。同一个进程里：
///    URLSession 拉 googlevideo → HTTP 206 正常；AVPlayer 拉同一地址 → NSURLErrorTimedOut。
///    所以 YouTube 直链在 Mac 上用 AVPlayer 直接播会超时。
/// 2. YouTube 直链的签名里绑定了出口 IP（URL 的 `ip=` 参数），拉流必须和解析时
///    用同一个出口。URLSession 会复用连接，能让解析和拉流落在同一条代理连接上。
/// 3. 直链签名还与 User-Agent 绑定，带上正确 UA 更稳。
///
/// 实现：自定义 scheme + AVAssetResourceLoaderDelegate。
/// AVPlayer 对 `melo-stream://` 发请求 → 我们转成真实地址，用共享的 URLSession
/// （走系统代理）拉回来，再把数据 respond 给 AVPlayer。
final class StreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    /// 自定义 scheme。AVPlayer 认这个 scheme，交给 resourceLoader 处理。
    static let scheme = "melo-stream"

    /// 共享 session：走系统代理，且复用连接（让解析与拉流同一出口 IP）。
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        // 同一 host 允许多连接，但代理连接本身会复用
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    /// scheme URL 的 host → 真实地址 + 请求头
    private static var registry: [String: Entry] = [:]
    private static let registryLock = NSLock()
    private static var counter = 0

    struct Entry {
        let target: URL
        let headers: [String: String]
    }

    /// 造一个「走我们网络栈」的 AVPlayerItem。
    /// - Parameters:
    ///   - target: 真实直链
    ///   - headers: 附加请求头（User-Agent 等）
    static func makeItem(target: URL, headers: [String: String]) -> AVPlayerItem {
        registryLock.lock()
        counter += 1
        let key = "s\(counter)"
        registry[key] = Entry(target: target, headers: headers)
        registryLock.unlock()

        var components = URLComponents()
        components.scheme = scheme
        components.host = key
        components.path = "/stream"

        let asset = AVURLAsset(url: components.url!)
        let loader = StreamResourceLoader(key: key)
        // delegate 必须保活，否则 asset 会立刻失去 loader
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "melo.streamloader"))
        holderLock.lock()
        holders.append(loader)
        holderLock.unlock()
        Diagnostics.mark("loader: registered \(key) -> \(target.host ?? "-")")
        return AVPlayerItem(asset: asset)
    }

    /// 保活所有 loader（asset 不持有 delegate 的强引用）
    private static var holders: [StreamResourceLoader] = []
    private static let holderLock = NSLock()

    private let key: String

    init(key: String) {
        self.key = key
        super.init()
        // 登记保活
        StreamResourceLoader.holderLock.lock()
        StreamResourceLoader.holders.append(self)
        StreamResourceLoader.holderLock.unlock()
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let entry = Self.entry(for: key) else { return false }

        var request = URLRequest(url: entry.target)
        for (name, value) in entry.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        // AVPlayer 会用 range 请求分片拉；这里把它的偏移带过去
        let offset: Int
        let length: Int
        if let dataRequest = loadingRequest.dataRequest {
            offset = Int(dataRequest.requestedOffset)
            length = Int(dataRequest.requestedLength)
            let upper = length > 0 ? offset + length - 1 : offset
            request.setValue("bytes=\(offset)-\(upper)", forHTTPHeaderField: "Range")
        } else {
            // 只要 contentInformation：拿 2 字节即可（带上完整响应头）
            offset = 0
            length = 2
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        }

        let task = Self.session.dataTask(with: request) { data, response, error in
            if let error = error {
                Diagnostics.mark("loader[\(self.key)]: net error \(error.localizedDescription) (offset=\(offset))")
                loadingRequest.finishLoading(with: error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                Diagnostics.mark("loader[\(self.key)]: bad response")
                loadingRequest.finishLoading(with: NSError(domain: "melo", code: -1))
                return
            }
            Diagnostics.mark("loader[\(self.key)]: HTTP \(http.statusCode) bytes=\(data?.count ?? 0) offset=\(offset) len=\(length)")

            // 内容信息（类型 / 长度 / 是否支持 range）
            if let info = loadingRequest.contentInformationRequest {
                if let type = http.mimeType, let uti = Self.uti(forMime: type) {
                    info.contentType = uti
                }
                if let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let total = range.split(separator: "/").last,
                   let length = Int(total) {
                    info.contentLength = Int64(length)
                } else if http.expectedContentLength > 0 {
                    info.contentLength = http.expectedContentLength
                }
                info.isByteRangeAccessSupported = (http.statusCode == 206)
            }

            // 数据
            if let dataRequest = loadingRequest.dataRequest, let data = data, !data.isEmpty {
                dataRequest.respond(with: data)
            }
            loadingRequest.finishLoading()
        }
        task.resume()
        return true
    }

    /// AVPlayer 想取消时（切歌 / 暂停）把请求停掉
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // URLSession 的 task 由 delegate 持有不到，这里靠 finishLoading 收尾即可。
    }

    private static func entry(for key: String) -> Entry? {
        registryLock.lock()
        defer { registryLock.unlock() }
        return registry[key]
    }

    /// MIME → UTI。AVPlayer 认 UTI，不认 MIME。
    static func uti(forMime mime: String) -> String? {
        switch mime.lowercased() {
        case "audio/mp4", "video/mp4", "application/mp4":
            return "public.mpeg-4"
        case "audio/webm", "video/webm":
            return "org.webmproject.webm"
        case "audio/mpeg", "audio/mp3":
            return "public.mp3"
        case "audio/aac":
            return "public.aac-audio"
        case "audio/flac", "audio/x-flac":
            return "public.flac-audio"
        case "audio/ogg", "application/ogg":
            return "org.xiph.ogg"
        case "audio/wav", "audio/x-wav":
            return "com.microsoft.waveform-audio"
        default:
            return nil
        }
    }
}
