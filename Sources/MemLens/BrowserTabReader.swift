import AppKit
import Foundation

enum TabReadError: Error, Equatable {
    case notRunning
    case notAuthorized
    case timeout
    case failed(String)
}

/// Lists browser tabs through Apple Events (osascript). Read-only: it never opens, closes or focuses tabs.
enum BrowserTabReader {
    enum Kind: Sendable { case chromium, safari }

    static let supported: [String: Kind] = [
        "com.google.Chrome": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.apple.Safari": .safari,
    ]

    private static let recordSep = Character(UnicodeScalar(30))
    private static let fieldSep = Character(UnicodeScalar(31))

    static func readTabs(bundleID: String) async throws -> [BrowserTab] {
        guard let kind = supported[bundleID] else { return [] }

        // Ask for consent up front: the first Apple Event would otherwise block on the
        // TCC dialog and trip the script timeout while the user is still reading it.
        let status = await Task.detached { permissionStatus(bundleID: bundleID) }.value
        switch status {
        case noErr: break
        case OSStatus(errAEEventNotPermitted): throw TabReadError.notAuthorized
        case OSStatus(procNotFound): throw TabReadError.notRunning
        default: break // unknown → let the script report the real error
        }

        let result = try await runOsascript(script(bundleID: bundleID, kind: kind), timeout: 20)
        try Task.checkCancellation()   // a cancelled run exits with SIGTERM; don't report it as a failure
        guard result.status == 0 else { throw mapError(result.stderr) }
        return parse(result.stdout)
    }

    private static func permissionStatus(bundleID: String) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, true)
    }

    // MARK: - Script

    /// `bundleID` comes only from `supported`, never from user or page input.
    private static func script(bundleID: String, kind: Kind) -> String {
        let windowBody: String
        switch kind {
        case .chromium:
            windowBody = """
                    set theTitles to title of every tab of w
                    set theUrls to URL of every tab of w
                    set activeIdx to active tab index of w
                    set winMode to "normal"
                    try
                        set winMode to mode of w
                    end try
            """
        case .safari:
            windowBody = """
                    set theTitles to name of every tab of w
                    set theUrls to URL of every tab of w
                    set activeIdx to index of current tab of w
                    set winMode to "safari"
            """
        }
        return """
        set recSep to character id 30
        set fldSep to character id 31
        set out to ""
        if application id "\(bundleID)" is running then
            with timeout of 5 seconds
                tell application id "\(bundleID)"
                    set wi to 0
                    repeat with w in windows
                        try
        \(windowBody)
                            set wi to wi + 1
                            repeat with i from 1 to count of theTitles
                                set theUrl to item i of theUrls
                                if theUrl is missing value then set theUrl to ""
                                set theTitle to item i of theTitles
                                if theTitle is missing value then set theTitle to ""
                                set out to out & (wi as text) & fldSep & (i as text) & fldSep & theTitle & fldSep & theUrl & fldSep & ((i = activeIdx) as text) & fldSep & (winMode as text) & recSep
                            end repeat
                        on error errMsg number errNum
                            -- Skip odd windows (Settings, Downloads) but surface a hung browser.
                            if errNum is -1712 then error errMsg number errNum
                        end try
                    end repeat
                end tell
            end timeout
        end if
        return out
        """
    }

    private static func parse(_ output: String) -> [BrowserTab] {
        output.split(separator: recordSep).compactMap { record in
            let f = record.split(separator: fieldSep, omittingEmptySubsequences: false)
            guard f.count == 6, let w = Int(f[0]), let i = Int(f[1]) else { return nil }
            let mode = f[5].trimmingCharacters(in: .whitespacesAndNewlines)
            let isPrivate = mode == "incognito"
            // Safari exposes no private-window flag, so its URLs are never shown.
            let hideURL = isPrivate || mode == "safari"
            return BrowserTab(window: w, index: i, title: String(f[2]),
                              url: hideURL ? "" : String(f[3]),
                              isActive: f[4] == "true", isPrivate: isPrivate)
        }
    }

    private static func mapError(_ stderr: String) -> TabReadError {
        let code = stderr.range(of: #"\((-?\d+)\)"#, options: .regularExpression)
            .flatMap { Int(stderr[$0].dropFirst().dropLast()) }
        switch code {
        case -1743: return .notAuthorized
        case -1712: return .timeout
        case -600: return .notRunning
        default:
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(message.isEmpty ? "osascript failed" : message)
        }
    }

    // MARK: - Process

    private struct RunResult: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var _timedOut = false
        private var _cancelled = false
        var timedOut: Bool { lock.withLock { _timedOut } }
        var cancelled: Bool { lock.withLock { _cancelled } }
        func kill(timeout: Bool) {
            lock.withLock { if timeout { _timedOut = true } else { _cancelled = true } }
            if process.isRunning { process.terminate() }
        }
    }

    private static func runOsascript(_ source: String, timeout: Double) async throws -> RunResult {
        let box = ProcessBox()
        let process = box.process
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RunResult, Error>) in
                // onCancel may already have fired before the process existed.
                if box.cancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: TabReadError.failed(error.localizedDescription))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.kill(timeout: true) }
                // Drain both pipes concurrently so a large tab list can't block osascript on a full pipe.
                DispatchQueue.global().async {
                    let group = DispatchGroup()
                    nonisolated(unsafe) var errData = Data()
                    group.enter()
                    DispatchQueue.global().async {
                        errData = err.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    let outData = out.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    if box.timedOut {
                        cont.resume(throwing: TabReadError.timeout)
                    } else {
                        cont.resume(returning: RunResult(status: process.terminationStatus,
                                                         stdout: String(decoding: outData, as: UTF8.self),
                                                         stderr: String(decoding: errData, as: UTF8.self)))
                    }
                }
            }
        } onCancel: {
            box.kill(timeout: false)
        }
    }
}
