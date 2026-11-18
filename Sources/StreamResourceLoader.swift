import AVFoundation
import Foundation

/// 让 AVPlayer 通过「本地按序分片缓冲」播放 YouTube 音频。
///
/// 为什么这样设计（2026-11-18 实测铁证）：
///   代理/googlevideo 对拉流请求有状态校验——
///     bytes=0-65535 / 0-262143  → 大部分 206
///     bytes=0-524287            → 全 403
///     bytes=100000-*            → 全 403（任何非零起点）
///   网页 MSE 播放器严格「从 0 开始、按序、小块」拉取，所以能播；
///   AVPlayer 会随机 seek + 一次请求几 MB，每个请求都被 403。
///
/// 实现：自定义 scheme → AVPlayer 的请求全部由本地缓冲文件满足；
/// 后台下载器只向服务器发「从 0 递增、每片 ≤256KB」的请求，403 就原样重试
/// （不跳片、不乱序），直到整首歌下完。AVPlayer 读到哪，下载器保障下到哪。
final class StreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    static let scheme = "melo-stream"

    /// 分片大小：实测 256KB 以内、从 0 起点才有高成功率
    fileprivate static let chunkSize = 256 * 1024
    /// 单片重试上限（403 是随机的，重试同片直到命中）
    fileprivate static let maxRetries = 24
    /// 等待下载器追上读取位置的最长时间
    fileprivate static let readWait: TimeInterval = 60

    private static var registry: [String: StreamSession] = [:]
    private static let regLock = NSLock()
    private static var counter = 0
    /// delegate 保活（AVURLAsset 不保证强持有）
    private static var holders: [StreamResourceLoader] = []
    private static let holderLock = NSLock()

    private let key: String
    private let stream: StreamSession

    private init(key: String, stream: StreamSession) {
        self.key = key
        self.stream = stream
        super.init()
    }

    static func makeItem(target: URL, headers: [String: String]) -> AVPlayerItem {
        regLock.lock()
        counter += 1
        let key = "s\(counter)"
        let session = StreamSession(target: target, headers: headers)
        registry[key] = session
        regLock.unlock()

        var c = URLComponents()
        c.scheme = scheme
        c.host = key
        c.path = "/stream"

        let asset = AVURLAsset(url: c.url!)
        let loader = StreamResourceLoader(key: key, stream: session)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "melo.stream.\(key)"))
        holderLock.lock()
        holders.append(loader)
        holderLock.unlock()
        Diagnostics.mark("loader: \(key) buffered stream -> \(target.host ?? "-")")
        return AVPlayerItem(asset: asset)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest
    ) -> Bool {
        // 1) 内容信息：等第一片下来，拿到 total / mime
        if let info = req.contentInformationRequest {
            do {
                let meta = try stream.ensureMetadata()
                if let uti = Self.uti(forMime: meta.mime) { info.contentType = uti }
                info.contentLength = meta.total
                info.isByteRangeAccessSupported = true
                Diagnostics.mark("loader[\(key)]: meta total=\(meta.total) mime=\(meta.mime)")
                req.finishLoading()
            } catch {
                req.finishLoading(with: error)
            }
            return true
        }

        // 2) 数据请求：从本地缓冲读，不向服务器发随机 offset
        guard let dataReq = req.dataRequest else {
            req.finishLoading()
            return true
        }
        do {
            let offset = Int64(dataReq.requestedOffset)
            let data = try stream.read(offset: offset, maxLength: Int(dataReq.requestedLength))
            if !data.isEmpty { dataReq.respond(with: data) }
            req.finishLoading()
        } catch {
            req.finishLoading(with: error)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        stream.cancel()
    }

    // MARK: - MIME → UTI

    private static func uti(forMime mime: String) -> String? {
        switch mime.lowercased() {
        case "audio/mp4", "video/mp4", "application/mp4": return "public.mpeg-4"
        case "audio/webm", "video/webm": return "org.webmproject.webm"
        case "audio/mpeg", "audio/mp3": return "public.mp3"
        case "audio/aac": return "public.aac-audio"
        case "audio/flac", "audio/x-flac": return "public.flac-audio"
        case "audio/ogg", "application/ogg": return "org.xiph.ogg"
        case "audio/wav", "audio/x-wav": return "com.microsoft.waveform-audio"
        default: return nil
        }
    }
}

// MARK: - 顺序分片下载器 + 本地缓冲

private final class StreamSession {

    struct Meta {
        let total: Int64
        let mime: String
    }

    private let target: URL
    private let headers: [String: String]
    private let fileURL: URL
    private let net: URLSession

    private let cond = NSCondition()
    private var total: Int64 = 0
    private var mime: String = "audio/mp4"
    private var downloaded: Int64 = 0
    private var metaReady = false
    private var metaFailed: Error?
    private var cancelled = false
    private var downloadStarted = false

    init(target: URL, headers: [String: String]) {
        self.target = target
        self.headers = headers
        self.fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-stream-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldSetCookies = false
        self.net = URLSession(configuration: cfg)
    }

