import AppIntents
import UsageCore

enum ProviderChoice: String, AppEnum {
    case claude
    case grok
    case codex

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Provider" }

    static var caseDisplayRepresentations: [ProviderChoice: DisplayRepresentation] {
        [
            .claude: "Claude",
            .grok: "Grok",
            .codex: "Codex",
        ]
    }

    var kind: ProviderKind { ProviderKind(rawValue: rawValue)! }
}

struct SelectProviderIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Provider" }
    static var description: IntentDescription { IntentDescription("Which provider’s usage to show.") }

    @Parameter(title: "Provider", default: ProviderChoice.claude)
    var provider: ProviderChoice

    init() {
        self.provider = .claude
    }

    init(provider: ProviderChoice) {
        self.provider = provider
    }
}
