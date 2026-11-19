import AppKit
import SwiftUI

struct Dashboard: View {
    struct Summary {
        let display: QuotaDisplay
        let failure: String?
    }

    let display: QuotaDisplay
    let summaries: [Summary]
    let nextAutoRefresh: Date?
    let selectProvider: @MainActor @Sendable (UsageProvider) -> Void
    let providerSelection: ProviderSelection
    let selectProviderSelection: @MainActor @Sendable (ProviderSelection) -> Void
    let menuLayout: MenuBarLayout
    let selectLayout: @MainActor @Sendable (MenuBarLayout) -> Void
    let selectPercentageMode: @MainActor @Sendable (PercentageMode) -> Void
    let detailsExpanded: Bool
    let setDetailsExpanded: @MainActor @Sendable (Bool) -> Void
    let claudeUsesLegacyReport: Bool
    let claudeConfigured: Bool
    let connectingClaude: Bool
    let claudeSetupError: String?
    let connectClaude: () -> Void
    let failure: String?
    let tokens: TokenTotals?
    let tokenFailure: String?
    let countingTokens: Bool
    let resetPhase: UsageResets.Phase
    let resetNotice: String?
    let resetBalanceUnconfirmed: Bool
    let resetRetry: Bool
    let canUseReset: Bool
    let prepareReset: () -> Void
    let cancelReset: () -> Void
    let confirmReset: () -> Void
    let refresh: () -> Void
    let showHelp: () -> Void
    let quit: () -> Void

    var canRefresh: Bool {
        !(display.refreshing && countingTokens) && resetPhase != .confirming && resetPhase != .submitting
    }

