import SwiftUI

@main
struct MemLensApp: App {
    private let store: MonitorStore

    init() {
        let store = MonitorStore()
        self.store = store
        // One sampling loop for the app's lifetime, independent of whether the popover is open,
        // so the menu bar label stays current.
        Task { await store.run() }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let store: MonitorStore

    var body: some View {
        // Menu bar labels render as template images; the text carries the state.
        HStack(spacing: 3) {
            Image(systemName: "memorychip")
            Text(store.system.total > 0 ? Bytes.format(store.system.used) : "…")
                .monospacedDigit()
        }
    }
}
