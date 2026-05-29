import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellables: Set<AnyCancellable> = []

    nonisolated override init() { super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(store: store)
        )
        popover.contentSize = NSSize(width: 280, height: 200)

        // objectWillChange fires before the @Published value is written, so
        // hop to the next runloop tick to read the post-write state.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemTitle() }
            .store(in: &cancellables)

        updateStatusItemTitle()
    }

    private func updateStatusItemTitle() {
        guard let button = statusItem.button else { return }
        let label = store.menubarLabel
        let baseFont = NSFont.menuBarFont(ofSize: 0)

        // Subtle dark halo lifts the colored text off translucent menubars,
        // especially against bright wallpapers.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 2.0

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: label.color,
            .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .heavy),
            .shadow: shadow,
        ]
        button.attributedTitle = NSAttributedString(string: label.text, attributes: attrs)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }

        // Let AppKit place the popover first…
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        // …then put it exactly where we want it, and keep it there. The popover's
        // height is driven by SwiftUI's intrinsic content, so a refresh that
        // adds/removes a row (loading spinner, rate-limit/error notice, per-model
        // sections) resizes the window. We reposition on every resize, otherwise
        // the one-shot origin goes stale and the growing popover drifts up over
        // the menu bar.
        positionPopover()
        if let popoverWindow = popover.contentViewController?.view.window {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didResizeNotification, object: popoverWindow)
            NotificationCenter.default.addObserver(
                self, selector: #selector(popoverWindowDidResize(_:)),
                name: NSWindow.didResizeNotification, object: popoverWindow)
        }
    }

    @objc private func popoverWindowDidResize(_ note: Notification) {
        guard popover.isShown else { return }
        positionPopover()
    }

    /// Pins the popover just below the menu bar, centered under the status item.
    /// On macOS 26 (Tahoe) the menu bar is taller than the status-item button's
    /// window and AppKit's anchor-rect math mis-places the popover (it ends up
    /// overlapping / above the bar). Working in screen coordinates is
    /// flip-independent and doesn't depend on AppKit honoring preferredEdge.
    private func positionPopover() {
        guard let button = statusItem.button,
              let popoverWindow = popover.contentViewController?.view.window,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen
        else { return }

        let buttonInScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let popoverSize = popoverWindow.frame.size

        // visibleFrame.maxY is the first point below the menu bar.
        let topEdge = screen.visibleFrame.maxY
        var origin = NSPoint(
            x: buttonInScreen.midX - popoverSize.width / 2,
            y: topEdge - popoverSize.height
        )

        // Keep it on-screen horizontally.
        let minX = screen.visibleFrame.minX
        let maxX = screen.visibleFrame.maxX - popoverSize.width
        origin.x = min(max(origin.x, minX), maxX)

        // setFrameOrigin only moves the window (no resize), so this won't loop
        // back through didResize. Skip redundant sets just in case.
        if popoverWindow.frame.origin != origin {
            popoverWindow.setFrameOrigin(origin)
        }
    }
}
