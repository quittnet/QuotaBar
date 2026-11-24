import AppKit
import SwiftUI

extension UsageProvider {
    var accentColor: NSColor {
        switch self {
        case .codex: return .systemBlue
        case .claude: return NSColor(srgbRed: 0xd9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)
        }
    }

    // The small native segmented picker draws white text over its selected tint.
    fileprivate var historyMetricTint: Color {
        switch self {
        case .codex: return Color(.sRGB, red: 0x0c / 255.0, green: 0x5d / 255.0, blue: 0xb5 / 255.0)
        case .claude: return Color(.sRGB, red: 0xb2 / 255.0, green: 0x50 / 255.0, blue: 0x2c / 255.0)
        }
    }
}

struct Dashboard: View {
    var isPresented = true
    var retainsClosedUsage = false
    var contentScale: CGFloat = 1
    var hostedSettingsSize: CGSize?

    enum Page {
        case usage, settings, help

        var parent: Self? {
            switch self {
            case .usage: return nil
            case .settings: return .usage
            case .help: return .settings
            }
        }
    }

    struct Summary {
        let display: QuotaDisplay
        let failure: String?
        let missingCLI: Bool
        let tokens: TokenTotals?
        let countingTokens: Bool

        func dailyUsage(mode: DailyUsageMode) -> String? {
            let unavailable: String
            switch mode {
            case .off: return nil
            case .tokens: unavailable = "Tokens unavailable"
            case .spend: unavailable = "Spend unavailable"
            case .both: unavailable = "Usage unavailable"
            }
            guard let tokens else { return countingTokens ? "Counting…" : unavailable }
            guard tokens.hasRetainedUsage else { return unavailable }

            let count = tokens.today.formatted(.number) + (tokens.today == 1 ? " token" : " tokens")
            let partialSuffix = display.provider == .claude ? " (partial)" : ""
            let tokenSummary = count + (tokens.partial ? partialSuffix : "")
            if mode == .tokens { return tokenSummary }
            let today = tokens.spend.today
            guard let amount = today.formattedUSD(historyPartial: tokens.partial) else {
                return mode == .both ? tokenSummary + " · Spend unavailable" : "Spend unavailable"
            }
            let estimate = amount.hasPrefix("<") ? amount : "≈" + amount
            let values = mode == .both ? count + " · " + estimate : estimate
            return values + (tokens.partial || today.partial ? partialSuffix : "")
        }
    }

    private var updater: UpdateController { .shared }

    private(set) var display: QuotaDisplay
    private(set) var summaries: [Summary]
    let nextAutoRefresh: Date?
    let selectProvider: @MainActor @Sendable (UsageProvider) -> Void
    let providerSelection: ProviderSelection
    let selectProviderSelection: @MainActor @Sendable (ProviderSelection) -> Void
    let chooseCLI: (UsageProvider) -> Void
    let automaticCLI: (UsageProvider) -> Void
    let menuLayout: MenuBarLayout
    let selectLayout: @MainActor @Sendable (MenuBarLayout) -> Void
    let selectPercentageMode: @MainActor @Sendable (PercentageMode) -> Void
    var menuBarLimits: [UsageProvider: MenuBarLimits] = [:]
    /// Providers whose latest report includes a 5-hour window alongside another limit.
    var fiveHourChoices: [UsageProvider] = []
    var selectMenuBarLimits: (@MainActor @Sendable (MenuBarLimits, UsageProvider) -> Void)? = nil
    let page: Page
    let selectPage: @MainActor @Sendable (Page) -> Void
    let detailsExpanded: Bool
    let setDetailsExpanded: @MainActor @Sendable (Bool) -> Void
    let showSpend: Bool
    let setShowSpend: @MainActor @Sendable (Bool) -> Void
    let dailyUsageMode: DailyUsageMode
    let setDailyUsageMode: @MainActor @Sendable (DailyUsageMode) -> Void
    let claudeUsesLegacyReport: Bool
    let claudeConnectionStatus: ClaudeConnection.Status
    let connectingClaude: Bool
    private(set) var claudeSetupError: String?
    let connectClaude: () -> Void
    let canDisconnectClaude: Bool
    let disconnectClaude: () -> Void
    private(set) var claudeProfilePath: String
    let chooseClaudeProfile: () -> Void
    let useDefaultClaudeProfile: () -> Void
    private(set) var failure: String?
    private(set) var tokens: TokenTotals?
    private(set) var tokenFailure: String?
    let countingTokens: Bool
    let resetPhase: UsageResets.Phase
    private(set) var resetNotice: String?
    let resetBalanceUnconfirmed: Bool
    let resetRetry: Bool
    let canReviewReset: Bool
    let reviewReset: () -> Void
    let canUseReset: Bool
    let prepareReset: () -> Void
    let cancelReset: () -> Void
    let confirmReset: () -> Void
    let refresh: () -> Void
    let checkForUpdates: () -> Void
    let quit: () -> Void
    var settingsActionsEnabled: @MainActor () -> Bool = { true }

