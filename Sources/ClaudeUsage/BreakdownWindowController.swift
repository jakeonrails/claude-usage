import AppKit
import SwiftUI

/// Owns the "Usage Breakdown" `NSWindow` — a titled, resizable, ordinary
/// window (not the borderless popover panel), lazily built on first `show()`
/// and reused across shows.
@MainActor
final class BreakdownWindowController {
    private let vm: BreakdownViewModel
    private var window: NSWindow?

    init(service: UsageBreakdownService, store: UsageStore) {
        self.vm = BreakdownViewModel(service: service, responseProvider: { [weak store] in
            store?.lastSuccess?.response
        })
    }

    /// Builds the window on first call, then just re-fronts it on later
    /// calls. Always re-runs `onAppear()` so data refreshes on reopen.
    func show() {
        let window = window ?? makeWindow()
        self.window = window

        // Accessory apps aren't active, so without this the window opens
        // behind/unfocused (same gotcha as the update-instructions alert).
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        Task { await vm.onAppear() }
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: BreakdownView(vm: vm))
        let window = KeyCloseableWindow(contentViewController: hosting)
        window.title = "Usage Breakdown"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 460, height: 460))
        window.center()
        return window
    }
}

/// As an accessory app we have no menu bar, so there's no Close menu item to
/// give ⌘W its key equivalent — handle it (and Escape) on the window itself.
private final class KeyCloseableWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // Escape reaches the window as cancelOperation(_:) via the responder chain.
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
