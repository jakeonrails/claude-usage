// find-popover-window.swift — print the ClaudeUsage popover window's bounds.
//
// Usage: swift find-popover-window.swift <pid>
// Prints: "<windowID> <x> <y> <width> <height>" for the largest on-screen
// window owned by <pid> below the menu-bar layer (the borderless popover panel
// — which, unlike a standard window, never appears in the Accessibility API,
// so we go through CoreGraphics instead). Exits non-zero if none is found
// (e.g. the popover isn't open).

import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write("usage: find-popover-window.swift <pid>\n".data(using: .utf8)!)
    exit(64)
}

guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write("could not read window list\n".data(using: .utf8)!)
    exit(1)
}

var best: (num: Int, rect: CGRect)? = nil
for w in infoList {
    guard let owner = w[kCGWindowOwnerPID as String] as? Int, owner == pid else { continue }
    // The status-item buttons live at the menu-bar layer (25). The popover
    // panel sits at a low layer (~3). Skip the menu-bar-level windows.
    let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
    if layer >= 20 { continue }
    guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
          let num = w[kCGWindowNumber as String] as? Int,
          let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"]
    else { continue }
    let rect = CGRect(x: x, y: y, width: width, height: height)
    if best == nil || rect.width * rect.height > best!.rect.width * best!.rect.height {
        best = (num, rect)
    }
}

guard let (num, r) = best else {
    FileHandle.standardError.write("no popover window found for pid \(pid) (is it open?)\n".data(using: .utf8)!)
    exit(2)
}
print("\(num) \(Int(r.minX)) \(Int(r.minY)) \(Int(r.width)) \(Int(r.height))")
