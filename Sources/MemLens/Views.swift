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
            List {
                Section {
                    SummaryHeader()
                }
                Section("Aplikasi") {
                    ForEach(store.groups) { group in
                        NavigationLink(value: group.id) {
                            AppRow(group: group, maxFootprint: store.maxFootprint)
                        }
                    }
                }
            }
            .navigationDestination(for: AppGroup.ID.self) { id in
                if let group = store.groups.first(where: { $0.id == id }) {
                    AppDetailView(group: group)
                } else {
                    ContentUnavailableView("Aplikasi sudah ditutup", systemImage: "xmark.app")
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
            Toggle("Buka saat login", isOn: Binding(
                get: { store.loginItem == .enabled || store.loginItem == .requiresApproval },
                set: { store.setLoginItem($0) }
            ))
            .toggleStyle(.checkbox)
            .disabled(store.loginItem == .notInstalled)
            .help(store.loginItem == .notInstalled
                  ? "Pasang dulu ke ~/Applications: ./build.sh --install"
                  : (store.loginItemError ?? "Jalankan MemLens otomatis setelah login"))
            if store.loginItem == .requiresApproval {
                Button("Setujui di Settings") { SMAppService.openSystemSettingsLoginItems() }
            }
            Spacer()
            Button("Activity Monitor") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            Button("Keluar") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if let error = store.loginItemError {
                Text("Gagal mengatur buka saat login: \(error)")
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
                Text("dari \(Bytes.format(s.total)) terpakai").foregroundStyle(.secondary)
            }
            ProgressView(value: Double(s.used), total: Double(max(s.total, 1)))
                .tint(MonitorStore.pressureColor(s))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    stat("App", s.appMemory)
                    stat("Dikompres", s.compressed)
                }
                GridRow {
                    stat("Wired", s.wired)
                    stat("Cache file", s.cached)
                }
                GridRow {
                    Text("Swap").foregroundStyle(.secondary)
                    Text("\(Bytes.format(s.swapUsed)) / \(Bytes.format(s.swapTotal))").monospacedDigit()
                }
            }
            .font(.caption)
            if store.unreadableCount > 0 {
                Text("\(store.unreadableCount) proses sistem tidak terbaca (butuh admin), mis. WindowServer.")
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
                Text(group.processes.count == 1 ? "1 proses" : "\(group.processes.count) proses")
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
            Section("Proses · \(group.processes.count)") {
                let titles = tabTitlesByProc
                ForEach(group.processes) { ProcessRow(process: $0, tabTitles: titles[$0.id] ?? []) }
            }
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

    /// Process id → titles of the tabs the last measurement put in it.
    private var tabTitlesByProc: [String: [String]] {
        guard let id = group.bundleID,
              case .done(let measurement) = store.measureStates[id],
              case .loaded(let tabs) = store.tabStates[id] else { return [:] }
        var result: [String: [String]] = [:]
        for tab in tabs {
            if let procID = measurement.procIDByTab[TabMeasurement.key(for: tab)] {
                result[procID, default: []].append(tab.isPrivate ? "Tab incognito" : tab.title)
            }
        }
        return result
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIcon(path: group.bundlePath, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.headline)
                Text([group.version.map { "Versi \($0)" }, group.bundlePath].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Bytes.format(group.footprint)).font(.headline).monospacedDigit()
                Text("jumlah \(group.processes.count) proses").font(.caption).foregroundStyle(.secondary)
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
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }

    private var label: String {
        switch kind {
        case "renderer": "Tab / halaman"
        case "gpu-process": "GPU"
        case "extension": "Ekstensi"
        case "utility:network.mojom.NetworkService": "Jaringan"
        case "utility:storage.mojom.StorageService": "Storage"
        case "utility:audio.mojom.AudioService": "Audio"
        case let k where k.hasPrefix("utility"): "Utility"
        default: kind
        }
    }

    private var color: Color {
        switch kind {
        case "renderer": .blue
        case "gpu-process": .orange
        case "extension": .purple
        default: .gray
        }
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
                    Text("Tab · \(tabs.count)")
                } else {
                    Text("Tab")
                }
                Spacer()
                if canMeasure {
                    Button {
                        store.measureTabs(bundleID: bundleID)
                    } label: {
                        Label("Ukur memory per tab", systemImage: "gauge.with.dots.needle.50percent")
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
                .help("Muat ulang daftar tab")
            }
        } footer: {
            Text(canMeasure
                 ? "Memory tab = proses renderer utamanya. Iframe lintas situs berjalan di proses terpisah dan tidak ikut terhitung."
                 : "Safari tidak punya Task Manager, jadi memory per tab tidak tersedia.")
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
            HStack { ProgressView().controlSize(.small); Text("Membaca Task Manager…").foregroundStyle(.secondary) }
        case .needsAccessibility:
            AccessibilityCard()
        case .needsTaskManager:
            VStack(alignment: .leading, spacing: 4) {
                Label("Buka Task Manager browser dulu", systemImage: "list.bullet.rectangle").font(.headline)
                Text("Di \(group.name): menu Window → Task Manager. Biarkan jendelanya terbuka, lalu tekan \"Ukur memory per tab\" lagi.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
        case .done(let m):
            TimelineView(.periodic(from: .now, by: 10)) { context in
                // Tabs move between renderers on navigation; an old mapping can point at the wrong process.
                let old = context.date.timeIntervalSince(m.measuredAt) > 300
                Text("Diukur \(m.measuredAt.formatted(.relative(presentation: .named, unitsStyle: .wide).locale(Locale(identifier: "id_ID")))) · \(m.procIDByTab.count) tab cocok"
                     + (old ? " · sudah lama, ukur ulang" : ""))
                    .font(.caption).foregroundStyle(old ? .orange : .secondary)
            }
        }
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
            HStack { ProgressView().controlSize(.small); Text("Membaca tab…").foregroundStyle(.secondary) }
        case .notRunning:
            Label("Browser tidak berjalan", systemImage: "moon.zzz").foregroundStyle(.secondary)
        case .notAuthorized:
            PermissionCard()
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        case .loaded(let tabs) where tabs.isEmpty:
            Text("Tidak ada tab").foregroundStyle(.secondary)
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
                        Text("Jendela \(window) · \(windowTabs.count) tab")
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
                Text(tab.title.isEmpty ? "(tanpa judul)" : tab.title).lineLimit(1)
                Text(tab.isPrivate ? "Incognito, URL disembunyikan" : (tab.url.isEmpty ? "URL tidak ditampilkan" : tab.host))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if tab.isActive {
                Text("Aktif").font(.caption2.weight(.medium))
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
            Text("ukur ulang").font(.caption2).foregroundStyle(.tertiary)
        case .notFound:
            Text("tidur / tak terukur").font(.caption2).foregroundStyle(.tertiary)
        case .bytes(let bytes, let sharedWith, let ambiguous):
            VStack(alignment: .trailing, spacing: 0) {
                Text(Bytes.format(bytes)).monospacedDigit()
                if ambiguous {
                    Text("judul kembar, ambigu").font(.caption2).foregroundStyle(.orange)
                } else if sharedWith > 1 {
                    Text("dibagi \(sharedWith) tab").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AccessibilityCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Izinkan MemLens di Accessibility", systemImage: "accessibility").font(.headline)
            Text("MemLens perlu izin ini untuk membaca jendela Task Manager browser (hanya membaca, tidak menekan apa pun). Nyalakan MemLens di Privacy & Security → Accessibility. Kalau sudah diizinkan tapi belum jalan, keluar lalu buka lagi MemLens.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Buka pengaturan Accessibility") {
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
            Label("MemLens belum diizinkan membaca tab", systemImage: "lock.shield").font(.headline)
            Text("Buka System Settings → Privacy & Security → Automation, lalu nyalakan browser ini di bawah MemLens. Kalau tidak muncul, jalankan di Terminal:")
                .font(.caption).foregroundStyle(.secondary)
            Text("tccutil reset AppleEvents id.underline.memlens")
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Button("Buka pengaturan Automation") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
