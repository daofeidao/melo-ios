import AVFoundation
import Foundation

/// 让 AVPlayer 走我们自己的网络栈拉流。
///
/// 为什么需要（2026-11-17 Mac 实测）：
/// 1. **AVFoundation 的网络栈不跟随 macOS 系统 HTTP 代理**。同一个进程里：
///    URLSession 拉 googlevideo → HTTP 206 正常；AVPlayer 拉同一地址 → NSURLErrorTimedOut。
/// 2. 直链签名绑定出口 IP（`ip=` 参数），而当前代理是**动态 IPv6 池**，每次请求落到
///    不同出口 → 403/206 随机跳（实测同一 URL 连发 6 次：403/302/206/403/302/302）。
///    对策：403 时**快速重试同一请求**，直到命中绑定 IP（约 1/3 概率，重试 10 次 >99%）。
///
/// 实现：自定义 scheme + AVAssetResourceLoaderDelegate。
final class StreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    static let scheme = "melo-stream"

    /// 403 重试参数：间隔要短，AVPlayer 对 loadingRequest 有超时（约 10s 会报 -11849）
    private static let retryMax = 6
    private static let retryDelay: Double = 0.1

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 90
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    private static var registry: [String: Entry] = [:]
    private static let registryLock = NSLock()
    private static var counter = 0

    struct Entry {
        let target: URL
        let headers: [String: String]
    }

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
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "melo.streamloader"))
        holderLock.lock()
        holders.append(loader)
        holderLock.unlock()
        Diagnostics.mark("loader: registered \(key) -> \(target.host ?? "-")")
        return AVPlayerItem(asset: asset)
    }

    private static var holders: [StreamResourceLoader] = []
    private static let holderLock = NSLock()

    private let key: String
    private var task: URLSessionDataTask?

    init(key: String) {
        self.key = key
        super.init()
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

        let offset: Int
        let length: Int
        if let dataRequest = loadingRequest.dataRequest {
            offset = Int(dataRequest.requestedOffset)
            length = Int(dataRequest.requestedLength)
            let upper = length > 0 ? offset + length - 1 : offset
            request.setValue("bytes=\(offset)-\(upper)", forHTTPHeaderField: "Range")
        } else {
            offset = 0
            length = 2
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        }

        // 403 = 出口 IP 与直链签名不符，动态池下重试可命中正确 IP
        fetch(request, loadingRequest: loadingRequest, attempt: 0, offset: offset, length: length)
        return true
    }

    private func fetch(
        _ request: URLRequest,
        loadingRequest: AVAssetResourceLoadingRequest,
        attempt: Int,
        offset: Int,
        length: Int
    ) {
        task = Self.session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if loadingRequest.isCancelled { return }

            // 403 / 302（重定向到签名不符的 IP）都重试
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (code == 403 || code == 302), attempt < Self.retryMax {
                Diagnostics.mark("loader[\(self.key)]: \(code) retry \(attempt + 1)/\(Self.retryMax) off=\(offset)")
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.retryDelay) {
                    self.fetch(request, loadingRequest: loadingRequest,
                               attempt: attempt + 1, offset: offset, length: length)
                }
                return
            }

            if let error = error {
                Diagnostics.mark("loader[\(self.key)]: net error \(error.localizedDescription) off=\(offset)")
                loadingRequest.finishLoading(with: error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                Diagnostics.mark("loader[\(self.key)]: bad response")
                loadingRequest.finishLoading(with: NSError(domain: "melo", code: -1))
                return
            }
            Diagnostics.mark("loader[\(self.key)]: HTTP \(http.statusCode) bytes=\(data?.count ?? 0) off=\(offset) try=\(attempt)")

            if let info = loadingRequest.contentInformationRequest {
                if let type = http.mimeType, let uti = Self.uti(forMime: type) {
                    info.contentType = uti
                }
                if let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let total = range.split(separator: "/").last,
                   let totalLen = Int(total) {
                    info.contentLength = Int64(totalLen)
                } else if http.expectedContentLength > 0 {
                    info.contentLength = http.expectedContentLength
                }
                info.isByteRangeAccessSupported = (http.statusCode == 206)
            }

            if http.statusCode != 206 && http.statusCode != 200 {
                loadingRequest.finishLoading(with: NSError(domain: "melo", code: http.statusCode))
                return
            }

            if let dataRequest = loadingRequest.dataRequest, let data = data, !data.isEmpty {
                dataRequest.respond(with: data)
            }
            loadingRequest.finishLoading()
        }
        task?.resume()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        task?.cancel()
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
