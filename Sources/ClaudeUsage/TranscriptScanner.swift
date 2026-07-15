import Foundation

/// One assistant turn's token usage, attributed to a project/session/model.
struct TranscriptEvent: Sendable, Equatable {
    let timestamp: Date
    let projectSlug: String
    let cwd: String?
    let sessionId: String
    let requestId: String?
    let messageId: String?
    let model: String
    let tokens: TokenCounts
    /// Uniqueness fallback used only when both `requestId` and `messageId`
    /// are absent, so such events never spuriously dedupe against each
    /// other. Defaults to a fresh UUID at construction time.
    private let fallbackID: String

    init(
        timestamp: Date, projectSlug: String, cwd: String?, sessionId: String,
        requestId: String?, messageId: String?, model: String, tokens: TokenCounts,
        fallbackID: String = UUID().uuidString
    ) {
        self.timestamp = timestamp
        self.projectSlug = projectSlug
        self.cwd = cwd
        self.sessionId = sessionId
        self.requestId = requestId
        self.messageId = messageId
        self.model = model
        self.tokens = tokens
        self.fallbackID = fallbackID
    }

    var modelClass: ModelClass { ModelClass.classify(model) }

    /// `requestId` ?? `"sid:mid"` ?? a fallback that never dedups.
    var dedupKey: String {
        if let requestId, !requestId.isEmpty { return "rid:\(requestId)" }
        if let messageId, !messageId.isEmpty { return "sid:\(sessionId):mid:\(messageId)" }
        return "sid:\(sessionId):ord:\(fallbackID)"
    }
}

