import CommonCrypto
import Foundation

// MARK: - AES-256-CBC string decryption

func _d(_ b64: String) -> String {
    guard let data = Data(base64Encoded: b64), data.count > kCCBlockSizeAES128 else { return "" }
    let iv = data.prefix(kCCBlockSizeAES128)
    let ciphertext = data.suffix(from: kCCBlockSizeAES128)
    let key = _key()
    let outLen = ciphertext.count + kCCBlockSizeAES128
    var out = Data(count: outLen)
    var written = 0
    let status = key.withUnsafeBytes { k in
        iv.withUnsafeBytes { i in
            ciphertext.withUnsafeBytes { c in
                out.withUnsafeMutableBytes { o in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, kCCKeySizeAES256, i.baseAddress,
                            c.baseAddress, ciphertext.count, o.baseAddress, outLen, &written)
                }
            }
        }
    }
    guard status == kCCSuccess else { return "" }
    return String(data: out.prefix(written), encoding: .utf8) ?? ""
}

// Key split into 4 parts — XOR all to recover AES-256 key
private let _kp0: [UInt8] = [0x7D, 0x90, 0x2B, 0x95, 0x1A, 0x4D, 0xED, 0x1F, 0x01, 0xF6, 0x0F, 0x19, 0x9F, 0xDB, 0x4F, 0x45, 0x16, 0x9D, 0x02, 0x24, 0xCA, 0x10, 0x49, 0xD6, 0xF8, 0x09, 0x0C, 0x32, 0x15, 0x9E, 0xEB, 0x66]
private let _kp1: [UInt8] = [0xB2, 0xA0, 0xD4, 0x3A, 0x64, 0xF6, 0xBA, 0x61, 0x50, 0x4E, 0x0A, 0x00, 0x21, 0x75, 0x05, 0x36, 0xBD, 0x69, 0xF3, 0xB4, 0x07, 0x24, 0x56, 0xF7, 0x2F, 0xD1, 0x93, 0x11, 0x08, 0x3D, 0x41, 0xB4]
private let _kp2: [UInt8] = [0xB6, 0x27, 0x28, 0x12, 0x84, 0x94, 0xD5, 0x62, 0x6A, 0xDF, 0x20, 0xBF, 0xD3, 0x28, 0x42, 0x33, 0xC0, 0xAE, 0xF7, 0x15, 0x53, 0xC2, 0x6B, 0xF7, 0x64, 0xD8, 0x4E, 0x57, 0x6F, 0xB4, 0x12, 0x8A]
private let _kp3: [UInt8] = [0xE2, 0x1C, 0xBC, 0x9D, 0x63, 0x0B, 0x75, 0x66, 0x98, 0xC4, 0xCB, 0x08, 0x5A, 0x00, 0x9E, 0x28, 0xB7, 0x32, 0xE8, 0x02, 0x3F, 0x77, 0xEB, 0xC5, 0x26, 0x94, 0x29, 0x70, 0x26, 0xBB, 0x12, 0x52]
func _key() -> Data { Data((0..<32).map { _kp0[$0] ^ _kp1[$0] ^ _kp2[$0] ^ _kp3[$0] }) }

/// Simple sliding-window rate limiter — timestamps of requests within the window.
fileprivate struct SlidingWindowThrottle {
    let limit: Int
    let windowSeconds: Double
    private var timestamps: [CFAbsoluteTime] = []
    init(limit: Int, windowSeconds: Double) {
        self.limit = limit
        self.windowSeconds = windowSeconds
    }
    mutating func allow() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        timestamps.removeAll { now - $0 > windowSeconds }
        if timestamps.count >= limit { return false }
        timestamps.append(now)
        return true
    }
}

