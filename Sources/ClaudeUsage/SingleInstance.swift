import Foundation

/// Ensures only one menubar GUI instance runs at a time.
///
/// macOS only de-dupes `.app` launches that go through LaunchServices (and
/// only with `LSMultipleInstancesProhibited`, which we don't set). Running the
/// executable inside the bundle directly — or `open`ing the app while the
/// LaunchAgent copy is already up — bypasses that entirely and produces a
/// *second* status item in the menubar. A bot that runs `ClaudeUsage` without
/// `--json` hits exactly this: `CLI.parse` returns nil and a full GUI boots.
///
/// So we guard the GUI path ourselves with a POSIX advisory lock (`flock`) on a
/// file in Application Support. The first GUI process to start holds the lock
/// for its lifetime; any later GUI process can't acquire it and bows out. This
/// is independent of how the process was launched (bundle vs. raw binary vs.
/// `open`), which LaunchServices-based checks are not.
///
/// `--json` mode never calls this — it's checked *before* the CLI dispatch in
/// `App.main`, so concurrent headless pollers are unaffected.
enum SingleInstance {
    /// Held for the process lifetime so the lock stays acquired. The kernel
    /// releases the `flock` automatically when the process exits (clean exit,
    /// crash, or kill), so a stale lock can never wedge future launches.
    private static var lockFD: Int32 = -1

    private static var lockFileURL: URL? {
        let fm = FileManager.default
        guard let dir = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("ClaudeUsage", isDirectory: true) else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("instance.lock")
    }

    /// Returns true if this process acquired the single-instance lock (and may
    /// proceed to start the menubar), false if another GUI instance already
    /// holds it. If the lock file can't be opened at all we fail open and
    /// return true — never block the app over a filesystem hiccup.
    static func acquire() -> Bool {
        guard let url = lockFileURL else { return true }

        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        if fd == -1 { return true }

        // LOCK_NB → don't wait; if another instance holds LOCK_EX we get
        // EWOULDBLOCK immediately and exit instead of blocking forever.
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd  // keep the fd (and thus the lock) alive
            return true
        }

        close(fd)
        return false
    }
}