/// Incrementally scans `*.jsonl` transcript files under a root directory
/// (`~/.claude/projects` in production), extracting deduped assistant-usage
/// events and session titles. Off the main actor; safe to call repeatedly —
/// each call only reads bytes appended since the last scan of each file.
actor TranscriptScanner {
    struct ScanOutput: Sendable {
        let events: [TranscriptEvent]
        let titles: [String: ScanState.SessionTitle]
    }

    private let root: URL
    private let appSupportDir: URL

    init(root: URL, appSupportDir: URL) {
        self.root = root
        self.appSupportDir = appSupportDir
    }

    /// Incrementally scans all `*.jsonl` files under `root` whose mtime is at
    /// or after `horizonStart`, reading only appended bytes and deduping by
    /// `TranscriptEvent.dedupKey` (last line wins). Persists `ScanState` +
    /// `EventDigest` to `appSupportDir`. Returns the full deduped event set
    /// with `timestamp >= horizonStart`, plus the accumulated title cache.
    func scan(horizonStart: Date, now: Date) async -> ScanOutput {
        var state = ScanStore.loadState(dir: appSupportDir)
        let digest = ScanStore.loadDigest(dir: appSupportDir)
        let horizonEpoch = horizonStart.timeIntervalSince1970

        var eventMap: [String: TranscriptEvent] = [:]
        if let digest {
            for stored in digest.events where stored.ts >= horizonEpoch {
                let event = Self.event(from: stored)
                eventMap[event.dedupKey] = event
            }
        }

        var titles = state.titles
        let fm = FileManager.default
        let files = Self.enumerateJSONLFiles(root: root)

        for path in files {
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtimeDate = attrs[.modificationDate] as? Date,
                  let sizeNum = (attrs[.size] as? NSNumber)?.intValue else { continue }
            // mtime filter: skip without opening files untouched since the horizon.
            if mtimeDate < horizonStart { continue }
            let mtime = mtimeDate.timeIntervalSince1970
            let currentSize = sizeNum

            let existingRecord = state.files[path] ?? FileScanRecord(size: 0, mtime: 0, offset: 0)
            var startOffset = existingRecord.offset
            // Dedup keys previously attributed to this file (so we can purge
            // them from eventMap if the file is truncated/replaced — the
            // digest is a flat, file-agnostic map, so without this a file
            // that got rewritten with different content would leave its old
            // events as permanent ghosts).
            var fileKeys = Set(state.fileEvents[path] ?? [])
            if currentSize < existingRecord.size || existingRecord.offset > currentSize {
                // Truncation/replacement guard: file shrank or our offset is
                // now past EOF — purge this file's previously-seen events and
                // rescan from the top.
                for key in fileKeys { eventMap.removeValue(forKey: key) }
                fileKeys.removeAll()
                startOffset = 0
            } else if currentSize == existingRecord.offset && mtime == existingRecord.mtime {
                // Nothing appended since last scan.
                state.files[path] = FileScanRecord(size: currentSize, mtime: mtime, offset: existingRecord.offset)
                continue
            }

            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            handle.seek(toFileOffset: UInt64(startOffset))
            let reader = GrowableLineReader(handle: handle)
            let slug = Self.projectSlug(forPath: path, root: root)

            var offset = startOffset
            while let (lineData, consumed) = reader.nextLine() {
                offset += consumed
                guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
                Self.process(line: line, slug: slug, titles: &titles, eventMap: &eventMap, fileKeys: &fileKeys)
            }
            try? handle.close()

            state.files[path] = FileScanRecord(size: currentSize, mtime: mtime, offset: offset)
            state.fileEvents[path] = Array(fileKeys)
        }

        state.titles = titles

        let events = eventMap.values.filter { $0.timestamp.timeIntervalSince1970 >= horizonEpoch }
        let newDigest = EventDigest(horizonStart: horizonEpoch, events: events.map(Self.storedEvent(from:)))

        ScanStore.saveState(state, dir: appSupportDir)
        ScanStore.saveDigest(newDigest, dir: appSupportDir)

        return ScanOutput(events: Array(events), titles: titles)
    }

    // MARK: - Line processing

    /// Quick-rejects lines that can't possibly matter (progress/system/huge
    /// tool-output blobs) before paying for a JSON decode: a line is only
    /// decoded if it could be an assistant usage line, an ai-title line, or a
    /// user-message line (the three types we ever extract anything from).
    private static func process(
        line: String, slug: String,
        titles: inout [String: ScanState.SessionTitle],
        eventMap: inout [String: TranscriptEvent],
        fileKeys: inout Set<String>
    ) {
        let hasUsage = line.contains("\"usage\"")
        let hasAiTitle = line.contains("ai-title")
        let hasUserType = line.contains("\"type\":\"user\"") || line.contains("\"type\": \"user\"")
        guard hasUsage || hasAiTitle || hasUserType else { return }

        guard let data = line.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawTranscriptLine.self, from: data) else { return }

        switch raw.type {
        case "assistant":
            guard hasUsage,
                  let message = raw.message,
                  let usage = message.usage,
                  let tsString = raw.timestamp,
                  let ts = UsageFormat.parseResetsAt(tsString),
                  let sessionId = raw.sessionId else { return }
            let model = message.model ?? ""
            guard ModelClass.classify(model) != .synthetic else { return }
            let tokens = TokenCounts(
                input: usage.input_tokens ?? 0,
                output: usage.output_tokens ?? 0,
                cacheCreation: usage.cache_creation_input_tokens ?? 0,
                cacheRead: usage.cache_read_input_tokens ?? 0
            )
            let event = TranscriptEvent(
                timestamp: ts, projectSlug: slug, cwd: raw.cwd, sessionId: sessionId,
                requestId: raw.requestId, messageId: message.id, model: model, tokens: tokens
            )
            eventMap[event.dedupKey] = event
            fileKeys.insert(event.dedupKey)

        case "ai-title":
            guard let aiTitle = raw.aiTitle, !aiTitle.isEmpty, let sessionId = raw.sessionId else { return }
            titles[sessionId] = ScanState.SessionTitle(title: aiTitle, source: "aiTitle")

        case "user":
            guard raw.isSidechain != true, let sessionId = raw.sessionId else { return }
            // Never overwrite an existing title (aiTitle wins outright; and
            // only the *first* user message should ever seed a fallback).
            guard titles[sessionId] == nil else { return }
            guard let text = raw.message?.content?.firstText, !text.isEmpty else { return }
            titles[sessionId] = ScanState.SessionTitle(title: Self.truncate(text, 80), source: "userMessage")

        default:
            return
        }
    }

    // MARK: - Helpers

    private static func truncate(_ s: String, _ limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "…"
    }

    /// Recursively enumerates every file under `root` ending in `.jsonl`,
    /// including `<sid>/subagents/**` and `.../workflows/**` — the strict
    /// extension filter naturally excludes `workflows/scripts/*.js`.
    private static func enumerateJSONLFiles(root: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            result.append(url.path)
        }
        return result
    }

    /// The project-dir name — the path component directly under `root`.
    /// Resolves symlinks on both sides before stripping the prefix: `root`
    /// (e.g. macOS's `/var/...` temp dir) and paths returned by
    /// `FileManager.enumerator` can disagree on `/var` vs. `/private/var`
    /// otherwise, throwing off a plain string-prefix strip.
    private static func projectSlug(forPath path: String, root: URL) -> String {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        var relative = resolvedPath
        if relative.hasPrefix(rootPath) {
            relative = String(relative.dropFirst(rootPath.count))
        }
        let comps = relative.split(separator: "/").map(String.init)
        return comps.first ?? ""
    }

    private static func event(from stored: EventDigest.StoredEvent) -> TranscriptEvent {
        TranscriptEvent(
            timestamp: Date(timeIntervalSince1970: stored.ts),
            projectSlug: stored.slug,
            cwd: stored.cwd,
            sessionId: stored.sid,
            requestId: stored.rid,
            messageId: stored.mid,
            model: stored.model,
            tokens: TokenCounts(input: stored.in, output: stored.out, cacheCreation: stored.cc, cacheRead: stored.cr),
            // Deterministic reconstruction so a digest round-trip doesn't
            // spuriously "un-dedupe" an event that had neither rid nor mid.
            fallbackID: stored.mid ?? stored.rid ?? "\(stored.sid):\(stored.ts)"
        )
    }

    private static func storedEvent(from event: TranscriptEvent) -> EventDigest.StoredEvent {
        EventDigest.StoredEvent(
            ts: event.timestamp.timeIntervalSince1970,
            slug: event.projectSlug,
            cwd: event.cwd,
            sid: event.sessionId,
            rid: event.requestId,
            mid: event.messageId,
            model: event.model,
            in: event.tokens.input,
            out: event.tokens.output,
            cc: event.tokens.cacheCreation,
            cr: event.tokens.cacheRead
        )
    }
}