/// One relay request's connection metrics, distilled from URLSessionTaskMetrics
/// into Sendable primitives so they can cross back to the @MainActor caller.
/// `reused=false` means this request paid a fresh DNS+TCP+TLS handshake — the
/// prime suspect for overhead spikes after idle or during typing bursts.
struct RelayConnMetrics: Sendable {
    let reused: Bool
    let proto: String
    let dnsMs: Double
    let connectMs: Double   // TCP connect + TLS (whole connectStart→connectEnd span)
    let tlsMs: Double        // TLS handshake (subset of connect)
    let ttfbMs: Double       // requestEnd → responseStart (to-edge + worker + back)

    init(from metrics: URLSessionTaskMetrics) {
        let m = metrics.transactionMetrics.last
        func ms(_ a: Date?, _ b: Date?) -> Double {
            guard let a, let b else { return 0 }
            return b.timeIntervalSince(a) * 1000
        }
        reused = m?.isReusedConnection ?? false
        proto = m?.networkProtocolName ?? "?"
        dnsMs = ms(m?.domainLookupStartDate, m?.domainLookupEndDate)
        connectMs = ms(m?.connectStartDate, m?.connectEndDate)
        tlsMs = ms(m?.secureConnectionStartDate, m?.secureConnectionEndDate)
        ttfbMs = ms(m?.requestEndDate, m?.responseStartDate)
    }
}

/// Per-request URLSession delegate that captures task metrics off the main
/// actor. `didFinishCollecting` fires once, just before the async
/// `data(for:delegate:)` call returns, so the caller reads `conn` right after.
final class RelayMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _conn: RelayConnMetrics?
    var conn: RelayConnMetrics? {
        lock.lock(); defer { lock.unlock() }
        return _conn
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let c = RelayConnMetrics(from: metrics)
        lock.lock(); _conn = c; lock.unlock()
    }
}

@MainActor
final class CloudProvider {
    private var activeTask: Task<Void, Never>?
    /// Client-side request throttle — caps cloud completion requests so a runaway
    /// can't spam the backend. A debounced human never approaches this; it's a
    /// backstop. The server still enforces its own (cheap, native) rate limit for
    /// the extracted-token abuse case the client can't cover.
    private var requestThrottle = SlidingWindowThrottle(limit: 300, windowSeconds: 60)

    // Relay (Phase 2). Low-stakes: the URL is public and the app token is meant
    // to be in the client binary (it only marks "this is the FlowIn app"; the
    // server's rate-limit + spend caps are the real defense).
    private static let relayBaseURL = "https://flowin-relay.lucas-a05.workers.dev"
    private static let relayAppToken = "4c3907de6b05a39f23da9972e0b0319f"

    /// Serialize a CompletionRequest to the relay's /v1/complete `request` shape.
    static func relayRequestJSON(_ r: CompletionRequest) -> [String: Any] {
        func opt(_ s: String?) -> Any { if let s = s { return s } else { return NSNull() } }
        func optArr(_ a: [String]?) -> Any { if let a = a { return a } else { return NSNull() } }
        var sk: [String: Any]
        switch r.suffixKind {
        case .plain:
            sk = ["kind": "plain"]
        case .mailReply(let q):
            sk = ["kind": "mailReply", "quote": ["older": opt(q.older), "newest": q.newest, "lead": q.lead]]
        }
        return [
            "prefix": r.prefix, "suffix": r.suffix, "appName": r.appName, "windowTitle": r.windowTitle,
            "provider": r.provider, "maxTokens": r.maxTokens, "requestId": r.requestId,
            "screenContext": opt(r.screenContext), "userContext": opt(r.userContext), "priorContext": opt(r.priorContext),
            "clipboardItems": optArr(r.clipboardItems), "recentMessages": optArr(r.recentMessages),
            "wantsAlternates": r.wantsAlternates, "suffixKind": sk,
        ]
    }

