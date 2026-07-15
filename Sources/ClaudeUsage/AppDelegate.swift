import AppKit
import Combine
import SwiftUI

/// Borderless panel that can still become key, so the SwiftUI controls inside
/// (Refresh / Quit) receive clicks without activating the (accessory) app.
private final class PopoverPanel: NSPanel {
    /// Invoked on Escape (or Cmd+.) — a borderless panel has no close button,
    /// so this is the keyboard dismissal path. Set by AppDelegate to closePanel().
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    // Esc reaches the window as cancelOperation(_:) via the responder chain
    // when no view inside claims it.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // Fallback: if a responder swallows the cancel selector but lets the raw
    // key event bubble, still treat Esc (keyCode 53) as dismiss instead of
    // letting NSWindow beep on the unhandled key.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let updateChecker = UpdateChecker()
    private let breakdownService = UsageBreakdownService.live()
    private lazy var breakdownController = BreakdownWindowController(service: breakdownService, store: store)
    private var statusItem: NSStatusItem!
    private var panel: PopoverPanel!
    private var hostingController: NSHostingController<PopoverView>!
    private var cancellables: Set<AnyCancellable> = []
    private var sizeObservation: NSKeyValueObservation?
    private var clickMonitor: Any?

    // Visual + motion tuning.
    private let panelWidth: CGFloat = 280
    private let cornerRadius: CGFloat = 12
    private let tintOpacity: CGFloat = 0.7
    private let slideDistance: CGFloat = 8
    private let openDuration: TimeInterval = 0.16
    private let closeDuration: TimeInterval = 0.12

    nonisolated override init() { super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        buildPanel()

        // objectWillChange fires before the @Published value is written, so
        // hop to the next runloop tick to read the post-write state.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemTitle() }
            .store(in: &cancellables)

        updateStatusItemTitle()

        // Accessory apps have no main menu, so Cmd+V/A/C/X have no
        // responder. Wire up a minimal Edit menu so paste works in TextFields.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: Panel construction

    private func buildPanel() {
        hostingController = NSHostingController(rootView: PopoverView(
            store: store, updateChecker: updateChecker,
            onShowBreakdown: { [weak self] in self?.breakdownController.show() }
        ))
        // Report the SwiftUI ideal size as preferredContentSize so we can size
        // the panel to the content (and resize-follow when it changes).
        hostingController.sizingOptions = [.preferredContentSize]

        // Rounded, vibrant background to replace the popover chrome we lose by
        // going borderless. `.menu` is the most opaque public material, but the
        // system Control Center panels (Wi-Fi / Sound) are more opaque/white
        // still, so we wash the blur with a semi-opaque adaptive tint below.
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        // Round the blur via a resizable mask image — the documented way for
        // NSVisualEffectView. (layer.cornerRadius on it is unreliable: square
        // corners poke out during animation/resize.)
        effect.maskImage = Self.roundedMaskImage(radius: cornerRadius)

        // Opacity wash: in light mode a window-background fill over the blur
        // lifts it toward the system panels' solidity. In dark mode the blur is
        // already dark enough, so the tint is clear (off). Dynamic color, so it
        // toggles automatically on appearance change. `tintOpacity` is the knob.
        let opacity = tintOpacity
        let tint = NSBox()
        tint.boxType = .custom
        tint.titlePosition = .noTitle
        tint.borderWidth = 0
        // Round the box to match the container. Relying on the effect view's
        // masksToBounds to clip this subview is unreliable (square corners pop
        // out during the open/resize animation), so the box rounds itself.
        tint.cornerRadius = cornerRadius
        tint.fillColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .clear
                : NSColor.windowBackgroundColor.withAlphaComponent(opacity)
        }
        tint.translatesAutoresizingMaskIntoConstraints = false

        let host = hostingController.view
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(tint)
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            tint.topAnchor.constraint(equalTo: effect.topAnchor),
            tint.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        panel = PopoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none           // we animate manually
        panel.isReleasedWhenClosed = false
        // .moveToActiveSpace (not .canJoinAllSpaces) so the panel follows the
        // user to whichever Space they're currently viewing. With
        // .canJoinAllSpaces, AppKit remembers the Space the panel was last
        // visible on and re-shows it there after orderOut, which puts the
        // popover off-screen when invoked from any non-primary Space.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        panel.onCancel = { [weak self] in self?.closePanel() }
    }

