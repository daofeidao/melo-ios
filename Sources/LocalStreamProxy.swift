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

    /// 一条路由 = 一首歌的上游直链。做成 class 是为了在播到一半直链失效
    /// （节点掉线 / URL 过期）时能原地换掉 upstream，不必让 AVPlayer 重新起播。
    final class Route {
        var upstream: URL
        let userAgent: String
        let mime: String
        /// 直链失效时的重解析闭包：返回同一 itag 的新直链
        var refresh: (() async -> URL?)?

        init(upstream: URL, userAgent: String, mime: String, refresh: (() async -> URL?)?) {
            self.upstream = upstream
            self.userAgent = userAgent
            self.mime = mime
            self.refresh = refresh
        }
    }

    /// 单次回灌的最大字节数。AVPlayer 常发 `bytes=0-`（不封口），原样转给上游
    /// 就是一个十几 MB 的大响应，慢网下永远传不完、AVPlayer 先超时。
    /// 主动截成几 MB 一段，让每个请求都能按时收尾，剩下的由 AVPlayer 续请求。
    private static let maxChunk: Int64 = 4 * 1024 * 1024

    /// 路由表访问队列（只在读写字典时短暂进入，不阻塞网络回调）
    private let stateQueue = DispatchQueue(label: "melo.streamproxy.state")
    /// 监听与连接回调队列
    private let ioQueue = DispatchQueue(label: "melo.streamproxy.io")

    private var listener: NWListener?
    private var port: UInt16 = 0
    private var routes: [String: Route] = [:]

    private(set) var lastStatus = "-"

    // MARK: - 对外

    /// - Parameter refresh: 直链失效时的重解析闭包。播放时重复注册（key 相同）不会把它冲掉。
    func register(upstream: URL, userAgent: String, mime: String, key: String,
                  refresh: (() async -> URL?)? = nil) -> URL? {
        guard startIfNeeded() else { return nil }
        let path = Self.path(for: key)
        stateQueue.sync {
            if let old = routes[path] {
                old.upstream = upstream
                old.refresh = refresh ?? old.refresh
            } else {
                routes[path] = Route(upstream: upstream, userAgent: userAgent,
                                     mime: mime, refresh: refresh)
            }
        }
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

    /// 启动监听。AVPlayer 一律连 127.0.0.1，所以端口交给系统分配。
    @discardableResult
    func startIfNeeded() -> Bool {
        if stateQueue.sync(execute: { listener != nil && port != 0 }) { return true }

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
        // 只服务本机：NWListener 绑的是 .any 端口，不挡的话这台机器就成了局域网开放代理。
        let desc = String(describing: conn.endpoint)
        guard desc.contains("127.0.0.1") || desc.contains("::1") || desc.contains("localhost") else {
            Diagnostics.mark("streamproxy: 拒绝外机连接 \(desc)")
            conn.cancel()
            return
        }
        conn.start(queue: ioQueue)
        readRequest(conn, buffer: Data())
    }

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

    /// 原样转发客户端要的 Range。
    ///
    /// 试过把 `bytes=0-`（AVPlayer 常发的不封口请求）截成 4MB 一段，结果 AVPlayer
    /// 收到比它要的短得多的 206 就直接判 -1 失败，并不会自己续请求。
    /// 所以这段不能省：要限流只能「按块上游取、但连接不断」，那是另一套写法，
    /// 今晚不冒险。连接复用已经把每段的握手开销省掉了。
    private static func clamp(_ range: String) -> String {
        range.isEmpty ? "bytes=0-" : range
    }

    private func fetchUpstream(route: Route, range: String, conn: NWConnection, attempt: Int = 0) {
        if let comps = URLComponents(url: route.upstream, resolvingAgainstBaseURL: false) {
            let items = comps.queryItems ?? []
            func value(_ name: String) -> String {
                guard let v = items.first(where: { $0.name == name })?.value else { return "-" }
                return "\(v.count)ch"
            }
            Diagnostics.mark("streamproxy: req range=\(range.isEmpty ? "none" : range)"
                + " n=\(value("n")) pot=\(value("pot")) itag=\(value("itag"))")
        }
        var req = URLRequest(url: route.upstream)
        req.timeoutInterval = 30
        req.setValue(route.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(Self.clamp(range), forHTTPHeaderField: "Range")

        let state = RelayHub.TaskState(
            conn: conn,
            mime: route.mime,
            onStatus: { [weak self] status in
                self?.stateQueue.sync { self?.lastStatus = status }
            },
            onRetry: { [weak self] in
                guard let self, attempt < 2 else { return false }
                Diagnostics.mark("streamproxy: 上游 403，重试第 \(attempt + 1) 次")
                self.ioQueue.asyncAfter(deadline: .now() + 0.35) {
                    self.fetchUpstream(route: route, range: range, conn: conn, attempt: attempt + 1)
                }
                return true
            },
            // 一个字节都没收到就断了：多半是这条直链所在的节点不可达或已过期。
            // 重新解析换一条新直链，再拿同一个 Range 续上——用户侧只是多等几秒，
            // 不用手动重按播放。
            onDead: { [weak self] in
                guard let self, attempt < 2, let refresh = route.refresh else { return false }
                Diagnostics.mark("streamproxy: 直链不可达，重新解析 (attempt \(attempt + 1))")
                Task { [weak self] in
                    let fresh = await refresh()
                    guard let self else { return }
                    self.ioQueue.async {
                        if let fresh {
                            route.upstream = fresh
                            Diagnostics.mark("streamproxy: 已换新直链，续传")
                        }
                        self.fetchUpstream(route: route, range: range, conn: conn, attempt: attempt + 1)
                    }
                }
                return true
            })
        RelayHub.shared.start(req, state: state)
    }
}

/// 上游回灌中枢：**所有**分段请求共用一条 URLSession。
///
/// 之前每个请求都新建一条 URLSession，等于每次都要重做 DNS + TLS 握手；
/// 这台机器上到 googlevideo 的握手要 3~8 秒，AVPlayer 等不到就直接 -1001 超时。
/// 共用一条 session 后连接会被复用，第二个 Range 起几乎是即时的。
final class RelayHub: NSObject, URLSessionDataDelegate {

    static let shared = RelayHub()

    final class TaskState {
        let conn: NWConnection
        let mime: String
        let onStatus: (String) -> Void
        /// 返回 true 表示已安排重试，本次错误不必回给客户端
        let onRetry: () -> Bool
        /// 零字节失败（节点不可达 / 直链过期）时的补救：重新解析后重试
        let onDead: () -> Bool
        var headersSent = false
        var sentBytes = 0
        var finished = false

        init(conn: NWConnection, mime: String,
             onStatus: @escaping (String) -> Void,
             onRetry: @escaping () -> Bool,
             onDead: @escaping () -> Bool) {
            self.conn = conn
            self.mime = mime
            self.onStatus = onStatus
            self.onRetry = onRetry
            self.onDead = onDead
        }
    }

    private let lock = NSLock()
    private var states: [Int: TaskState] = [:]
    private var session: URLSession!

    private override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 900
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // delegate 逐块回调，不聚合：AVPlayer 要的是渐进数据流
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func start(_ request: URLRequest, state: TaskState) {
        let task = session.dataTask(with: request)
        lock.lock()
        states[task.taskIdentifier] = state
        lock.unlock()
        task.resume()
    }

    private func state(_ id: Int) -> TaskState? {
        lock.lock(); defer { lock.unlock() }
        return states[id]
    }

    private func drop(_ id: Int) {
        lock.lock(); states.removeValue(forKey: id); lock.unlock()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let st = state(dataTask.taskIdentifier) else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            drop(dataTask.taskIdentifier)
            st.conn.cancel()
            return
        }
        let code = http.statusCode
        st.onStatus("HTTP \(code)")
        Diagnostics.mark("streamproxy: upstream \(code) "
            + (http.value(forHTTPHeaderField: "Content-Range") ?? "-"))

        guard code == 200 || code == 206 else {
            if code == 403, st.onRetry() {
                st.finished = true
                drop(dataTask.taskIdentifier)
                completionHandler(.cancel)
                return
            }
            let body = Data("upstream \(code)".utf8)
            var text = "HTTP/1.1 \(code == 403 ? "403 Forbidden" : "502 Bad Gateway")\r\n"
            text += "Content-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var payload = Data(text.utf8)
            payload.append(body)
            st.conn.send(content: payload, completion: .contentProcessed { _ in st.conn.cancel() })
            st.finished = true
            drop(dataTask.taskIdentifier)
            completionHandler(.cancel)
            return
        }

        var head = "HTTP/1.1 \(code == 206 ? "206 Partial Content" : "200 OK")\r\n"
        head += "Content-Type: " + (http.value(forHTTPHeaderField: "Content-Type") ?? st.mime) + "\r\n"
        head += "Accept-Ranges: bytes\r\n"
        if let cr = http.value(forHTTPHeaderField: "Content-Range") {
            head += "Content-Range: \(cr)\r\n"
        }
        if let cl = http.value(forHTTPHeaderField: "Content-Length") {
            head += "Content-Length: \(cl)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        st.headersSent = true
        st.conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let st = state(dataTask.taskIdentifier), st.headersSent, !st.finished else { return }
        st.sentBytes += data.count
        st.conn.send(content: data, completion: .contentProcessed { _ in })
    }

    /// googlevideo 对部分 Range 请求会回 302 换节点。URLSession 默认跟随重定向，
    /// 但**会丢掉 Range 头** —— 于是上游从字节 0 开始回整段，AVPlayer 按自己的
    /// 期望偏移去读就对不上，表现为「缓冲一直在涨却一直 waiting」。
    /// 这里手动跟随，把 Range / UA 原样带过去。
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var req = request
        if let original = task.originalRequest {
            for name in ["Range", "User-Agent"] {
                if let value = original.value(forHTTPHeaderField: name) {
                    req.setValue(value, forHTTPHeaderField: name)
                }
            }
        }
        Diagnostics.mark("streamproxy: 跟随重定向 \(response.statusCode) -> \(req.url?.host ?? "-")")
        completionHandler(req)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        guard let st = state(id), !st.finished else {
            drop(id)
            return
        }
        st.finished = true
        drop(id)
        if let error = error, st.sentBytes == 0 {
            st.onStatus("上游失败 \(error.localizedDescription)")
            Diagnostics.mark("streamproxy: 上游中断 \(error.localizedDescription)")
            if st.onDead() { return }
            st.conn.cancel()
            return
        }
        // 这一段 Range 传完就断开：AVPlayer 需要时会再发下一次 Range
        st.conn.send(content: Data(), isComplete: true, completion: .contentProcessed { _ in
            st.conn.cancel()
        })
    }
}