    /// Settings is cached across visits. Drop provider and profile data as soon as its host becomes hidden.
    mutating func discardHiddenSettingsData() {
        display = QuotaDisplay(
            reading: nil, now: display.now, failed: false, refreshing: false,
            provider: display.provider, percentageMode: display.percentageMode)
        summaries = []
        failure = nil
        tokens = nil
        tokenFailure = nil
        resetNotice = nil
        claudeSetupError = nil
        claudeProfilePath = ""
    }

    var canRefresh: Bool {
        !(display.refreshing && countingTokens) && resetPhase != .confirming && resetPhase != .submitting
    }

    var claudeSettingsAction: String? {
        switch claudeConnectionStatus {
        case .needsUpgrade: return "Upgrade Claude Code Connection"
        case .configured: return "Reconnect Claude Code"
        case .notConfigured: return nil
        }
    }

    func claudeSetupAction(for display: QuotaDisplay) -> String? {
        guard display.provider == .claude else { return nil }
        if claudeConnectionStatus == .needsUpgrade { return claudeSettingsAction }
        guard claudeUsesLegacyReport, !display.hasCurrentPercentage,
            claudeConnectionStatus == .notConfigured || claudeSetupError != nil
        else { return nil }
        return "Connect Claude Code"
    }

    var body: some View {
        if !isPresented && !(page == .usage && retainsClosedUsage) {
            EmptyView()
        } else if let hostedSettingsSize {
            Color.clear.frame(width: hostedSettingsSize.width, height: hostedSettingsSize.height)
                .allowsHitTesting(false).accessibilityHidden(true)
        } else if page == .settings {
            ViewThatFits(in: .vertical) {
                settingsPage(compact: false)
                settingsPage(compact: true)
            }
            .scaleEffect(contentScale)
        } else if let parent = page.parent {
            VStack(spacing: 0) {
                navigationHeader(backTo: parent)
                Divider()
                HelpView()
            }
            .frame(width: 316)
            .fixedSize(horizontal: false, vertical: true)
            .scaleEffect(contentScale)
        } else {
            usagePage.accessibilityHidden(!isPresented)
        }
    }

