import AppKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class MonitorStore {
    private(set) var system = SystemStats()
    private(set) var groups: [AppGroup] = []
    private(set) var unreadableCount = 0
    private(set) var tabStates: [String: TabState] = [:]

    /// Popover visible → sample every 3 s; hidden → every 15 s (menu bar label only).
    /// Driven by key-window notifications: MenuBarExtra keeps its content view alive,
    /// so onAppear/onDisappear can't be trusted for open/close.
    private(set) var isPopoverOpen = false {
        didSet {
            if isPopoverOpen && !oldValue {
                wakeRequested = true
                refreshLoginItem()   // the user may have changed it in System Settings
            }
        }
    }

    private(set) var measureStates: [String: MeasureState] = [:]
    private(set) var loginItem: LoginItemState = .disabled
    private(set) var loginItemError: String?

    private let sampler = ProcessSampler()
    private var isSampling = false
    private var wakeRequested = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var measureTasks: [String: Task<Void, Never>] = [:]

    init() {
        refreshLoginItem()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPopoverOpen = true }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPopoverOpen = false }
        })
    }

    var maxFootprint: UInt64 { groups.map(\.footprint).max() ?? 1 }

    /// Single sampling loop for the app's lifetime; a second caller returns immediately.
    func run() async {
        guard !isSampling else { return }
        isSampling = true
        defer { isSampling = false }
        while !Task.isCancelled {
            await refresh()
            // Sleep in 1 s slices so opening the popover refreshes right away.
            var waited = 0
            while !Task.isCancelled, !wakeRequested, waited < (isPopoverOpen ? 3 : 15) {
                try? await Task.sleep(for: .seconds(1))
                waited += 1
            }
            wakeRequested = false
        }
    }

    func refresh() async {
        let snapshot = await sampler.sample()
        system = snapshot.system
        unreadableCount = snapshot.unreadableCount
        groups = Self.stableOrder(previous: groups, next: snapshot.groups)
    }

    /// Keeps the previous row order unless an app grows past its neighbour by more than 5 %,
    /// so rows don't jump under the pointer every tick.
    private static func stableOrder(previous: [AppGroup], next: [AppGroup]) -> [AppGroup] {
        let byID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        var ordered = previous.compactMap { byID[$0.id] }
        let known = Set(ordered.map(\.id))
        ordered += next.filter { !known.contains($0.id) }
        guard ordered.count > 1 else { return ordered }
        for i in 1..<ordered.count {
            var j = i
            while j > 0, Double(ordered[j].footprint) > Double(ordered[j - 1].footprint) * 1.05 {
                ordered.swapAt(j, j - 1)
                j -= 1
            }
        }
        return ordered
    }

    static func pressureColor(_ s: SystemStats) -> Color {
        let free = Double(s.total) - Double(s.used)
        if s.swapUsed > s.swapTotal / 2 || free < Double(s.total) * 0.05 { return .red }
        if s.swapUsed > 0 || free < Double(s.total) * 0.15 { return .orange }
        return .green
    }

    // MARK: - Tabs

    static func isBrowser(_ group: AppGroup) -> Bool {
        group.bundleID.map { BrowserTabReader.supported[$0] != nil } ?? false
    }

    func loadTabs(bundleID: String) async {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false else {
            tabStates[bundleID] = .notRunning
            return
        }
        if case .loaded = tabStates[bundleID] {} else { tabStates[bundleID] = .loading }
        do {
            tabStates[bundleID] = .loaded(try await BrowserTabReader.readTabs(bundleID: bundleID))
        } catch is CancellationError {
            if case .loading = tabStates[bundleID] { tabStates[bundleID] = nil }
        } catch TabReadError.notAuthorized {
            tabStates[bundleID] = .notAuthorized
        } catch TabReadError.notRunning {
            tabStates[bundleID] = .notRunning
        } catch TabReadError.timeout {
            tabStates[bundleID] = .failed("The browser didn't respond in time.")
        } catch TabReadError.failed(let message) {
            tabStates[bundleID] = .failed(message)
        } catch {
            tabStates[bundleID] = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Per-tab memory

extension MonitorStore {
    static func supportsTabMemory(_ bundleID: String) -> Bool {
        BrowserTabReader.supported[bundleID] == .chromium
    }

    /// Single-flight per browser: a second tap while measuring is ignored.
    func measureTabs(bundleID: String) {
        guard measureTasks[bundleID] == nil else { return }
        measureTasks[bundleID] = Task {
            await performMeasure(bundleID)
            measureTasks[bundleID] = nil
        }
    }

    private func performMeasure(_ bundleID: String) async {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            tabStates[bundleID] = .notRunning
            measureStates[bundleID] = .idle
            return
        }
        guard TaskManagerReader.isTrusted(prompt: true) else {
            measureStates[bundleID] = .needsAccessibility
            return
        }
        measureStates[bundleID] = .running
        await refresh()
        guard let group = groups.first(where: { $0.bundleID == bundleID }) else {
            measureStates[bundleID] = .failed("Couldn't find the browser's processes.")
            return
        }
        let procIDByPid = Dictionary(group.processes.map { ($0.pid, $0.id) }, uniquingKeysWith: { first, _ in first })

        do {
            let rows = try await TaskManagerReader.read(browserPid: app.processIdentifier,
                                                        livePids: Set(procIDByPid.keys))
            // Tabs are read right after the AX snapshot so titles drift as little as possible.
            let tabs = try await BrowserTabReader.readTabs(bundleID: bundleID)
            tabStates[bundleID] = .loaded(tabs)

            var procIDByTab: [String: String] = [:]
            var ambiguous = Set<String>()
            let tabsByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
            for (tabID, match) in TabMatcher.match(rows: rows, tabs: tabs) {
                guard let tab = tabsByID[tabID], let procID = procIDByPid[match.pid] else { continue }
                let key = TabMeasurement.key(for: tab)
                procIDByTab[key] = procID
                if match.ambiguous { ambiguous.insert(key) }
            }
            measureStates[bundleID] = procIDByTab.isEmpty
                ? .failed("Read the Task Manager, but no rows matched a tab title.")
                : .done(TabMeasurement(measuredAt: Date(), procIDByTab: procIDByTab, ambiguousTabs: ambiguous))
        } catch TaskManagerReader.Failure.notTrusted {
            measureStates[bundleID] = .needsAccessibility
        } catch TaskManagerReader.Failure.windowNotFound {
            measureStates[bundleID] = .needsTaskManager
        } catch TaskManagerReader.Failure.tableNotFound(let dump), TaskManagerReader.Failure.noPidColumn(let dump) {
            measureStates[bundleID] = .failed("Task Manager layout not recognized."
                + (dump.map { " Details saved to \($0.replacingOccurrences(of: NSHomeDirectory(), with: "~"))." } ?? ""))
        } catch TaskManagerReader.Failure.timeout {
            measureStates[bundleID] = .failed("Task Manager isn't responding.")
        } catch TabReadError.notAuthorized {
            tabStates[bundleID] = .notAuthorized
            measureStates[bundleID] = .idle
        } catch {
            measureStates[bundleID] = .failed("Couldn't read tabs: \(error)")
        }
    }

    // MARK: - Launch at login

    func refreshLoginItem() {
        let path = Bundle.main.bundlePath
        // Registering a copy in a temporary build folder would leave a dead login item behind.
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") else {
            loginItem = .notInstalled
            return
        }
        switch SMAppService.mainApp.status {
        case .enabled: loginItem = .enabled
        case .requiresApproval: loginItem = .requiresApproval
        default: loginItem = .disabled
        }
    }

    func setLoginItem(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItem()
    }
}

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String?) -> NSImage? {
        guard let path else { return nil }
        if let icon = cache[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}
