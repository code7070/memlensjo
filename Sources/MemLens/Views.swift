import AppKit
import ServiceManagement
import SwiftUI

/// Popover content shown from the menu bar item.
struct ContentView: View {
    @Environment(MonitorStore.self) private var store
    @State private var path: [AppGroup.ID] = []
    @State private var closedAt: Date?

    var body: some View {
        NavigationStack(path: $path) {
            // Once per render, not once per row.
            let maxFootprint = store.maxFootprint
            List {
                Section {
                    SummaryHeader()
                }
                Section("Apps") {
                    ForEach(store.groups) { group in
                        NavigationLink(value: group.id) {
                            AppRow(group: group, maxFootprint: maxFootprint)
                        }
                    }
                }
            }
            .navigationDestination(for: AppGroup.ID.self) { id in
                if let group = store.groups.first(where: { $0.id == id }) {
                    AppDetailView(group: group)
                } else {
                    ContentUnavailableView("App Has Quit", systemImage: "xmark.app")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { Footer() }
        .frame(width: 460, height: 640)
        // Back to the app list only after a longer break, so a quick trip to the
        // browser (to open its Task Manager) returns to the same detail page.
        .onChange(of: store.isPopoverOpen) { _, isOpen in
            if isOpen {
                if let closedAt, Date().timeIntervalSince(closedAt) > 60 { path = [] }
            } else {
                closedAt = Date()
            }
        }
    }
}

struct Footer: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Open at Login", isOn: Binding(
                get: { store.loginItem == .enabled || store.loginItem == .requiresApproval },
                set: { store.setLoginItem($0) }
            ))
            .toggleStyle(.checkbox)
            .disabled(store.loginItem == .notInstalled)
            .help(store.loginItem == .notInstalled
                  ? "Install to ~/Applications or /Applications first: ./build.sh --install"
                  : (store.loginItemError ?? "Start MemLens automatically when you log in"))
            if store.loginItem == .requiresApproval {
                Button("Approve in Settings") { SMAppService.openSystemSettingsLoginItems() }
            }
            Spacer()
            Button("Activity Monitor") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if let error = store.loginItemError {
                Text("Couldn't change Open at Login: \(error)")
                    .font(.caption2).foregroundStyle(.red).lineLimit(2)
                    .padding(.horizontal, 12).offset(y: -18)
            }
        }
        .background(.bar)
    }
}

// MARK: - Summary

struct SummaryHeader: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        let s = store.system
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Bytes.format(s.used)).font(.title2.weight(.semibold)).monospacedDigit()
                Text("of \(Bytes.format(s.total)) used").foregroundStyle(.secondary)
            }
            ProgressView(value: Double(s.used), total: Double(max(s.total, 1)))
                .tint(MonitorStore.pressureColor(s))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    stat("App", s.appMemory)
                    stat("Compressed", s.compressed)
                }
                GridRow {
                    stat("Wired", s.wired)
                    stat("Cached Files", s.cached)
                }
                GridRow {
                    Text("Swap").foregroundStyle(.secondary)
                    Text("\(Bytes.format(s.swapUsed)) / \(Bytes.format(s.swapTotal))").monospacedDigit()
                }
            }
            .font(.caption)
            if store.unreadableCount > 0 {
                Text("\(plural(store.unreadableCount, "system process", "system processes")) can't be read without admin rights, e.g. WindowServer.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func stat(_ label: String, _ value: UInt64) -> some View {
        Text(label).foregroundStyle(.secondary)
        Text(Bytes.format(value)).monospacedDigit()
    }
}

