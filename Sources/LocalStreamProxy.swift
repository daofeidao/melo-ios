import Foundation
import Network

/// 本地流代理：把「googlevideo 直链」变成本机 127.0.0.1 上的一个普通 HTTP 地址。
///
/// 为什么要这一层：
/// - googlevideo 会校验请求头里的 UA 必须与签发直链的客户端身份一致，而
///   AVPlayer 会自己塞 `AppleCoreMedia/...` 的 UA，我们改不了。UA 一换就 403。
/// - 受保护视频强制要 GVS PO Token，只能挂在 URL 的 `&pot=`；交给 AVPlayer 时
///   既不能保证带上，也不能保证 URL 不被它重新转义。
/// - AVPlayer 的媒体网络栈不走 App 的 URLSession，Mac 上遇到只有代理才通的环境
///   会直接失败；这一层用 URLSession 向上游取数据，天然走系统代理。
///
/// 所以：AVPlayer 只跟 127.0.0.1 说话（一定通），我们把 Range 原样转给上游，
/// 带上正确的 UA / pot，再把响应头和字节流逐步回灌。支持 AVPlayer 的分段请求、
/// 任意位置 seek，起播只等第一块数据，不用整首下载。
final class LocalStreamProxy {

    static let shared = LocalStreamProxy()

    private struct Route {
        let upstream: URL
        let userAgent: String
        let mime: String
    }

    /// 路由表访问队列（只在读写字典时短暂进入，不阻塞网络回调）
    private let stateQueue = DispatchQueue(label: "melo.streamproxy.state")
    /// 监听与连接回调队列
    private let ioQueue = DispatchQueue(label: "melo.streamproxy.io")

    private var listener: NWListener?
    private var port: UInt16 = 0
    private var routes: [String: Route] = [:]

    /// 最近一次上游状态，诊断面板可见
    private(set) var lastStatus = "-"

    // MARK: - 对外

    /// 把上游直链登记进来，返回给 AVPlayer 用的本地地址。失败返回 nil（调用方回落直链）。
    func register(upstream: URL, userAgent: String, mime: String, key: String) -> URL? {
        guard startIfNeeded() else { return nil }
        let path = Self.path(for: key)
        stateQueue.sync { routes[path] = Route(upstream: upstream, userAgent: userAgent, mime: mime) }
        return URL(string: "http://127.0.0.1:\(port)\(path)")
    }

    func unregister(key: String) {
        let path = Self.path(for: key)
        stateQueue.async { self.routes.removeValue(forKey: path) }
    }

    var listeningPort: UInt16 { stateQueue.sync { port } }

    private static func path(for key: String) -> String {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "s"
        return "/s/" + safe
    }

    /// 启动监听。AVPlayer 一律连 127.0.0.1，所以绑定 loopback、端口交给系统分配。
    @discardableResult
    func startIfNeeded() -> Bool {
        if stateQueue.sync(execute: { listener != nil && port != 0 }) { return true }

        // 用引用盒装端口，避免在并发闭包里改捕获的 var（Swift 6 会直接报错）
        final class PortBox { var value: UInt16 = 0 }
        let box = PortBox()
        let sem = DispatchSemaphore(value: 0)

        ioQueue.async { [weak self] in
            guard let self else { sem.signal(); return }
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let l = try NWListener(using: params, on: .any)
                // 必须自己持有：NWListener 启动后不会自我保活，释放掉监听就没了
                self.stateQueue.sync { self.listener = l }
                l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                l.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        box.value = l.port?.rawValue ?? 0
                        sem.signal()
                    case .failed(let err):
                        Diagnostics.mark("streamproxy: failed \(err.localizedDescription)")
                        sem.signal()
                    case .cancelled:
                        sem.signal()
                    default:
                        break
                    }
                }
                l.start(queue: self.ioQueue)
            } catch {
                Diagnostics.mark("streamproxy: \(error.localizedDescription)")
                sem.signal()
            }
        }

        _ = sem.wait(timeout: .now() + 3)
        guard box.value != 0 else {
            Diagnostics.mark("streamproxy: 启动失败")
            return false
        }
        let started = box.value
        stateQueue.sync { self.port = started }
        Diagnostics.mark("streamproxy: listening 127.0.0.1:\(started)")
        return true
    }

    // MARK: - 连接处理

    private func accept(_ conn: NWConnection) {
        // 只服务本机：NWListener 绑的是 .any 端口，端口本身在所有网卡上都能连，
        // 不挡的话这台机器就成了局域网里的开放代理。
        let desc = String(describing: conn.endpoint)
        guard desc.contains("127.0.0.1") || desc.contains("::1") || desc.contains("localhost") else {
            Diagnostics.mark("streamproxy: 拒绝外机连接 \(desc)")
            conn.cancel()
            return
        }
        conn.start(queue: ioQueue)
        readRequest(conn, buffer: Data())
    }

    /// 读到一个完整的请求头（\r\n\r\n）就分发。AVPlayer 的请求头很小，不会超过 16KB。
    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data = data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
                self.handle(head: head, conn: conn)
                return
            }
            if error != nil || isComplete || buf.count > 16384 {
                conn.cancel()
                return
            }
            self.readRequest(conn, buffer: buf)
        }
    }

    private func handle(head: String, conn: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { conn.cancel(); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = String(parts[0]).uppercased()
        let rawPath = String(parts[1])
        let path = rawPath.components(separatedBy: "?").first ?? rawPath

        var rangeHeader = ""
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                rangeHeader = line.components(separatedBy: ":").dropFirst()
                    .joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }

        guard let route = stateQueue.sync(execute: { routes[path] }) else {
            writeHead(conn, status: "404 Not Found", headers: "", thenClose: true)
            return
        }

        if method == "HEAD" {
            // AVPlayer 探测用：不需要长度，声明可分段即可
            writeHead(conn, status: "200 OK",
                      headers: "Content-Type: \(route.mime)\r\nAccept-Ranges: bytes\r\n",
                      thenClose: true)
            return
        }

        fetchUpstream(route: route, range: rangeHeader, conn: conn)
    }

    private func writeHead(_ conn: NWConnection, status: String, headers: String, thenClose: Bool) {
        let text = "HTTP/1.1 \(status)\r\n" + headers + "Connection: close\r\n\r\n"
        conn.send(content: Data(text.utf8), completion: .contentProcessed { _ in
            if thenClose { conn.cancel() }
        })
    }

    /// 向上游发同样的 Range，拿到响应头先回给 AVPlayer，再边收边转发字节。
    /// - Parameter attempt: 已重试次数。googlevideo 偶发对刚签出的直链回一次 403
    ///   （紧接着同一个请求就 206），不重试的话 AVPlayer 会当成资源不可用直接报错。
    private func fetchUpstream(route: Route, range: String, conn: NWConnection, attempt: Int = 0) {
        // 把关键查询参数记下来：受保护视频的 403 往往跟 n 参数有没有解、pot 在不在有关，
        // 不记的话线上只看得到一个 403，完全没法定位。
        if let comps = URLComponents(url: route.upstream, resolvingAgainstBaseURL: false) {
            let items = comps.queryItems ?? []
            func value(_ name: String) -> String {
                guard let v = items.first(where: { $0.name == name })?.value else { return "-" }
                return "\(v.count)ch"
            }
            Diagnostics.mark("streamproxy: req range=\(range.isEmpty ? "none" : range)"
                + " n=\(value("n")) pot=\(value("pot")) itag=\(value("itag"))"
                + " ua=\(route.userAgent.prefix(20))")
        }
        var req = URLRequest(url: route.upstream)
        req.timeoutInterval = 30
        req.setValue(route.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(range.isEmpty ? "bytes=0-" : range, forHTTPHeaderField: "Range")

        let delegate = RelayDelegate(
            conn: conn, fallbackMime: route.mime,
            onStatus: { [weak self] status in
                self?.stateQueue.sync { self?.lastStatus = status }
            },
            onTransient: { [weak self] in
                guard let self, attempt < 2 else { return false }
                Diagnostics.mark("streamproxy: 上游 403，重试第 \(attempt + 1) 次")
                self.ioQueue.asyncAfter(deadline: .now() + 0.35) {
                    self.fetchUpstream(route: route, range: range, conn: conn, attempt: attempt + 1)
                }
                return true
            })
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 900
        // 用 delegate 逐块回调，不要 dataTask 聚合：AVPlayer 要的是渐进数据流
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        delegate.session = session
        session.dataTask(with: req).resume()
    }
}

