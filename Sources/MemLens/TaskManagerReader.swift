import ApplicationServices
import Foundation

/// Reads the rows of a Chromium browser's own Task Manager window through the Accessibility API.
/// Read-only: it never opens, closes or presses anything. The user opens Window → Task Manager.
enum TaskManagerReader {
    struct Row: Sendable {
        let task: String
        let pid: pid_t?
    }

    enum Failure: Error, Equatable {
        case notTrusted
        case windowNotFound
        case tableNotFound(dumpPath: String?)
        case noPidColumn(dumpPath: String?)
        case timeout
    }

    static let dumpPath = NSHomeDirectory() + "/Library/Logs/MemLens/ax-dump.txt"

    static func isTrusted(prompt: Bool) -> Bool {
        // String key instead of kAXTrustedCheckOptionPrompt: that global is a mutable var under Swift 6.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    /// Runs the blocking AX walk on a GCD thread (not the cooperative pool) with an overall deadline.
    static func read(browserPid: pid_t, livePids: Set<pid_t>) async throws -> [Row] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try readBlocking(browserPid: browserPid, livePids: livePids) })
            }
        }
    }

    // MARK: - Walk

    private struct Deadline {
        let end = Date().addingTimeInterval(6)
        func check() throws { if Date() > end { throw Failure.timeout } }
    }

    private static func readBlocking(browserPid: pid_t, livePids: Set<pid_t>) throws -> [Row] {
        guard isTrusted(prompt: false) else { throw Failure.notTrusted }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        let deadline = Deadline()
        let app = AXUIElementCreateApplication(browserPid)

        // Only windows titled like a task manager are searched, so web content is never walked.
        // A normal browser window can match too (a tab titled "Task Manager - Jira"), so the
        // candidate must also contain a table; otherwise it's skipped and never dumped.
        let candidates = elements(app, kAXWindowsAttribute).filter { w in
            let title = (string(w, kAXTitleAttribute) ?? "").lowercased()
            return title.contains("task manager") || title.contains("pengelola tugas")
        }
        try deadline.check()
        var found: (window: AXUIElement, table: AXUIElement)?
        for window in candidates {
            if let table = try findTable(in: window, deadline: deadline) {
                found = (window, table)
                break
            }
        }
        guard let (window, table) = found else { throw Failure.windowNotFound }

        var rows = elements(table, kAXRowsAttribute)
        if rows.isEmpty {
            rows = elements(table, kAXChildrenAttribute).filter { string($0, kAXRoleAttribute) == kAXRowRole }
        }

        var cells: [[String]] = []
        for row in rows {
            try deadline.check()
            let rowCells = elements(row, kAXChildrenAttribute)
            cells.append(try rowCells.map { try text(of: $0, depth: 2, deadline: deadline) ?? "" })
        }
        guard !cells.isEmpty else { throw Failure.tableNotFound(dumpPath: writeDump(window)) }

        // PID column = the one whose integers are live processes of this browser (headers are localized).
        let columnCount = cells.map(\.count).max() ?? 0
        let pidColumn = (0..<columnCount).max { a, b in
            hits(cells, a, livePids) < hits(cells, b, livePids)
        }
        guard let pidColumn, hits(cells, pidColumn, livePids) > 0 else {
            throw Failure.noPidColumn(dumpPath: writeDump(window))
        }

        // Grouped rows may leave the PID blank after the first row of a process: carry it forward.
        var lastPid: pid_t?
        return cells.compactMap { row in
            guard let task = row.first, !task.isEmpty else { return nil }
            if pidColumn < row.count, let pid = pid_t(row[pidColumn].trimmingCharacters(in: .whitespaces)) {
                lastPid = pid
            }
            return Row(task: task, pid: lastPid)
        }
    }

    private static func hits(_ cells: [[String]], _ column: Int, _ live: Set<pid_t>) -> Int {
        cells.reduce(0) { n, row in
            guard column < row.count, let pid = pid_t(row[column].trimmingCharacters(in: .whitespaces)) else { return n }
            return live.contains(pid) ? n + 1 : n
        }
    }

    private static func findTable(in root: AXUIElement, deadline: Deadline) throws -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 800 {
            try deadline.check()
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = string(element, kAXRoleAttribute)
            if role == kAXTableRole || role == kAXOutlineRole { return element }
            if role == "AXWebArea" || depth >= 10 { continue }
            queue += elements(element, kAXChildrenAttribute).map { ($0, depth + 1) }
        }
        return nil
    }

    // MARK: - AX helpers (CF values are type-checked, never force-cast)

    private static func value(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func string(_ e: AXUIElement, _ name: String) -> String? {
        guard let v = value(e, name) else { return nil }
        if CFGetTypeID(v) == CFStringGetTypeID() { return v as? String }
        if CFGetTypeID(v) == CFNumberGetTypeID() { return (v as? NSNumber)?.stringValue }
        return nil
    }

    private static func elements(_ e: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let v = value(e, name), CFGetTypeID(v) == CFArrayGetTypeID(), let array = v as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? unsafeDowncast(item, to: AXUIElement.self) : nil
        }
    }

    private static func text(of e: AXUIElement, depth: Int, deadline: Deadline) throws -> String? {
        try deadline.check()
        for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = string(e, name)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        }
        guard depth > 0 else { return nil }
        for child in elements(e, kAXChildrenAttribute) {
            if let s = try text(of: child, depth: depth - 1, deadline: deadline) { return s }
        }
        return nil
    }

    // MARK: - Diagnostics

    /// Dumps only the Task Manager window (capped), redacting private-window rows,
    /// so the parser can be adapted to the real tree.
    private static func writeDump(_ window: AXUIElement) -> String? {
        let deadline = Date().addingTimeInterval(3)
        var lines: [String] = []
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        while let (element, depth) = stack.popLast(), lines.count < 600, Date() < deadline {
            let role = string(element, kAXRoleAttribute) ?? "?"
            var label = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
                .compactMap { string(element, $0) }.filter { !$0.isEmpty }.joined(separator: " | ")
            let lower = label.lowercased()
            if ["incognito", "private", "pribadi", "penyamaran"].contains(where: lower.contains) {
                label = "[redacted]"
            }
            lines.append(String(repeating: "  ", count: depth) + role + (label.isEmpty ? "" : "  " + String(label.prefix(80))))
            if role != "AXWebArea", depth < 10 {
                stack += elements(element, kAXChildrenAttribute).reversed().map { ($0, depth + 1) }
            }
        }
        let url = URL(fileURLWithPath: dumpPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dumpPath)
        return dumpPath
    }
}