struct AppRow: View {
    let group: AppGroup
    let maxFootprint: UInt64

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(path: group.bundlePath, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(group.name).lineLimit(1)
                    Spacer()
                    Text(Bytes.format(group.footprint)).monospacedDigit().foregroundStyle(.secondary)
                }
                // Relative to the biggest app: footprints include compressed pages, so they don't sum to RAM.
                GeometryReader { geo in
                    Capsule().fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.accentColor.opacity(0.8))
                                .frame(width: geo.size.width * CGFloat(group.footprint) / CGFloat(max(maxFootprint, 1)))
                        }
                }
                .frame(height: 4)
                Text(plural(group.processes.count, "process", "processes"))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct AppIcon: View {
    let path: String?
    let size: CGFloat

    var body: some View {
        if let image = IconCache.icon(for: path) {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "gearshape").font(.system(size: size * 0.6))
                .frame(width: size, height: size).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Detail

struct AppDetailView: View {
    let group: AppGroup

    var body: some View {
        List {
            Section { header }
            if MonitorStore.isBrowser(group), let bundleID = group.bundleID {
                TabsSection(bundleID: bundleID, group: group)
            }
            processSection
        }
        .navigationTitle(group.name)
        // On the List (not the Section) so it runs once per app, not once per row.
        .task(id: group.bundleID) {
            if MonitorStore.isBrowser(group), let bundleID = group.bundleID {
                await store.loadTabs(bundleID: bundleID)
            }
        }
    }

    @Environment(MonitorStore.self) private var store
    /// Selected process role; nil = all. Survives the 3 s refreshes.
    @State private var filter: ProcessCategory?

    @ViewBuilder
    private var processSection: some View {
        let categories = ProcessCategory.present(in: group.processes, keeping: filter)
        let shown = filter.map { f in group.processes.filter { ProcessCategory(kind: $0.kind).id == f.id } }
            ?? group.processes
        Section {
            let titles = tabTitlesByProc
            ForEach(shown) { ProcessRow(process: $0, tabTitles: titles[$0.id] ?? []) }
            if shown.isEmpty {
                // The selection stays in the picker so the list can't silently narrow again when the role returns.
                Text("No processes of this type right now").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(filter == nil ? "Processes · \(group.processes.count)"
                                   : "Processes · \(shown.count) of \(group.processes.count)")
                Spacer()
                if categories.count > 1 || filter != nil {
                    // No counts in the items: titles that change every 3 s would reflow the open menu.
                    Picker("Type", selection: $filter) {
                        Text("All").tag(ProcessCategory?.none)
                        Divider()
                        ForEach(categories) { category in
                            Text(category.label).tag(Optional(category))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }
        }
    }

    /// Process id → titles of the tabs the last measurement put in it.
    private var tabTitlesByProc: [String: [String]] {
        guard let id = group.bundleID,
              case .done(let measurement) = store.measureStates[id],
              case .loaded(let tabs) = store.tabStates[id] else { return [:] }
        var result: [String: [String]] = [:]
        for tab in tabs {
            if let procID = measurement.procIDByTab[TabMeasurement.key(for: tab)] {
                result[procID, default: []].append(tab.isPrivate ? "Private tab" : tab.title)
            }
        }
        return result
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIcon(path: group.bundlePath, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.headline)
                Text([group.version.map { "Version \($0)" }, group.bundlePath].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Bytes.format(group.footprint)).font(.headline).monospacedDigit()
                Text("in \(plural(group.processes.count, "process", "processes"))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ProcessRow: View {
    let process: ProcSample
    var tabTitles: [String] = []

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(process.name).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("PID \(String(process.pid))").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    if let kind = process.kind { KindBadge(kind: kind) }
                }
                if !tabTitles.isEmpty {
                    Text(tabTitles.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.blue).lineLimit(2)
                }
            }
            Spacer()
            Text(Bytes.format(process.footprint)).monospacedDigit()
        }
        .help(process.path)
    }
}

struct KindBadge: View {
    let kind: String

    var body: some View {
        let category = ProcessCategory(kind: kind)
        Text(category.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(category.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(category.color)
    }
}

/// Display group for a Chromium/Electron process role: the badge and the process-type picker.
struct ProcessCategory: Identifiable, Hashable {
    /// Stable key, separate from the label so a raw kind can't collide with a named category.
    let id: String
    let label: String
    let color: Color
    /// Fixed position, so picker items don't reorder between refreshes.
    let order: Int

    init(kind: String?) {
        let v: (id: String, label: String, color: Color, order: Int)
        switch kind {
        // No --type= argument: the browser's or Electron app's main process.
        case nil: v = ("_main", "Main", .gray, 0)
        case "renderer"?: v = ("renderer", "Tab / page", .blue, 1)
        case "extension"?: v = ("extension", "Extension", .purple, 2)
        case "gpu-process"?: v = ("gpu-process", "GPU", .orange, 3)
        case "utility:network.mojom.NetworkService"?: v = ("network", "Network", .gray, 4)
        case "utility:storage.mojom.StorageService"?: v = ("storage", "Storage", .gray, 5)
        case "utility:audio.mojom.AudioService"?: v = ("audio", "Audio", .gray, 6)
        case let k? where k.hasPrefix("utility"): v = ("_utility", "Utility", .gray, 7)
        case let k?: v = ("raw:" + k, k, .gray, 8)
        }
        (id, label, color, order) = (v.id, v.label, v.color, v.order)
    }

    /// Categories present in `processes`, in fixed order. A selected category that no longer
    /// has processes is kept so the selection stays valid and visible.
    static func present(in processes: [ProcSample], keeping selected: ProcessCategory?) -> [ProcessCategory] {
        var byID: [String: ProcessCategory] = [:]
        for process in processes {
            let category = ProcessCategory(kind: process.kind)
            byID[category.id] = category
        }
        if let selected { byID[selected.id] = selected }
        return byID.values.sorted { ($0.order, $0.label) < ($1.order, $1.label) }
    }
}

// MARK: - Tabs

enum TabMemory {
    case bytes(UInt64, sharedWith: Int, ambiguous: Bool)
    case stale
    /// Measured, but no Task Manager row: usually a sleeping/discarded tab, or a title that changed.
    case notFound
    case unmeasured
}

struct TabsSection: View {
    let bundleID: String
    let group: AppGroup
    @Environment(MonitorStore.self) private var store

    private var canMeasure: Bool { MonitorStore.supportsTabMemory(bundleID) }

    var body: some View {
        Section {
            if canMeasure { measureStatus }
            content
        } header: {
            HStack {
                if case .loaded(let tabs) = store.tabStates[bundleID] {
                    Text("Tabs · \(tabs.count)")
                } else {
                    Text("Tabs")
                }
                Spacer()
                if canMeasure {
                    Button {
                        store.measureTabs(bundleID: bundleID)
                    } label: {
                        Label("Measure Tab Memory", systemImage: "gauge.with.dots.needle.50percent")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isRunning)
                }
                Button {
                    Task { await store.loadTabs(bundleID: bundleID) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload tab list")
            }
        } footer: {
            Text(canMeasure
                 ? "A tab's memory is its main renderer process. Cross-site iframes run in separate processes and aren't counted."
                 : "Safari has no Task Manager, so per-tab memory isn't available.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var isRunning: Bool {
        if case .running = store.measureStates[bundleID] { return true }
        return false
    }

    private var measurement: TabMeasurement? {
        if case .done(let m) = store.measureStates[bundleID] { return m }
        return nil
    }

    @ViewBuilder
    private var measureStatus: some View {
        switch store.measureStates[bundleID] ?? .idle {
        case .idle:
            EmptyView()
        case .running:
            HStack { ProgressView().controlSize(.small); Text("Reading Task Manager…").foregroundStyle(.secondary) }
        case .needsAccessibility:
            AccessibilityCard()
        case .needsTaskManager:
            VStack(alignment: .leading, spacing: 4) {
                Label("Open the Browser's Task Manager", systemImage: "list.bullet.rectangle").font(.headline)
                Text("In \(group.name), choose Window → Task Manager. Keep it open, then click \"Measure Tab Memory\" again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
        case .done(let m):
            // The clock only ticks while the popover is visible; a hidden detail page stays still.
            if store.isPopoverOpen {
                TimelineView(.periodic(from: .now, by: 10)) { context in measuredLine(m, now: context.date) }
            } else {
                measuredLine(m, now: .now)
            }
        }
    }

    private func measuredLine(_ m: TabMeasurement, now: Date) -> some View {
        // Tabs move between renderers on navigation; an old mapping can point at the wrong process.
        let old = now.timeIntervalSince(m.measuredAt) > 300
        let when = m.measuredAt.formatted(.relative(presentation: .named, unitsStyle: .wide).locale(Locale(identifier: "en_US")))
        return Text("Measured \(when) · \(plural(m.procIDByTab.count, "tab", "tabs")) matched"
                    + (old ? " · outdated, measure again" : ""))
            .font(.caption).foregroundStyle(old ? .orange : .secondary)
    }

    private func memory(for tab: BrowserTab, procs: [String: ProcSample], sharers: [String: Int]) -> TabMemory {
        guard let m = measurement else { return .unmeasured }
        let key = TabMeasurement.key(for: tab)
        guard let procID = m.procIDByTab[key] else { return .notFound }
        // The process exited or the pid was reused: the old number would be someone else's.
        guard let proc = procs[procID] else { return .stale }
        return .bytes(proc.footprint, sharedWith: sharers[procID] ?? 1, ambiguous: m.ambiguousTabs.contains(key))
    }

    @ViewBuilder
    private var content: some View {
        switch store.tabStates[bundleID] {
        case .none, .loading:
            HStack { ProgressView().controlSize(.small); Text("Reading tabs…").foregroundStyle(.secondary) }
        case .notRunning:
            Label("Browser isn't running", systemImage: "moon.zzz").foregroundStyle(.secondary)
        case .notAuthorized:
            PermissionCard()
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        case .loaded(let tabs) where tabs.isEmpty:
            Text("No tabs").foregroundStyle(.secondary)
        case .loaded(let tabs):
            if let m = measurement {
                // Measured: one list, biggest first.
                let procs = Dictionary(uniqueKeysWithValues: group.processes.map { ($0.id, $0) })
                let sharers = Dictionary(m.procIDByTab.values.map { ($0, 1) }, uniquingKeysWith: +)
                let rows = tabs.map { ($0, memory(for: $0, procs: procs, sharers: sharers)) }
                    .sorted { Self.sortValue($0.1) > Self.sortValue($1.1) }
                ForEach(rows, id: \.0.id) { tab, mem in TabRow(tab: tab, memory: mem) }
            } else {
                let windows = Dictionary(grouping: tabs, by: \.window).sorted { $0.key < $1.key }
                ForEach(windows, id: \.key) { window, windowTabs in
                    if windows.count > 1 {
                        Text("Window \(window) · \(plural(windowTabs.count, "tab", "tabs"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(windowTabs) { TabRow(tab: $0, memory: .unmeasured) }
                }
            }
        }
    }

    private static func sortValue(_ m: TabMemory) -> UInt64 {
        if case .bytes(let b, _, _) = m { return b }
        return 0
    }
}

struct TabRow: View {
    let tab: BrowserTab
    let memory: TabMemory

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.isPrivate ? "eyeglasses" : "globe")
                .foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title.isEmpty ? "(Untitled)" : tab.title).lineLimit(1)
                Text(tab.isPrivate ? "Private window, URL hidden" : (tab.url.isEmpty ? "URL not shown" : tab.host))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if tab.isActive {
                Text("Active").font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.green)
            }
            memoryLabel
        }
        .help(tab.isPrivate ? tab.title : tab.host)
    }

    @ViewBuilder
    private var memoryLabel: some View {
        switch memory {
        case .unmeasured:
            EmptyView()
        case .stale:
            Text("measure again").font(.caption2).foregroundStyle(.tertiary)
        case .notFound:
            Text("asleep / not found").font(.caption2).foregroundStyle(.tertiary)
        case .bytes(let bytes, let sharedWith, let ambiguous):
            VStack(alignment: .trailing, spacing: 0) {
                Text(Bytes.format(bytes)).monospacedDigit()
                if ambiguous {
                    Text("ambiguous match").font(.caption2).foregroundStyle(.orange)
                } else if sharedWith > 1 {
                    Text("shared by \(sharedWith) tabs").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AccessibilityCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Allow MemLens in Accessibility", systemImage: "accessibility").font(.headline)
            Text("MemLens needs this to read the browser's Task Manager window. It only reads and never clicks anything. Turn on MemLens in Privacy & Security → Accessibility. If it's already on but still not working, quit and reopen MemLens.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open Accessibility Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct PermissionCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("MemLens Can't Read Tabs Yet", systemImage: "lock.shield").font(.headline)
            Text("Open System Settings → Privacy & Security → Automation and turn on this browser under MemLens. If it isn't listed, run this in Terminal:")
                .font(.caption).foregroundStyle(.secondary)
            Text("tccutil reset AppleEvents id.underline.memlens")
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Button("Open Automation Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// "1 process", "3 processes".
func plural(_ count: Int, _ singular: String, _ plural: String) -> String {
    "\(count) \(count == 1 ? singular : plural)"
}
