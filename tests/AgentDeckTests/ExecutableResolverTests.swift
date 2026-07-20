import Foundation
import Testing
@testable import AgentDeck

/// Covers `ExecutableResolver.isTrustedHint`, the security boundary that
/// decides whether an attacker-influenced hint may reach `Process`. Only the
/// pure validation is exercised — never the login-shell / searchDirs chain
/// (out of scope). Nothing is ever written outside the OS temp dir.
@Suite struct ExecutableResolverHintTests {
    init() { ExecutableResolver._resetCacheForTesting() }

    @Test func rejectsRelativePath() {
        #expect(ExecutableResolver.isTrustedHint("wezterm", name: "wezterm") == nil)
        #expect(ExecutableResolver.isTrustedHint("usr/bin/true", name: "true") == nil)
    }

    @Test func rejectsNonExecutableFile() {
        let dir = makeTempDir(); defer { cleanup(dir) }
        let file = makeNonExecutableFile(at: dir.appendingPathComponent("wezterm"))
        #expect(ExecutableResolver.isTrustedHint(file.path, name: "wezterm") == nil)
    }

    @Test func rejectsExecutableUnderUntrustedPrefix() {
        // An executable named exactly right, but parked in temp (an untrusted
        // scratch prefix — the "/tmp/wezterm" case).
        let dir = makeTempDir(); defer { cleanup(dir) }
        let exe = makeExecutableFile(at: dir.appendingPathComponent("wezterm"))
        #expect(ExecutableResolver.isTrustedHint(exe.path, name: "wezterm") == nil)
    }

    @Test func acceptsExactMatchUnderTrustedPrefix() {
        // /usr/bin/true: absolute, executable, basename == name, under /usr
        // (a trusted prefix) — with zero writes to the filesystem.
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/true") else { return }
        let resolved = ExecutableResolver.isTrustedHint("/usr/bin/true", name: "true")
        #expect(resolved == "/usr/bin/true")
    }

    @Test func acceptsDashSuffixedNameUnderTrustedPrefix() {
        // The `wezterm-gui` acceptance rule: a `<name>-...` basename under a
        // trusted prefix. Exercised against a real dashed executable in
        // /usr/bin so nothing is written. Skips only if the host truly has none.
        let fm = FileManager.default
        let usrBin = "/usr/bin"
        guard let items = try? fm.contentsOfDirectory(atPath: usrBin),
              let dashed = items.sorted().first(where: {
                  $0.contains("-") && fm.isExecutableFile(atPath: "\(usrBin)/\($0)")
              })
        else { return }
        let name = String(dashed.prefix(while: { $0 != "-" }))
        let path = "\(usrBin)/\(dashed)"
        #expect(ExecutableResolver.isTrustedHint(path, name: name) == path)
    }

    @Test func rejectsBasenameLookalike() {
        // `weztermXYZ` rejected: a basename that merely starts with the name
        // but is neither an exact match nor a `<name>-` prefix. /usr/bin/true
        // with name "tru" is that exact shape ("true" vs "tru").
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/true") else { return }
        #expect(ExecutableResolver.isTrustedHint("/usr/bin/true", name: "tru") == nil)
    }
}
