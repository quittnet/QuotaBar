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
    private(set) var detailsExpanded: Bool
    private var updaterObservation: AnyCancellable?
    private var badges: MenuBarBadges?
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
    private final class ProviderState {
        var reading: QuotaReading?
        var failure: String?
        var missingCLI = false
        var refreshing = false
        var generation = 0
        var needsVerification = false
        var restrictionUnconfirmed = false
        var retryAt: Date?
        var balancePoll: UsageResets.BalancePoll?
        var consecutiveFailures = 0
        var lastAttempt = Date.distantPast
        var tokens: TokenTotals?
        var tokenFailure: String?
        var countingTokens = false
        var lastTokenScan = Date.distantPast
        var tokenTimeZone = TimeZone.current

        func nextRetry(at now: Date) -> Date? {
            retryAt ?? balancePoll?.fireDate(at: now)
        }
    }

    private let codex = ProviderState()
    private let claude = ProviderState()
    private(set) var provider: UsageProvider
    private func state(for source: UsageProvider) -> ProviderState { source == .codex ? codex : claude }
    private var current: ProviderState { state(for: provider) }
    private var visibleProviders: [UsageProvider] { menuLayout == .both ? UsageProvider.allCases : [provider] }
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
    private var claudeUsesLegacyReport = false
    private var canDisconnectClaude = false
    private var connectingClaude = false
    private var claudeSetupError: String?

    private let tokenReader = LocalTokenReader()
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
        self.menuLayout = selection.singleProvider != nil && layout == .both ? .percentage : layout
        self.percentageMode =
            defaults.string(forKey: "percentageMode").flatMap(PercentageMode.init(rawValue:)) ?? .remaining
        self.menuBarLimits = Dictionary(
            uniqueKeysWithValues: UsageProvider.allCases.map { source in
                let saved = defaults.string(forKey: Self.menuBarLimitsKey(source)).flatMap(MenuBarLimits.init)
                return (source, saved ?? .fiveHour)
            })
        self.detailsExpanded = defaults.stringArray(forKey: "expandedDashboardSections")?.contains("details") == true
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
            restrictionUnconfirmed: state.restrictionUnconfirmed, menuBarLimits: menuBarLimits[source] ?? .fiveHour)
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
        dashboard = NSHostingController(rootView: makePanel())
        dashboard.sizingOptions = []
        dropdown = DropdownPanel(dashboard: dashboard)
        updaterObservation = UpdateController.shared.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateViews() }
        }
        UpdateController.shared.start()
        dropdown.onDismiss = { [weak self] in self?.resets.cancel() }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(wokeUp),
            name: NSWorkspace.didWakeNotification, object: nil)
        for name: Notification.Name in [.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            clockObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.wokeUp() }
                })
        }

        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer

        refreshAndRestartTimer()
        networkMonitor?.onChange = { [weak self] available in self?.networkChanged(available: available) }
        networkMonitor?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        modeFeedbackTimer?.invalidate()
        loadingTimer?.invalidate()
        networkMonitor?.stop()
        dropdown?.dismiss()
        displayTimer?.invalidate()
        autoRefreshTimer?.invalidate()
        expiryTimer?.invalidate()
        for observer in clockObservers { NotificationCenter.default.removeObserver(observer) }
        clockObservers.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private var canRetryCodex: Bool {
        networkAvailable != false && resets.phase != .confirming && resets.phase != .submitting
    }

    var nextRefreshDate: Date? {
        let scheduled = autoRefreshTimer?.fireDate
        guard networkAvailable != false, provider != .codex || canRetryCodex else { return nil }
        guard let retry = current.nextRetry(at: quotaNow()) else { return scheduled }
        return scheduled.map { min($0, retry) } ?? retry
    }

    private lazy var helpWindow: NSWindow = {
        let content = HelpView { [weak self] in self?.helpWindow.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = "QuotaBar Help"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }()

    private func showHelp() {
        dropdown.dismiss()
        NSApp.activate()
        helpWindow.makeKeyAndOrderFront(nil)
    }

    func makePanel() -> Dashboard {
        let currentRanges =
            current.lastTokenScan <= Date() && Calendar.current.isDateInToday(current.lastTokenScan)
            && current.tokenTimeZone == .current
        return Dashboard(
            display: display,
            summaries: enabledProviders.map {
                Dashboard.Summary(
                    display: display(for: $0), failure: state(for: $0).failure, missingCLI: state(for: $0).missingCLI)
            }, nextAutoRefresh: nextRefreshDate,
            selectProvider: { [weak self] in self?.selectProvider($0) },
            providerSelection: providerSelection,
            selectProviderSelection: { [weak self] in self?.selectProviderSelection($0) },
            chooseCLI: { [weak self] in self?.chooseCLI($0) },
            automaticCLI: { [weak self] source in
                ProviderExecutable.useAutomatic(source.rawValue)
                self?.providerCLIChanged(source)
            },
            menuLayout: menuLayout, selectLayout: { [weak self] in self?.selectLayout($0) },
            selectPercentageMode: { [weak self] in self?.selectPercentageMode($0) },
            menuBarLimits: menuBarLimits,
            fiveHourChoices: enabledProviders.filter { display(for: $0).offersFiveHourChoice },
            selectMenuBarLimits: { [weak self] in self?.selectMenuBarLimits($0, for: $1) },
            detailsExpanded: detailsExpanded, setDetailsExpanded: { [weak self] in self?.setDetailsExpanded($0) },
            claudeUsesLegacyReport: claudeUsesLegacyReport,
            claudeConnectionStatus: enabledProviders.contains(.claude) ? claudeConnectionStatus : .notConfigured,
            connectingClaude: connectingClaude,
            claudeSetupError: claudeSetupError,
            connectClaude: { [weak self] in self?.changeClaudeConnection(disconnect: false) },
            canDisconnectClaude: canDisconnectClaude,
            disconnectClaude: { [weak self] in self?.changeClaudeConnection(disconnect: true) },
            claudeProfilePath: ClaudeProfile.directory.path,
            chooseClaudeProfile: { [weak self] in self?.chooseClaudeProfile() },
            useDefaultClaudeProfile: { [weak self] in self?.selectClaudeProfile(nil) },
            failure: current.failure, tokens: currentRanges ? current.tokens : nil,
            tokenFailure: current.tokenFailure, countingTokens: current.countingTokens,
            resetPhase: provider == .codex ? resets.phase : .ready,
            resetNotice: provider == .codex ? resets.notice : nil,
            resetBalanceUnconfirmed: provider == .codex
                && (resets.awaitingUpdatedBalance || resets.phase == .uncertain || resets.phase == .submitting),
            resetRetry: provider == .codex && resets.isRetry,
            canReviewReset: provider == .codex && resets.canReviewRecovery(display),
            reviewReset: { [weak self] in self?.reviewReset() },
            canUseReset: provider == .codex && resets.canPrepare(display),
            prepareReset: { [weak self] in self?.prepareReset() },
            cancelReset: { [weak self] in self?.cancelReset() },
            confirmReset: { [weak self] in self?.confirmReset() },
            refresh: { [weak self] in self?.refreshFromPanel() },
            checkForUpdates: { [weak self] in
                self?.dropdown.dismiss()
                NSApp.activate()
                UpdateController.shared.checkForUpdates()
            },
            showHelp: { [weak self] in self?.showHelp() },
            quit: { NSApp.terminate(nil) })
    }

    private func refreshClaudeConnectionStatus() {
        guard !connectingClaude else { return }
        claudeConnectionCheck?.cancel()
        let readStatus = readClaudeConnectionStatus
        claudeConnectionCheck = Task { [weak self] in
            let (status, managed) = await Task.detached(priority: .utility) { readStatus() }.value
            guard !Task.isCancelled, let self, claudeConnectionStatus != status || canDisconnectClaude != managed else {
                return
            }
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
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ProviderExecutable.choose(url, name: source.rawValue)
                }.value
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
        let state = state(for: source)
        state.reading = nil
        invalidate(source)
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
        picker.directoryURL = ClaudeProfile.directory.deletingLastPathComponent()
        dropdown?.dismiss()
        NSApp.activate()
        if picker.runModal() == .OK, let url = picker.url { selectClaudeProfile(url) }
    }

    private func selectClaudeProfile(_ url: URL?) {
        guard !connectingClaude else { return }
        let old = ClaudeProfile.directory
        ClaudeConnection.selectDirectory(url)
        guard old != ClaudeProfile.directory else { return }
        claudeConnectionCheck?.cancel()
        invalidate(.claude)
        claude.reading = nil
        claude.tokens = nil
        claude.failure = nil
        claude.missingCLI = false
        claude.tokenFailure = nil
        claude.lastTokenScan = .distantPast
        claudeConnectionStatus = .notConfigured
        canDisconnectClaude = false
        claudeUsesLegacyReport = false
        claudeSetupError = nil
        refreshClaudeConnectionStatus()
        refresh(source: .claude)
        refreshTokens(source: .claude)
        updateViews()
    }

    private func changeClaudeConnection(disconnect: Bool) {
        guard enabledProviders.contains(.claude), !connectingClaude else { return }
        claudeConnectionCheck?.cancel()
        connectingClaude = true
        claudeSetupError = nil
        updateViews()
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { if disconnect { try ClaudeConnection.disconnect() } else { try ClaudeConnection.connect() } }
            }.value
            connectingClaude = false
            switch result {
            case .success:
                claudeConnectionStatus = disconnect ? .notConfigured : .configured
                refreshClaudeConnectionStatus()
                invalidate(.claude)
                refresh(source: .claude)
            case .failure(let error):
                claudeSetupError = error.localizedDescription
            }
            updateViews()
        }
    }

    private func setDetailsExpanded(_ expanded: Bool) {
        guard expanded != detailsExpanded else { return }
        detailsExpanded = expanded
        if !expanded { resets.cancel() }
        defaults.set(expanded ? ["details"] : [], forKey: "expandedDashboardSections")
        updateViews()
    }

    private func selectProviderSelection(_ next: ProviderSelection) {
        guard next != providerSelection, resets.phase != .submitting else { return }
        resets.cancel()
        providerSelection = next
        defaults.set(next.rawValue, forKey: "providerSelection")
        if let single = next.singleProvider {
            invalidate(single == .codex ? .claude : .codex)
            provider = single
            if menuLayout == .both { menuLayout = .percentage }
        } else {
            menuLayout = .both
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
        guard next != menuLayout, next != .both || providerSelection == .both else { return }
        menuLayout = next
        defaults.set(next.rawValue, forKey: "menuBarLayout")
        updateViews()
    }

    static func menuBarLimitsKey(_ source: UsageProvider) -> String { source.rawValue + "MenuBarLimits" }

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

    private func cancelReset() {
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

    private func confirmReset() {
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
        refresh(source: .codex, checkingResetBalance: outcome == .reset)
    }

    private var resetControlsVisible: Bool {
        provider == .codex && dropdown?.isVisible == true && detailsExpanded
    }

    private func renderMenuBar(_ button: NSStatusBarButton) {
        let font = button.font ?? NSFont.menuBarFont(ofSize: 0)
        func title(_ value: QuotaDisplay) -> String {
            if modeFeedbackTimer != nil && value.hasCurrentPercentage {
                return value.menuBarTitle + (percentageMode == .remaining ? " left" : " used")
            }
            return value.refreshing && !value.hasCurrentPercentage && value.restrictionMessage == nil
                ? MenuBarBadges.loadingDots : value.menuBarTitle
        }
        let titles = visibleProviders.map { title(display(for: $0)) }
        let animate =
            titles.contains(MenuBarBadges.loadingDots) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
        if menuLayout == .both {
            let left = titles[0]
            let right = titles[1]
            if badges?.codex != left || badges?.claude != right || badges?.loadingPhase != phase {
                let rendered = MenuBarBadges(codex: left, claude: right, font: font, loadingPhase: phase)
                badges = rendered
                button.attributedTitle = NSAttributedString(string: "")
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleNone
                button.image = rendered.image
            }
        } else {
            badges = nil
            button.imagePosition = menuLayout == .logo ? .imageLeading : .noImage
            button.image = menuLayout == .logo ? ProviderLogo.image(for: provider) : nil
            let text = titles[0]
            button.attributedTitle =
                text == MenuBarBadges.loadingDots
                ? MenuBarBadges.label(text, font: font, color: .labelColor, loadingPhase: phase)
                : NSAttributedString(string: text)
        }
    }

    private func updateViews() {
        guard let button = item?.button else { return }
        renderMenuBar(button)
        let accessibility = visibleProviders.map { display(for: $0).tooltipReading }.joined(separator: "\n")
        let hasPercentage = visibleProviders.contains { display(for: $0).hasCurrentPercentage }
        let toggleHint =
            percentageMode == .remaining
            ? "Secondary-click to show the amount used." : "Secondary-click to show the amount left."
        button.toolTip =
            accessibility + "\nClick for details." + (hasPercentage ? " " + toggleHint : "")
        button.setAccessibilityLabel(accessibility)
        button.setAccessibilityHelp("Open details to change how percentages are shown.")
        if dropdown.isVisible {
            dashboard.rootView = makePanel()
            dropdown.fitToDashboard()
        }
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        let now = quotaNow()
        var deadlines = enabledProviders.compactMap { source -> Date? in
            let value = display(for: source)
            return value.stale ? nil : value.validUntil
        }
        for source in enabledProviders {
            let state = state(for: source)
            if !state.refreshing, networkAvailable != false, source != .codex || canRetryCodex,
                let retry = state.nextRetry(at: now)
            {
                deadlines.append(retry)
            }
        }
        if dropdown.isVisible, let day = Calendar.current.dateInterval(of: .day, for: now) {
            deadlines.append(day.end)
            if provider == .codex, let expiry = codex.reading?.resetCredits?.nextExpiration(at: now) {
                deadlines.append(expiry)
            }
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
        if target != provider {
            selectProvider(target)
            if dropdown.isVisible { return }
        } else if dropdown.isVisible {
            dropdown.dismiss()
            return
        }
        tick()
        refreshTokensIfDue()
        dashboard.rootView = makePanel()
        dropdown.show(under: button)
        scheduleExpiry()
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
        for source in enabledProviders {
            invalidate(source)
            if !available { state(for: source).failure = "Offline. QuotaBar will check when the connection returns." }
        }
        updateViews()
        if available {
            for source in enabledProviders { refresh(source: source) }
        }
    }

    @objc private func wokeUp() {
        codex.consecutiveFailures = 0
        for source in UsageProvider.allCases { invalidate(source) }
        updateViews()
        refreshAll()
    }

    private func invalidate(_ source: UsageProvider) {
        let state = state(for: source)
        state.generation += 1
        state.needsVerification = true
    }

    private func refreshFromPanel() {
        for source in enabledProviders where state(for: source).refreshing {
            invalidate(source)
        }
        refreshAndRestartTimer()
    }

    private func refreshAndRestartTimer() {
        autoRefreshTimer?.invalidate()
        let timer = Timer(
            fire: quotaNow().addingTimeInterval(QuotaDisplay.refreshInterval), interval: 0, repeats: false
        ) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAndRestartTimer() }
        }
        autoRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshAll()
    }

    private func refreshAll() {
        for source in enabledProviders {
            refresh(source: source)
            refreshTokens(source: source)
        }
    }

    private func refreshTokensIfDue() {
        if Date().timeIntervalSince(current.lastTokenScan) >= 15
            || current.lastTokenScan > Date()
            || !Calendar.current.isDateInToday(current.lastTokenScan)
            || current.tokenTimeZone != .current
        {
            refreshTokens(source: provider)
        }
    }

    private func refreshTokens(source: UsageProvider) {
        let state = state(for: source)
        guard enabledProviders.contains(source), !state.countingTokens else { return }
        let asOf = Date()
        let timeZone = TimeZone.current
        let profile = ClaudeProfile.directory
        state.countingTokens = true
        updateViews()
        Task(priority: .utility) {
            do {
                state.tokens = try await tokenReader.totals(for: source, now: asOf, claudeProfile: profile)
                state.tokenFailure = nil
            } catch {
                state.tokens = nil
                state.tokenFailure = "Local \(source.name) token history is unavailable. Refresh to try again."
            }
            state.lastTokenScan = asOf
            state.tokenTimeZone = timeZone
            state.countingTokens = false
            if (source == .claude && profile != ClaudeProfile.directory) || asOf > Date()
                || !Calendar.current.isDateInToday(asOf) || timeZone != .current
            {
                state.tokens = nil
                refreshTokens(source: source)
            }
            if provider == source { updateViews() }
        }
    }

    func tick() {
        let now = quotaNow()
        if dropdown?.isVisible == true { refreshTokensIfDue() }
        for source in enabledProviders {
            let state = state(for: source)
            let crossedReset =
                state.reading?.windows.contains { window in
                    guard let reset = window.resetsAt else { return false }
                    return reset > state.lastAttempt && reset <= now
                } ?? false
            if state.retryAt.map({ $0 <= now }) == true || crossedReset {
                refresh(source: source)
            } else if state.balancePoll?.fireDate(at: now).map({ $0 <= now }) == true {
                refresh(source: source, checkingResetBalance: true)
            } else if source == .claude && claudeUsesLegacyReport {
                refresh(source: source, legacyCacheOnly: true)
            }
        }
        updateViews()
    }

    private func refresh(source: UsageProvider, legacyCacheOnly: Bool = false, checkingResetBalance: Bool = false) {
        let state = state(for: source)
        guard enabledProviders.contains(source), !state.refreshing else { return }
        if source == .claude { refreshClaudeConnectionStatus() }
        guard networkAvailable != false else { return }
        if source == .codex, resets.phase == .submitting || resets.phase == .confirming {
            if !checkingResetBalance { state.retryAt = quotaNow() }
            return
        }
        state.refreshing = true
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
        updateViews()
        Task {
            let (result, usesLegacyReport) = await Task.detached(priority: .utility) {
                () -> (Result<QuotaReading?, Error>, Bool) in
                if source == .codex {
                    return (Result { try readCodex(needsUserIdentity) }, false)
                }
                if !legacyCacheOnly {
                    do {
                        return (.success(try readClaude()), false)
                    } catch ClaudeUsageClient.Failure.unsupported {
                        // Older clients report usage through the status line.
                    } catch {
                        return (.failure(error), false)
                    }
                }
                return (Result { try readLegacyClaude() }, true)
            }.value
            state.refreshing = false
            guard generation == state.generation else {
                updateViews()
                refresh(source: source)
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
                if checkingResetBalance { break }
                state.consecutiveFailures = min(state.consecutiveFailures + 1, 4)
                let delay: TimeInterval
                switch error as? QuotaError {
                case .codexNotFound?, .signInRequired?, .subscriptionRequired?, .quotaUnavailable?:
                    delay = QuotaDisplay.refreshInterval
                default:
                    delay =
                        source == .codex
                        ? [5.0, 15, 30, 60][state.consecutiveFailures - 1] : QuotaDisplay.refreshInterval
                }
                state.retryAt = quotaNow().addingTimeInterval(delay)
                if retryOnFailure { refresh(source: source) }
            }
            if enabledProviders.contains(source) {
                updateViews()
                if state.missingCLI, !defaults.bool(forKey: "didPresentCLISetup"), let button = item?.button {
                    if !dropdown.isVisible {
                        dashboard.rootView = makePanel()
                        dropdown.show(under: button)
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
