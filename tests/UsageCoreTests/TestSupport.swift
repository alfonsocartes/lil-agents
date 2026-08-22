import Foundation
import Synchronization
@testable import UsageCore

let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z

// MARK: - Temp filesystem helpers (never writes outside the temp dir)

func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("UsageCoreTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - Usage fetcher spies

/// Records every request handed to an injected `transport` closure and
/// replays canned `(Data, HTTPURLResponse)` results (or throws) in the order
/// given — the LAST configured result repeats for any call beyond the
/// list's length. `Mutex`-backed (never `@unchecked Sendable`).
final class TransportSpy: Sendable {
    enum StubResult {
        case success(status: Int, headers: [String: String] = [:], body: Data)
        case failure(Error)
    }

    private struct State {
        var callCount = 0
        var results: [StubResult]
        var requests: [URLRequest] = []
    }

    private let state: Mutex<State>

    init(_ results: [StubResult]) {
        state = Mutex(State(results: results))
    }

    var callCount: Int { state.withLock { $0.callCount } }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func handle(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let result = state.withLock { s -> StubResult in
            let index = min(s.callCount, s.results.count - 1)
            let picked = s.results[index]
            s.callCount += 1
            s.requests.append(request)
            return picked
        }
        switch result {
        case .success(let status, let headers, let body):
            let http = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            return (body, http)
        case .failure(let error):
            throw error
        }
    }
}

/// Canned, ordered `UsageProviding` stub: each call to `fetchUsage()` returns
/// the next configured result, repeating the last one for any call beyond
/// the list's length. `Mutex`-backed (never `@unchecked Sendable`).
final class StubUsageProvider: UsageProviding, Sendable {
    enum StubResult {
        case success(ProviderUsage)
        case failure(UsageFetchError)
    }

    private struct State {
        var callCount = 0
        var results: [StubResult]
    }

    private let state: Mutex<State>

    init(_ results: [StubResult]) {
        state = Mutex(State(results: results))
    }

    var callCount: Int { state.withLock { $0.callCount } }

    func fetchUsage() async throws -> ProviderUsage {
        let result = state.withLock { s -> StubResult? in
            guard !s.results.isEmpty else { return nil }
            let index = min(s.callCount, s.results.count - 1)
            let picked = s.results[index]
            s.callCount += 1
            return picked
        }
        guard let result else { throw UsageFetchError.credentialsMissing }
        switch result {
        case .success(let usage): return usage
        case .failure(let error): throw error
        }
    }
}

final class MemoryTokenStore: TokenStoring, Sendable {
    private let state: Mutex<[ProviderKind: String]>

    init(_ initial: [ProviderKind: String] = [:]) {
        state = Mutex(initial)
    }

    func load(kind: ProviderKind) throws -> String? {
        state.withLock { $0[kind] }
    }

    func save(kind: ProviderKind, raw: String) throws {
        state.withLock { $0[kind] = raw }
    }

    func delete(kind: ProviderKind) throws {
        state.withLock { _ = $0.removeValue(forKey: kind) }
    }
}

final class TestClock: Sendable {
    private let state: Mutex<Date>

    init(_ date: Date) {
        state = Mutex(date)
    }

    var now: Date { state.withLock { $0 } }

    func advance(_ interval: TimeInterval) {
        state.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}
