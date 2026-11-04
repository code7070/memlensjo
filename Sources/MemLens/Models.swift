import Foundation

struct ProcSample: Sendable, Identifiable {
    let pid: pid_t
    let startTime: UInt64
    let name: String
    let path: String
    let footprint: UInt64
    /// Chromium/Electron process role from argv (`renderer`, `gpu-process`, `extension`, ...).
    let kind: String?

    var id: String { "\(pid)-\(startTime)" }
}

struct AppGroup: Sendable, Identifiable {
    /// Bundle path for app groups, `proc:<name>` for loose processes. Stable across samples.
    let id: String
    let name: String
    let bundlePath: String?
    let bundleID: String?
    let version: String?
    var footprint: UInt64
    var processes: [ProcSample]
}

struct SystemStats: Sendable {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var appMemory: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
}

struct Snapshot: Sendable {
    let system: SystemStats
    let groups: [AppGroup]
    /// Processes owned by root or other users; their memory needs admin rights to read.
    let unreadableCount: Int
}

struct BrowserTab: Sendable, Identifiable, Equatable {
    let window: Int
    let index: Int
    let title: String
    let url: String
    let isActive: Bool
    let isPrivate: Bool

    var id: String { "\(window)-\(index)" }

    var host: String {
        URL(string: url)?.host() ?? url
    }
}

enum TabState: Equatable {
    case loading
    case loaded([BrowserTab])
    case notRunning
    case notAuthorized
    case failed(String)
}

/// Result of reading the browser's Task Manager. Tabs point at a process by `ProcSample.id`
/// (pid + start time), so a reused pid or a tab that moved to another renderer shows as stale.
struct TabMeasurement: Sendable {
    let measuredAt: Date
    /// Keyed by `key(for:)`, which includes the title, so a reordered tab list can't misattribute.
    let procIDByTab: [String: String]
    let ambiguousTabs: Set<String>

    static func key(for tab: BrowserTab) -> String {
        tab.id + "\u{1F}" + TabMatcher.normalize(tab.title)
    }
}

enum MeasureState {
    case idle
    case running
    case needsAccessibility
    case needsTaskManager
    case failed(String)
    case done(TabMeasurement)
}

enum LoginItemState: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case notInstalled
}

enum Bytes {
    private static let locale = Locale(identifier: "id_ID")

    static func format(_ value: UInt64) -> String {
        let mb = Double(value) / 1_048_576
        if mb >= 1024 {
            return (mb / 1024).formatted(.number.precision(.fractionLength(2)).locale(locale)) + " GB"
        }
        return mb.formatted(.number.precision(.fractionLength(mb < 10 ? 1 : 0)).locale(locale)) + " MB"
    }
}