    private var usagePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(summaries, id: \.display.provider) { summary in
                if summary.display.provider != summaries.first?.display.provider {
                    Divider().padding(.vertical, 12)
                }
                VStack(alignment: .leading, spacing: 0) {
                    limitSection(summary.display, failure: summary.failure, missingCLI: summary.missingCLI)
                    if let daily = summary.dailyUsage(mode: dailyUsageMode) {
                        Text(verbatim: "Today · " + daily)
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                            .help(
                                "Usage recorded on this Mac since midnight. Spend is estimated in USD at standard API rates."
                            )
                            .accessibilityLabel(
                                summary.display.provider.name + " today, "
                                    + daily.replacingOccurrences(of: "≈", with: "estimated "))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("quota-summary-" + summary.display.provider.rawValue)
            }

            if let version = updater.pendingUpdateVersion {
                Button("Update to QuotaBar \(version)…", action: checkForUpdates)
                    .padding(.top, 10)
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
        .scaleEffect(contentScale)
    }

    @ViewBuilder
    private func limitSection(_ display: QuotaDisplay, failure: String?, missingCLI: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(display.provider.name)
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.bottom, 12)

        if missingCLI {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    display.provider == .codex
                        ? "Choose your installed Codex CLI, or follow the guide to install it and sign in with ChatGPT."
                        : "Choose your installed Claude Code CLI, or follow the guide to install it and sign in with your Claude subscription."
                )
                .fixedSize(horizontal: false, vertical: true)
                Button("Choose Installed CLI…") { chooseCLI(display.provider) }
                Link(
                    display.provider == .codex ? "Codex CLI installation guide" : "Claude Code installation guide",
                    destination: display.provider == .codex
                        ? URL(string: "https://developers.openai.com/codex/cli/")!
                        : URL(string: "https://code.claude.com/docs/en/quickstart")!)
            }
            .font(.callout)
        } else if let restriction = display.restrictionMessage {
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

        let showLegacyHelp = display.provider == .claude && claudeUsesLegacyReport && !display.hasCurrentPercentage
        let action = claudeSetupAction(for: display)
        if display.provider == .claude && (showLegacyHelp || action != nil || claudeSetupError != nil) {
            VStack(alignment: .leading, spacing: 6) {
                if let claudeSetupError {
                    Text(claudeSetupError)
                } else if showLegacyHelp {
                    Text(
                        "This Claude Code client doesn’t support automatic usage checks. QuotaBar can read reports from an active Claude Code session."
                    )
                }
                if let action {
                    Button(connectingClaude ? "Connecting…" : action, action: connectClaude)
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
                        menuLayout.showsBoth
                            ? "Choose which provider’s details to view" : "Choose the provider shown in the menu bar")
            }

            if display.stale || display.restrictionMessage != nil, !display.windows.isEmpty {
                Text(display.stale ? "Last reported limits" : "Reported quota windows").font(.headline)
                ForEach(Array(display.windows.enumerated()), id: \.offset) { _, window in
                    quotaRow(window, display: display)
                }
            }

            if failure == nil && display.windows.isEmpty && display.restrictionMessage == nil {
                Text(
                    display.provider == .claude
                        ? "API-billed sessions show local usage history."
                        : "Fetching the latest reading from Codex."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if isPresented && display.provider == .codex
                && (display.reading?.resetCredits != nil || resetPhase != .ready || resetNotice != nil
                    || resetBalanceUnconfirmed || canReviewReset)
            {
                Text("Usage resets").font(.headline).accessibilityAddTraits(.isHeader)
                resetSection
            }

            TokenHistoryHeader(showSpend: Binding(get: { showSpend }, set: setShowSpend))
                .tint(display.provider.historyMetricTint)
            tokenSection
                .help(
                    showSpend
                        ? "Estimated USD at standard API token rates for local \(display.provider.name) history. Excludes subscription charges and tool fees."
                        : "Includes input and output tokens recorded in local \(display.provider.name) history. Day boundaries use your Mac’s time zone."
                )
        }
    }

    var footerControls: some View {
        HStack(spacing: 7) {
            if detailsExpanded {
                if let reading = display.reading,
                    !display.windows.isEmpty || (!display.stale && display.restrictionMessage == nil)
                {
                    readingStatus(reading).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
            } else {
                detailsDisclosure
            }
            if let nextAutoRefresh {
                TimelineView(RefreshCountdownSchedule(deadline: nextAutoRefresh)) { context in
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

            Button {
                selectPage(.settings)
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("open-settings")
        }
        .padding(.horizontal, 17)
        .padding(.bottom, 12)
    }

    private func navigationHeader(backTo parent: Page) -> some View {
        ZStack(alignment: .leading) {
            Text(page == .help ? "Help" : "Settings")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity)
            Button {
                selectPage(parent)
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(parent == .settings ? "Back to Settings" : "Back to usage")
            .accessibilityIdentifier(page == .help ? "help-back" : "settings-back")
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
    }

    private func settingsPage(compact: Bool) -> some View {
        VStack(spacing: 0) {
            navigationHeader(backTo: .usage)
            Divider()
            VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                displaySettings(compact: compact)
                Divider()
                settingsToolsAndUpdates
                Divider()
                HStack {
                    Button("Help") { selectPage(.help) }
                    Spacer()
                    Button("Quit QuotaBar", action: quit)
                        .keyboardShortcut("q")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, compact ? 7 : 12)
        }
        .frame(width: 288)
        .fixedSize()
    }

    @ViewBuilder
    private var settingsToolsAndUpdates: some View {
        toolSettings
        if updater.supported {
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                settingsHeading("Updates", systemImage: "arrow.down.circle")
                Toggle(
                    isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { if settingsActionsEnabled() { updater.automaticallyChecksForUpdates = $0 } })
                ) {
                    Text("Automatically Check for Updates").frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                Button("Check for Updates…", action: checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }

    private func settingsHeading(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 15)
                .accessibilityHidden(true)
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
        }
    }

    private func settingsMenuRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 6) {
            Text(title).accessibilityHidden(true)
            Spacer(minLength: 0)
            control().labelsHidden()
        }
    }

    @ViewBuilder
    private func settingsChoice<Control: View>(
        _ title: String, compact: Bool, @ViewBuilder control: () -> Control
    ) -> some View {
        if compact {
            settingsMenuRow(title) { control().pickerStyle(.menu) }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.medium))
                control().labelsHidden().pickerStyle(.segmented)
            }
        }
    }

    private func displaySettings(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            settingsHeading("Display", systemImage: "slider.horizontal.3")
            settingsMenuRow("Providers") {
                Picker("Providers", selection: Binding(get: { providerSelection }, set: selectProviderSelection)) {
                    ForEach(ProviderSelection.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(resetPhase == .submitting)
            }

            if providerSelection == .both {
                settingsMenuRow("Menu Bar Shows") {
                    Picker(
                        "Menu Bar Shows",
                        selection: Binding(
                            get: { menuLayout.showsBoth }, set: { selectLayout(menuLayout.showing(both: $0)) })
                    ) {
                        Text("Both Providers").tag(true)
                        Text("Selected Provider").tag(false)
                    }
                }
            }
            Toggle(isOn: Binding(get: { menuLayout.showsLogos }, set: { selectLayout(menuLayout.showing(logos: $0)) }))
            {
                Text("Show Logos").frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            if let selectMenuBarLimits {
                ForEach(fiveHourChoices, id: \.self) { source in
                    settingsMenuRow("\(source.name) in Menu Bar") {
                        Picker(
                            "\(source.name) in Menu Bar",
                            selection: Binding(
                                get: { menuBarLimits[source] ?? .fiveHour }, set: { selectMenuBarLimits($0, source) })
                        ) {
                            ForEach(MenuBarLimits.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                }
            }
            settingsChoice("Show Percentage As", compact: compact) {
                Picker(
                    "Show Percentage As", selection: Binding(get: { display.percentageMode }, set: selectPercentageMode)
                ) {
                    ForEach(PercentageMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings-percentage-mode")
            }
            settingsChoice("Daily usage", compact: compact) {
                Picker("Daily usage", selection: Binding(get: { dailyUsageMode }, set: setDailyUsageMode)) {
                    ForEach(DailyUsageMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .accessibilityIdentifier("settings-daily-usage")
            }
            .help("Choose what appears under each provider’s quota bars.")
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var toolSettings: some View {
        VStack(alignment: .leading, spacing: 7) {
            settingsHeading("Command-Line Tools", systemImage: "terminal")
            ForEach(UsageProvider.allCases, id: \.self) { source in
                HStack(spacing: 6) {
                    Image(nsImage: ProviderLogo.image(for: source))
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(Color(nsColor: source.accentColor))
                        .accessibilityHidden(true)
                    Text(source.name)
                    Spacer()
                    Button("Choose…") { chooseCLI(source) }
                        .accessibilityLabel("Choose trusted \(source.name) executable")
                        .help("Choose a trusted \(source.name) executable")
                    Button("Use Automatic") { automaticCLI(source) }
                        .accessibilityLabel("Use automatic \(source.name) detection")
                }
            }
        }
        if providerSelection != .codex {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                settingsHeading("Claude Configuration Folder", systemImage: "folder")
                Text(verbatim: claudeProfilePath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(claudeProfilePath)
                HStack {
                    Button("Choose Folder…", action: chooseClaudeProfile)
                    Button("Use Default Folder", action: useDefaultClaudeProfile)
                }
                if let action = claudeSettingsAction {
                    Button(action, action: connectClaude)
                }
                if canDisconnectClaude {
                    Button("Disconnect Claude Status Line", action: disconnectClaude)
                }
                if let claudeSetupError {
                    Text(claudeSetupError).font(.callout).foregroundStyle(.secondary)
                }
            }
            .disabled(connectingClaude)
        }
    }

    private func readingStatus(_ reading: QuotaReading) -> some View {
        let date = reading.fetchedAt
        let time = display.reportTime(date)
        let lastKnown = display.provider == .claude ? "Last known Claude limit" : "Last known limit"
        let status = display.stale ? lastKnown + " · " + time : "Limit updated " + time
        return HStack(spacing: 4) {
            Group {
                if isPresented && display.refreshing {
                    ProgressView().controlSize(.mini).accessibilityLabel("Refreshing limits")
                } else {
                    Image(systemName: display.stale ? "clock.badge.exclamationmark" : "clock")
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 12, height: 12)
            ViewThatFits(in: .horizontal) {
                Text(verbatim: status)
                Text(verbatim: (display.stale ? "Last known " : "Updated ") + time)
                Text(date, format: .dateTime.year(.twoDigits).month(.twoDigits).day(.twoDigits).hour().minute())
            }
            .lineLimit(1)
            .accessibilityRepresentation {
                Text(verbatim: status).accessibilityIdentifier("limit-report-time")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(status)
    }

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            if resetPhase == .confirming {
                Text(resetRetry ? "Retry the same reset?" : "Use one reset?")
                    .font(.headline)
                Text(
                    resetRetry
                        ? "QuotaBar will send the original request ID again. Check the outcome in Codex if you’re unsure whether it was applied."
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
                if canReviewReset { Button("Review Saved Reset…", action: reviewReset) }
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
        if reading.resetOwner(for: credits.preferredCreditID(at: display.now)) == nil {
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
                if tokens.hasRetainedUsage || (!showSpend && tokens.claudeStatsLifetime != nil) {
                    TokenHistoryTable(totals: tokens, provider: display.provider, showSpend: showSpend)
                }
                if !tokens.hasRetainedUsage {
                    Text(
                        showSpend
                            ? "No retained usage available to estimate spend."
                            : tokens.partial
                                ? "Retained token history is unavailable or incomplete."
                                : "No token usage records found."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            } else if isPresented && tokenFailure == nil {
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

    private func quotaRow(_ window: QuotaWindow, display: QuotaDisplay) -> some View {
        let expired = display.hasReset(window)
        let name = QuotaDisplay.name(window)
        let accessibleName = display.provider.name + " " + name.lowercased()
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
                    .accessibilityLabel(accessibleName)
                    .accessibilityValue(display.accessibilityPercentage(for: window))
                    .accessibilityHint(switchHint)
                }
            }
            if !expired {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(Color(nsColor: display.provider.accentColor))
                            .frame(width: geometry.size.width * CGFloat(min(max(percentage / 100, 0), 1)))
                    }
                }
                .frame(height: 5)
                .accessibilityHidden(true)
                if isPresented, let reset = window.resetsAt, !display.stale, display.restrictionMessage == nil {
                    TimelineView(ResetCountdownSchedule(reset: reset)) { context in
                        let countdown = QuotaDisplay.resetCountdown(reset.timeIntervalSince(context.date))
                        Text(countdown)
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .accessibilityLabel(accessibleName + ". " + countdown)
                    }
                }
            }
        }
    }
}

/// The refresh footer shows rounded-up minutes, then ticks on whole seconds through its deadline.
struct RefreshCountdownSchedule: TimelineSchedule {
    let deadline: Date

    func entries(from startDate: Date, mode: Mode) -> some Sequence<Date> {
        sequence(first: startDate) { current in
            let remaining = deadline.timeIntervalSince(current)
            guard remaining > 0 else { return nil }
            let unit: TimeInterval = remaining > 60 ? 60 : 1
            let next = deadline.addingTimeInterval((1 - ceil(remaining / unit)) * unit)
            return next > current ? next : deadline
        }
    }
}

/// Long countdowns display whole hours or minutes. Schedule the next change in the displayed unit.
struct ResetCountdownSchedule: TimelineSchedule {
    let reset: Date

    func entries(from startDate: Date, mode: Mode) -> some Sequence<Date> {
        sequence(first: startDate) { current in
            let remaining = reset.timeIntervalSince(current)
            guard remaining > 0 else { return nil }
            if remaining < 60 {
                return reset.addingTimeInterval(1 - ceil(remaining))
            }
            let unit: TimeInterval = remaining >= 86_400 ? 3_600 : 60
            // The formatter rounds down, so the label changes just after the exact boundary.
            let next = current.addingTimeInterval(remaining.truncatingRemainder(dividingBy: unit) + 0.001)
            return next > current ? next : reset
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
        control.selectedSegmentBezelColor = provider.accentColor
    }
}

struct TokenHistoryHeader: View {
    @Binding var showSpend: Bool

    var body: some View {
        HStack {
            Text(showSpend ? "Est. spend (USD)" : "Tokens on this Mac")
                .font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
            Picker("History metric", selection: $showSpend) {
                Text("Tokens").tag(false)
                Text("Spend").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Choose token counts or estimated spend at standard API rates.")
        }
    }
}

struct TokenHistoryTable: View {
    let totals: TokenTotals
    let provider: UsageProvider
    let showSpend: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 9) {
                if !showSpend, provider == .claude, let lifetime = totals.claudeStatsLifetime {
                    row("All time · Claude /stats", count: lifetime, spend: nil)
                        .help(
                            "Claude Code’s lifetime total can include older or repeated activity. Cost estimates use retained sessions."
                        )
                }
                if totals.hasRetainedUsage {
                    row("All retained sessions", count: totals.allTime, spend: totals.spend.allTime)
                    row("Last 30 days", count: totals.month, spend: totals.spend.month)
                    row("Last 7 days", count: totals.week, spend: totals.spend.week)
                    row("Yesterday", count: totals.yesterday, spend: totals.spend.yesterday)
                    row("Today", count: totals.today, spend: totals.spend.today)
                }
            }
            if !showSpend, totals.hasRetainedUsage, let peak = totals.peakDay {
                Divider().padding(.vertical, 3)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Peak day").font(.callout.weight(.medium))
                        Text(peak.date, format: .dateTime.year().month(.abbreviated).day())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text(peak.tokens, format: .number)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Peak day")
                .accessibilityValue(
                    peak.date.formatted(date: .long, time: .omitted) + ", " + peak.tokens.formatted(.number)
                        + (peak.tokens == 1 ? " token" : " tokens")
                )
                .accessibilityIdentifier("history-peak-day")
                .help("The highest daily token count in this provider’s retained local history.")
            }
            if showSpend && totals.hasRetainedUsage && (totals.partial || totals.spend.hasPartialPeriod) {
                Text("* Partial estimate. A dash means cost is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ period: String, count: Int64, spend: TokenSpendAmount?) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(period).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            if showSpend {
                let amount = spend?.formattedUSD(historyPartial: totals.partial)
                let partial = totals.partial || spend?.partial == true
                Text(verbatim: amount.map { partial ? $0 + "*" : $0 } ?? "—")
                    .accessibilityLabel(
                        period + ", "
                            + (amount.map { (partial ? "partial estimated API cost, " : "estimated API cost, ") + $0 }
                                ?? "estimated API cost unavailable"))
            } else {
                Text(verbatim: count.formatted(.number))
                    .accessibilityLabel(period + ", " + count.formatted(.number) + (count == 1 ? " token" : " tokens"))
            }
        }
        .font(.callout)
        .monospacedDigit()
    }
}
