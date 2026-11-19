import AppKit

/// A single template keeps both readings together and lets macOS tint them for the current menu bar.
struct MenuBarBadges {
    static let loadingDots = "···"
    let loadingPhase: Int?
    let codex: String
    let claude: String
    let image: NSImage
    private let split: CGFloat

    static func label(_ value: String, font: NSFont, color: NSColor, loadingPhase: Int?) -> NSAttributedString {
        let text = NSMutableAttributedString(string: value, attributes: [.font: font, .foregroundColor: color])
        if value == loadingDots, let loadingPhase {
            for dot in 0..<3 where dot != loadingPhase {
                text.addAttribute(
                    .foregroundColor, value: color.withAlphaComponent(0.45), range: NSRange(location: dot, length: 1))
            }
        }
        return text
    }

    init(codex: String, claude: String, font: NSFont, loadingPhase: Int?) {
        self.loadingPhase = loadingPhase
        self.codex = codex
        self.claude = claude
        let logoSide = ProviderLogo.menuBarSize
        let innerGap: CGFloat = 3
        let pairGap: CGFloat = 10
        let height: CGFloat = 18
        let first = Self.label(codex, font: font, color: .black, loadingPhase: loadingPhase)
        let second = Self.label(claude, font: font, color: .black, loadingPhase: loadingPhase)
        let firstWidth = logoSide + innerGap + ceil(first.size().width)
        let secondStart = firstWidth + pairGap
        let width = secondStart + logoSide + innerGap + ceil(second.size().width)
        split = firstWidth + pairGap / 2
        let codexLogo = ProviderLogo.image(for: .codex)
        let claudeLogo = ProviderLogo.image(for: .claude)
        image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            func draw(_ logo: NSImage, _ text: NSAttributedString, x: CGFloat) {
                logo.draw(in: NSRect(x: x, y: (height - logoSide) / 2, width: logoSide, height: logoSide))
                text.draw(at: NSPoint(x: x + logoSide + innerGap, y: floor((height - text.size().height) / 2)))
            }
            draw(codexLogo, first, x: 0)
            draw(claudeLogo, second, x: secondStart)
            return true
        }
        image.isTemplate = true
    }

    @MainActor func provider(at point: NSPoint, in button: NSStatusBarButton) -> UsageProvider {
        let imageRect = button.cell?.imageRect(forBounds: button.bounds) ?? .zero
        let x =
            imageRect.width > 0
            ? (point.x - imageRect.minX) * image.size.width / imageRect.width
            : point.x - button.bounds.midX + image.size.width / 2
        return x < split ? .codex : .claude
    }
}
