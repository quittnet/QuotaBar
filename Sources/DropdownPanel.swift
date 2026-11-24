import AppKit
import SwiftUI

@MainActor
final class DropdownPanel: NSPanel {
    private let dashboard: NSHostingController<Dashboard>
    private var settingsDashboard: NSHostingController<Dashboard>?
    private let body = NSView()
    private let footer: NSHostingView<AnyView>
    private weak var anchor: NSStatusBarButton?
    private var anchorObservers: [NSObjectProtocol] = []
    private var fittedScreenSize: NSSize?
    private var globalClick: Any?
    private var localMonitor: Any?
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(dashboard: NSHostingController<Dashboard>) {
        self.dashboard = dashboard
        footer = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "QuotaBar"
        level = .statusBar
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let surface = NSVisualEffectView()
        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 18
        surface.layer?.cornerCurve = .circular
        surface.layer?.masksToBounds = true
        // Mask the material itself as well as its content. A layer-only clip can leave
        // the window's native backdrop and shadow with rectangular corners.
        let mask = NSImage(size: NSSize(width: 37, height: 37), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        mask.resizingMode = .stretch
        surface.maskImage = mask

        let container = NSViewController()
        container.view = surface
        container.addChild(dashboard)
        surface.addSubview(body)
        surface.addSubview(footer)
        body.addSubview(dashboard.view)
        contentViewController = container
    }

    /// The primary dashboard remains the mounted page model and keeps its view/controller identity.
    /// The Settings controls stay in one native host. Hidden hosts do not enter fitting or event routing.
    func presentPage(_ model: Dashboard) {
        guard model.page == .settings else {
            hideSettings()
            dashboard.rootView = model
            return
        }
        let renderer: NSHostingController<Dashboard>
        if let settingsDashboard {
            renderer = settingsDashboard
            renderer.rootView = model
        } else {
            renderer = NSHostingController(rootView: model)
            renderer.sizingOptions = []
            settingsDashboard = renderer
            contentViewController?.addChild(renderer)
        }
        if renderer.view.superview == nil {
            body.addSubview(renderer.view, positioned: .above, relativeTo: dashboard.view)
        }
        renderer.view.isHidden = false
        var page = model
        page.hostedSettingsSize = renderer.view.bounds.size
        dashboard.rootView = page
    }

    private func hideSettings() {
        guard let renderer = settingsDashboard, !renderer.view.isHidden else { return }
        if let responder = firstResponder as? NSView, responder.isDescendant(of: renderer.view) {
            makeFirstResponder(nil)
        }
        renderer.view.isHidden = true
        renderer.view.removeFromSuperview()
        renderer.rootView.discardHiddenSettingsData()
    }

    @MainActor struct AnchorGeometry {
        let window: NSWindow
        let buttonRect: NSRect
        let limits: NSRect

        init?(_ button: NSStatusBarButton) {
            guard let window = button.window, let screen = window.screen else { return nil }
            self.window = window
            buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
            limits = screen.visibleFrame.insetBy(dx: 4, dy: 4)
        }
    }

    func show(under button: NSStatusBarButton, fallback: AnchorGeometry? = nil) {
        // Updating the badge can briefly detach its screen after AppKit has delivered the click.
        guard let geometry = AnchorGeometry(button) ?? fallback else {
            if !isVisible { dashboard.rootView.isPresented = false }
            return
        }
        if !dashboard.rootView.isPresented { dashboard.rootView.isPresented = true }
        dashboard.view.isHidden = false
        stopTrackingAnchor()
        anchor = button
        fitToDashboard(at: geometry)
        makeKeyAndOrderFront(nil)
        button.highlight(true)
        installEventMonitors()
        let events: [(Notification.Name, AnyObject)] = [
            (NSWindow.didMoveNotification, geometry.window), (NSWindow.didResizeNotification, geometry.window),
            (NSWindow.didChangeScreenNotification, geometry.window),
            (NSApplication.didChangeScreenParametersNotification, NSApp),
        ]
        for (name, object) in events {
            let token = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.anchorGeometryChanged() }
            }
            anchorObservers.append(token)
        }
    }

    private func anchorGeometryChanged() {
        guard isVisible, let anchor, let geometry = AnchorGeometry(anchor) else { return }
        if fittedScreenSize != geometry.limits.size {
            fitToDashboard(at: geometry)
        } else {
            place(size: frame.size, at: geometry)
        }
    }

    func fitToDashboard() {
        guard let anchor, let geometry = AnchorGeometry(anchor) else { return }
        fitToDashboard(at: geometry)
    }

    private func fitToDashboard(at geometry: AnchorGeometry) {
        let limits = geometry.limits
        dashboard.view.layoutSubtreeIfNeeded()
        let showsFooter = dashboard.rootView.page == .usage
        let renderer = dashboard.rootView.hostedSettingsSize == nil ? dashboard : settingsDashboard ?? dashboard
        // Give Settings the screen height so it can compact its controls within the same column.
        let proposedHeight = renderer.rootView.page == .settings ? limits.height : CGFloat.greatestFiniteMagnitude
        let size = renderer.sizeThatFits(in: CGSize(width: limits.width, height: proposedHeight))
        if renderer !== dashboard, dashboard.rootView.hostedSettingsSize != size {
            dashboard.rootView.hostedSettingsSize = size
        }
        let width = min(ceil(size.width), limits.width)
        if showsFooter {
            footer.rootView = AnyView(dashboard.rootView.footerControls)
        } else if !footer.isHidden {
            footer.rootView = AnyView(EmptyView())
        }
        footer.isHidden = !showsFooter
        let footerHeight = showsFooter ? ceil(footer.fittingSize.height) : 0
        let bodyHeight = ceil(size.height)
        let widthScale = min(1, width / max(1, size.width))
        let height = min(ceil(bodyHeight * widthScale) + footerHeight, limits.height)
        guard width > 0, height > 0 else { return }
        fittedScreenSize = limits.size
        place(size: NSSize(width: width, height: height), at: geometry)
        footer.frame = NSRect(x: 0, y: 0, width: width, height: footerHeight)
        let availableHeight = max(0, height - footerHeight)
        let scale = min(widthScale, availableHeight / max(1, bodyHeight))
        // Scale the rendered SwiftUI content, keeping AppKit's event coordinates in window points.
        // Scaling an ancestor's bounds leaves hosted control frames and pointer routing out of sync.
        if renderer.rootView.contentScale != scale { renderer.rootView.contentScale = scale }
        body.frame = NSRect(x: 0, y: footerHeight, width: width, height: availableHeight)
        if showsFooter {
            // Usage exposes its full intrinsic height even when the screen constrains its viewport.
            dashboard.view.frame = NSRect(x: 0, y: (availableHeight - bodyHeight) / 2, width: width, height: bodyHeight)
        } else {
            dashboard.view.frame = body.bounds
        }
        if renderer !== dashboard { renderer.view.frame = dashboard.view.frame }
    }

    private func place(size: NSSize, at geometry: AnchorGeometry) {
        let limits = geometry.limits
        let buttonRect = geometry.buttonRect
        let x = max(limits.minX, min(buttonRect.midX - size.width / 2, limits.maxX - size.width))
        let y = max(limits.minY, min(buttonRect.minY, limits.maxY) - size.height)
        let target = NSRect(origin: NSPoint(x: x, y: y), size: size)
        if frame != target {
            setFrame(target, display: true)
            invalidateShadow()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if let parent = dashboard.rootView.page.parent {
            dashboard.rootView.selectPage(parent)
        } else {
            dismiss()
        }
    }

    func dismiss() {
        stopTrackingAnchor()
        guard isVisible else { return }
        // AppKit can retain a closing animation and its rendered contents when this panel reopens.
        let openingAnimation = animationBehavior
        animationBehavior = .none
        orderOut(nil)
        animationBehavior = openingAnimation
        hideSettings()
        if dashboard.rootView.hostedSettingsSize != nil { dashboard.rootView.discardHiddenSettingsData() }
        // Retain a previously opened Usage page with its timers and actions suspended.
        var inactive = dashboard.rootView
        inactive.isPresented = false
        inactive.retainsClosedUsage = inactive.page == .usage
        dashboard.view.isHidden = true
        dashboard.rootView = inactive
        footer.rootView = AnyView(EmptyView())
        onDismiss?()
    }

    private func stopTrackingAnchor() {
        for observer in anchorObservers { NotificationCenter.default.removeObserver(observer) }
        anchorObservers.removeAll()
        if let globalClick { NSEvent.removeMonitor(globalClick) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalClick = nil
        localMonitor = nil
        anchor?.highlight(false)
        anchor = nil
    }

    override func close() {
        dismiss()
        super.close()
    }

    private func installEventMonitors() {
        let buttons: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClick = NSEvent.addGlobalMonitorForEvents(matching: buttons) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let button = self.anchor, let window = button.window else { return }
                let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
                if !rect.contains(NSEvent.mouseLocation) { self.dismiss() }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: buttons.union(.keyDown)) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleLocalEvent(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func handleLocalEvent(_ event: NSEvent) -> Bool {
        if event.type == .keyDown {
            guard event.window === self || (event.window == nil && isKeyWindow) else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "r":
                    if !event.isARepeat && dashboard.rootView.canRefresh { dashboard.rootView.refresh() }
                    return true
                case "q":
                    if !event.isARepeat { dashboard.rootView.quit() }
                    return true
                default: return false
                }
            }
            guard event.charactersIgnoringModifiers == "\u{1b}", modifiers.isEmpty else { return false }
            if !event.isARepeat { cancelOperation(nil) }
            return true
        }
        if let target = event.window, target !== self, target !== anchor?.window,
            target.parent !== self, target.level.rawValue < NSWindow.Level.popUpMenu.rawValue
        {
            dismiss()
        }
        return false
    }
}