/// 把上游的响应头和字节流原样灌回本地连接。
private final class RelayDelegate: NSObject, URLSessionDataDelegate {

    private let conn: NWConnection
    private let fallbackMime: String
    private let onStatus: (String) -> Void
    /// 返回 true 表示已安排重试，本次错误不必回给客户端
    private let onTransient: () -> Bool
    private var headersSent = false
    private var sentBytes = 0
    private var finished = false
    var session: URLSession?

    init(conn: NWConnection, fallbackMime: String,
         onStatus: @escaping (String) -> Void,
         onTransient: @escaping () -> Bool) {
        self.conn = conn
        self.fallbackMime = fallbackMime
        self.onStatus = onStatus
        self.onTransient = onTransient
    }

    private func abort(_ session: URLSession) {
        session.invalidateAndCancel()
        conn.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            conn.cancel()
            return
        }
        let code = http.statusCode
        onStatus("HTTP \(code)")
        Diagnostics.mark("streamproxy: upstream \(code) \(http.value(forHTTPHeaderField: "Content-Range") ?? "-")")

        guard code == 200 || code == 206 else {
            if code == 403, onTransient() {
                finished = true
                session.finishTasksAndInvalidate()
                completionHandler(.cancel)
                return
            }
            let body = Data("upstream \(code)".utf8)
            var text = "HTTP/1.1 \(code == 403 ? "403 Forbidden" : "502 Bad Gateway")\r\n"
            text += "Content-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var payload = Data(text.utf8)
            payload.append(body)
            conn.send(content: payload, completion: .contentProcessed { _ in self.conn.cancel() })
            completionHandler(.cancel)
            return
        }

        var head = "HTTP/1.1 \(code == 206 ? "206 Partial Content" : "200 OK")\r\n"
        head += "Content-Type: " + (http.value(forHTTPHeaderField: "Content-Type") ?? fallbackMime) + "\r\n"
        head += "Accept-Ranges: bytes\r\n"
        if let cr = http.value(forHTTPHeaderField: "Content-Range") {
            head += "Content-Range: \(cr)\r\n"
        }
        if let cl = http.value(forHTTPHeaderField: "Content-Length") {
            head += "Content-Length: \(cl)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        headersSent = true
        conn.send(content: Data(head.utf8), completion: .contentProcessed { error in
            if error != nil { self.abort(session) }
        })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard headersSent else { return }
        sentBytes += data.count
        conn.send(content: data, completion: .contentProcessed { error in
            if error != nil { self.abort(session) }
        })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        if let error = error, sentBytes == 0 {
            onStatus("上游失败 \(error.localizedDescription)")
            conn.cancel()
            session.finishTasksAndInvalidate()
            return
        }
        // 这一段 Range 传完就断开：AVPlayer 需要时会再发下一次 Range
        conn.send(content: Data(), isComplete: true, completion: .contentProcessed { _ in
            self.conn.cancel()
        })
        session.finishTasksAndInvalidate()
    }
}
