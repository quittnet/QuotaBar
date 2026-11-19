import AppKit
import SwiftUI

@MainActor
final class DropdownPanel: NSPanel {
    private let dashboard: NSHostingController<Dashboard>
    private let scroll = NSScrollView()
    private let footer: NSHostingView<AnyView>
    private weak var anchor: NSStatusBarButton?
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
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        surface.addSubview(scroll)
        surface.addSubview(footer)
        scroll.documentView = dashboard.view
        contentViewController = container
    }

    func show(under button: NSStatusBarButton) {
        guard button.window?.screen != nil else { return }
        anchor = button
        fitToDashboard()
        makeKeyAndOrderFront(nil)
        button.highlight(true)
        installEventMonitors()
    }

    func fitToDashboard() {
        guard let button = anchor, let window = button.window, let screen = window.screen else { return }
        let limits = screen.visibleFrame.insetBy(dx: 4, dy: 4)
        dashboard.view.layoutSubtreeIfNeeded()
        let size = dashboard.sizeThatFits(in: CGSize(width: limits.width, height: .greatestFiniteMagnitude))
        let width = min(ceil(size.width), limits.width)
        footer.rootView = AnyView(dashboard.rootView.footerControls)
        let footerHeight = ceil(footer.fittingSize.height)
        let height = min(ceil(size.height) + footerHeight, limits.height)
        guard width > 0, height > 0 else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let x = max(limits.minX, min(buttonRect.midX - width / 2, limits.maxX - width))
        let y = max(limits.minY, min(buttonRect.minY, limits.maxY) - height)
        let target = NSRect(x: x, y: y, width: width, height: height)
        if frame != target {
            setFrame(target, display: true)
            invalidateShadow()
        }
        footer.frame = NSRect(x: 0, y: 0, width: width, height: footerHeight)
        scroll.frame = NSRect(x: 0, y: footerHeight, width: width, height: max(0, height - footerHeight))
        dashboard.view.setFrameSize(NSSize(width: width, height: ceil(size.height)))
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    func dismiss() {
        if let globalClick { NSEvent.removeMonitor(globalClick) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalClick = nil
        localMonitor = nil
        guard isVisible else { return }
        orderOut(nil)
        footer.rootView = AnyView(EmptyView())
        anchor?.highlight(false)
        anchor = nil
        onDismiss?()
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
            dismiss()
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
