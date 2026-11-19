import SwiftUI

struct HelpView: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Using the menu bar")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            entry("Left-click", "Open or close the dropdown. With two badges, click a provider to view its details.")
            entry(
                "Right-click",
                "Switch a current percentage between amount left and amount used. A two-finger click or Control-click does the same. You can also click a percentage inside the dropdown."
            )
            entry(
                "Refresh · ⌘R",
                "With the dropdown open, refresh now and restart the three-minute countdown. Press Esc or click outside to close it."
            )
            Divider()
            Text("Reading your usage")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            entry(
                "Percentages",
                "The menu bar shows the most restrictive active limit for each displayed provider. Three dots mean QuotaBar is checking. A dash means it has no current reading."
            )
            entry(
                "Providers and tokens",
                "Choose your providers in Settings. Expand Details to switch between their token totals and reset controls. Token totals cover usage recorded on this Mac."
            )
            entry(
                "Resets",
                "The time under each bar counts down to its scheduled reset. Use Reset spends an available Codex reset only after you confirm."
            )
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 432, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func entry(_ title: String, _ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(explanation).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
