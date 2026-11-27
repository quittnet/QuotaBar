import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var item: NSStatusItem!
    private(set) var dropdown: DropdownPanel!
    private(set) var dashboard: NSHostingController<Dashboard>!
    private(set) var providerSelection: ProviderSelection
    private(set) var menuLayout: MenuBarLayout
    private(set) var percentageMode: PercentageMode
    private(set) var menuBarLimits: [UsageProvider: MenuBarLimits]
    private var page = Dashboard.Page.usage
    private var settingsVisit: UInt64 = 0
    private(set) var detailsExpanded: Bool
    private var showTokenSpend: Bool
    private(set) var compactMenuBarLimits: Bool
    private(set) var smallMenuBarText: Bool
    private var dailyUsageMode: DailyUsageMode
    private var updaterObservation: AnyCancellable?
    private var badges: MenuBarBadges?
    private var loadingBadgeFrames: [Int: MenuBarBadges] = [:]
    private var lastStatusClickTime: TimeInterval?
    private var modeFeedbackTimer: Timer?
    private var loadingTimer: Timer?
    private var loadingPhase = 0
    private var displayTimer: Timer?
    private var autoRefreshTimer: Timer?
    private var expiryTimer: Timer?
    private let networkMonitor: NetworkChanges?
    private var networkAvailable: Bool?
    private var retryLaunchReadOnFailure: Set<UsageProvider> = []
    private var clockObservers: [NSObjectProtocol] = []
    private enum RefreshTrigger { case standard, scheduled, legacyCache }

    private final class ProviderState {
        var reading: QuotaReading?
        var failure: String?
        var missingCLI = false
        var pendingCLIChoice: UUID?
        var refreshTrigger: RefreshTrigger?
        var refreshing: Bool { refreshTrigger != nil }
        var generation = 0
        var needsVerification = false
        var restrictionUnconfirmed = false
        var retryAt: Date?
        var balancePoll: UsageResets.BalancePoll?
        var consecutiveFailures = 0
        var lastAttempt = Date.distantPast
        let tokenReader = LocalTokenReader()
        var configurationGeneration = 0
        var tokens: TokenTotals?
        var tokenFailure: String?
        var countingTokens = false
        var tokenRefreshPending = false
        var lastTokenScan = Date.distantPast
        var tokenTimeZone = TimeZone.current

        func hasCurrentTokenDay(at now: Date, calendar: Calendar) -> Bool {
            tokenTimeZone == calendar.timeZone && lastTokenScan <= now
                && calendar.isDate(lastTokenScan, inSameDayAs: now)
        }

        func nextRetry(at now: Date) -> Date? {
            retryAt ?? balancePoll?.fireDate(at: now)
        }

        var nextWindowReset: Date? {
            reading?.windows.compactMap(\.resetsAt).filter { $0 > lastAttempt }.min()
        }
    }

    private let codex = ProviderState()
    private let claude = ProviderState()
    private(set) var provider: UsageProvider
    private func state(for source: UsageProvider) -> ProviderState { source == .codex ? codex : claude }
    private var current: ProviderState { state(for: provider) }
    private var visibleProviders: [UsageProvider] { menuLayout.showsBoth ? UsageProvider.allCases : [provider] }
    private var enabledProviders: [UsageProvider] {
        providerSelection.singleProvider.map { [$0] } ?? UsageProvider.allCases
    }
    private let defaults: UserDefaults
    private let quotaNow: () -> Date
    private let readCodex: @Sendable (Bool) throws -> QuotaReading
    private let readClaude: @Sendable () throws -> QuotaReading?
    private let readLegacyClaude: @Sendable () throws -> QuotaReading?
    private let readClaudeConnectionStatus: @Sendable () -> (status: ClaudeConnection.Status, managed: Bool)
    private let resets: UsageResets
    private let redeem: @Sendable (ResetAttempt) -> QuotaResetClaimResult

    private var claudeConnectionStatus = ClaudeConnection.Status.notConfigured
    private var claudeConnectionCheck: Task<Void, Never>?
    private var claudeConnectionCheckPending = false
    private var claudeUsesLegacyReport = false
    private var canDisconnectClaude = false
    private var connectingClaude = false
    private var claudeSetupError: String?

    var tokenTotals: TokenTotals? { current.tokens }

    init(
        resetStore: UsageResets? = nil, defaults: UserDefaults = .standard, monitorNetwork: Bool = true,
        quotaNow: @escaping () -> Date = Date.init,
        readCodex: @escaping @Sendable (Bool) throws -> QuotaReading = {
            try QuotaSource.read(includeCountOnlyIdentity: $0)
        },
        readClaude: @escaping @Sendable () throws -> QuotaReading? = { try ClaudeUsageClient.read() },
        readLegacyClaude: @escaping @Sendable () throws -> QuotaReading? = { try ClaudeQuotaSource.read() },
        readClaudeConnectionStatus: @escaping @Sendable () -> (ClaudeConnection.Status, Bool) = {
            (ClaudeConnection.status(), ClaudeConnection.canDisconnect())
        },
        redeem: @escaping @Sendable (ResetAttempt) -> QuotaResetClaimResult = { attempt in
            QuotaSource.claimReset(
                idempotencyKey: attempt.key, creditID: attempt.creditID,
                accountFingerprint: attempt.accountFingerprint)
        }
    ) {
        networkMonitor = monitorNetwork ? NetworkChanges() : nil
        self.defaults = defaults
        self.quotaNow = quotaNow
        self.readCodex = readCodex
        self.readClaude = readClaude
        self.readLegacyClaude = readLegacyClaude
        self.readClaudeConnectionStatus = readClaudeConnectionStatus
        let selection = ProviderSelection.saved(in: defaults)
        self.providerSelection = selection
        let detected = selection.singleProvider.map { [$0] } ?? UsageProvider.detected(defaults: defaults)
        self.provider =
            selection.singleProvider ?? defaults.string(forKey: "selectedProvider").flatMap(
                UsageProvider.init(rawValue:))
            ?? detected.first ?? .codex
        let layout =
            defaults.string(forKey: "menuBarLayout").flatMap(MenuBarLayout.init(rawValue:))
            ?? (detected.count > 1 ? .both : .percentage)
        self.menuLayout = selection.singleProvider != nil ? layout.showing(both: false) : layout
        self.percentageMode =
            defaults.string(forKey: "percentageMode").flatMap(PercentageMode.init(rawValue:)) ?? .remaining
        self.menuBarLimits = Dictionary(
            uniqueKeysWithValues: UsageProvider.allCases.map { source in
                let saved = defaults.string(forKey: Self.menuBarLimitsKey(source)).flatMap(MenuBarLimits.init)
                return (source, saved ?? .fiveHour)
            })
        self.detailsExpanded = defaults.stringArray(forKey: "expandedDashboardSections")?.contains("details") == true
        self.showTokenSpend = defaults.bool(forKey: "showTokenSpend")
        self.compactMenuBarLimits = defaults.bool(forKey: Self.compactMenuBarLimitsKey)
        self.smallMenuBarText = defaults.bool(forKey: Self.smallMenuBarTextKey)
        self.dailyUsageMode = DailyUsageMode.saved(in: defaults)
        self.resets = resetStore ?? UsageResets()
        self.redeem = redeem
        super.init()
    }

    private func display(for source: UsageProvider) -> QuotaDisplay {
        let state = state(for: source)
        return QuotaDisplay(
            reading: state.reading, now: quotaNow(), failed: state.failure != nil || state.needsVerification,
            refreshing: state.refreshing && networkAvailable != false, provider: source,
            percentageMode: percentageMode,
            restrictionUnconfirmed: state.restrictionUnconfirmed, menuBarLimits: menuBarLimits[source] ?? .fiveHour,
            compactLimits: compactMenuBarLimits)
    }

    var display: QuotaDisplay { display(for: provider) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "QuotaBarPercentage"
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        var initial = makePanel()
        initial.isPresented = false
        dashboard = NSHostingController(rootView: initial)
        dashboard.sizingOptions = []
        dropdown = DropdownPanel(dashboard: dashboard)
        updaterObservation = UpdateController.shared.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateViews() }
        }
        UpdateController.shared.start()
        dropdown.onDismiss = { [weak self] in
            self?.page = .usage
            self?.resets.cancel()
            self?.updateLoadingAnimation()
            self?.scheduleTimers()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(wokeUp),
            name: NSWorkspace.didWakeNotification, object: nil)
        for name: Notification.Name in [.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            clockObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.wokeUp() }
                })
        }

        refreshAndRestartTimer()
        networkMonitor?.onChange = { [weak self] available in self?.networkChanged(available: available) }
        networkMonitor?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        modeFeedbackTimer?.invalidate()
        loadingTimer?.invalidate()
        networkMonitor?.stop()
        cancelClaudeConnectionCheck()
        dropdown?.dismiss()
        displayTimer?.invalidate()
        autoRefreshTimer?.invalidate()
        expiryTimer?.invalidate()
        for observer in clockObservers { NotificationCenter.default.removeObserver(observer) }
        clockObservers.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func canRefreshQuota(for source: UsageProvider) -> Bool {
        networkAvailable != false && (source != .codex || (resets.phase != .confirming && resets.phase != .submitting))
    }

    private func retryDate(for source: UsageProvider, at now: Date) -> Date? {
        let state = state(for: source)
        guard canRefreshQuota(for: source), !state.refreshing else { return nil }
        return state.nextRetry(at: now)
    }

    var nextRefreshDate: Date? {
        guard networkAvailable != false else { return nil }
        let enabled = enabledProviders.filter { canRefreshQuota(for: $0) }
        let now = quotaNow()
        var deadlines = enabled.compactMap { retryDate(for: $0, at: now) }
        if !enabled.isEmpty, let regular = autoRefreshTimer?.fireDate { deadlines.append(regular) }
        // An expiring reading cancels an open confirmation and triggers a fresh Codex read.
        if enabledProviders.contains(.codex), resets.phase == .confirming,
            let expiry = display(for: .codex).validUntil
        {
            deadlines.append(expiry)
        }
        for source in enabled {
            let state = state(for: source)
            if !state.refreshing, let reset = state.nextWindowReset { deadlines.append(reset) }
        }
        return deadlines.min()
    }

    func makePanel(forPresentation: Bool = false) -> Dashboard {
        let now = Date()
        let calendar = Calendar.current
        let confirmation = resets.confirmationGeneration
        let offline = networkAvailable == false ? "Offline. QuotaBar will check when the connection returns." : nil
        func currentTokens(_ state: ProviderState) -> TokenTotals? {
            state.hasCurrentTokenDay(at: now, calendar: calendar) ? state.tokens : nil
        }
        // A callback issued for Settings is valid only while that Settings visit remains visible.
        let scopedSettingsAction = forPresentation && page == .settings
        let visit = settingsVisit
        let owner: @MainActor @Sendable () -> AppDelegate? = { [weak self] in
            guard let self else { return nil }
            if scopedSettingsAction
                && (self.page != .settings || self.settingsVisit != visit || self.dropdown?.isVisible != true)
            {
                return nil
            }
            return self
        }
        return Dashboard(
            display: display,
            summaries: enabledProviders.map { source in
                let state = state(for: source)
                return Dashboard.Summary(
                    display: display(for: source), failure: offline ?? state.failure, missingCLI: state.missingCLI,
                    tokens: currentTokens(state), countingTokens: state.countingTokens)
            }, nextAutoRefresh: nextRefreshDate,
            selectProvider: { owner()?.selectProvider($0) },
            providerSelection: providerSelection,
            selectProviderSelection: { owner()?.selectProviderSelection($0) },
            chooseCLI: { owner()?.chooseCLI($0) },
            automaticCLI: { source in
                guard let self = owner() else { return }
                self.state(for: source).pendingCLIChoice = nil
                ProviderExecutable.useAutomatic(source.rawValue, defaults: self.defaults)
                self.providerCLIChanged(source)
            },
            menuLayout: menuLayout, selectLayout: { owner()?.selectLayout($0) },
            selectPercentageMode: { owner()?.selectPercentageMode($0) },
            menuBarLimits: menuBarLimits,
            fiveHourChoices: enabledProviders.filter { display(for: $0).offersFiveHourChoice },
            selectMenuBarLimits: { owner()?.selectMenuBarLimits($0, for: $1) },
            compactLimits: compactMenuBarLimits, setCompactLimits: { owner()?.setCompactMenuBarLimits($0) },
            smallText: smallMenuBarText, setSmallText: { owner()?.setSmallMenuBarText($0) },
            page: page, selectPage: { owner()?.selectPage($0) },
            detailsExpanded: detailsExpanded, setDetailsExpanded: { owner()?.setDetailsExpanded($0) },
            showSpend: showTokenSpend, setShowSpend: { owner()?.setShowSpend($0) },
            dailyUsageMode: dailyUsageMode, setDailyUsageMode: { owner()?.setDailyUsageMode($0) },
            claudeUsesLegacyReport: claudeUsesLegacyReport,
            claudeConnectionStatus: enabledProviders.contains(.claude) ? claudeConnectionStatus : .notConfigured,
            connectingClaude: connectingClaude,
            claudeSetupError: claudeSetupError,
            connectClaude: { owner()?.changeClaudeConnection(disconnect: false) },
            canDisconnectClaude: canDisconnectClaude,
            disconnectClaude: { owner()?.changeClaudeConnection(disconnect: true) },
            claudeProfilePath: ClaudeProfile.resolve(defaults: defaults).path,
            chooseClaudeProfile: { owner()?.chooseClaudeProfile() },
            useDefaultClaudeProfile: { owner()?.selectClaudeProfile(nil) },
            failure: offline ?? current.failure, tokens: currentTokens(current),
            tokenFailure: current.tokenFailure, countingTokens: current.countingTokens,
            resetPhase: provider == .codex ? resets.phase : .ready,
            resetNotice: provider == .codex ? resets.notice : nil,
            resetBalanceUnconfirmed: provider == .codex
                && (resets.awaitingUpdatedBalance || resets.phase == .uncertain || resets.phase == .submitting),
            resetRetry: provider == .codex && resets.isRetry,
            canReviewReset: provider == .codex && resets.canReviewRecovery(display),
            reviewReset: { owner()?.reviewReset() },
            canUseReset: provider == .codex && resets.canPrepare(display),
            prepareReset: { owner()?.prepareReset() },
            cancelReset: { owner()?.cancelReset(confirmation: confirmation) },
            confirmReset: { owner()?.confirmReset(confirmation: confirmation) },
            refresh: { owner()?.refreshFromPanel() },
            checkForUpdates: {
                guard let delegate = owner() else { return }
                delegate.dropdown.dismiss()
                NSApp.activate()
                UpdateController.shared.checkForUpdates()
            },
            quit: { if owner() != nil { NSApp.terminate(nil) } }, settingsActionsEnabled: { owner() != nil })
    }

    private func cancelClaudeConnectionCheck() {
        claudeConnectionCheck?.cancel()
        claudeConnectionCheck = nil
        claudeConnectionCheckPending = false
    }

    private func refreshClaudeConnectionStatus(retryingProfile: Bool = false) {
        guard !connectingClaude, enabledProviders.contains(.claude) else { return }
        if claudeConnectionCheck != nil {
            claudeConnectionCheckPending = true
            return
        }
        let readStatus = readClaudeConnectionStatus
        let profile = ClaudeProfile.resolve(defaults: defaults)
        claudeConnectionCheck = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) {
                try? ClaudeProfile.read(at: profile) { _ in readStatus() }
            }.value
            guard !Task.isCancelled, let self else { return }
            claudeConnectionCheck = nil
            if result == nil {
                claudeConnectionStatus = .notConfigured
                canDisconnectClaude = false
                updateViews()
            }
            guard let (status, managed) = result, !claudeConnectionCheckPending else {
                let shouldRetry = claudeConnectionCheckPending || !retryingProfile
                claudeConnectionCheckPending = false
                if shouldRetry { refreshClaudeConnectionStatus(retryingProfile: result == nil) }
                return
            }
            guard claudeConnectionStatus != status || canDisconnectClaude != managed else { return }
            claudeConnectionStatus = status
            canDisconnectClaude = managed
            updateViews()
        }
    }

    private func chooseCLI(_ source: UsageProvider) {
        let picker = NSOpenPanel()
        picker.title = "Choose the trusted " + source.name + " executable"
        picker.message =
            "QuotaBar will run this file as you to read your " + source.name
            + " account. Choose the CLI you installed from the provider."
        picker.prompt = "Trust This CLI"
        picker.showsHiddenFiles = true
        picker.resolvesAliases = false
        dropdown?.dismiss()
        NSApp.activate()
        guard picker.runModal() == .OK, let url = picker.url else { return }
        chooseCLI(for: source) { try ProviderExecutable.Selection(url) }
    }

    @discardableResult
    func chooseCLI(for source: UsageProvider, preparing: @escaping @Sendable () throws -> ProviderExecutable.Selection)
        -> Task<Void, Never>
    {
        let state = state(for: source)
        let request = UUID()
        state.pendingCLIChoice = request
        return Task {
            let prepared = await Task.detached(priority: .userInitiated) { Result(catching: preparing) }.value
            // A new choice or a switch to automatic can finish while this file is being hashed.
            guard state.pendingCLIChoice == request else { return }
            state.pendingCLIChoice = nil
            do {
                try prepared.get().save(name: source.rawValue, defaults: defaults)
                providerCLIChanged(source)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t use that executable"
                alert.informativeText = "Choose a readable, executable file from your " + source.name + " installation."
                alert.runModal()
            }
        }
    }

    private func providerCLIChanged(_ source: UsageProvider) {
        clearQuotaResults(source)
        refresh(source: source)
        updateViews()
    }

    private func chooseClaudeProfile() {
        let picker = NSOpenPanel()
        picker.title = "Choose Claude Code’s configuration folder"
        picker.prompt = "Use Folder"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.showsHiddenFiles = true
        picker.directoryURL = ClaudeProfile.resolve(defaults: defaults).deletingLastPathComponent()
        dropdown?.dismiss()
        NSApp.activate()
        if picker.runModal() == .OK, let url = picker.url { selectClaudeProfile(url) }
    }

    func selectClaudeProfile(_ url: URL?) {
        guard !connectingClaude else { return }
        let previousDirectory = ClaudeProfile.resolve(defaults: defaults)
        let previousOverride = ClaudeProfile.childConfigurationDirectory(defaults: defaults)
        ClaudeProfile.select(url, defaults: defaults)
        guard
            previousDirectory != ClaudeProfile.resolve(defaults: defaults)
                || previousOverride != ClaudeProfile.childConfigurationDirectory(defaults: defaults)
        else { return }
        clearProviderResults(.claude)
        refreshClaudeAfterConfigurationChange()
        refreshTokens(source: .claude)
        updateViews()
    }

    private func refreshClaudeAfterConfigurationChange() {
        refresh(source: .claude)
        // A quota read already in flight skips the ordinary status check.
        if claudeConnectionCheck == nil { refreshClaudeConnectionStatus() }
    }

    private func changeClaudeConnection(disconnect: Bool) {
        guard enabledProviders.contains(.claude), !connectingClaude else { return }
        cancelClaudeConnectionCheck()
        connectingClaude = true
        let generation = claude.configurationGeneration
        claudeSetupError = nil
        updateViews()
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { if disconnect { try ClaudeConnection.disconnect() } else { try ClaudeConnection.connect() } }
            }.value
            connectingClaude = false
            guard enabledProviders.contains(.claude) else {
                updateViews()
                return
            }
            // A profile manager can change the selected folder while the operation holds
            // its original profile lock. Recheck before offering Reconnect or Disconnect.
            claudeConnectionStatus = .notConfigured
            canDisconnectClaude = false
            switch result {
            case .success:
                invalidate(.claude)
                refreshClaudeAfterConfigurationChange()
            case .failure(let error):
                if generation == claude.configurationGeneration { claudeSetupError = error.localizedDescription }
                refreshClaudeConnectionStatus()
            }
            updateViews()
        }
    }

    private func selectPage(_ next: Dashboard.Page) {
        guard page != next else { return }
        if page == .usage { resets.cancel() }
        page = next
        if next == .settings { settingsVisit &+= 1 }
        if next == .usage, dropdown?.isVisible == true { refreshVisibleTokensIfDue() }
        updateViews()
    }

    private func setDetailsExpanded(_ expanded: Bool) {
        guard expanded != detailsExpanded else { return }
        detailsExpanded = expanded
        if !expanded { resets.cancel() }
        defaults.set(expanded ? ["details"] : [], forKey: "expandedDashboardSections")
        if expanded, dropdown?.isVisible == true { refreshVisibleTokensIfDue() }
        updateViews()
    }

    private func setShowSpend(_ show: Bool) {
        guard show != showTokenSpend else { return }
        showTokenSpend = show
        defaults.set(show, forKey: "showTokenSpend")
        updateViews()
    }

    private func setDailyUsageMode(_ mode: DailyUsageMode) {
        guard mode != dailyUsageMode else { return }
        dailyUsageMode = mode
        defaults.set(mode.rawValue, forKey: DailyUsageMode.preferenceKey)
        if mode != .off, dropdown?.isVisible == true { refreshVisibleTokensIfDue() }
        updateViews()
    }

    private func selectProviderSelection(_ next: ProviderSelection) {
        guard next != providerSelection, resets.phase != .submitting else { return }
        resets.cancel()
        providerSelection = next
        defaults.set(next.rawValue, forKey: "providerSelection")
        if let single = next.singleProvider {
            clearProviderResults(single == .codex ? .claude : .codex)
            provider = single
            menuLayout = menuLayout.showing(both: false)
        } else {
            menuLayout = menuLayout.showing(both: true)
        }
        defaults.set(provider.rawValue, forKey: "selectedProvider")
        defaults.set(menuLayout.rawValue, forKey: "menuBarLayout")
        updateViews()
        refreshAll()
    }

    private func selectProvider(_ next: UsageProvider) {
        guard providerSelection == .both, next != provider, resets.phase != .submitting else { return }
        resets.cancel()
        provider = next
        defaults.set(next.rawValue, forKey: "selectedProvider")
        updateViews()
        refresh(source: next)
        refreshTokens(source: next)
    }

    private func selectLayout(_ next: MenuBarLayout) {
        guard next != menuLayout, !next.showsBoth || providerSelection == .both else { return }
        menuLayout = next
        defaults.set(next.rawValue, forKey: "menuBarLayout")
        updateViews()
    }

    static func menuBarLimitsKey(_ source: UsageProvider) -> String { source.rawValue + "MenuBarLimits" }

    static let compactMenuBarLimitsKey = "compactMenuBarLimits"

    func setCompactMenuBarLimits(_ compact: Bool) {
        guard compact != compactMenuBarLimits else { return }
        compactMenuBarLimits = compact
        defaults.set(compact, forKey: Self.compactMenuBarLimitsKey)
        updateViews()
    }

    static let smallMenuBarTextKey = "smallMenuBarText"

    func setSmallMenuBarText(_ small: Bool) {
        guard small != smallMenuBarText else { return }
        smallMenuBarText = small
        defaults.set(small, forKey: Self.smallMenuBarTextKey)
        updateViews()
    }

    func selectMenuBarLimits(_ next: MenuBarLimits, for source: UsageProvider) {
        guard next != menuBarLimits[source] else { return }
        menuBarLimits[source] = next
        defaults.set(next.rawValue, forKey: Self.menuBarLimitsKey(source))
        updateViews()
    }

    private func selectPercentageMode(_ next: PercentageMode) {
        guard next != percentageMode else { return }
        percentageMode = next
        defaults.set(next.rawValue, forKey: "percentageMode")
        modeFeedbackTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.modeFeedbackTimer = nil
                if let button = self.item?.button { self.renderMenuBar(button) }
            }
        }
        modeFeedbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        updateViews()
    }

    private func prepareReset() {
        guard resetControlsVisible else { return }
        resets.prepare(display)
        updateViews()
    }

    private func cancelReset(confirmation: UInt64) {
        guard resets.confirmationGeneration == confirmation else { return }
        guard provider == .codex else { return }
        resets.cancel()
        updateViews()
    }

    private func reviewReset() {
        guard resetControlsVisible else { return }
        do {
            let review = try resets.reviewRecovery(display)
            let alert = NSAlert()
            alert.messageText = "Review saved reset"
            alert.informativeText = review.message
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Archive Record and Refresh")
            dropdown?.dismiss()
            NSApp.activate()
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            _ = try resets.recover(review, display: display)
            invalidate(.codex)
            refresh(source: .codex, checkingResetBalance: true)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t recover the saved reset"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        updateViews()
    }

    private func confirmReset(confirmation: UInt64) {
        guard resets.confirmationGeneration == confirmation else { return }
        guard resetControlsVisible else { return }
        guard let attempt = resets.begin(display) else {
            if resets.awaitingUpdatedBalance { refresh(source: .codex, checkingResetBalance: true) }
            updateViews()
            return
        }
        invalidate(.codex)
        updateViews()
        let redeem = self.redeem
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { redeem(attempt) }.value
            finishReset(outcome)
        }
    }

    func finishReset(_ outcome: QuotaResetClaimResult) {
        resets.finish(outcome, reading: codex.reading)
        if networkAvailable == false {
            updateViews()
        } else {
            refresh(source: .codex, checkingResetBalance: outcome == .reset)
        }
    }

    private var resetControlsVisible: Bool {
        provider == .codex && dropdown?.isVisible == true && detailsExpanded && page == .usage
    }

    private func updateLoadingAnimation() {
        if let button = item?.button { renderMenuBar(button) }
    }

    private func renderMenuBar(_ button: NSStatusBarButton) {
        let standardFont = button.font ?? NSFont.menuBarFont(ofSize: 0)
        // The small option draws the readings two points smaller, keeping equal-width digits so the item stays put.
        let font =
            smallMenuBarText
            ? NSFont.monospacedDigitSystemFont(ofSize: standardFont.pointSize - 2, weight: .regular) : standardFont
        func title(_ value: QuotaDisplay) -> String {
            if modeFeedbackTimer != nil && value.hasCurrentPercentage {
                return value.menuBarTitle + (percentageMode == .remaining ? " left" : " used")
            }
            return value.refreshing && !value.hasCurrentPercentage && value.restrictionMessage == nil
                ? MenuBarBadges.loadingDots : value.menuBarTitle
        }
        let providers = visibleProviders
        let titles = providers.map { title(display(for: $0)) }
        let animate =
            titles.contains(MenuBarBadges.loadingDots) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && (dropdown?.isVisible == true
                || zip(providers, titles).contains { source, text in
                    text == MenuBarBadges.loadingDots && state(for: source).refreshTrigger == .standard
                })
        if animate && loadingTimer == nil {
            let timer = Timer(timeInterval: 0.28, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let button = self.item?.button else { return }
                    self.loadingPhase = (self.loadingPhase + 1) % 3
                    self.renderMenuBar(button)
                }
            }
            loadingTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if !animate {
            loadingTimer?.invalidate()
            loadingTimer = nil
            loadingPhase = 0
        }
        let phase = animate ? loadingPhase : nil
        if menuLayout.showsBoth {
            let style = MenuBarBadges.Style(
                codex: titles[0], claude: titles[1], logos: menuLayout.showsLogos, font: font,
                appearance: button.effectiveAppearance)
            if badges == nil {
                button.attributedTitle = NSAttributedString(string: "")
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleNone
            }
            guard badges?.style != style || badges?.loadingPhase != phase else { return }
            if badges?.style != style || phase == nil { loadingBadgeFrames.removeAll(keepingCapacity: true) }
            let rendered: MenuBarBadges
            if let phase, let cached = loadingBadgeFrames[phase] {
                rendered = cached
            } else {
                rendered = MenuBarBadges(style: style, loadingPhase: phase)
                if let phase { loadingBadgeFrames[phase] = rendered }
            }
            badges = rendered
            button.image = rendered.image
        } else {
            badges = nil
            loadingBadgeFrames.removeAll(keepingCapacity: true)
            let position: NSControl.ImagePosition = menuLayout.showsLogos ? .imageLeading : .noImage
            if button.imagePosition != position { button.imagePosition = position }
            let image = menuLayout.showsLogos ? ProviderLogo.image(for: provider) : nil
            if button.image !== image { button.image = image }
            let text = titles[0]
            let title: NSAttributedString
            if !menuLayout.showsLogos {
                // Without a logo, the provider's color identifies the percentage.
                title = MenuBarBadges.label(
                    text, font: font, color: provider.menuBarColor, loadingPhase: phase)
            } else {
                title =
                    text == MenuBarBadges.loadingDots
                    ? MenuBarBadges.label(text, font: font, color: .labelColor, loadingPhase: phase)
                    : smallMenuBarText
                        ? NSAttributedString(string: text, attributes: [.font: font]) : NSAttributedString(string: text)
            }
            if !button.attributedTitle.isEqual(to: title) { button.attributedTitle = title }
        }
    }

    private func updateViews() {
        guard let button = item?.button else { return }
        renderMenuBar(button)
        let accessibility = visibleProviders.map { display(for: $0).accessibilityReading }.joined(separator: "\n")
        button.setAccessibilityLabel(accessibility)
        button.setAccessibilityHelp("Open details to change how percentages are shown.")
        if dropdown.isVisible {
            dropdown.presentPage(makePanel(forPresentation: true))
            dropdown.fitToDashboard()
        }
        scheduleTimers()
    }

    private func updateDisplayTimer() {
        let pollLegacyCache = enabledProviders.contains(.claude) && claudeUsesLegacyReport && networkAvailable != false
        guard (dropdown.isVisible && page == .usage) || pollLegacyCache else {
            displayTimer?.invalidate()
            displayTimer = nil
            return
        }
        guard displayTimer == nil else { return }
        let timer = Timer(fire: Date().addingTimeInterval(30), interval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func scheduleTimers() {
        updateDisplayTimer()
        let now = quotaNow()
        var deadlines: [Date] = []
        for source in enabledProviders {
            if let retry = retryDate(for: source, at: now) { deadlines.append(retry) }
            let state = state(for: source)
            guard let reading = state.reading else { continue }
            let value = display(for: source)
            if !value.stale, let expiry = value.validUntil { deadlines.append(expiry) }
            if reading.fetchedAt > now { deadlines.append(reading.fetchedAt) }
            // A later reset can still trigger a new read after an earlier window or reading has expired.
            if !state.refreshing, canRefreshQuota(for: source), let reset = state.nextWindowReset {
                deadlines.append(reset)
            }
        }
        if let day = Calendar.current.dateInterval(of: .day, for: now),
            dropdown.isVisible
                || visibleProviders.contains(where: { source in
                    state(for: source).reading.map { day.contains($0.fetchedAt) } == true
                })
        {
            deadlines.append(day.end)
        }
        if dropdown.isVisible, provider == .codex, let expiry = codex.reading?.resetCredits?.nextExpiration(at: now) {
            deadlines.append(expiry)
        }
        let deadline = deadlines.min()
        guard deadline != expiryTimer?.fireDate else { return }
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let deadline else { return }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        expiryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func togglePanel(_ button: NSStatusBarButton) {
        // AppKit can retain the previous mouse-up as currentEvent during a later accessibility press.
        guard let event = NSApp.currentEvent, event.window === button.window,
            event.type == .leftMouseUp || event.type == .rightMouseUp, event.timestamp != lastStatusClickTime
        else {
            handleClick(on: button, at: nil)
            return
        }
        lastStatusClickTime = event.timestamp
        let point = button.convert(event.locationInWindow, from: nil)
        let secondaryClick = event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        handleClick(on: button, at: point, secondaryClick: secondaryClick)
    }

    func handleClick(on button: NSStatusBarButton, at point: NSPoint?, secondaryClick: Bool = false) {
        let target = point.flatMap { badges?.provider(at: $0, in: button) } ?? provider
        if secondaryClick && display(for: target).hasCurrentPercentage {
            selectPercentageMode(percentageMode.toggled)
            return
        }
        if secondaryClick, dropdown.isVisible, target == provider {
            // The unavailable-badge shortcut shows this provider's status, even if already open.
            selectPage(.usage)
            return
        }
        let clickAnchor = DropdownPanel.AnchorGeometry(button)
        // Either badge toggles expanded Details. The provider picker controls which history it shows.
        let keepsDetailsProvider = !secondaryClick && page == .usage && detailsExpanded
        if target != provider && !keepsDetailsProvider {
            selectProvider(target)
            if dropdown.isVisible {
                selectPage(.usage)
                return
            }
        } else if dropdown.isVisible {
            dropdown.dismiss()
            return
        }
        tick()
        refreshVisibleTokensIfDue()
        dropdown.presentPage(makePanel(forPresentation: true))
        showDropdown(under: button, fallback: clickAnchor)
    }

    private func showDropdown(under button: NSStatusBarButton, fallback: DropdownPanel.AnchorGeometry? = nil) {
        dropdown.show(under: button, fallback: fallback)
        updateLoadingAnimation()
        scheduleTimers()
    }

    func applicationDidResignActive(_ notification: Notification) {
        dropdown?.dismiss()
    }

    func networkChanged(available: Bool) {
        let previous = networkAvailable
        networkAvailable = available
        if previous == nil && available {
            // Launch already started a read. Retry immediately if that read raced Wi-Fi joining.
            for source in enabledProviders {
                let state = state(for: source)
                if state.refreshing {
                    retryLaunchReadOnFailure.insert(source)
                } else if state.failure != nil {
                    refresh(source: source)
                }
            }
            return
        }
        retryLaunchReadOnFailure.removeAll()
        if available { codex.consecutiveFailures = 0 }
        for source in enabledProviders { invalidate(source) }
        updateViews()
        if available {
            for source in enabledProviders { refresh(source: source) }
        }
    }

    @objc private func wokeUp() {
        codex.consecutiveFailures = 0
        for source in UsageProvider.allCases { invalidate(source) }
        updateViews()
        refreshAndRestartTimer()
    }

    private func invalidate(_ source: UsageProvider) {
        let state = state(for: source)
        state.generation += 1
        state.needsVerification = true
        if source == .codex, resets.phase == .confirming {
            resets.cancelInvalidConfirmation(display(for: .codex))
        }
    }

    private func clearQuotaResults(_ source: UsageProvider) {
        invalidate(source)
        let state = state(for: source)
        state.reading = nil
        state.failure = nil
        state.missingCLI = false
        state.restrictionUnconfirmed = false
        state.consecutiveFailures = 0
        if source == .codex { resets.clearUnverifiedBalanceNotice(for: nil) }
        if source == .claude { claudeUsesLegacyReport = false }
    }

    private func clearProviderResults(_ source: UsageProvider) {
        clearQuotaResults(source)
        let state = state(for: source)
        state.tokens = nil
        state.tokenFailure = nil
        state.lastTokenScan = .distantPast
        state.configurationGeneration += 1
        if source == .claude {
            cancelClaudeConnectionCheck()
            claudeConnectionStatus = .notConfigured
            canDisconnectClaude = false
            claudeSetupError = nil
        }
    }

    private func refreshFromPanel() {
        for source in enabledProviders where state(for: source).refreshing {
            let state = state(for: source)
            // Supersede the in-flight read while keeping the last verified reading visible.
            state.generation += 1
            state.refreshTrigger = .standard
        }
        refreshAndRestartTimer()
        updateLoadingAnimation()
    }

    private func refreshAndRestartTimer(_ trigger: RefreshTrigger = .standard) {
        autoRefreshTimer?.invalidate()
        let timer = Timer(
            fire: quotaNow().addingTimeInterval(QuotaDisplay.refreshInterval), interval: 0, repeats: false
        ) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAndRestartTimer(.scheduled) }
        }
        autoRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshAll(trigger)
    }

    private func refreshAll(_ trigger: RefreshTrigger = .standard) {
        for source in enabledProviders {
            refresh(source: source, trigger: trigger)
            refreshTokens(source: source)
        }
    }

    func refreshVisibleTokensIfDue() {
        guard page == .usage else { return }
        let now = Date()
        let calendar = Calendar.current
        for source in enabledProviders where dailyUsageMode != .off || (detailsExpanded && source == provider) {
            let state = state(for: source)
            guard !state.countingTokens else { continue }
            if now.timeIntervalSince(state.lastTokenScan) >= 15
                || !state.hasCurrentTokenDay(at: now, calendar: calendar)
            {
                refreshTokens(source: source)
            }
        }
    }

    private func refreshTokens(source: UsageProvider, retryingProfile: Bool = false) {
        let state = state(for: source)
        guard enabledProviders.contains(source) else { return }
        if state.countingTokens {
            state.tokenRefreshPending = true
            return
        }
        let asOf = Date()
        let timeZone = TimeZone.current
        let profile = ClaudeProfile.resolve(defaults: defaults)
        let generation = state.configurationGeneration
        state.countingTokens = true
        updateViews()
        Task(priority: .utility) {
            var profileChanged = false
            do {
                state.tokens = try await state.tokenReader.totals(for: source, now: asOf, claudeProfile: profile)
                state.tokenFailure = nil
            } catch ClaudeProfile.ReadError.directoryChanged {
                state.tokens = nil
                state.tokenFailure = nil
                profileChanged = true
            } catch {
                state.tokens = nil
                state.tokenFailure = "Local \(source.name) token history is unavailable. Refresh to try again."
            }
            state.lastTokenScan = asOf
            state.tokenTimeZone = timeZone
            state.countingTokens = false
            let obsolete =
                generation != state.configurationGeneration
                || (source == .claude && profile != ClaudeProfile.resolve(defaults: defaults))
                || asOf > Date() || !Calendar.current.isDateInToday(asOf) || timeZone != .current
            if obsolete {
                state.tokens = nil
                state.tokenFailure = nil
            }
            if obsolete || state.tokenRefreshPending || (profileChanged && !retryingProfile) {
                state.tokenRefreshPending = false
                refreshTokens(source: source, retryingProfile: profileChanged)
            } else if profileChanged {
                // The retry also saw the profile change. Say so until the next scheduled scan.
                state.tokenFailure =
                    "\(source.name)’s profile changed during refresh. QuotaBar will check again shortly."
            }
            if provider == source || dropdown?.isVisible == true { updateViews() }
        }
    }

    func tick() {
        let now = quotaNow()
        if resets.phase == .confirming {
            let value = display(for: .codex)
            resets.cancelInvalidConfirmation(value)
            if value.stale { refresh(source: .codex) }
        }
        if dropdown?.isVisible == true { refreshVisibleTokensIfDue() }
        for source in enabledProviders {
            let state = state(for: source)
            let crossedReset = state.nextWindowReset.map { $0 <= now } == true
            if state.retryAt.map({ $0 <= now }) == true || crossedReset {
                refresh(source: source)
            } else if state.balancePoll?.fireDate(at: now).map({ $0 <= now }) == true {
                refresh(source: source, checkingResetBalance: true)
            } else if source == .claude && claudeUsesLegacyReport {
                refresh(source: source, trigger: .legacyCache)
            }
        }
        updateViews()
    }

    private func refresh(
        source: UsageProvider, checkingResetBalance: Bool = false,
        trigger: RefreshTrigger = .standard, retryingClaudeProfile: Bool = false
    ) {
        let state = state(for: source)
        guard enabledProviders.contains(source) else { return }
        if state.refreshing {
            // A status-line cache read cannot satisfy a requested live account check.
            if state.refreshTrigger == .legacyCache, trigger != .legacyCache {
                state.refreshTrigger = trigger
            }
            return
        }
        if source == .claude { refreshClaudeConnectionStatus() }
        guard networkAvailable != false else { return }
        if source == .codex, resets.phase == .submitting || resets.phase == .confirming {
            if !checkingResetBalance { state.retryAt = quotaNow() }
            return
        }
        state.refreshTrigger = trigger
        state.retryAt = nil
        state.balancePoll = nil
        state.lastAttempt = quotaNow()
        let generation = state.generation
        let resetReadGeneration = source == .codex ? resets.readGeneration() : nil
        let needsUserIdentity =
            source == .codex
            && (checkingResetBalance || resets.needsCountOnlyIdentityRefresh
                || !(defaults.stringArray(forKey: Self.restrictionsKey) ?? []).isEmpty)
        let readCodex = self.readCodex
        let readClaude = self.readClaude
        let readLegacyClaude = self.readLegacyClaude
        let profile = source == .claude ? ClaudeProfile.resolve(defaults: defaults) : nil
        updateViews()
        Task {
            let (result, usesLegacyReport) = await Task.detached(priority: .utility) {
                () -> (Result<QuotaReading?, Error>, Bool) in
                guard let profile else {
                    return (Result { try readCodex(needsUserIdentity) }, false)
                }
                var legacy = trigger == .legacyCache
                let reading = Result {
                    try ClaudeProfile.read(at: profile) { _ in
                        if !legacy {
                            do {
                                return try readClaude()
                            } catch ClaudeUsageClient.Failure.unsupported {
                                legacy = true
                            }
                        }
                        return try readLegacyClaude()
                    }
                }
                return (reading, legacy)
            }.value
            let requestedTrigger = state.refreshTrigger
            state.refreshTrigger = nil
            guard generation == state.generation, requestedTrigger == trigger else {
                updateViews()
                let scheduledFollowUp = trigger == .legacyCache && requestedTrigger == .scheduled
                refresh(source: source, trigger: scheduledFollowUp ? .scheduled : .standard)
                return
            }
            if case .failure(ClaudeProfile.ReadError.directoryChanged) = result {
                state.reading = nil
                state.missingCLI = false
                state.needsVerification = true
                claudeUsesLegacyReport = false
                if retryingClaudeProfile {
                    state.failure = "Claude’s profile changed during refresh. QuotaBar will check again shortly."
                    state.retryAt = quotaNow().addingTimeInterval(5)
                    updateViews()
                } else {
                    state.failure = nil
                    refresh(source: source, retryingClaudeProfile: true)
                }
                return
            }
            if source == .claude {
                claudeUsesLegacyReport = usesLegacyReport
            }
            let retryOnFailure = retryLaunchReadOnFailure.remove(source) != nil
            switch result {
            case .success(let reading):
                state.missingCLI = false
                state.reading = reading
                state.needsVerification = false
                state.failure = nil
                state.consecutiveFailures = 0
                if source == .codex, let reading, let resetReadGeneration {
                    state.restrictionUnconfirmed = restrictionNeedsConfirmation(reading)
                    resets.received(reading, generation: resetReadGeneration)
                    state.balancePoll = resets.nextBalancePoll(for: reading, at: quotaNow())
                }
            case .failure(let error):
                state.missingCLI =
                    (error as? QuotaError) == .codexNotFound || (error as? ClaudeUsageClient.Failure) == .notInstalled
                state.failure =
                    (error as? LocalizedError)?.errorDescription
                    ?? "Couldn’t read \(source.name) limits. Try refreshing."
                let transientCodexFailure: Bool
                switch error as? QuotaError {
                case .signInRequired?, .subscriptionRequired?:
                    // A verified sign-out or API-key session ends the previous subscription account.
                    state.reading = nil
                    state.restrictionUnconfirmed = false
                    resets.clearUnverifiedBalanceNotice(for: nil)
                    transientCodexFailure = false
                case .codexNotFound?, .quotaUnavailable?: transientCodexFailure = false
                default: transientCodexFailure = source == .codex
                }
                if checkingResetBalance {
                    if transientCodexFailure, let reading = state.reading {
                        state.balancePoll = resets.nextBalancePoll(for: reading, at: quotaNow())
                    }
                    break
                }
                state.consecutiveFailures = min(state.consecutiveFailures + 1, 4)
                let delay =
                    transientCodexFailure
                    ? [5.0, 15, 30, 60][state.consecutiveFailures - 1] : QuotaDisplay.refreshInterval
                state.retryAt = quotaNow().addingTimeInterval(delay)
                if retryOnFailure { refresh(source: source) }
            }
            if enabledProviders.contains(source) {
                updateViews()
                if state.missingCLI, !defaults.bool(forKey: "didPresentCLISetup"), let button = item?.button {
                    if !dropdown.isVisible {
                        dropdown.presentPage(makePanel(forPresentation: true))
                        showDropdown(under: button)
                    }
                    if dropdown.isVisible { defaults.set(true, forKey: "didPresentCLISetup") }
                }
            }
        }
    }

    private static let restrictionsKey = "restrictedCodexAccounts"

    func restrictionNeedsConfirmation(_ reading: QuotaReading) -> Bool {
        let unknown = "unidentified"
        // These entries are needed only while the owner of a past restriction is unknown.
        let confirmedPrefix = "confirmed:"
        let owner = reading.resetCountOnlyFingerprint
        let saved = Set(defaults.stringArray(forKey: Self.restrictionsKey) ?? [])
        var restricted = saved
        switch reading.ordinaryUsageAllowed {
        case false?:
            if let owner {
                restricted.remove(confirmedPrefix + owner)
                restricted.insert(owner)
            } else {
                restricted = restricted.filter { !$0.hasPrefix(confirmedPrefix) }
                restricted.insert(unknown)
            }
        case true?:
            if let owner {
                restricted.remove(owner)
                if restricted.contains(unknown) { restricted.insert(confirmedPrefix + owner) }
            }
        case nil:
            guard let owner else { return !restricted.isEmpty }
            return restricted.contains(owner)
                || (restricted.contains(unknown) && !restricted.contains(confirmedPrefix + owner))
        }
        if restricted != saved { defaults.set(restricted.sorted(), forKey: Self.restrictionsKey) }
        return false
    }
}