    @Environment(\.colorScheme) private var colorScheme
    private var quotaColor: Color {
        colorScheme == .dark ? Color(red: 0.46, green: 0.94, blue: 0.96) : Color(red: 0, green: 0.36, blue: 0.40)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(summaries, id: \.display.provider) { summary in
                if summary.display.provider != summaries.first?.display.provider {
                    Divider().padding(.vertical, 12)
                }
                VStack(alignment: .leading, spacing: 0) {
                    limitSection(summary.display, failure: summary.failure)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("quota-summary-" + summary.display.provider.rawValue)
            }

            Divider().padding(.top, 12)
            if detailsExpanded {
                detailsDisclosure.padding(.top, 12)
                details.padding(.top, 8)
            }
        }
        .padding([.top, .horizontal], 17)
        .padding(.bottom, detailsExpanded ? 17 : 6)
        .frame(width: 316, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func limitSection(_ display: QuotaDisplay, failure: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(display.provider.name)
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if display.provider == .claude && display.hasCurrentPercentage {
                Text("Account-wide").font(.caption).foregroundStyle(.secondary)
                    .help("Includes shared five-hour and weekly limits. Individual models may have additional limits.")
            }
            Spacer()
        }
        .padding(.bottom, 12)

        if let restriction = display.restrictionMessage {
            Text(restriction).font(.callout).foregroundStyle(.secondary)
        } else if let failure, !display.refreshing {
            Label(failure, systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if display.stale {
            Text(display.refreshing ? "Checking your limits…" : "Current limit unavailable")
                .font(.callout).foregroundStyle(.secondary)
        } else if display.windows.isEmpty {
            Text(
                display.refreshing
                    ? "Checking your limits…"
                    : (display.provider == .claude && failure == nil
                        ? "No current Claude limit reported" : "Usage unavailable")
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            ForEach(Array(display.windows.enumerated()), id: \.offset) { index, window in
                if index > 0 { Divider().padding(.vertical, 13) }
                quotaRow(window, display: display)
            }
        }

        if display.provider == .claude && claudeUsesLegacyReport && !display.hasCurrentPercentage {
            VStack(alignment: .leading, spacing: 6) {
                if let claudeSetupError {
                    Text(claudeSetupError)
                } else {
                    Text(
                        "Update Claude Code for automatic usage checks. This version can only show reports from an active session."
                    )
                }
                if !claudeConfigured || claudeSetupError != nil {
                    Button(connectingClaude ? "Connecting…" : "Connect Claude Code", action: connectClaude)
                        .disabled(connectingClaude)
                        .help("Set up quota reporting in your Claude Code user settings")
                }
            }
            .font(.callout)
            .padding(.top, 6)
        }

    }

    private var detailsDisclosure: some View {
        DisclosureGroup(
            isExpanded: Binding(get: { detailsExpanded }, set: setDetailsExpanded)
        ) {
            EmptyView()
        } label: {
            Text("Details")
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { setDetailsExpanded(!detailsExpanded) }
        }
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 9) {
            if providerSelection == .both {
                DetailsProviderPicker(provider: Binding(get: { display.provider }, set: selectProvider))
                    .fixedSize()
                    .disabled(resetPhase == .submitting)
                    .help(
                        menuLayout == .both
                            ? "Choose which provider’s details to view" : "Choose the provider shown in the menu bar")
            }

            if display.stale || display.restrictionMessage != nil, !display.windows.isEmpty {
                Text(display.stale ? "Last reported limits" : "Reported quota windows").font(.headline)
                if let reading = display.reading { readingStatus(reading) }
                ForEach(Array(display.windows.enumerated()), id: \.offset) { _, window in
                    quotaRow(window, display: display)
                }
            }

            if failure == nil && display.windows.isEmpty && display.restrictionMessage == nil {
                Text(
                    display.provider == .claude
                        ? "API-billed sessions show local token totals only."
                        : "Fetching the latest reading from Codex."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if display.provider == .codex
                && (display.reading?.resetCredits != nil || resetPhase != .ready || resetNotice != nil
                    || resetBalanceUnconfirmed)
            {
                Text("Usage resets").font(.headline).accessibilityAddTraits(.isHeader)
                resetSection
            }
            if display.provider == .claude {
                Text("No resets available")
                    .font(.callout).foregroundStyle(.secondary)
                    .help("Claude Code does not provide a manual reset action in QuotaBar.")
            }

            Text("Tokens on this Mac").font(.headline).accessibilityAddTraits(.isHeader)
            tokenSection
                .help(
                    "Includes input and output tokens recorded in local \(display.provider.name) history. Day boundaries use your Mac’s time zone."
                )

            if let reading = display.reading, !display.stale && display.restrictionMessage == nil {
                readingStatus(reading)
            }
        }
    }

    var footerControls: some View {
        HStack(spacing: 7) {
            if detailsExpanded { Spacer() } else { detailsDisclosure }
            if let nextAutoRefresh {
                TimelineView(.periodic(from: nextAutoRefresh.addingTimeInterval(-QuotaDisplay.refreshInterval), by: 1))
                { context in
                    Text(verbatim: QuotaDisplay.refreshCountdown(nextAutoRefresh.timeIntervalSince(context.date)))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Refresh now (⌘R)")
            .accessibilityLabel("Refresh limits and token totals")
            .disabled(!canRefresh)

            Menu {
                Section("Providers") {
                    Picker(
                        "Providers",
                        selection: Binding(get: { providerSelection }, set: selectProviderSelection)
                    ) {
                        ForEach(ProviderSelection.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(resetPhase == .submitting)
                }
                if claudeConfigured {
                    Button("Reconnect Claude Code", action: connectClaude)
                        .disabled(connectingClaude)
                }
                Divider()
                Section("Menu Bar") {
                    Picker("Menu bar layout", selection: Binding(get: { menuLayout }, set: selectLayout)) {
                        ForEach(
                            MenuBarLayout.allCases.filter { providerSelection == .both || $0 != .both }, id: \.self
                        ) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Divider()
                Section("Show Percentage As") {
                    Picker(
                        "Show Percentage As",
                        selection: Binding(get: { display.percentageMode }, set: selectPercentageMode)
                    ) {
                        ForEach(PercentageMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Divider()
                Button("Help", action: showHelp)
                Button("Quit QuotaBar", action: quit)
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 17)
        .padding(.bottom, 12)
    }

    private func readingStatus(_ reading: QuotaReading) -> some View {
        HStack(spacing: 5) {
            Image(systemName: display.stale ? "clock.badge.exclamationmark" : "clock")
                .accessibilityHidden(true)
            Text(footer(reading.fetchedAt))
            Spacer()
            if display.refreshing { ProgressView().controlSize(.mini).accessibilityLabel("Refreshing limits") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            if resetPhase == .confirming {
                Text(resetRetry ? "Retry the same reset?" : "Use one reset?")
                    .font(.headline)
                Text(
                    resetRetry
                        ? "QuotaBar will reuse the original request so Codex can apply it only once."
                        : "This spends one reset if Codex can restore an eligible usage limit."
                )
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", action: cancelReset)
                    Button(resetRetry ? "Retry Reset" : "Use 1 Reset", action: confirmReset)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                if resetBalanceUnconfirmed {
                    Text("Waiting for Codex to confirm the reset balance.").font(.callout).foregroundStyle(.secondary)
                } else if display.stale && display.reading?.resetCredits != nil {
                    Text("Refresh to check your reset balance.").font(.callout).foregroundStyle(.secondary)
                } else if let credits = display.reading?.resetCredits {
                    let count = credits.availableCount(at: display.now)
                    let nextExpiry = credits.nextExpiration(at: display.now)
                    let expiry = nextExpiry?.formatted(.dateTime.month(.abbreviated).day())
                    Text(expiry.map { "\(count) available · Next known expiry \($0)" } ?? "\(count) available")
                        .font(.callout).foregroundStyle(.secondary)
                        .help(
                            nextExpiry.map { "Expires " + $0.formatted(date: .long, time: .shortened) }
                                ?? "Available Codex usage resets")
                }
                if let resetNotice {
                    Text(resetNotice).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let hint = disabledResetHint {
                    Text(hint).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if resetPhase == .submitting {
                    ProgressView().controlSize(.small).accessibilityLabel("Using reset")
                } else if resetPhase == .uncertain {
                    Button("Retry Same Reset…", action: prepareReset).disabled(!canUseReset)
                } else if let credits = display.reading?.resetCredits, credits.canClaim(at: display.now) {
                    Button("Use Reset", action: prepareReset).disabled(!canUseReset)
                }
            }
        }
        .controlSize(.small)
    }

    private var disabledResetHint: String? {
        guard !canUseReset else { return nil }
        if resetPhase == .uncertain {
            if display.refreshing { return "Checking the reset balance…" }
            return display.stale ? "Refresh limits to retry this reset." : nil
        }
        guard !resetBalanceUnconfirmed, !display.stale, resetPhase == .ready, let reading = display.reading,
            let credits = reading.resetCredits, credits.canClaim(at: display.now)
        else { return nil }
        if display.refreshing { return "Checking the reset balance…" }
        if credits.preferredCreditID(at: display.now) == nil && reading.resetCountOnlyFingerprint == nil {
            return "Refresh limits so Codex can verify the account for this reset."
        }
        return "Waiting for Codex to update the reset balance."
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let tokens {
                if tokens.partial && tokens.hasRetainedUsage {
                    Text("Partial history · Totals cover the readable records.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let lifetime = tokens.claudeStatsLifetime, display.provider == .claude {
                    tokenRow("All time · Claude /stats", count: lifetime)
                        .help(
                            "Lifetime total in Claude Code’s saved Stats. It includes older activity and can count repeated response entries."
                        )
                }
                if tokens.hasRetainedUsage {
                    tokenRow("All retained sessions", count: tokens.allTime)
                    tokenRow("Last 30 days", count: tokens.month)
                    tokenRow("Last 7 days", count: tokens.week)
                    tokenRow("Yesterday", count: tokens.yesterday)
                    tokenRow("Today", count: tokens.today)
                } else {
                    Text(
                        tokens.partial
                            ? "Retained token history is unavailable or incomplete." : "No token usage records found."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            } else if tokenFailure == nil {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("Counting local history…").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let tokenFailure {
                Text(tokenFailure).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func tokenRow(_ period: String, count: Int64) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(period).foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: count.formatted(.number)).monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private func footer(_ date: Date) -> String {
        let time = display.reportTime(date)
        if display.provider == .claude {
            return (display.stale ? "Last known Claude limit · " : "Reported by Claude Code · ") + time
        }
        return display.stale ? "Last known limit · " + time : "Limit updated " + time
    }

    private func quotaRow(_ window: QuotaWindow, display: QuotaDisplay) -> some View {
        let expired = display.hasReset(window)
        let name = QuotaDisplay.name(window)
        let percentage = display.percentage(for: window)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.system(size: 13, weight: .medium))
                    .accessibilityHidden(true)
                Spacer()
                if expired {
                    Text("Awaiting update").font(.callout).foregroundStyle(.secondary)
                        .accessibilityLabel(name + ", awaiting update")
                } else {
                    let switchHint = display.percentageMode == .remaining ? "Show amount used" : "Show amount left"
                    Button {
                        selectPercentageMode(display.percentageMode.toggled)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(display.formattedPercentage(for: window))
                                .font(.system(size: 21, weight: .semibold)).monospacedDigit()
                            Text(display.percentageMode == .remaining ? "left" : "used")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(switchHint)
                    .accessibilityLabel(name)
                    .accessibilityValue(display.accessibilityPercentage(for: window))
                    .accessibilityHint(switchHint)
                }
            }
            if !expired {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(quotaColor)
                            .frame(width: geometry.size.width * CGFloat(min(max(percentage / 100, 0), 1)))
                    }
                }
                .frame(height: 5)
                .accessibilityHidden(true)
                if let reset = window.resetsAt, !display.stale, display.restrictionMessage == nil {
                    TimelineView(.periodic(from: display.now, by: 1)) { context in
                        Text(QuotaDisplay.resetCountdown(reset.timeIntervalSince(context.date)))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .accessibilityLabel(
                                name + ". " + QuotaDisplay.resetCountdown(reset.timeIntervalSince(context.date)))
                    }
                }
            }
        }
    }
}

private struct DetailsProviderPicker: NSViewRepresentable {
    @Binding var provider: UsageProvider
    @Environment(\.isEnabled) private var isEnabled

    final class Coordinator: NSObject {
        var selection: Binding<UsageProvider>

        init(_ selection: Binding<UsageProvider>) {
            self.selection = selection
        }

        @MainActor @objc func changed(_ control: NSSegmentedControl) {
            guard UsageProvider.allCases.indices.contains(control.selectedSegment) else { return }
            selection.wrappedValue = UsageProvider.allCases[control.selectedSegment]
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator($provider) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: UsageProvider.allCases.map(\.name), trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentStyle = .rounded
        control.setAccessibilityLabel("Details provider")
        control.setAccessibilityIdentifier("details-provider-picker")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $provider
        control.isEnabled = isEnabled
        control.selectedSegment = UsageProvider.allCases.firstIndex(of: provider) ?? -1
        control.selectedSegmentBezelColor =
            provider == .claude
            ? NSColor(srgbRed: 0xd9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)
            : .systemBlue
    }
}