    // Stable per-install identifier used as OpenAI's `prompt_cache_key`.
    // Persisted in UserDefaults so it survives app restarts.
    private static let promptCacheKey: String = {
        let defaults = UserDefaults.standard
        let key = "openai_prompt_cache_key"
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: key)
        return fresh
    }()

    /// Stable anonymous per-install id (same value the relay uses as the prompt
    /// cache key). Exposed for the usage-stats uploader.
    static var installId: String { promptCacheKey }

    static func parseDur(_ header: String, _ metric: String) -> Double? {
        guard let r = header.range(of: metric + ";dur=") else { return nil }
        let num = header[r.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(num)
    }

    private func performRemoteRequest(_ request: CompletionRequest) async throws -> [String] {
        guard let url = URL(string: Self.relayBaseURL + "/v1/complete") else {
            throw CloudProviderError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.relayAppToken, forHTTPHeaderField: "X-App-Token")
        let payload: [String: Any] = ["request": Self.relayRequestJSON(request), "installId": Self.promptCacheKey]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let collector = RelayMetricsCollector()
        let t0 = CFAbsoluteTimeGetCurrent()
        let (data, response) = try await URLSession.shared.data(for: req, delegate: collector)
        let httpMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        guard let http = response as? HTTPURLResponse else { throw CloudProviderError.invalidResponse }
        guard http.statusCode == 200 else {
            throw CloudProviderError.httpError(http.statusCode, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        // Decompose the relay round trip (no extra latency — the Server-Timing
        // header already arrived). overhead = http − vendor splits into:
        //   worker_self = worker − vendor  (relay KV read + rate-limit)
        //   transport   = http − worker    (network both ways + client scheduling)
        // Connection metrics then attribute `transport` to fresh TLS vs reuse.
        let timing = http.value(forHTTPHeaderField: "Server-Timing")
        if let v = timing.flatMap({ Self.parseDur($0, "vendor") }) {
            var line = "[Latency] relay http=\(Int(httpMs))ms vendor=\(Int(v))ms overhead=\(Int(httpMs - v))ms"
            if let w = timing.flatMap({ Self.parseDur($0, "worker") }) {
                line += " | worker_self=\(Int(w - v))ms transport=\(Int(httpMs - w))ms"
            }
            if let c = collector.conn {
                line += " | reused=\(c.reused) proto=\(c.proto) dns=\(Int(c.dnsMs))ms tcp=\(Int(c.connectMs))ms tls=\(Int(c.tlsMs))ms ttfb=\(Int(c.ttfbMs))ms"
            }
            Log.info(line)
        } else {
            Log.info("[Latency] relay http=\(Int(httpMs))ms (no Server-Timing)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = obj["candidates"] as? [String] else {
            throw CloudProviderError.invalidResponse
        }
        return candidates
    }

    func complete(
        request: CompletionRequest,
        callback: @escaping (Result<[String], Error>) -> Void
    ) {
        guard requestThrottle.allow() else {
            Log.info("[CloudProvider] client throttle hit (>300 req/60s) — dropping request")
            callback(.success([]))  // empty = "no suggestion"; Engine handles benignly (no outage)
            return
        }
        activeTask?.cancel()

        activeTask = Task {
            do {
                let candidates = try await performRemoteRequest(request)
                if !Task.isCancelled { callback(.success(candidates)) }
            } catch {
                if Task.isCancelled { return }  // cancelled — not a failure
                // Relay-only: no direct fallback. Suppress (empty = no suggestion);
                // the Engine handles it benignly, so a relay blip is a missed
                // suggestion, not an outage.
                Log.info("[CloudProvider] relay failed (\(error)); no suggestion")
                callback(.success([]))
            }
        }
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }

    /// Serialize a reply request to the relay's /v1/reply/* `request` shape.
    static func relayReplyJSON(conversation: String, userContext: String?, appName: String, windowTitle: String,
                               provider: String, recentMessages: [String]?, clipboardItems: [String]?,
                               prefix: String, suffix: String, suffixKind: SuffixKind, scrollback: String) -> [String: Any] {
        func opt(_ s: String?) -> Any { if let s = s { return s } else { return NSNull() } }
        func optArr(_ a: [String]?) -> Any { if let a = a { return a } else { return NSNull() } }
        var sk: [String: Any]
        switch suffixKind {
        case .plain: sk = ["kind": "plain"]
        case .mailReply(let q): sk = ["kind": "mailReply", "quote": ["older": opt(q.older), "newest": q.newest, "lead": q.lead]]
        }
        return [
            "conversation": conversation, "userContext": opt(userContext), "appName": appName, "windowTitle": windowTitle,
            "provider": provider, "recentMessages": optArr(recentMessages), "clipboardItems": optArr(clipboardItems),
            "prefix": prefix, "suffix": suffix, "suffixKind": sk, "scrollback": scrollback,
        ]
    }

    /// POST a JSON body to a relay path and return the decoded object. Throws on
    /// non-200 / network / decode so the reply caller can surface the failure.
    private func postRelay(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: Self.relayBaseURL + path) else { throw CloudProviderError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.relayAppToken, forHTTPHeaderField: "X-App-Token")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CloudProviderError.httpError(code, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudProviderError.invalidResponse
        }
        return obj
    }

    func generateReplyIntents(conversation: String, userContext: String?, appName: String, windowTitle: String, provider: String, recentMessages: [String]?, clipboardItems: [String]?, prefix: String, suffix: String, suffixKind: SuffixKind, scrollback: String) async throws -> [String] {
        let body: [String: Any] = ["request": Self.relayReplyJSON(
            conversation: conversation, userContext: userContext, appName: appName, windowTitle: windowTitle,
            provider: provider, recentMessages: recentMessages, clipboardItems: clipboardItems,
            prefix: prefix, suffix: suffix, suffixKind: suffixKind, scrollback: scrollback)]
        let obj = try await postRelay("/v1/reply/intents", body: body)
        guard let intents = obj["intents"] as? [String] else { throw CloudProviderError.invalidResponse }
        return Array(intents.prefix(3))
    }

    /// Expands a chosen reply intent into a full reply in the user's voice.
    func expandReply(intent: String, conversation: String, userContext: String?, appName: String, windowTitle: String, provider: String, recentMessages: [String]?, clipboardItems: [String]?, prefix: String, suffix: String, suffixKind: SuffixKind, scrollback: String) async throws -> String {
        var request = Self.relayReplyJSON(
            conversation: conversation, userContext: userContext, appName: appName, windowTitle: windowTitle,
            provider: provider, recentMessages: recentMessages, clipboardItems: clipboardItems,
            prefix: prefix, suffix: suffix, suffixKind: suffixKind, scrollback: scrollback)
        request["intent"] = intent
        request["timezone"] = TimeZone.current.identifier
        let obj = try await postRelay("/v1/reply/expand", body: ["request": request])
        guard let reply = obj["reply"] as? String else { throw CloudProviderError.invalidResponse }
        return reply
    }

    /// Uploads recent per-day usage rollups to the relay (write-only sink).
    /// Best-effort: returns true on a 200, swallows failures (callers fire it and
    /// forget — a missed upload is retried on the next trigger).
    func uploadUsage(rollups: [[String: Any]], appVersion: String?) async -> Bool {
        var body: [String: Any] = ["installId": Self.promptCacheKey, "days": rollups]
        if let appVersion { body["appVersion"] = appVersion }
        do {
            _ = try await postRelay("/v1/stats", body: body)
            return true
        } catch {
            return false
        }
    }
}

enum CloudProviderError: Error, LocalizedError {
    case unknownProvider(String)
    case noAPIKey
    case invalidURL
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .unknownProvider(let name): return "Unknown provider: \(name)"
        case .noAPIKey: return "No API key configured"
        case .invalidURL: return "Invalid API URL"
        case .invalidResponse: return "Invalid response from API"
        case .httpError(let code, let body): return "API error \(code): \(body.prefix(200))"
        }
    }
}