    /// A resizable rounded-rect mask: the center stretches and the corners stay
    /// fixed (cap insets), so one image rounds the effect view at any size.
    private static func roundedMaskImage(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: Show / hide

    @objc private func togglePanel(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    // MARK: Right-click context menu

    /// Right-click on the status item: a native NSMenu (so it picks up the
    /// system light/dark appearance automatically) with the same invert-colors
    /// toggle and Quit that live in the popover's overflow menu. Assigned to
    /// `statusItem.menu` only for the duration of the click — a permanently
    /// assigned menu would hijack left-clicks too — and detached in
    /// `menuDidClose` so the next left-click toggles the panel again.
    private func showContextMenu() {
        closePanel()

        let menu = NSMenu()
        let invert = NSMenuItem(
            title: "Invert Menu Bar Colors",
            action: #selector(toggleInvertColors(_:)),
            keyEquivalent: ""
        )
        invert.target = self
        invert.state = store.invertMenubarColors ? .on : .off
        menu.addItem(invert)
        menu.addItem(.separator())
        // A local selector (not NSApplication.terminate(_:)) and no key
        // equivalent: macOS auto-decorates well-known selectors with a system
        // icon, and a "q" equivalent renders a ⌘Q hint — we want neither.
        let quit = NSMenuItem(
            title: "Quit ClaudeUsage",
            action: #selector(quitApp(_:)),
            keyEquivalent: ""
        )
        quit.target = self
        menu.addItem(quit)
        menu.delegate = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    @objc private func toggleInvertColors(_ sender: Any?) {
        store.invertMenubarColors.toggle()
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func showPanel() {
        // Size to the SwiftUI content's intrinsic size.
        hostingController.view.layoutSubtreeIfNeeded()
        var size = hostingController.view.fittingSize
        if size.width < 1 || size.height < 1 { size = NSSize(width: panelWidth, height: 200) }
        // On the very first click after launch the hosting view can report a
        // degenerate fittingSize before SwiftUI's initial layout settles; an
        // over-tall panel drives the origin math (topEdge - height) below the
        // screen. Clamp to the visible frame — followContentSize corrects the
        // size once the real preferredContentSize lands.
        if let visible = (statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame,
           size.width > visible.width || size.height > visible.height {
            NSLog("ClaudeUsage: clamping degenerate panel fittingSize %@ to screen %@",
                  NSStringFromSize(size), NSStringFromSize(visible.size))
            size.width = min(size.width, visible.width)
            size.height = min(size.height, visible.height)
        }
        panel.setContentSize(size)

        guard let finalOrigin = panelOrigin(for: panel.frame.size) else {
            // Status-item geometry unresolved (seen on the first click right
            // after launch). Never fall through to the panel's default frame —
            // its (0,0) origin puts the popover at the bottom-left corner.
            NSLog("ClaudeUsage: panelOrigin unresolved (button=%d window=%d screen=%d) — using top-right fallback",
                  statusItem.button != nil ? 1 : 0,
                  statusItem.button?.window != nil ? 1 : 0,
                  statusItem.button?.window?.screen != nil ? 1 : 0)
            if let visible = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(
                    x: visible.maxX - panel.frame.width - 8,
                    y: visible.maxY - panel.frame.height
                ))
            }
            panel.makeKeyAndOrderFront(nil)
            clearInitialFocus()
            return
        }

        // Start tucked up under the menu bar and transparent, then slide down
        // and fade in. The fade masks the few px that briefly overlap the bar.
        panel.setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y + slideDistance))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        clearInitialFocus()
        statusItem.button?.highlight(true)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = openDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(finalOrigin)
            panel.animator().alphaValue = 1
        }

        // When a refresh adds/removes a row the content height changes; keep the
        // panel pinned just under the menu bar instead of drifting.
        sizeObservation = hostingController.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.followContentSize() }
        }

        // Transient dismissal: a mouse-down anywhere outside this app (another
        // app, the desktop, other menu-bar items) closes the panel. Clicks
        // inside the panel and on our own status item are local events and
        // don't reach a global monitor, so they don't double-toggle.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    /// Drop the panel's first responder right after it becomes key. The
    /// connected popover has no text entry, so an auto-focused control just
    /// paints an accent-colored focus ring (the "nagging green highlight" on
    /// the gear/first control). Clearing focus removes the ring without
    /// affecting clicks; we do it now and again next runloop tick because
    /// SwiftUI re-seats first responder as its hierarchy settles. Skipped when
    /// disconnected so ConnectAccountView's paste field keeps its focus.
    private func clearInitialFocus() {
        guard !store.needsConnection else { return }
        panel.makeFirstResponder(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.store.needsConnection else { return }
            self.panel.makeFirstResponder(nil)
        }
    }

    private func followContentSize() {
        guard panel.isVisible else { return }
        let size = hostingController.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }
        panel.setContentSize(size)
        if let origin = panelOrigin(for: panel.frame.size) {
            panel.setFrameOrigin(origin)
        }
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        sizeObservation?.invalidate(); sizeObservation = nil
        statusItem.button?.highlight(false)

        let up = NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y + slideDistance)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = closeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrameOrigin(up)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Runs on the main thread once the animation finishes.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }

    /// Final origin: top edge just below the menu bar, centered under the status
    /// item, clamped on-screen. Screen-coordinate math is flip-independent and
    /// sidesteps the Tahoe anchor-rect mis-placement that plagued NSPopover.
    private func panelOrigin(for size: NSSize) -> NSPoint? {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen
        else { return nil }

        let buttonInScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let topEdge = screen.visibleFrame.maxY          // first point below the menu bar
        var origin = NSPoint(x: buttonInScreen.midX - size.width / 2, y: topEdge - size.height)

        let minX = screen.visibleFrame.minX
        let maxX = screen.visibleFrame.maxX - size.width
        origin.x = min(max(origin.x, minX), maxX)
        return origin
    }

    // MARK: Menubar title

    private func updateStatusItemTitle() {
        guard let button = statusItem.button else { return }
        let label = store.menubarLabel
        let baseFont = NSFont.menuBarFont(ofSize: 0)
        let font = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .heavy)

        if label.filled {
            // Solid color block, black text. Drawn as a (non-template) image so
            // we get a filled background the menubar can't give an attributed
            // title. The dynamic fill resolves per-appearance at draw time.
            button.image = Self.filledLabelImage(text: label.text, fill: label.color, font: font)
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            button.image = nil
            button.imagePosition = .noImage
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: label.color,
                .font: font,
            ]
            button.attributedTitle = NSAttributedString(string: label.text, attributes: attrs)
        }
    }

    /// A solid rounded color block with black, centered text — the menubar
    /// "pill". Sized to the text plus small padding; redrawn on demand so the
    /// dynamic `fill` re-resolves when the system appearance changes.
    private static func filledLabelImage(text: String, fill: NSColor, font: NSFont) -> NSImage {
        let padX: CGFloat = 5
        let padY: CGFloat = 1.5
        let radius: CGFloat = 3.5

        let measureAttrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: measureAttrs)
        let width = ceil(textSize.width + padX * 2)
        let height = ceil(textSize.height + padY * 2)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).setClip()
            fill.setFill()
            rect.fill()

            // Black reads best on the green/amber/orange stops, but goes muddy
            // on the red/dark-red end — switch to white once the block is dark.
            let textColor = Self.contrastingText(on: fill)

            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: para,
            ]
            let ts = (text as NSString).size(withAttributes: attrs)
            let textRect = NSRect(x: 0, y: (rect.height - ts.height) / 2, width: rect.width, height: ts.height)
            (text as NSString).draw(in: textRect, withAttributes: attrs)
            return true
        }
        image.isTemplate = false   // keep our colors; don't let the bar tint it
        return image
    }

    /// Black or white, whichever has more contrast against `fill`. Resolved
    /// against the current drawing appearance (the fill is a dynamic color) and
    /// keyed off perceived luminance, so the red/dark-red end gets white text.
    private static func contrastingText(on fill: NSColor) -> NSColor {
        guard let rgb = fill.usingColorSpace(.sRGB) else { return .black }
        // Rec. 601 luma — cheap and good enough for a "is this dark?" test.
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luma < 0.55 ? .white : .black
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Detach the transient right-click menu so the next left-click goes back
    /// to toggling the panel instead of re-opening the menu.
    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }
}
