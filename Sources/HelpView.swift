import SwiftUI

struct HelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Using the menu bar")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            entry("Left-click", "Open or close the dropdown. With two badges, click a provider to view its details.")
            entry(
                "Right-click",
                "Switch a current percentage between amount left and amount used. A two-finger click or Control-click does the same. You can also click a percentage inside the dropdown."
            )
            entry(
                "Refresh · ⌘R",
                "Refresh now and restart the three-minute countdown. Esc goes back one page or closes the usage view. Clicking outside closes the dropdown."
            )
            Divider()
            Text("Reading your usage")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            entry(
                "Percentages",
                "The menu bar shows each provider’s 5-hour limit when available. Otherwise it shows the limit with the least remaining. Choose \(MenuBarLimits.both.title) in Settings to show the other windows alongside the 5-hour limit. Three dots mean QuotaBar is checking. A dash means it has no current reading."
            )
            entry(
                "Providers and tokens",
                "Choose your providers in Settings. Expand Details to switch between their token totals and reset controls. Token totals cover usage recorded on this Mac."
            )
            entry(
                "Resets",
                "The time under each bar counts down to its scheduled reset. Use Reset spends an available Codex reset only after you confirm."
            )
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func entry(_ title: String, _ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.semibold))
            Text(explanation).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
