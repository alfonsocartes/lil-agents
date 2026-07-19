import Foundation
import Network

/// A tiny loopback HTTP server that receives `POST /event` from installed CLI
/// hooks and forwards decoded `HookEvent`s to the SessionStore on the main actor.
///
/// Wire contract — the forwarder script POSTs JSON like:
///   { "tool":"claude", "event":"Stop", "session_id":"…",
///     "cwd":"/path", "tty":"/dev/ttys003", "notification_type":"idle_prompt" }
/// with header `X-AgentDeck-Token: <per-install bearer token>`.
///
/// Any local process can otherwise reach 127.0.0.1:8787, so every request must:
///   1. be `POST /event` (anything else → 404/405), and
///   2. carry the correct bearer token (else → 401)
/// before its body is even decoded. Buffering is bounded throughout so a
/// malformed or hostile request can't grow memory unboundedly or crash the
/// process — see `maxHeaderBytes`/`maxBodyBytes`/`maxConnections` below.
final class EventListener {
    /// Header block (everything before `\r\n\r\n`) larger than this is refused.
    /// A real request's headers are well under 1 KB.
    private static let maxHeaderBytes = 8 * 1024
    /// A real HookEvent JSON body is under 4 KB; this is a generous cap against
    /// a malicious or runaway Content-Length.
    private static let maxBodyBytes = 64 * 1024
    /// Caps concurrent in-flight connections so a flood of opens can't grow
    /// unbounded per-connection state.
    private static let maxConnections = 16

    private let store: SessionStore
    private let token: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "agentdeck.listener")
    private var activeConnections = 0

    init(store: SessionStore, token: String) {
        self.store = store
        self.token = token
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: AgentDeck.port)!
            )
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    // Bind failure (most commonly EADDRINUSE) used to be logged
                    // and silently swallowed, leaving the forwarder posting hook
                    // events — now including the bearer token — at whatever else
                    // is squatting on the port. Make this loud instead.
                    NSLog("AgentDeck: ⚠️ FAILED to bind 127.0.0.1:\(AgentDeck.port) — \(err). Another process may already be bound to this port and intercepting hook events; AgentDeck will not receive session updates until this is resolved.")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            NSLog("AgentDeck listening on 127.0.0.1:\(AgentDeck.port)")
        } catch {
            NSLog("AgentDeck could not start listener: \(error)")
        }
    }

    private func handle(_ conn: NWConnection) {
        guard activeConnections < Self.maxConnections else {
            // Over the concurrent-connection cap — refuse outright rather than
            // accept and let per-connection buffers pile up.
            conn.cancel()
            return
        }
        activeConnections += 1
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    /// Accumulate bytes until we have headers + full body (per Content-Length),
    /// or hit a bound/validation failure.
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch self.evaluate(buffer) {
            case .ready(let body):
                self.dispatch(body)
                self.respond(conn, status: "200 OK")
                return
            case .badRequest:
                self.respond(conn, status: "400 Bad Request")
                return
            case .notFound:
                self.respond(conn, status: "404 Not Found")
                return
            case .methodNotAllowed:
                self.respond(conn, status: "405 Method Not Allowed")
                return
            case .unauthorized:
                self.respond(conn, status: "401 Unauthorized")
                return
            case .needsMore:
                break
            }

            if isComplete || error != nil {
                self.respond(conn, status: "400 Bad Request")
                return
            }
            self.receive(conn, buffer: buffer)
        }
    }

    private enum Evaluation {
        case needsMore
        case badRequest
        case notFound
        case methodNotAllowed
        case unauthorized
        case ready(Data)
    }

    /// Parses as much of `buffer` as is available and decides what to do next.
    /// Order matches the design: request line (method/path) → auth → body.
    private func evaluate(_ buffer: Data) -> Evaluation {
        let sep = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: sep) else {
            // No header terminator yet — bound how long we'll keep buffering
            // while waiting for one.
            return buffer.count > Self.maxHeaderBytes ? .badRequest : .needsMore
        }
        let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        guard headerData.count <= Self.maxHeaderBytes else { return .badRequest }
        let header = String(decoding: headerData, as: UTF8.self)

        guard let requestLine = header.components(separatedBy: "\r\n").first else { return .badRequest }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return .badRequest }
        let method = String(parts[0])
        let path = String(parts[1])

        guard path == "/event" else { return .notFound }
        guard method == "POST" else { return .methodNotAllowed }

        guard let providedToken = Self.headerValue(header, name: "x-agentdeck-token"),
              AgentDeck.constantTimeEquals(providedToken, token)
        else { return .unauthorized }

        // Content-Length: must be present and a well-formed, non-negative,
        // bounded integer. A missing/unparseable/negative/huge value is a 400
        // rather than ever being coerced (e.g. via `?? 0`) into an unsafe
        // `subdata(in:)` range.
        guard let contentLengthRaw = Self.headerValue(header, name: "content-length"),
              let length = Int(contentLengthRaw),
              length >= 0, length <= Self.maxBodyBytes
        else { return .badRequest }

        let bodyStart = range.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= length else { return .needsMore }
        return .ready(buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: length)))
    }

    private static func headerValue(_ header: String, name: String) -> String? {
        for line in header.split(separator: "\r\n") {
            let fields = line.split(separator: ":", maxSplits: 1)
            if fields.count == 2, fields[0].lowercased().trimmingCharacters(in: .whitespaces) == name {
                return fields[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func dispatch(_ body: Data) {
        guard let event = try? JSONDecoder().decode(HookEvent.self, from: body) else {
            NSLog("AgentDeck: undecodable event body")
            return
        }
        Task { @MainActor in self.store.apply(event) }
    }

    private func respond(_ conn: NWConnection, status: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            conn.cancel()
            self?.activeConnections -= 1
        })
    }
}
