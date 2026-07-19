import Foundation
import Network

/// A tiny loopback HTTP server that receives `POST /event` from installed CLI
/// hooks and forwards decoded `HookEvent`s to the SessionStore on the main actor.
///
/// Wire contract — the forwarder script POSTs JSON like:
///   { "tool":"claude", "event":"Stop", "session_id":"…",
///     "cwd":"/path", "tty":"/dev/ttys003", "notification_type":"idle_prompt" }
/// The server always replies `200 OK` (or `400` on unparseable bodies).
final class EventListener {
    private let store: SessionStore
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "agentdeck.listener")

    init(store: SessionStore) {
        self.store = store
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
                    NSLog("AgentDeck listener failed: \(err)")
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
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    /// Accumulate bytes until we have headers + full body (per Content-Length).
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let body = Self.completeBody(in: buffer) {
                self.dispatch(body)
                self.respond(conn, status: "200 OK")
                return
            }
            if isComplete || error != nil {
                self.respond(conn, status: "400 Bad Request")
                return
            }
            self.receive(conn, buffer: buffer)
        }
    }

    /// Returns the request body once headers and the full Content-Length are present.
    private static func completeBody(in buffer: Data) -> Data? {
        let sep = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: sep) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        let header = String(decoding: headerData, as: UTF8.self)
        let length = Self.contentLength(header) ?? 0
        let bodyStart = range.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= length else { return nil }
        return buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: length))
    }

    private static func contentLength(_ header: String) -> Int? {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased().trimmingCharacters(in: .whitespaces) == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
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
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
