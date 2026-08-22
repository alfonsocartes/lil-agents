/// Persistence seam for the raw paste string (JSON or bare token). Parse at
/// fetch time via `TokenParsing` so the original shape is preserved.
/// No Keychain in this module — the app supplies a concrete store.
public protocol TokenStoring: Sendable {
    func load(kind: ProviderKind) throws -> String?
    func save(kind: ProviderKind, raw: String) throws
    func delete(kind: ProviderKind) throws
}