    deinit {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: 对外

    /// 幂等。确保拿到元数据并启动后台顺序下载，然后返回。
    func ensureMetadata() throws -> Meta {
        cond.lock()
        if metaReady {
            let m = Meta(total: total, mime: mime); cond.unlock(); return m
        }
        if let e = metaFailed { cond.unlock(); throw e }
        cond.unlock()

        // 同步拉第一片（0 起点、≤256KB），拿到 total
        let first: (Data, HTTPURLResponse)
        do {
            first = try fetchChunk(offset: 0, length: StreamResourceLoader.chunkSize)
        } catch {
            cond.lock(); metaFailed = error; cond.broadcast(); cond.unlock()
            throw error
        }

        let t = Self.parseTotal(from: first.1) ?? Int64(first.0.count)
        write(first.0, at: 0)

        cond.lock()
        total = t
        mime = first.1.mimeType ?? "audio/mp4"
        downloaded = Int64(first.0.count)
        metaReady = true
        cond.broadcast()
        let shouldStart = !downloadStarted
        downloadStarted = true
        cond.unlock()

        if shouldStart { startDownloadLoop() }
        return Meta(total: total, mime: mime)
    }

    /// 从本地缓冲读。若下载器还没下到 offset，等待（下载器严格按序，终会覆盖）。
    func read(offset: Int64, maxLength: Int) throws -> Data {
        _ = try ensureMetadata()

        let deadline = Date().addingTimeInterval(StreamResourceLoader.readWait)
        cond.lock()
        while downloaded <= offset && metaFailed == nil && !cancelled && Date() < deadline {
            cond.wait(until: Date().addingTimeInterval(0.2))
        }
        let avail = downloaded - offset
        let err = metaFailed
        cond.unlock()

        if avail <= 0 {
            if let e = err { throw e }
            return Data()
        }
        let want = min(Int64(maxLength), avail)
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else {
            throw NSError(domain: "melo.loader", code: -2)
        }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(offset))
        return fh.readData(ofLength: Int(want))
    }

    func cancel() {
        cond.lock(); cancelled = true; cond.broadcast(); cond.unlock()
    }

    // MARK: 后台顺序下载

    private func startDownloadLoop() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.downloadLoop()
        }
    }

    private func downloadLoop() {
        while true {
            cond.lock()
            let off = downloaded
            let tot = total
            let stop = cancelled
            cond.unlock()
            if stop || off >= tot { break }

            let len = Int(min(Int64(StreamResourceLoader.chunkSize), tot - off))
            do {
                let chunk = try fetchChunk(offset: off, length: len)
                write(chunk.0, at: off)
                cond.lock()
                downloaded += Int64(chunk.0.count)
                cond.broadcast()
                cond.unlock()
            } catch {
                cond.lock(); metaFailed = error; cond.broadcast(); cond.unlock()
                Diagnostics.mark("loader: download failed \(error.localizedDescription)")
                break
            }
        }
        Diagnostics.mark("loader: download loop end (total=\(total) got=\(downloaded))")
    }

    // MARK: 网络：严格从指定 offset 拉单片，403 原样重试（不跳片、不乱序）

    private func fetchChunk(offset: Int64, length: Int) throws -> (Data, HTTPURLResponse) {
        var last: Error?
        for attempt in 0..<StreamResourceLoader.maxRetries {
            if cancelled { throw NSError(domain: "melo.loader", code: -3) }
            var req = URLRequest(url: target)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            req.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)",
                         forHTTPHeaderField: "Range")

            let (data, resp) = net.syncData(req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 206 || (code == 200 && offset == 0), let http = resp as? HTTPURLResponse,
               !data.isEmpty {
                if attempt > 0 {
                    Diagnostics.mark("loader: chunk off=\(offset) ok after \(attempt) retries")
                }
                return (data, http)
            }
            last = NSError(domain: "melo.loader", code: code == 0 ? -1 : code)
            Thread.sleep(forTimeInterval: 0.03)
        }
        throw last ?? NSError(domain: "melo.loader", code: -1)
    }

    private func write(_ data: Data, at offset: Int64) {
        guard let fh = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(offset))
        fh.write(data)
    }

    private static func parseTotal(from http: HTTPURLResponse) -> Int64? {
        guard let cr = http.value(forHTTPHeaderField: "Content-Range"),
              let last = cr.split(separator: "/").last,
              let n = Int64(last) else { return nil }
        return n > 0 ? n : nil
    }
}

// MARK: - 同步 URLSession（下载器在后台线程单片顺序执行，用信号量等待即可）

private extension URLSession {
    func syncData(_ req: URLRequest, timeout: TimeInterval = 8) -> (Data, URLResponse) {
        var result: (Data?, URLResponse?, Error?)?
        let sem = DispatchSemaphore(value: 0)
        let task = dataTask(with: req) { d, r, e in
            result = (d, r, e)
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return (Data(), URLResponse())
        }
        return (result?.0 ?? Data(), result?.1 ?? URLResponse())
    }
}