// MARK: - Growable-buffer line reader

/// Reads complete newline-terminated lines from a `FileHandle` already
/// positioned at the desired offset, using a growable in-memory buffer so a
/// single very large line (observed up to ~600 KB for large tool-result
/// blobs) is never truncated mid-line. Any trailing partial line at EOF (a
/// write-in-progress) is left unconsumed — the caller's offset simply stops
/// before it, so the next scan resumes from the start of that partial line.
private final class GrowableLineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private let chunkSize = 64 * 1024

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// Returns `(lineBytes, consumedByteCount)` for the next complete line
    /// (consumed count includes the trailing `\n`), or nil at EOF.
    func nextLine() -> (Data, Int)? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newlineIndex]
                let consumed = buffer.distance(from: buffer.startIndex, to: newlineIndex) + 1
                let result = Data(line)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                return (result, consumed)
            }
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }
}

// MARK: - Minimal decode target

private struct RawTranscriptLine: Decodable {
    let type: String?
    let timestamp: String?
    let sessionId: String?
    let cwd: String?
    let requestId: String?
    let isSidechain: Bool?
    let aiTitle: String?
    let message: RawMessage?

    struct RawMessage: Decodable {
        let id: String?
        let model: String?
        let usage: RawUsage?
        let content: RawContent?
    }

    struct RawUsage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
    }

    /// `message.content` is a `String` for simple turns, or an array of typed
    /// parts (`{"type":"text","text":"..."}`, tool_use, tool_result, …) for
    /// richer ones.
    enum RawContent: Decodable {
        case text(String)
        case parts([Part])

        struct Part: Decodable {
            let type: String?
            let text: String?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) {
                self = .text(s)
            } else if let parts = try? container.decode([Part].self) {
                self = .parts(parts)
            } else {
                self = .parts([])
            }
        }

        var firstText: String? {
            switch self {
            case .text(let s): return s
            case .parts(let ps): return ps.first(where: { $0.text != nil })?.text
            }
        }
    }
}