/// Maps Task Manager rows to AppleScript tabs.
enum TabMatcher {
    /// Row prefixes that are a browser tab. Everything else (Subframe, Prerender, Back/Forward cache,
    /// Background Page, Extension, GPU, Utility, Browser) is not matched to a tab.
    /// English prefixes come from Chromium; the Indonesian ones are best guesses.
    private static let tabPrefixes = ["Tab: ", "Incognito Tab: ", "Private Tab: ", "InPrivate Tab: ", "App: ",
                                      "Tab Pribadi: ", "Tab Penyamaran: "]

    static func normalize(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.properties.generalCategory != .format }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns tab id → (pid, ambiguous).
    static func match(rows: [TaskManagerReader.Row], tabs: [BrowserTab]) -> [String: (pid: pid_t, ambiguous: Bool)] {
        var pidsByTitle: [String: [pid_t]] = [:]
        for row in rows {
            guard let pid = row.pid,
                  let prefix = tabPrefixes.first(where: { row.task.hasPrefix($0) }) else { continue }
            pidsByTitle[normalize(String(row.task.dropFirst(prefix.count))), default: []].append(pid)
        }
        var result: [String: (pid: pid_t, ambiguous: Bool)] = [:]
        let tabsByTitle = Dictionary(grouping: tabs, by: { normalize($0.title) })
        for (title, sameTitleTabs) in tabsByTitle {
            guard let pids = pidsByTitle[title], !pids.isEmpty else { continue }
            // Can't tell which tab is which when the rows point at different processes, or when
            // same-titled tabs and rows don't pair up (one of them asleep): flag instead of guessing.
            let ambiguous = Set(pids).count > 1 || (sameTitleTabs.count > 1 && pids.count != sameTitleTabs.count)
            for (i, tab) in sameTitleTabs.enumerated() where i < pids.count {
                result[tab.id] = (pids[i], ambiguous)
            }
        }
        return result
    }
}
