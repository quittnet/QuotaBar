import AppKit

enum ProviderLogo {
    static let menuBarSize: CGFloat = 14
    private static let codex = makeImage(for: .codex)
    private static let claude = makeImage(for: .claude)

    static func image(for provider: UsageProvider) -> NSImage {
        switch provider {
        case .codex: return codex
        case .claude: return claude
        }
    }

    private static func makeImage(for provider: UsageProvider) -> NSImage {
        let filename = provider == .codex ? "OpenAI" : "Claude"
        let dimensions = NSSize(width: menuBarSize, height: menuBarSize)
        let artwork = Bundle.main.url(forResource: filename, withExtension: "png", subdirectory: "ProviderLogos")
            .flatMap { NSImage(contentsOf: $0) }
        let image =
            artwork
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            ?? NSImage(size: dimensions)
        image.size = dimensions
        image.isTemplate = true
        return image
    }
}
