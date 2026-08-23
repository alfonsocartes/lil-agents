import SwiftUI
import UsageCore
#if canImport(UIKit)
import UIKit
#endif

struct SignInSheet: View {
    let kind: ProviderKind
    var onSuccess: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .idle
    @State private var claudeCode = ""
    @State private var claudeStart: ClaudeOAuthStart?
    @State private var safariURL: URL?
    @State private var showingSafari = false
    @State private var copiedCode = false
    @State private var task: Task<Void, Never>?
    @State private var started = false

    private enum Phase: Equatable {
        case idle
        case device(code: String, url: URL)
        case waiting
        case claudePaste
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .idle:
                    ProgressView("Starting…")
                case .device(let code, let url):
                    Text("Copy this code first. Then open the login page and paste it.")
                    Text(code)
                        .font(.largeTitle.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                    Button(copiedCode ? "Copied" : "Copy code") {
                        copyCode(code)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open login page") { openInApp(url) }
                        .buttonStyle(.bordered)
                        .disabled(!copiedCode)
                    if kind == .codex {
                        Text("If it fails, turn on Device code authorization in ChatGPT → Settings → Security.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView("Waiting for approval…")
                case .waiting:
                    ProgressView("Finishing sign-in…")
                case .claudePaste:
                    Text("Approve in the page that opens, then paste the code here (code#state).")
                    if safariURL != nil {
                        Button("Open login page") { showingSafari = true }
                            .buttonStyle(.borderedProminent)
                    }
                    TextField("Paste code", text: $claudeCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .textFieldStyle(.roundedBorder)
                    ClipboardPasteButton { claudeCode = $0 }
                    Button("Continue") {
                        Task { await finishClaude() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(claudeCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                case .failed(let message):
                    Text(message)
                        .foregroundStyle(.red)
                    Button("Try again") {
                        started = false
                        phase = .idle
                        start()
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Sign in to \(ProviderChrome.title(kind))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        task?.cancel()
                        dismiss()
                    }
                }
            }
            .task { start() }
            .onDisappear { task?.cancel() }
            .sheet(isPresented: $showingSafari) {
                if let safariURL {
                    SafariView(url: safariURL)
                        .ignoresSafeArea()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func start() {
        guard !started else { return }
        started = true
        task?.cancel()
        switch kind {
        case .claude:
            let start = ClaudeOAuth.start()
            claudeStart = start
            safariURL = start.authorizationURL
            phase = .claudePaste
            showingSafari = true
        case .codex:
            phase = .idle
            task = Task { await runCodex() }
        case .grok:
            phase = .idle
            task = Task { await runGrok() }
        }
    }

    private func runCodex() async {
        do {
            let pending = try await CodexDeviceAuth.start(transport: urlTransport)
            if Task.isCancelled { return }
            copiedCode = false
            phase = .device(code: pending.userCode, url: pending.verificationURL)
            let tokens = try await CodexDeviceAuth.poll(pending: pending, transport: urlTransport)
            if Task.isCancelled { return }
            succeed(CredentialBlob.encode(tokens, kind: .codex))
        } catch is CancellationError {
            return
        } catch let error as OAuthLoginError {
            phase = .failed(message(error))
        } catch {
            phase = .failed("Sign-in failed")
        }
    }

    private func runGrok() async {
        do {
            let pending = try await GrokDeviceAuth.start(transport: urlTransport)
            if Task.isCancelled { return }
            copiedCode = false
            phase = .device(code: pending.userCode, url: pending.verificationURL)
            let tokens = try await GrokDeviceAuth.poll(pending: pending, transport: urlTransport)
            if Task.isCancelled { return }
            succeed(CredentialBlob.encode(tokens, kind: .grok))
        } catch is CancellationError {
            return
        } catch let error as OAuthLoginError {
            phase = .failed(message(error))
        } catch {
            phase = .failed("Sign-in failed")
        }
    }

    private func finishClaude() async {
        guard let start = claudeStart else { return }
        phase = .waiting
        do {
            let tokens = try await ClaudeOAuth.exchange(
                pasted: claudeCode,
                pkce: start.pkce,
                transport: urlTransport
            )
            succeed(CredentialBlob.encode(tokens, kind: .claude))
        } catch let error as OAuthLoginError {
            phase = .failed(message(error))
        } catch {
            phase = .failed("Couldn't exchange the code")
        }
    }

    @MainActor
    private func copyCode(_ code: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = code
        #endif
        copiedCode = true
    }

    @MainActor
    private func openInApp(_ url: URL) {
        safariURL = url
        showingSafari = true
    }

    private func succeed(_ raw: String) {
        onSuccess(raw)
        dismiss()
    }

    private func message(_ error: OAuthLoginError) -> String {
        switch error {
        case .cancelled: "Cancelled"
        case .timedOut: "Timed out — try again"
        case .denied(let text): text
        case .badResponse, .network: "Sign-in failed. Try again."
        }
    }
}

private let urlTransport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
    try await URLSession.shared.data(for: request)
}
